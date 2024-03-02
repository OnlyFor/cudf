/*
 * Copyright (c) 2024, NVIDIA CORPORATION.
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

// #define PRINT_DEBUG

#include "io/comp/gpuinflate.hpp"
#include "io/comp/nvcomp_adapter.hpp"
#include "io/orc/reader_impl.hpp"
#include "io/orc/reader_impl_chunking.hpp"
#include "io/orc/reader_impl_helpers.hpp"
#include "io/utilities/config_utils.hpp"

#include <cudf/column/column_device_view.cuh>
#include <cudf/column/column_factories.hpp>
#include <cudf/copying.hpp>
#include <cudf/detail/offsets_iterator_factory.cuh>
#include <cudf/detail/timezone.hpp>
#include <cudf/detail/utilities/integer_utils.hpp>
#include <cudf/detail/utilities/logger.hpp>
#include <cudf/detail/utilities/vector_factories.hpp>
#include <cudf/lists/lists_column_view.hpp>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/table/table.hpp>
#include <cudf/table/table_device_view.cuh>
#include <cudf/utilities/bit.hpp>
#include <cudf/utilities/error.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/device_buffer.hpp>
#include <rmm/device_scalar.hpp>
#include <rmm/device_uvector.hpp>
#include <rmm/exec_policy.hpp>

#include <cuda/functional>
#include <thrust/copy.h>
#include <thrust/fill.h>
#include <thrust/for_each.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/pair.h>
#include <thrust/reduce.h>
#include <thrust/scan.h>
#include <thrust/transform.h>

#include <algorithm>
#include <iterator>

//
//
//
#include <cudf_test/debug_utilities.hpp>

#include <cudf/detail/utilities/linked_column.hpp>
//
//
//

namespace cudf::io::orc::detail {

std::size_t gather_stream_info_and_column_desc(
  int64_t stripe_index,
  std::size_t level,
  orc::StripeInformation const* stripeinfo,
  orc::StripeFooter const* stripefooter,
  host_span<int const> orc2gdf,
  host_span<orc::SchemaType const> types,
  bool use_index,
  bool apply_struct_map,
  int64_t* num_dictionary_entries,
  std::size_t* stream_idx,
  std::optional<std::vector<orc_stream_info>*> const& stream_info,
  std::optional<cudf::detail::hostdevice_2dvector<gpu::ColumnDesc>*> const& chunks)
{
  CUDF_EXPECTS(stream_info.has_value() ^ chunks.has_value(),
               "Either stream_info or chunks must be provided, but not both.");

  uint64_t src_offset = 0;
  uint64_t dst_offset = 0;

  auto const get_stream_index_type = [](orc::StreamKind kind) {
    switch (kind) {
      case orc::DATA: return gpu::CI_DATA;
      case orc::LENGTH:
      case orc::SECONDARY: return gpu::CI_DATA2;
      case orc::DICTIONARY_DATA: return gpu::CI_DICTIONARY;
      case orc::PRESENT: return gpu::CI_PRESENT;
      case orc::ROW_INDEX: return gpu::CI_INDEX;
      default:
        // Skip this stream as it's not strictly required
        return gpu::CI_NUM_STREAMS;
    }
  };

  for (auto const& stream : stripefooter->streams) {
    if (!stream.column_id || *stream.column_id >= orc2gdf.size()) {
      // Ignore reading this stream from source.
      // cudf::logger().warn("Unexpected stream in the input ORC source. The stream will be
      // ignored.");
      printf("Unexpected stream in the input ORC source. The stream will be ignored\n");
      fflush(stdout);
      src_offset += stream.length;
      continue;
    }

    auto const column_id = *stream.column_id;
    auto col             = orc2gdf[column_id];

    if (col == -1 and apply_struct_map) {
      // A struct-type column has no data itself, but rather child columns
      // for each of its fields. There is only a PRESENT stream, which
      // needs to be included for the reader.
      auto const schema_type = types[column_id];
      if (!schema_type.subtypes.empty() && schema_type.kind == orc::STRUCT &&
          stream.kind == orc::PRESENT) {
        // printf("present stream\n");
        for (auto const& idx : schema_type.subtypes) {
          auto const child_idx = (idx < orc2gdf.size()) ? orc2gdf[idx] : -1;
          if (child_idx >= 0) {
            col = child_idx;
            if (chunks.has_value()) {
              auto& chunk                     = (*chunks.value())[stripe_index][col];
              chunk.strm_id[gpu::CI_PRESENT]  = *stream_idx;
              chunk.strm_len[gpu::CI_PRESENT] = stream.length;
            }
          }
        }
      }
    } else if (col != -1) {
      if (chunks.has_value()) {
        if (src_offset >= stripeinfo->indexLength || use_index) {
          auto const index_type = get_stream_index_type(stream.kind);
          if (index_type < gpu::CI_NUM_STREAMS) {
            auto& chunk = (*chunks.value())[stripe_index][col];
            // printf("use stream id: %d, stripe: %d, level: %d, col idx: %d, kind: %d\n",
            //        (int)(*stream_idx),
            //        (int)stripe_index,
            //        (int)level,
            //        (int)column_id,
            //        (int)stream.kind);

            chunk.strm_id[index_type]  = *stream_idx;
            chunk.strm_len[index_type] = stream.length;
            // NOTE: skip_count field is temporarily used to track the presence of index streams
            chunk.skip_count |= 1 << index_type;

            if (index_type == gpu::CI_DICTIONARY) {
              chunk.dictionary_start = *num_dictionary_entries;
              chunk.dict_len         = stripefooter->columns[column_id].dictionarySize;
              *num_dictionary_entries += stripefooter->columns[column_id].dictionarySize;
            }
          }
        }

        (*stream_idx)++;
      } else {  // not chunks.has_value()
        // printf("collect stream id: stripe: %d, level: %d, col idx: %d, kind: %d\n",
        //        (int)stripe_index,
        //        (int)level,
        //        (int)column_id,
        //        (int)stream.kind);

        stream_info.value()->emplace_back(
          stripeinfo->offset + src_offset,
          dst_offset,
          stream.length,
          stream_id_info{static_cast<uint32_t>(stripe_index), level, column_id, stream.kind});
      }

      dst_offset += stream.length;
    }
    src_offset += stream.length;
  }

  return dst_offset;
}

#if 1
/**
 * @brief Find the splits of the input data such that each split has cumulative size less than a
 * given `size_limit`.
 */
std::vector<chunk> find_splits(host_span<cumulative_size const> sizes,
                               int64_t total_count,
                               size_t size_limit)
{
  // if (size_limit == 0) {
  //   printf("0 limit: output chunk = 0, %d\n", (int)total_count);
  //   return {chunk{0, total_count}};
  // }
  CUDF_EXPECTS(size_limit > 0, "Invalid size limit");

  std::vector<chunk> splits;
  int64_t cur_count{0};
  int64_t cur_pos{0};
  size_t cur_cumulative_size{0};

  auto const start = thrust::make_transform_iterator(
    sizes.begin(), [&](auto const& size) { return size.size_bytes - cur_cumulative_size; });
  auto const end = start + static_cast<int64_t>(sizes.size());

  while (cur_count < total_count) {
    int64_t split_pos =
      thrust::distance(start, thrust::lower_bound(thrust::seq, start + cur_pos, end, size_limit));

    // If we're past the end, or if the returned bucket is bigger than the chunk_read_limit, move
    // back one.
    if (static_cast<std::size_t>(split_pos) >= sizes.size() ||
        (sizes[split_pos].size_bytes - cur_cumulative_size > size_limit)) {
      split_pos--;
    }

    // best-try. if we can't find something that'll fit, we have to go bigger. we're doing this in
    // a loop because all of the cumulative sizes for all the pages are sorted into one big list.
    // so if we had two columns, both of which had an entry {1000, 10000}, that entry would be in
    // the list twice. so we have to iterate until we skip past all of them.  The idea is that we
    // either do this, or we have to call unique() on the input first.
    while (split_pos < (static_cast<int64_t>(sizes.size()) - 1) &&
           (split_pos < 0 || sizes[split_pos].count == cur_count)) {
      split_pos++;
    }

    auto const start_idx = cur_count;
    cur_count            = sizes[split_pos].count;
    splits.emplace_back(chunk{start_idx, static_cast<size_type>(cur_count - start_idx)});
    cur_pos             = split_pos;
    cur_cumulative_size = sizes[split_pos].size_bytes;
  }

  // If the last chunk has size smaller than `merge_threshold` percent of the second last one,
  // merge it with the second last one.
  if (splits.size() > 1) {
    auto constexpr merge_threshold = 0.15;
    if (auto const last = splits.back(), second_last = splits[splits.size() - 2];
        last.count <= static_cast<int64_t>(merge_threshold * second_last.count)) {
      splits.pop_back();
      splits.back().count += last.count;
    }
  }

  return splits;
}
#endif

namespace {

#ifdef PRINT_DEBUG
/**
 * @brief Verify the splits, checking if they are correct.
 *
 * We need to verify that:
 *  1. All chunk must have count > 0
 *  2. Chunks are continuous.
 *  3. sum(all sizes in a chunk) < size_limit
 *  4. sum(all counts in all chunks) == total_count.
 */
void verify_splits(host_span<chunk const> splits,
                   host_span<cumulative_size const> sizes,
                   size_type total_count,
                   size_t size_limit)
{
  chunk last_split{0, 0};
  int64_t count{0};
  size_t cur_cumulative_size{0};
  for (auto const& split : splits) {
    CUDF_EXPECTS(split.count > 0, "Invalid split count.");
    CUDF_EXPECTS(last_split.start_idx + last_split.count == split.start_idx,
                 "Invalid split start_idx.");
    count += split.count;
    last_split = split;

    if (split.count > 1) {
      //      printf("split: %ld - %ld, size: %zu, limit: %zu\n",
      //             split.start_idx,
      //             split.count,
      //             sizes[split.start_idx + split.count - 1].size_bytes - cur_cumulative_size,
      //             size_limit);
      //      fflush(stdout);
      CUDF_EXPECTS(
        sizes[split.start_idx + split.count - 1].size_bytes - cur_cumulative_size <= size_limit,
        "Chunk total size exceeds limit.");
      if (split.start_idx + split.count < total_count) {
        //        printf("wrong split: %ld - %ld, size: %zu, limit: %zu\n",
        //               split.start_idx,
        //               split.count + 1,
        //               sizes[split.start_idx + split.count].size_bytes - cur_cumulative_size,
        //               size_limit);

        CUDF_EXPECTS(
          sizes[split.start_idx + split.count].size_bytes - cur_cumulative_size > size_limit,
          "Invalid split.");
      }
    }
    cur_cumulative_size = sizes[split.start_idx + split.count - 1].size_bytes;
  }
  CUDF_EXPECTS(last_split.start_idx + last_split.count == sizes.back().count,
               "Invalid split start_idx.");
  CUDF_EXPECTS(count == total_count, "Invalid total count.");
}
#endif

}  // namespace

/**
 * @brief Find range of the data span by a given chunk of chunks.
 *
 * @param input_chunks The list of all data chunks
 * @param selected_chunks A chunk of chunks in the input_chunks
 * @return The range of data span by the selected chunk of given chunks
 */
std::pair<int64_t, int64_t> get_range(std::vector<chunk> const& input_chunks,
                                      chunk const& selected_chunks)
{
  // Range indices to input_chunks
  auto const chunk_begin = selected_chunks.start_idx;
  auto const chunk_end   = selected_chunks.start_idx + selected_chunks.count;

  // The first and last chunk, according to selected_chunk.
  auto const& first_chunk = input_chunks[chunk_begin];
  auto const& last_chunk  = input_chunks[chunk_end - 1];

  // The range of data covered from the first to the last chunk.
  auto const begin = first_chunk.start_idx;
  auto const end   = last_chunk.start_idx + last_chunk.count;

  return {begin, end};
}

void reader::impl::global_preprocess(uint64_t skip_rows,
                                     std::optional<size_type> const& num_rows_opt,
                                     std::vector<std::vector<size_type>> const& stripes)
{
  if (_file_itm_data.global_preprocessed) { return; }
  _file_itm_data.global_preprocessed = true;

  // Load stripes's metadata.
  std::tie(
    _file_itm_data.rows_to_skip, _file_itm_data.rows_to_read, _file_itm_data.selected_stripes) =
    _metadata.select_stripes(stripes, skip_rows, num_rows_opt, _stream);
  if (_file_itm_data.has_no_data()) { return; }

  printf("input skip rows: %d, num rows: %d\n", (int)skip_rows, (int)num_rows_opt.value_or(-1));
  printf("actual skip rows: %d, num rows: %d\n",
         (int)_file_itm_data.rows_to_skip,
         (int)_file_itm_data.rows_to_read);

  //  auto const rows_to_skip      = _file_itm_data.rows_to_skip;
  //  auto const rows_to_read      = _file_itm_data.rows_to_read;
  auto const& selected_stripes = _file_itm_data.selected_stripes;

  auto& lvl_stripe_data  = _file_itm_data.lvl_stripe_data;
  auto& lvl_stripe_sizes = _file_itm_data.lvl_stripe_sizes;
  lvl_stripe_data.resize(_selected_columns.num_levels());
  lvl_stripe_sizes.resize(_selected_columns.num_levels());

  auto& read_info                = _file_itm_data.data_read_info;
  auto& stripe_data_read_chunks  = _file_itm_data.stripe_data_read_chunks;
  auto& lvl_stripe_stream_chunks = _file_itm_data.lvl_stripe_stream_chunks;

  // Logically view streams as columns
  _file_itm_data.lvl_stream_info.resize(_selected_columns.num_levels());

  // TODO: handle large number of stripes.
  // Get the total number of stripes across all input files.
  auto const num_stripes = selected_stripes.size();

  printf("num load stripe: %d\n", (int)num_stripes);

  stripe_data_read_chunks.resize(num_stripes);
  lvl_stripe_stream_chunks.resize(_selected_columns.num_levels());

  // TODO: move this
  auto& lvl_chunks = _file_itm_data.lvl_data_chunks;
  lvl_chunks.resize(_selected_columns.num_levels());
  _out_buffers.resize(_selected_columns.num_levels());

  // TODO: Check if these data depends on pass and subpass, instead of global pass.
  // Prepare data.
  // Iterates through levels of nested columns, child column will be one level down
  // compared to parent column.
  auto& col_meta = *_col_meta;
  for (std::size_t level = 0; level < _selected_columns.num_levels(); ++level) {
    auto& columns_level = _selected_columns.levels[level];
    // Association between each ORC column and its cudf::column
    col_meta.orc_col_map.emplace_back(_metadata.get_num_cols(), -1);

    size_type col_id{0};
    for (auto& col : columns_level) {
      // Map each ORC column to its column
      col_meta.orc_col_map[level][col.id] = col_id++;
    }

    auto& stripe_data = lvl_stripe_data[level];
    stripe_data.resize(num_stripes);

    auto& stream_info      = _file_itm_data.lvl_stream_info[level];
    auto const num_columns = _selected_columns.levels[level].size();
    auto& stripe_sizes     = lvl_stripe_sizes[level];
    stream_info.reserve(selected_stripes.size() * num_columns);  // final size is unknown

    stripe_sizes.resize(selected_stripes.size());
    if (read_info.capacity() < selected_stripes.size()) {
      read_info.reserve(selected_stripes.size() * num_columns);  // final size is unknown
    }

    auto& stripe_stream_chunks = lvl_stripe_stream_chunks[level];
    stripe_stream_chunks.resize(num_stripes);
  }

  cudf::detail::hostdevice_vector<cumulative_size> total_stripe_sizes(num_stripes, _stream);

  // Compute input size for each stripe.
  for (std::size_t stripe_idx = 0; stripe_idx < num_stripes; ++stripe_idx) {
    auto const& stripe       = selected_stripes[stripe_idx];
    auto const stripe_info   = stripe.stripe_info;
    auto const stripe_footer = stripe.stripe_footer;

    std::size_t total_stripe_size{0};
    auto const last_read_size = static_cast<int64_t>(read_info.size());
    for (std::size_t level = 0; level < _selected_columns.num_levels(); ++level) {
      auto& stream_info  = _file_itm_data.lvl_stream_info[level];
      auto& stripe_sizes = lvl_stripe_sizes[level];

      auto stream_count = stream_info.size();
      auto const stripe_size =
        gather_stream_info_and_column_desc(stripe_idx,
                                           level,
                                           stripe_info,
                                           stripe_footer,
                                           col_meta.orc_col_map[level],
                                           _metadata.get_types(),
                                           false,  // use_index,
                                           level == 0,
                                           nullptr,  // num_dictionary_entries
                                           nullptr,  // stream_idx
                                           &stream_info,
                                           std::nullopt  // chunks
        );

      auto const is_stripe_data_empty = stripe_size == 0;
      CUDF_EXPECTS(not is_stripe_data_empty or stripe_info->indexLength == 0,
                   "Invalid index rowgroup stream data");

      stripe_sizes[stripe_idx] = stripe_size;
      total_stripe_size += stripe_size;

      auto& stripe_stream_chunks = lvl_stripe_stream_chunks[level];
      stripe_stream_chunks[stripe_idx] =
        chunk{static_cast<int64_t>(stream_count),
              static_cast<int64_t>(stream_info.size() - stream_count)};

      // Coalesce consecutive streams into one read
      while (not is_stripe_data_empty and stream_count < stream_info.size()) {
        auto const d_dst  = stream_info[stream_count].dst_pos;
        auto const offset = stream_info[stream_count].offset;
        auto len          = stream_info[stream_count].length;
        stream_count++;

        while (stream_count < stream_info.size() &&
               stream_info[stream_count].offset == offset + len) {
          len += stream_info[stream_count].length;
          stream_count++;
        }
        read_info.emplace_back(offset, len, d_dst, stripe.source_idx, stripe_idx, level);
      }
    }
    total_stripe_sizes[stripe_idx] = {1, total_stripe_size};
    stripe_data_read_chunks[stripe_idx] =
      chunk{last_read_size, static_cast<int64_t>(read_info.size() - last_read_size)};
  }

  _chunk_read_data.curr_load_stripe_chunk = 0;

  // Load all chunks if there is no read limit.
  if (_chunk_read_data.data_read_limit == 0) {
    printf("0 limit: output load stripe chunk = 0, %d\n", (int)num_stripes);
    _chunk_read_data.load_stripe_chunks = {chunk{0, static_cast<int64_t>(num_stripes)}};
    return;
  }

  printf("total stripe sizes:\n");
  for (auto& size : total_stripe_sizes) {
    printf("size: %ld, %zu\n", size.count, size.size_bytes);
  }

  // Compute the prefix sum of stripe data sizes.
  total_stripe_sizes.host_to_device_async(_stream);
  thrust::inclusive_scan(rmm::exec_policy(_stream),
                         total_stripe_sizes.d_begin(),
                         total_stripe_sizes.d_end(),
                         total_stripe_sizes.d_begin(),
                         cumulative_size_sum{});

  total_stripe_sizes.device_to_host_sync(_stream);

  printf("prefix sum total stripe sizes:\n");
  for (auto& size : total_stripe_sizes) {
    printf("size: %ld, %zu\n", size.count, size.size_bytes);
  }

  // TODO: handle case for extremely large files.
  auto const load_limit = [&] {
    auto const tmp = static_cast<std::size_t>(_chunk_read_data.data_read_limit *
                                              chunk_read_data::load_limit_ratio);
    return tmp > 0UL ? tmp : 1UL;
  }();
  _chunk_read_data.load_stripe_chunks = find_splits(total_stripe_sizes, num_stripes, load_limit);

#ifndef PRINT_DEBUG
  auto& splits = _chunk_read_data.load_stripe_chunks;
  printf("------------\nSplits (/total num stripe = %d): \n", (int)num_stripes);
  for (size_t idx = 0; idx < splits.size(); idx++) {
    printf("{%ld, %ld}\n", splits[idx].start_idx, splits[idx].count);
  }
  fflush(stdout);

  //  std::cout << "  total rows: " << _file_itm_data.rows_to_read << std::endl;
  //  print_cumulative_row_info(stripe_size_bytes, "  ", _chunk_read_info.chunks);

  // We need to verify that:
  //  1. All chunk must have count > 0
  //  2. Chunks are continuous.
  //  3. sum(sizes of stripes in a chunk) < size_limit if chunk has more than 1 stripe
  //  4. sum(number of stripes in all chunks) == total_num_stripes.
  // TODO: enable only in debug.
//  verify_splits(splits, total_stripe_sizes, num_stripes, _chunk_read_data.data_read_limit);
#endif
}

// Load each chunk from `load_stripe_chunks`.
void reader::impl::load_data()
{
  if (_file_itm_data.has_no_data()) { return; }

  //  auto const rows_to_read      = _file_itm_data.rows_to_read;
  //  auto const& selected_stripes = _file_itm_data.selected_stripes;

  auto& lvl_stripe_data  = _file_itm_data.lvl_stripe_data;
  auto& lvl_stripe_sizes = _file_itm_data.lvl_stripe_sizes;
  auto& read_info        = _file_itm_data.data_read_info;

  //  std::size_t num_stripes = selected_stripes.size();
  auto const stripe_chunk =
    _chunk_read_data.load_stripe_chunks[_chunk_read_data.curr_load_stripe_chunk++];
  auto const stripe_start = stripe_chunk.start_idx;
  auto const stripe_end   = stripe_chunk.start_idx + stripe_chunk.count;

  printf("\n\nloading data from stripe %d -> %d\n", (int)stripe_start, (int)stripe_end);

  // Prepare the buffer to read raw data onto.
  // TODO: clear all old buffer.
  for (std::size_t level = 0; level < _selected_columns.num_levels(); ++level) {
    auto& stripe_data  = lvl_stripe_data[level];
    auto& stripe_sizes = lvl_stripe_sizes[level];
    for (auto stripe_idx = stripe_start; stripe_idx < stripe_end; ++stripe_idx) {
      // TODO: only do this if it was not allocated before.
      stripe_data[stripe_idx] = rmm::device_buffer(
        cudf::util::round_up_safe(stripe_sizes[stripe_idx], BUFFER_PADDING_MULTIPLE), _stream);
    }
  }

  std::vector<std::unique_ptr<cudf::io::datasource::buffer>> host_read_buffers;
  std::vector<std::pair<std::future<std::size_t>, std::size_t>> read_tasks;

  auto const& stripe_data_read_chunks = _file_itm_data.stripe_data_read_chunks;
  auto const [read_begin, read_end]   = get_range(stripe_data_read_chunks, stripe_chunk);

  for (auto read_idx = read_begin; read_idx < read_end; ++read_idx) {
    auto const& read  = read_info[read_idx];
    auto& stripe_data = lvl_stripe_data[read.level];
    auto dst_base     = static_cast<uint8_t*>(stripe_data[read.stripe_idx].data());

    if (_metadata.per_file_metadata[read.source_idx].source->is_device_read_preferred(
          read.length)) {
      read_tasks.push_back(
        std::pair(_metadata.per_file_metadata[read.source_idx].source->device_read_async(
                    read.offset, read.length, dst_base + read.dst_pos, _stream),
                  read.length));

    } else {
      auto buffer =
        _metadata.per_file_metadata[read.source_idx].source->host_read(read.offset, read.length);
      CUDF_EXPECTS(buffer->size() == read.length, "Unexpected discrepancy in bytes read.");
      CUDF_CUDA_TRY(cudaMemcpyAsync(
        dst_base + read.dst_pos, buffer->data(), read.length, cudaMemcpyDefault, _stream.value()));
      //        _stream.synchronize();
      host_read_buffers.emplace_back(std::move(buffer));
    }
  }

  if (host_read_buffers.size() > 0) { _stream.synchronize(); }
  for (auto& task : read_tasks) {
    CUDF_EXPECTS(task.first.get() == task.second, "Unexpected discrepancy in bytes read.");
  }

  auto& lvl_stripe_stream_chunks = _file_itm_data.lvl_stripe_stream_chunks;

  // TODO: This is subpass
  // TODO: Don't have to keep it for all stripe/level. Can reset it after each iter.
  stream_id_map<gpu::CompressedStreamInfo*> stream_compinfo_map;

  cudf::detail::hostdevice_vector<cumulative_size> stripe_decomp_sizes(stripe_chunk.count, _stream);
  std::fill(stripe_decomp_sizes.begin(), stripe_decomp_sizes.end(), cumulative_size{1, 0});

  // Parse the decompressed sizes for each stripe.
  for (std::size_t level = 0; level < _selected_columns.num_levels(); ++level) {
    auto& stream_info      = _file_itm_data.lvl_stream_info[level];
    auto const num_columns = _selected_columns.levels[level].size();

    // Tracker for eventually deallocating compressed and uncompressed data
    auto& stripe_data = lvl_stripe_data[level];
    if (stripe_data.empty()) { continue; }

    auto const& stripe_stream_chunks      = lvl_stripe_stream_chunks[level];
    auto const [stream_begin, stream_end] = get_range(stripe_stream_chunks, stripe_chunk);
    auto const num_streams                = stream_end - stream_begin;

    // Setup row group descriptors if using indexes
    if (_metadata.per_file_metadata[0].ps.compression != orc::NONE) {
      auto const& decompressor = *_metadata.per_file_metadata[0].decompressor;

      // Cannot be cached, since this is for streams in a loaded stripe chunk, while
      // the latter decoding step will use a different stripe chunk.
      cudf::detail::hostdevice_vector<gpu::CompressedStreamInfo> compinfo(0, num_streams, _stream);

      // TODO: Instead of all stream info, loop using read_chunk info to process
      // only stream info of the curr_load_stripe_chunk.

      for (auto stream_idx = stream_begin; stream_idx < stream_end; ++stream_idx) {
        auto const& info = stream_info[stream_idx];
        compinfo.push_back(gpu::CompressedStreamInfo(
          static_cast<uint8_t const*>(stripe_data[info.id.stripe_idx].data()) + info.dst_pos,
          info.length));
        stream_compinfo_map[stream_id_info{
          info.id.stripe_idx, info.id.level, info.id.orc_col_idx, info.id.kind}] = &compinfo.back();
#ifdef PRINT_DEBUG
        printf("collec stream [%d, %d, %d, %d]: dst = %lu,  length = %lu\n",
               (int)info.id.stripe_idx,
               (int)info.id.level,
               (int)info.id.orc_col_idx,
               (int)info.id.kind,
               info.dst_pos,
               info.length);
        fflush(stdout);
#endif
      }

      compinfo.host_to_device_async(_stream);

      gpu::ParseCompressedStripeData(compinfo.device_ptr(),
                                     compinfo.size(),
                                     decompressor.GetBlockSize(),
                                     decompressor.GetLog2MaxCompressionRatio(),
                                     _stream);
      compinfo.device_to_host_sync(_stream);

      auto& compinfo_map = _file_itm_data.compinfo_map;
      for (auto& [stream_id, stream_compinfo] : stream_compinfo_map) {
        // Cache these parsed numbers so they can be reused in the decoding step.
        compinfo_map[stream_id] = {stream_compinfo->num_compressed_blocks,
                                   stream_compinfo->num_uncompressed_blocks,
                                   stream_compinfo->max_uncompressed_size};
        stripe_decomp_sizes[stream_id.stripe_idx - stripe_chunk.start_idx].size_bytes +=
          stream_compinfo->max_uncompressed_size;
#ifdef PRINT_DEBUG
        printf("cache info [%d, %d, %d, %d]:  %lu | %lu | %lu\n",
               (int)stream_id.stripe_idx,
               (int)stream_id.level,
               (int)stream_id.orc_col_idx,
               (int)stream_id.kind,
               (size_t)stream_compinfo->num_compressed_blocks,
               (size_t)stream_compinfo->num_uncompressed_blocks,
               stream_compinfo->max_uncompressed_size);
        fflush(stdout);
#endif
      }

      // Must clear map since the next level will have similar keys.
      stream_compinfo_map.clear();

    } else {
      printf("no compression \n");
      fflush(stdout);

      // Set decompression size equal to the input size.
      for (auto stream_idx = stream_begin; stream_idx < stream_end; ++stream_idx) {
        auto const& info = stream_info[stream_idx];
        stripe_decomp_sizes[info.id.stripe_idx - stripe_chunk.start_idx].size_bytes += info.length;
      }
    }

    // printf("  end level %d\n\n", (int)level);

  }  // end loop level

  // Decoding is reset to start from the first chunk in `decode_stripe_chunks`.
  _chunk_read_data.curr_decode_stripe_chunk = 0;

  // Decode all chunks if there is no read and no output limit.
  // In theory, we should just decode enough stripes for output one table chunk.
  // However, we do not know the output size of each stripe after decompressing and decoding,
  // thus we have to process all loaded chunks.
  // That is because the estimated `max_uncompressed_size` of stream data from
  // `ParseCompressedStripeData` is just the approximate of the maximum possible size, not the
  // actual size, which can be much smaller in practice.
  if (_chunk_read_data.data_read_limit == 0) {
    _chunk_read_data.decode_stripe_chunks = {stripe_chunk};
    return;
  }

  // Compute the prefix sum of stripe data sizes.
  stripe_decomp_sizes.host_to_device_async(_stream);
  thrust::inclusive_scan(rmm::exec_policy(_stream),
                         stripe_decomp_sizes.d_begin(),
                         stripe_decomp_sizes.d_end(),
                         stripe_decomp_sizes.d_begin(),
                         cumulative_size_sum{});

  stripe_decomp_sizes.device_to_host_sync(_stream);

  auto const decode_limit = [&] {
    auto const tmp = static_cast<std::size_t>(_chunk_read_data.data_read_limit *
                                              (1.0 - chunk_read_data::load_limit_ratio));
    return tmp > 0UL ? tmp : 1UL;
  }();
  _chunk_read_data.decode_stripe_chunks =
    find_splits(stripe_decomp_sizes, stripe_chunk.count, decode_limit);
  for (auto& chunk : _chunk_read_data.decode_stripe_chunks) {
    chunk.start_idx += stripe_chunk.start_idx;
  }

  for (auto& size : stripe_decomp_sizes) {
    printf("decomp size: %ld, %zu\n", size.count, size.size_bytes);
  }

#ifndef PRINT_DEBUG
  auto& splits = _chunk_read_data.decode_stripe_chunks;
  printf("------------\nSplits decode_stripe_chunks (/%d): \n", (int)stripe_chunk.count);
  for (size_t idx = 0; idx < splits.size(); idx++) {
    printf("{%ld, %ld}\n", splits[idx].start_idx, splits[idx].count);
  }
  fflush(stdout);

  //  std::cout << "  total rows: " << _file_itm_data.rows_to_read << std::endl;
  //  print_cumulative_row_info(stripe_size_bytes, "  ", _chunk_read_info.chunks);

  // We need to verify that:
  //  1. All chunk must have count > 0
  //  2. Chunks are continuous.
  //  3. sum(sizes of stripes in a chunk) < size_limit if chunk has more than 1 stripe
  //  4. sum(number of stripes in all chunks) == total_num_stripes.
  // TODO: enable only in debug.
//  verify_splits(splits, stripe_decompression_sizes, stripe_chunk.count,
//  _file_itm_data.data_read_limit);
#endif

  // lvl_stripe_data.clear();
  // _file_itm_data.compinfo_ready = true;
}

}  // namespace cudf::io::orc::detail
