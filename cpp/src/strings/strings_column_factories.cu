/*
 * Copyright (c) 2019-2024, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cudf/column/column.hpp>
#include <cudf/column/column_factories.hpp>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/detail/utilities/vector_factories.hpp>
#include <cudf/detail/valid_if.cuh>
#include <cudf/strings/detail/strings_column_factories.cuh>
#include <cudf/utilities/error.hpp>
#include <cudf/utilities/span.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/device_uvector.hpp>
#include <rmm/exec_policy.hpp>

#include <cuda/functional>

namespace cudf {

namespace strings::detail {

namespace {

using string_pair         = thrust::pair<char const*, size_type>;
using column_string_pairs = cudf::device_span<string_pair const>;

template <typename OutputType>
std::pair<std::vector<std::unique_ptr<column>>, rmm::device_uvector<int64_t>>
make_offsets_child_column_batch_async(std::vector<column_string_pairs> const& input,
                                      rmm::cuda_stream_view stream,
                                      rmm::device_async_resource_ref mr)
{
  auto const num_columns = input.size();
  std::vector<std::unique_ptr<column>> offsets_columns(num_columns);
  rmm::device_uvector<int64_t> chars_sizes(num_columns, stream);
  for (std::size_t idx = 0; idx < num_columns; ++idx) {
    auto const string_pairs = input[idx];
    auto const string_count = static_cast<size_type>(string_pairs.size());
    auto offsets            = make_numeric_column(
      data_type{type_to_id<OutputType>()}, string_count + 1, mask_state::UNALLOCATED, stream, mr);

    auto const offsets_transformer = cuda::proclaim_return_type<size_type>(
      [string_count, string_pairs = string_pairs.data()] __device__(size_type idx) -> size_type {
        return idx < string_count ? string_pairs[idx].second : size_type{0};
      });
    auto const input_it  = cudf::detail::make_counting_transform_iterator(0, offsets_transformer);
    auto const d_offsets = offsets->mutable_view().template data<OutputType>();
    auto const output_it = cudf::detail::make_sizes_to_offsets_iterator(
      d_offsets, d_offsets + string_count + 1, chars_sizes.data() + idx);
    thrust::exclusive_scan(rmm::exec_policy_nosync(stream),
                           input_it,
                           input_it + string_count + 1,
                           output_it,
                           int64_t{0});
    offsets_columns[idx] = std::move(offsets);
  }

  return {std::move(offsets_columns), std::move(chars_sizes)};
}

std::pair<std::vector<rmm::device_buffer>, rmm::device_uvector<size_type>> valid_if_batch_async(
  std::vector<column_string_pairs> const& input,
  rmm::cuda_stream_view stream,
  rmm::device_async_resource_ref mr)
{
  auto const d_input =
    cudf::detail::make_device_uvector_async(input, stream, cudf::get_current_device_resource_ref());
  auto const is_valid_fn = [input = d_input.data()] __device__(size_type col_idx,
                                                               size_type row_idx) -> bool {
    return input[col_idx][row_idx].first != nullptr;
  };
  auto const mask_size_fn = cudf::detail::make_counting_transform_iterator(
    0,
    cuda::proclaim_return_type<size_type>([input = d_input.data()] __device__(size_type col_idx) {
      return static_cast<size_type>(input[col_idx].size());
    }));

  auto const num_columns = input.size();
  std::vector<rmm::device_buffer> null_masks(num_columns);
  for (std::size_t idx = 0; idx < num_columns; ++idx) {
    null_masks[idx] = cudf::create_null_mask(
      static_cast<size_type>(input[idx].size()), mask_state::UNINITIALIZED, stream, mr);
  }
  std::vector<bitmask_type*> h_masks(num_columns);
  std::transform(null_masks.begin(), null_masks.end(), h_masks.begin(), [](auto& mask) {
    return reinterpret_cast<bitmask_type*>(mask.data());
  });
  auto d_masks = cudf::detail::make_device_uvector_async(
    h_masks, stream, cudf::get_current_device_resource_ref());

  rmm::device_uvector<size_type> valid_counts(num_columns, stream, mr);
  thrust::uninitialized_fill(
    rmm::exec_policy_nosync(stream), valid_counts.begin(), valid_counts.end(), 0);
  auto const counting_it = thrust::make_counting_iterator(0);

  constexpr size_type block_size{256};
  auto const grid = cudf::detail::grid_1d{static_cast<int64_t>(num_columns), block_size};
  cudf::detail::valid_if_n_kernel<block_size>
    <<<grid.num_blocks, grid.num_threads_per_block, 0, stream.value()>>>(
      counting_it,
      counting_it,
      is_valid_fn,
      d_masks.data(),
      static_cast<size_type>(num_columns),
      mask_size_fn,
      valid_counts.data());

  return {std::move(null_masks), std::move(valid_counts)};
}

}  // namespace

std::vector<std::unique_ptr<column>> make_strings_column_batch(
  std::vector<column_string_pairs> const& input,
  rmm::cuda_stream_view stream,
  rmm::device_async_resource_ref mr)
{
  auto [offsets_cols, d_chars_sizes] =
    make_offsets_child_column_batch_async<size_type>(input, stream, mr);
  auto [null_masks, d_valid_counts] = valid_if_batch_async(input, stream, mr);

  auto const chars_sizes  = cudf::detail::make_host_vector_async(d_chars_sizes, stream);
  auto const valid_counts = cudf::detail::make_host_vector_async(d_valid_counts, stream);

  // This should be the only stream sync in the entire API.
  stream.synchronize();

  auto const threshold = cudf::strings::get_offset64_threshold();
  auto const overflow_count =
    std::count_if(chars_sizes.begin(), chars_sizes.end(), [threshold](auto const chars_size) {
      return chars_size >= threshold;
    });
  CUDF_EXPECTS(cudf::strings::is_large_strings_enabled() || overflow_count == 0,
               "Size of output exceeds the column size limit",
               std::overflow_error);

  auto const num_columns = input.size();
  if (overflow_count > 0) {
    std::vector<column_string_pairs> long_string_input;
    std::vector<std::size_t> long_string_col_idx;
    long_string_input.reserve(overflow_count);
    long_string_col_idx.reserve(overflow_count);
    for (std::size_t idx = 0; idx < num_columns; ++idx) {
      if (chars_sizes[idx] >= threshold) {
        long_string_input.push_back(input[idx]);
        long_string_col_idx.push_back(idx);
      }
    }

    [[maybe_unused]] auto [new_offsets_cols, d_new_chars_sizes] =
      make_offsets_child_column_batch_async<int64_t>(long_string_input, stream, mr);

    // Update the new offsets columns.
    // The new chars sizes should be the same as before, thus we don't need to update them.
    for (std::size_t idx = 0; idx < long_string_col_idx.size(); ++idx) {
      offsets_cols[long_string_col_idx[idx]] = std::move(new_offsets_cols[idx]);
    }
  }

  std::vector<std::unique_ptr<column>> chars_cols(num_columns);
  std::vector<std::unique_ptr<column>> output(num_columns);
  for (std::size_t idx = 0; idx < num_columns; ++idx) {
    auto const strings_count = static_cast<size_type>(input[idx].size());
    if (strings_count == 0) {
      output[idx] = make_empty_column(type_id::STRING);
      continue;
    }

    auto const chars_size        = chars_sizes[idx];
    auto const valid_count       = valid_counts[idx];
    auto const avg_bytes_per_row = chars_size / std::max(valid_count, 1);

    auto chars_data = make_chars_column(offsets_cols[idx]->view(),
                                        chars_size,
                                        avg_bytes_per_row,
                                        input[idx].data(),
                                        strings_count,
                                        stream,
                                        mr);
    output[idx]     = make_strings_column(strings_count,
                                      std::move(offsets_cols[idx]),
                                      chars_data.release(),
                                      strings_count - valid_count,
                                      std::move(null_masks[idx]));
  }

  return output;
}

}  // namespace strings::detail

// Create a strings-type column from vector of pointer/size pairs
std::unique_ptr<column> make_strings_column(
  device_span<thrust::pair<char const*, size_type> const> strings,
  rmm::cuda_stream_view stream,
  rmm::device_async_resource_ref mr)
{
  CUDF_FUNC_RANGE();

  return cudf::strings::detail::make_strings_column(strings.begin(), strings.end(), stream, mr);
}

std::vector<std::unique_ptr<column>> make_strings_column_batch(
  std::vector<cudf::device_span<thrust::pair<char const*, size_type> const>> const& input,
  rmm::cuda_stream_view stream,
  rmm::device_async_resource_ref mr)
{
  CUDF_FUNC_RANGE();

  return cudf::strings::detail::make_strings_column_batch(input, stream, mr);
}

namespace {
struct string_view_to_pair {
  string_view null_placeholder;
  string_view_to_pair(string_view n) : null_placeholder(n) {}
  __device__ thrust::pair<char const*, size_type> operator()(string_view const& i)
  {
    return (i.data() == null_placeholder.data())
             ? thrust::pair<char const*, size_type>{nullptr, 0}
             : thrust::pair<char const*, size_type>{i.data(), i.size_bytes()};
  }
};

}  // namespace

std::unique_ptr<column> make_strings_column(device_span<string_view const> string_views,
                                            string_view null_placeholder,
                                            rmm::cuda_stream_view stream,
                                            rmm::device_async_resource_ref mr)
{
  CUDF_FUNC_RANGE();

  auto it_pair =
    thrust::make_transform_iterator(string_views.begin(), string_view_to_pair{null_placeholder});
  return cudf::strings::detail::make_strings_column(
    it_pair, it_pair + string_views.size(), stream, mr);
}

std::unique_ptr<column> make_strings_column(size_type num_strings,
                                            std::unique_ptr<column> offsets_column,
                                            rmm::device_buffer&& chars_buffer,
                                            size_type null_count,
                                            rmm::device_buffer&& null_mask)
{
  CUDF_FUNC_RANGE();

  if (null_count > 0) { CUDF_EXPECTS(null_mask.size() > 0, "Column with nulls must be nullable."); }
  CUDF_EXPECTS(num_strings == offsets_column->size() - 1,
               "Invalid offsets column size for strings column.");
  CUDF_EXPECTS(offsets_column->null_count() == 0, "Offsets column should not contain nulls");

  std::vector<std::unique_ptr<column>> children;
  children.emplace_back(std::move(offsets_column));

  return std::make_unique<column>(data_type{type_id::STRING},
                                  num_strings,
                                  std::move(chars_buffer),
                                  std::move(null_mask),
                                  null_count,
                                  std::move(children));
}

std::unique_ptr<column> make_strings_column(size_type num_strings,
                                            rmm::device_uvector<size_type>&& offsets,
                                            rmm::device_uvector<char>&& chars,
                                            rmm::device_buffer&& null_mask,
                                            size_type null_count)
{
  CUDF_FUNC_RANGE();

  if (num_strings == 0) { return make_empty_column(type_id::STRING); }

  auto const offsets_size = static_cast<size_type>(offsets.size());

  if (null_count > 0) CUDF_EXPECTS(null_mask.size() > 0, "Column with nulls must be nullable.");

  CUDF_EXPECTS(num_strings == offsets_size - 1, "Invalid offsets column size for strings column.");

  auto offsets_column = std::make_unique<column>(  //
    data_type{type_id::INT32},
    offsets_size,
    offsets.release(),
    rmm::device_buffer(),
    0);

  auto children = std::vector<std::unique_ptr<column>>();

  children.emplace_back(std::move(offsets_column));

  return std::make_unique<column>(data_type{type_id::STRING},
                                  num_strings,
                                  chars.release(),
                                  std::move(null_mask),
                                  null_count,
                                  std::move(children));
}

}  // namespace cudf
