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

// #define PRINT_DEBUG

// TODO: remove
#include <cudf_test/debug_utilities.hpp>

#include <cudf/concatenate.hpp>
//
//
//
#include "io/comp/gpuinflate.hpp"
#include "io/comp/nvcomp_adapter.hpp"
#include "io/orc/reader_impl.hpp"
#include "io/orc/reader_impl_chunking.hpp"
#include "io/orc/reader_impl_helpers.hpp"
#include "io/utilities/config_utils.hpp"

#include <cudf/detail/copy.hpp>
#include <cudf/detail/timezone.hpp>
#include <cudf/detail/transform.hpp>
#include <cudf/detail/utilities/integer_utils.hpp>
#include <cudf/detail/utilities/vector_factories.hpp>
#include <cudf/table/table.hpp>
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
#include <thrust/scan.h>
#include <thrust/transform.h>

#include <algorithm>
#include <iterator>

namespace cudf::io::orc::detail {

namespace {

// TODO: update
// TODO: compute num stripes from chunks
/**
 * @brief Decompresses the stripe data, at stream granularity.
 *
 * @param decompressor Block decompressor
 * @param stripe_data List of source stripe column data
 * @param stream_info List of stream to column mappings
 * @param chunks Vector of list of column chunk descriptors
 * @param row_groups Vector of list of row index descriptors
 * @param num_stripes Number of stripes making up column chunks
 * @param row_index_stride Distance between each row index
 * @param use_base_stride Whether to use base stride obtained from meta or use the computed value
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @return Device buffer to decompressed page data
 */
rmm::device_buffer decompress_stripe_data(
  chunk const& load_stripe_chunk,
  chunk const& stripe_chunk,
  stream_id_map<stripe_level_comp_info> const& compinfo_map,
  OrcDecompressor const& decompressor,
  host_span<rmm::device_buffer const> stripe_data,
  host_span<orc_stream_info const> stream_info,
  cudf::detail::hostdevice_2dvector<gpu::ColumnDesc>& chunks,
  cudf::detail::hostdevice_2dvector<gpu::RowGroup>& row_groups,
  size_type num_stripes,
  size_type row_index_stride,
  bool use_base_stride,
  rmm::cuda_stream_view stream)
{
  // Count the exact number of compressed blocks
  std::size_t num_compressed_blocks   = 0;
  std::size_t num_uncompressed_blocks = 0;
  std::size_t total_decomp_size       = 0;

  // printf("decompress #stripe: %d, ")

  // TODO: use lvl_stripe_stream_chunks
  std::size_t count{0};
  for (auto const& info : stream_info) {
    if (info.id.stripe_idx < stripe_chunk.start_idx ||
        info.id.stripe_idx >= stripe_chunk.start_idx + stripe_chunk.count) {
      continue;
    }
    count++;
  }

  cudf::detail::hostdevice_vector<gpu::CompressedStreamInfo> compinfo(0, count, stream);

  for (auto const& info : stream_info) {
    if (info.id.stripe_idx < stripe_chunk.start_idx ||
        info.id.stripe_idx >= stripe_chunk.start_idx + stripe_chunk.count) {
      continue;
    }

#ifdef PRINT_DEBUG
    printf("collec stream  again [%d, %d, %d, %d]: dst = %lu,  length = %lu\n",
           (int)info.id.stripe_idx,
           (int)info.id.level,
           (int)info.id.orc_cold_idx,
           (int)info.id.kind,
           info.dst_pos,
           info.length);
    fflush(stdout);
#endif

    compinfo.push_back(gpu::CompressedStreamInfo(
      static_cast<uint8_t const*>(
        stripe_data[info.id.stripe_idx - load_stripe_chunk.start_idx].data()) +
        info.dst_pos,
      info.length));

    //    printf("line %d\n", __LINE__);
    //    fflush(stdout);
    auto const& cached_comp_info = compinfo_map.at(
      stream_id_info{info.id.stripe_idx, info.id.level, info.id.orc_col_idx, info.id.kind});
    //    printf("line %d\n", __LINE__);
    //    fflush(stdout);
    // auto const& cached_comp_info =
    //   compinfo_map[stream_id_info{info.id.stripe_idx, info.id.level, info.id.orc_cold_idx,
    //   info.id.kind}];
    auto& stream_comp_info                   = compinfo.back();
    stream_comp_info.num_compressed_blocks   = cached_comp_info.num_compressed_blocks;
    stream_comp_info.num_uncompressed_blocks = cached_comp_info.num_uncompressed_blocks;
    stream_comp_info.max_uncompressed_size   = cached_comp_info.total_decomp_size;

    num_compressed_blocks += cached_comp_info.num_compressed_blocks;
    num_uncompressed_blocks += cached_comp_info.num_uncompressed_blocks;
    total_decomp_size += cached_comp_info.total_decomp_size;
  }

  CUDF_EXPECTS(
    not((num_uncompressed_blocks + num_compressed_blocks > 0) and (total_decomp_size == 0)),
    "Inconsistent info on compression blocks");

#ifdef XXX
  std::size_t old_num_compressed_blocks   = num_compressed_blocks;
  std::size_t old_num_uncompressed_blocks = num_uncompressed_blocks;
  std::size_t old_total_decomp_size       = total_decomp_size;

  num_compressed_blocks   = 0;
  num_uncompressed_blocks = 0;
  total_decomp_size       = 0;
  for (std::size_t i = 0; i < compinfo.size(); ++i) {
    num_compressed_blocks += compinfo[i].num_compressed_blocks;
    num_uncompressed_blocks += compinfo[i].num_uncompressed_blocks;
    total_decomp_size += compinfo[i].max_uncompressed_size;

    auto const& info = stream_info[i];
    printf("compute info [%d, %d, %d, %d]:  %lu | %lu | %lu\n",
           (int)info.id.stripe_idx,
           (int)info.id.level,
           (int)info.id.orc_cold_idx,
           (int)info.id.kind,
           (size_t)compinfo[i].num_compressed_blocks,
           (size_t)compinfo[i].num_uncompressed_blocks,
           compinfo[i].max_uncompressed_size);
    fflush(stdout);
  }

  if (old_num_compressed_blocks != num_compressed_blocks ||
      old_num_uncompressed_blocks != num_uncompressed_blocks ||
      old_total_decomp_size != total_decomp_size) {
    printf("invalid: %d - %d, %d - %d, %d - %d\n",
           (int)old_num_compressed_blocks,
           (int)num_compressed_blocks,
           (int)old_num_uncompressed_blocks,
           (int)num_uncompressed_blocks,
           (int)old_total_decomp_size,
           (int)total_decomp_size

    );
  }
#endif

  // Buffer needs to be padded.
  // Required by `gpuDecodeOrcColumnData`.
  rmm::device_buffer decomp_data(
    cudf::util::round_up_safe(total_decomp_size, BUFFER_PADDING_MULTIPLE), stream);
  if (decomp_data.is_empty()) { return decomp_data; }

  rmm::device_uvector<device_span<uint8_t const>> inflate_in(
    num_compressed_blocks + num_uncompressed_blocks, stream);
  rmm::device_uvector<device_span<uint8_t>> inflate_out(
    num_compressed_blocks + num_uncompressed_blocks, stream);
  rmm::device_uvector<compression_result> inflate_res(num_compressed_blocks, stream);
  thrust::fill(rmm::exec_policy(stream),
               inflate_res.begin(),
               inflate_res.end(),
               compression_result{0, compression_status::FAILURE});

  // Parse again to populate the decompression input/output buffers
  std::size_t decomp_offset      = 0;
  uint32_t max_uncomp_block_size = 0;
  uint32_t start_pos             = 0;
  auto start_pos_uncomp          = (uint32_t)num_compressed_blocks;
  for (std::size_t i = 0; i < compinfo.size(); ++i) {
    auto dst_base                 = static_cast<uint8_t*>(decomp_data.data());
    compinfo[i].uncompressed_data = dst_base + decomp_offset;
    compinfo[i].dec_in_ctl        = inflate_in.data() + start_pos;
    compinfo[i].dec_out_ctl       = inflate_out.data() + start_pos;
    compinfo[i].dec_res      = {inflate_res.data() + start_pos, compinfo[i].num_compressed_blocks};
    compinfo[i].copy_in_ctl  = inflate_in.data() + start_pos_uncomp;
    compinfo[i].copy_out_ctl = inflate_out.data() + start_pos_uncomp;

    //    stream_info[i].dst_pos = decomp_offset;
    decomp_offset += compinfo[i].max_uncompressed_size;
    start_pos += compinfo[i].num_compressed_blocks;
    start_pos_uncomp += compinfo[i].num_uncompressed_blocks;
    max_uncomp_block_size =
      std::max(max_uncomp_block_size, compinfo[i].max_uncompressed_block_size);
  }
  compinfo.host_to_device_async(stream);
  gpu::ParseCompressedStripeData(compinfo.device_ptr(),
                                 compinfo.size(),
                                 decompressor.GetBlockSize(),
                                 decompressor.GetLog2MaxCompressionRatio(),
                                 stream);

  // Value for checking whether we decompress successfully.
  // It doesn't need to be atomic as there is no race condition: we only write `true` if needed.
  cudf::detail::hostdevice_vector<bool> any_block_failure(1, stream);
  any_block_failure[0] = false;
  any_block_failure.host_to_device_async(stream);

  // Dispatch batches of blocks to decompress
  if (num_compressed_blocks > 0) {
    device_span<device_span<uint8_t const>> inflate_in_view{inflate_in.data(),
                                                            num_compressed_blocks};
    device_span<device_span<uint8_t>> inflate_out_view{inflate_out.data(), num_compressed_blocks};
    switch (decompressor.compression()) {
      case compression_type::ZLIB:
        if (nvcomp::is_decompression_disabled(nvcomp::compression_type::DEFLATE)) {
          gpuinflate(
            inflate_in_view, inflate_out_view, inflate_res, gzip_header_included::NO, stream);
        } else {
          nvcomp::batched_decompress(nvcomp::compression_type::DEFLATE,
                                     inflate_in_view,
                                     inflate_out_view,
                                     inflate_res,
                                     max_uncomp_block_size,
                                     total_decomp_size,
                                     stream);
        }
        break;
      case compression_type::SNAPPY:
        if (nvcomp::is_decompression_disabled(nvcomp::compression_type::SNAPPY)) {
          gpu_unsnap(inflate_in_view, inflate_out_view, inflate_res, stream);
        } else {
          nvcomp::batched_decompress(nvcomp::compression_type::SNAPPY,
                                     inflate_in_view,
                                     inflate_out_view,
                                     inflate_res,
                                     max_uncomp_block_size,
                                     total_decomp_size,
                                     stream);
        }
        break;
      case compression_type::ZSTD:
        if (auto const reason = nvcomp::is_decompression_disabled(nvcomp::compression_type::ZSTD);
            reason) {
          CUDF_FAIL("Decompression error: " + reason.value());
        }
        nvcomp::batched_decompress(nvcomp::compression_type::ZSTD,
                                   inflate_in_view,
                                   inflate_out_view,
                                   inflate_res,
                                   max_uncomp_block_size,
                                   total_decomp_size,
                                   stream);
        break;
      case compression_type::LZ4:
        if (auto const reason = nvcomp::is_decompression_disabled(nvcomp::compression_type::LZ4);
            reason) {
          CUDF_FAIL("Decompression error: " + reason.value());
        }
        nvcomp::batched_decompress(nvcomp::compression_type::LZ4,
                                   inflate_in_view,
                                   inflate_out_view,
                                   inflate_res,
                                   max_uncomp_block_size,
                                   total_decomp_size,
                                   stream);
        break;
      default: CUDF_FAIL("Unexpected decompression dispatch"); break;
    }

    // TODO: proclam return type

    // Check if any block has been failed to decompress.
    // Not using `thrust::any` or `thrust::count_if` to defer stream sync.
    thrust::for_each(
      rmm::exec_policy(stream),
      thrust::make_counting_iterator(std::size_t{0}),
      thrust::make_counting_iterator(inflate_res.size()),
      [results           = inflate_res.begin(),
       any_block_failure = any_block_failure.device_ptr()] __device__(auto const idx) {
        if (results[idx].status != compression_status::SUCCESS) { *any_block_failure = true; }
      });
  }

  if (num_uncompressed_blocks > 0) {
    device_span<device_span<uint8_t const>> copy_in_view{inflate_in.data() + num_compressed_blocks,
                                                         num_uncompressed_blocks};
    device_span<device_span<uint8_t>> copy_out_view{inflate_out.data() + num_compressed_blocks,
                                                    num_uncompressed_blocks};
    gpu_copy_uncompressed_blocks(copy_in_view, copy_out_view, stream);
  }

  // Copy without stream sync, thus need to wait for stream sync below to access.
  any_block_failure.device_to_host_async(stream);

  gpu::PostDecompressionReassemble(compinfo.device_ptr(), compinfo.size(), stream);
  compinfo.device_to_host_sync(stream);  // This also sync stream for `any_block_failure`.

  // We can check on host after stream synchronize
  CUDF_EXPECTS(not any_block_failure[0], "Error during decompression");

  auto const num_columns = static_cast<size_type>(chunks.size().second);

  // Update the stream information with the updated uncompressed info
  // TBD: We could update the value from the information we already
  // have in stream_info[], but using the gpu results also updates
  // max_uncompressed_size to the actual uncompressed size, or zero if
  // decompression failed.
  for (size_type i = 0; i < num_stripes; ++i) {
    for (size_type j = 0; j < num_columns; ++j) {
      auto& chunk = chunks[i][j];
      for (int k = 0; k < gpu::CI_NUM_STREAMS; ++k) {
        if (chunk.strm_len[k] > 0 && chunk.strm_id[k] < compinfo.size()) {
          chunk.streams[k]  = compinfo[chunk.strm_id[k]].uncompressed_data;
          chunk.strm_len[k] = compinfo[chunk.strm_id[k]].max_uncompressed_size;
        }
      }
    }
  }

  if (row_groups.size().first) {
    chunks.host_to_device_async(stream);
    row_groups.host_to_device_async(stream);
    gpu::ParseRowGroupIndex(row_groups.base_device_ptr(),
                            compinfo.device_ptr(),
                            chunks.base_device_ptr(),
                            num_columns,
                            num_stripes,
                            row_index_stride,
                            use_base_stride,
                            stream);
  }

  return decomp_data;
}

/**
 * @brief Updates null mask of columns whose parent is a struct column.
 *
 * If struct column has null element, that row would be skipped while writing child column in ORC,
 * so we need to insert the missing null elements in child column. There is another behavior from
 * pyspark, where if the child column doesn't have any null elements, it will not have present
 * stream, so in that case parent null mask need to be copied to child column.
 *
 * @param chunks Vector of list of column chunk descriptors
 * @param out_buffers Output columns' device buffers
 * @param stream CUDA stream used for device memory operations and kernel launches.
 * @param mr Device memory resource to use for device memory allocation
 */
void update_null_mask(cudf::detail::hostdevice_2dvector<gpu::ColumnDesc>& chunks,
                      host_span<column_buffer> out_buffers,
                      rmm::cuda_stream_view stream,
                      rmm::mr::device_memory_resource* mr)
{
  auto const num_stripes = chunks.size().first;
  auto const num_columns = chunks.size().second;
  bool is_mask_updated   = false;

  for (std::size_t col_idx = 0; col_idx < num_columns; ++col_idx) {
    if (chunks[0][col_idx].parent_validity_info.valid_map_base != nullptr) {
      if (not is_mask_updated) {
        chunks.device_to_host_sync(stream);
        is_mask_updated = true;
      }

      auto parent_valid_map_base = chunks[0][col_idx].parent_validity_info.valid_map_base;
      auto child_valid_map_base  = out_buffers[col_idx].null_mask();
      auto child_mask_len =
        chunks[0][col_idx].column_num_rows - chunks[0][col_idx].parent_validity_info.null_count;
      auto parent_mask_len = chunks[0][col_idx].column_num_rows;

      if (child_valid_map_base != nullptr) {
        rmm::device_uvector<uint32_t> dst_idx(child_mask_len, stream);
        // Copy indexes at which the parent has valid value.
        thrust::copy_if(rmm::exec_policy(stream),
                        thrust::make_counting_iterator(0),
                        thrust::make_counting_iterator(0) + parent_mask_len,
                        dst_idx.begin(),
                        [parent_valid_map_base] __device__(auto idx) {
                          return bit_is_set(parent_valid_map_base, idx);
                        });

        auto merged_null_mask = cudf::detail::create_null_mask(
          parent_mask_len, mask_state::ALL_NULL, rmm::cuda_stream_view(stream), mr);
        auto merged_mask      = static_cast<bitmask_type*>(merged_null_mask.data());
        uint32_t* dst_idx_ptr = dst_idx.data();
        // Copy child valid bits from child column to valid indexes, this will merge both child
        // and parent null masks
        thrust::for_each(rmm::exec_policy(stream),
                         thrust::make_counting_iterator(0),
                         thrust::make_counting_iterator(0) + dst_idx.size(),
                         [child_valid_map_base, dst_idx_ptr, merged_mask] __device__(auto idx) {
                           if (bit_is_set(child_valid_map_base, idx)) {
                             cudf::set_bit(merged_mask, dst_idx_ptr[idx]);
                           };
                         });

        out_buffers[col_idx].set_null_mask(std::move(merged_null_mask));

      } else {
        // Since child column doesn't have a mask, copy parent null mask
        auto mask_size = bitmask_allocation_size_bytes(parent_mask_len);
        out_buffers[col_idx].set_null_mask(
          rmm::device_buffer(static_cast<void*>(parent_valid_map_base), mask_size, stream, mr));
      }
    }
  }

  if (is_mask_updated) {
    // Update chunks with pointers to column data which might have been changed.
    for (std::size_t stripe_idx = 0; stripe_idx < num_stripes; ++stripe_idx) {
      for (std::size_t col_idx = 0; col_idx < num_columns; ++col_idx) {
        auto& chunk          = chunks[stripe_idx][col_idx];
        chunk.valid_map_base = out_buffers[col_idx].null_mask();
      }
    }
    chunks.host_to_device_sync(stream);
  }
}

/**
 * @brief Converts the stripe column data and outputs to columns.
 *
 * @param num_dicts Number of dictionary entries required
 * @param skip_rows Number of rows to offset from start
 * @param row_index_stride Distance between each row index
 * @param level Current nesting level being processed
 * @param tz_table Local time to UTC conversion table
 * @param chunks Vector of list of column chunk descriptors
 * @param row_groups Vector of list of row index descriptors
 * @param out_buffers Output columns' device buffers
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @param mr Device memory resource to use for device memory allocation
 */
void decode_stream_data(std::size_t num_dicts,
                        int64_t skip_rows,
                        size_type row_index_stride,
                        std::size_t level,
                        table_view const& tz_table,
                        cudf::detail::hostdevice_2dvector<gpu::ColumnDesc>& chunks,
                        cudf::detail::device_2dspan<gpu::RowGroup> row_groups,
                        std::vector<column_buffer>& out_buffers,
                        rmm::cuda_stream_view stream,
                        rmm::mr::device_memory_resource* mr)
{
  auto const num_stripes = chunks.size().first;
  auto const num_columns = chunks.size().second;
  printf("decode %d stripess \n", (int)num_stripes);

  thrust::counting_iterator<int> col_idx_it(0);
  thrust::counting_iterator<int> stripe_idx_it(0);

  // Update chunks with pointers to column data
  std::for_each(stripe_idx_it, stripe_idx_it + num_stripes, [&](auto stripe_idx) {
    std::for_each(col_idx_it, col_idx_it + num_columns, [&](auto col_idx) {
      auto& chunk            = chunks[stripe_idx][col_idx];
      chunk.column_data_base = out_buffers[col_idx].data();
      chunk.valid_map_base   = out_buffers[col_idx].null_mask();
    });
  });

  // Allocate global dictionary for deserializing
  rmm::device_uvector<gpu::DictionaryEntry> global_dict(num_dicts, stream);

  chunks.host_to_device_sync(stream);
  gpu::DecodeNullsAndStringDictionaries(
    chunks.base_device_ptr(), global_dict.data(), num_columns, num_stripes, skip_rows, stream);

  if (level > 0) {
    printf("update_null_mask\n");
    // Update nullmasks for children if parent was a struct and had null mask
    update_null_mask(chunks, out_buffers, stream, mr);
  }

  auto const tz_table_dptr = table_device_view::create(tz_table, stream);
  rmm::device_scalar<size_type> error_count(0, stream);
  // Update the null map for child columns

  // printf(
  //   "num col: %d, num stripe: %d, skip row: %d, row_groups size: %d, row index stride: %d, "
  //   "level: "
  //   "%d\n",
  //   (int)num_columns,
  //   (int)num_stripes,
  //   (int)skip_rows,
  //   (int)row_groups.size().first,
  //   (int)row_index_stride,
  //   (int)level
  // );

  gpu::DecodeOrcColumnData(chunks.base_device_ptr(),
                           global_dict.data(),
                           row_groups,
                           num_columns,
                           num_stripes,
                           skip_rows,
                           *tz_table_dptr,
                           row_groups.size().first,
                           row_index_stride,
                           level,
                           error_count.data(),
                           stream);
  chunks.device_to_host_async(stream);
  // `value` synchronizes
  auto const num_errors = error_count.value(stream);
  CUDF_EXPECTS(num_errors == 0, "ORC data decode failed");

  std::for_each(col_idx_it + 0, col_idx_it + num_columns, [&](auto col_idx) {
    out_buffers[col_idx].null_count() =
      std::accumulate(stripe_idx_it + 0,
                      stripe_idx_it + num_stripes,
                      0,
                      [&](auto null_count, auto const stripe_idx) {
                        // printf(
                        //   "null count: %d => %d\n", (int)stripe_idx,
                        //   (int)chunks[stripe_idx][col_idx].null_count);
                        // printf("num child rows: %d \n",
                        // (int)chunks[stripe_idx][col_idx].num_child_rows);

                        return null_count + chunks[stripe_idx][col_idx].null_count;
                      });
  });
}

/**
 * @brief Compute the per-stripe prefix sum of null count, for each struct column in the current
 * layer.
 */
void scan_null_counts(cudf::detail::hostdevice_2dvector<gpu::ColumnDesc> const& chunks,
                      cudf::host_span<rmm::device_uvector<uint32_t>> prefix_sums,
                      rmm::cuda_stream_view stream)
{
  auto const num_stripes = chunks.size().first;
  if (num_stripes == 0) return;

  auto const num_columns = chunks.size().second;
  std::vector<thrust::pair<size_type, cudf::device_span<uint32_t>>> prefix_sums_to_update;
  for (auto col_idx = 0ul; col_idx < num_columns; ++col_idx) {
    // Null counts sums are only needed for children of struct columns
    if (chunks[0][col_idx].type_kind == STRUCT) {
      prefix_sums_to_update.emplace_back(col_idx, prefix_sums[col_idx]);
    }
  }
  auto const d_prefix_sums_to_update = cudf::detail::make_device_uvector_async(
    prefix_sums_to_update, stream, rmm::mr::get_current_device_resource());

  thrust::for_each(rmm::exec_policy(stream),
                   d_prefix_sums_to_update.begin(),
                   d_prefix_sums_to_update.end(),
                   [chunks = cudf::detail::device_2dspan<gpu::ColumnDesc const>{chunks}] __device__(
                     auto const& idx_psums) {
                     auto const col_idx = idx_psums.first;
                     auto const psums   = idx_psums.second;

                     thrust::transform(
                       thrust::seq,
                       thrust::make_counting_iterator(0),
                       thrust::make_counting_iterator(0) + psums.size(),
                       psums.begin(),
                       [&](auto stripe_idx) { return chunks[stripe_idx][col_idx].null_count; });

                     thrust::inclusive_scan(thrust::seq, psums.begin(), psums.end(), psums.begin());
                   });
  // `prefix_sums_to_update` goes out of scope, copy has to be done before we return
  stream.synchronize();
}

// TODO: this is called for each chunk of stripes.
/**
 * @brief Aggregate child metadata from parent column chunks.
 */
void aggregate_child_meta(std::size_t stripe_start,
                          std::size_t level,
                          cudf::io::orc::detail::column_hierarchy const& selected_columns,
                          cudf::detail::host_2dspan<gpu::ColumnDesc> chunks,
                          cudf::detail::host_2dspan<gpu::RowGroup> row_groups,
                          host_span<orc_column_meta const> nested_cols,
                          host_span<column_buffer> out_buffers,
                          reader_column_meta& col_meta)
{
  auto const num_of_stripes         = chunks.size().first;
  auto const num_of_rowgroups       = row_groups.size().first;
  auto const num_child_cols         = selected_columns.levels[level + 1].size();
  auto const number_of_child_chunks = num_child_cols * num_of_stripes;
  auto& num_child_rows              = col_meta.num_child_rows;
  auto& parent_column_data          = col_meta.parent_column_data;

  // Reset the meta to store child column details.
  num_child_rows.resize(selected_columns.levels[level + 1].size());
  std::fill(num_child_rows.begin(), num_child_rows.end(), 0);
  parent_column_data.resize(number_of_child_chunks);
  col_meta.parent_column_index.resize(number_of_child_chunks);
  col_meta.child_start_row.resize(number_of_child_chunks);
  col_meta.num_child_rows_per_stripe.resize(number_of_child_chunks);
  col_meta.rwgrp_meta.resize(num_of_rowgroups * num_child_cols);

  auto child_start_row = cudf::detail::host_2dspan<int64_t>(
    col_meta.child_start_row.data(), num_of_stripes, num_child_cols);
  auto num_child_rows_per_stripe = cudf::detail::host_2dspan<int64_t>(
    col_meta.num_child_rows_per_stripe.data(), num_of_stripes, num_child_cols);
  auto rwgrp_meta = cudf::detail::host_2dspan<reader_column_meta::row_group_meta>(
    col_meta.rwgrp_meta.data(), num_of_rowgroups, num_child_cols);

  int index = 0;  // number of child column processed

  printf("\n\n");
  // For each parent column, update its child column meta for each stripe.
  std::for_each(nested_cols.begin(), nested_cols.end(), [&](auto const p_col) {
    // printf("p_col.id: %d\n", (int)p_col.id);

    auto const parent_col_idx = col_meta.orc_col_map[level][p_col.id];
    // printf("   level: %d, parent_col_idx: %d\n", (int)level, (int)parent_col_idx);

    int64_t start_row         = 0;
    auto processed_row_groups = 0;

    for (std::size_t stripe_id = 0; stripe_id < num_of_stripes; stripe_id++) {
      // Aggregate num_rows and start_row from processed parent columns per row groups
      if (num_of_rowgroups) {
        // printf("   num_of_rowgroups: %d\n", (int)num_of_rowgroups);

        auto stripe_num_row_groups = chunks[stripe_id][parent_col_idx].num_rowgroups;
        auto processed_child_rows  = 0;

        for (std::size_t rowgroup_id = 0; rowgroup_id < stripe_num_row_groups;
             rowgroup_id++, processed_row_groups++) {
          auto const child_rows = row_groups[processed_row_groups][parent_col_idx].num_child_rows;
          for (size_type id = 0; id < p_col.num_children; id++) {
            auto const child_col_idx                                  = index + id;
            rwgrp_meta[processed_row_groups][child_col_idx].start_row = processed_child_rows;
            rwgrp_meta[processed_row_groups][child_col_idx].num_rows  = child_rows;
          }
          processed_child_rows += child_rows;
        }
      }

      // Aggregate start row, number of rows per chunk and total number of rows in a column
      auto const child_rows = chunks[stripe_id][parent_col_idx].num_child_rows;
      // printf("     stripe_id: %d: child_rows: %d\n", (int)stripe_id, (int)child_rows);
      // printf("      p_col.num_children: %d\n", (int)p_col.num_children);

      for (size_type id = 0; id < p_col.num_children; id++) {
        auto const child_col_idx = index + id;

        // TODO: Check for overflow here.
        num_child_rows[child_col_idx] += child_rows;
        num_child_rows_per_stripe[stripe_id][child_col_idx] = child_rows;
        // start row could be different for each column when there is nesting at each stripe level
        child_start_row[stripe_id][child_col_idx] = (stripe_id == 0) ? 0 : start_row;
        // printf("update child_start_row (%d, %d): %d\n",
        //        (int)stripe_id,
        //        (int)child_col_idx,
        //        (int)start_row);
      }
      start_row += child_rows;
      // printf("        start_row: %d\n", (int)start_row);
    }

    // Parent column null mask and null count would be required for child column
    // to adjust its nullmask.
    auto type              = out_buffers[parent_col_idx].type.id();
    auto parent_null_count = static_cast<uint32_t>(out_buffers[parent_col_idx].null_count());
    auto parent_valid_map  = out_buffers[parent_col_idx].null_mask();
    auto num_rows          = out_buffers[parent_col_idx].size;

    for (size_type id = 0; id < p_col.num_children; id++) {
      auto const child_col_idx                    = index + id;
      col_meta.parent_column_index[child_col_idx] = parent_col_idx;
      if (type == type_id::STRUCT) {
        parent_column_data[child_col_idx] = {parent_valid_map, parent_null_count};
        // Number of rows in child will remain same as parent in case of struct column
        num_child_rows[child_col_idx] = num_rows;
      } else {
        parent_column_data[child_col_idx] = {nullptr, 0};
      }
    }
    index += p_col.num_children;
  });
}

/**
 * @brief struct to store buffer data and size of list buffer
 */
struct list_buffer_data {
  size_type* data;
  size_type size;
};

// Generates offsets for list buffer from number of elements in a row.
void generate_offsets_for_list(host_span<list_buffer_data> buff_data, rmm::cuda_stream_view stream)
{
  for (auto& list_data : buff_data) {
    thrust::exclusive_scan(rmm::exec_policy_nosync(stream),
                           list_data.data,
                           list_data.data + list_data.size,
                           list_data.data);
  }
}

/**
 * @brief TODO
 * @param input
 * @param size_limit
 * @param stream
 * @return
 */
std::vector<chunk> find_table_splits(table_view const& input,
                                     size_type segment_length,
                                     std::size_t size_limit,
                                     rmm::cuda_stream_view stream)
{
  printf("find table split, seg length = %d, limit = %d \n", segment_length, (int)size_limit);

  // If segment_length is zero: we don't have any limit on granularity.
  // As such, set segment length to the number of rows.
  if (segment_length == 0) { segment_length = input.num_rows(); }

  // If we have small number of rows, need to adjust segment_length before calling to
  // `segmented_row_bit_count`.
  segment_length = std::min(segment_length, input.num_rows());

  // Default 10k rows.
  auto const d_segmented_sizes = cudf::detail::segmented_row_bit_count(
    input, segment_length, stream, rmm::mr::get_current_device_resource());

  auto segmented_sizes =
    cudf::detail::hostdevice_vector<cumulative_size>(d_segmented_sizes->size(), stream);

  // TODO: exec_policy_nosync
  thrust::transform(
    rmm::exec_policy(stream),
    thrust::make_counting_iterator(0),
    thrust::make_counting_iterator(d_segmented_sizes->size()),
    segmented_sizes.d_begin(),
    [segment_length,
     num_rows = input.num_rows(),
     d_sizes  = d_segmented_sizes->view().begin<size_type>()] __device__(auto const segment_idx) {
      // Since the number of rows may not divisible by segment_length,
      // the last segment may be shorter than the others.
      auto const current_length =
        cuda::std::min(segment_length, num_rows - segment_length * segment_idx);
      auto const size = d_sizes[segment_idx];
      return cumulative_size{current_length, static_cast<std::size_t>(size)};
    });

  // TODO: remove:
  segmented_sizes.device_to_host_sync(stream);
  printf("total row sizes by segment = %d:\n", (int)segment_length);
  for (auto& size : segmented_sizes) {
    printf("size: %ld, %zu\n", size.count, size.size_bytes / CHAR_BIT);
  }

  // TODO: exec_policy_nosync
  thrust::inclusive_scan(rmm::exec_policy(stream),
                         segmented_sizes.d_begin(),
                         segmented_sizes.d_end(),
                         segmented_sizes.d_begin(),
                         cumulative_size_sum{});
  segmented_sizes.device_to_host_sync(stream);

  // Since the segment sizes are in bits, we need to multiply CHAR_BIT with the output limit.
  return find_splits(segmented_sizes, input.num_rows(), size_limit * CHAR_BIT);
}

}  // namespace

// TODO: this should be called per chunk of stripes.
void reader::impl::decompress_and_decode()
{
  if (_file_itm_data.has_no_data()) { return; }

  auto const stripe_chunk =
    _chunk_read_data.decode_stripe_chunks[_chunk_read_data.curr_decode_stripe_chunk++];
  auto const stripe_start = stripe_chunk.start_idx;
  auto const stripe_end   = stripe_chunk.start_idx + stripe_chunk.count;

  auto const load_stripe_start =
    _chunk_read_data.load_stripe_chunks[_chunk_read_data.curr_load_stripe_chunk - 1].start_idx;

  printf("\ndecoding data from stripe %d -> %d\n", (int)stripe_start, (int)stripe_end);

  auto const rows_to_skip = _file_itm_data.rows_to_skip;
  // auto const rows_to_read      = _file_itm_data.rows_to_read;
  auto const& selected_stripes = _file_itm_data.selected_stripes;

  // auto const rows_to_skip = 0;
  auto rows_to_read = 0;
  for (auto stripe_idx = stripe_start; stripe_idx < stripe_end; ++stripe_idx) {
    auto const& stripe     = selected_stripes[stripe_idx];
    auto const stripe_info = stripe.stripe_info;
    // TODO: check overflow
    // CUDF_EXPECTS(per_file_metadata[src_file_idx].ff.stripes[stripe_idx].numberOfRows <
    //                static_cast<uint64_t>(std::numeric_limits<size_type>::max()),
    //              "TODO");
    rows_to_read += static_cast<size_type>(stripe_info->numberOfRows);

    if (_file_itm_data.rows_to_skip > 0) {
      CUDF_EXPECTS(_file_itm_data.rows_to_skip < static_cast<int64_t>(stripe_info->numberOfRows),
                   "TODO");
    }
  }
  rows_to_read = std::min<int64_t>(rows_to_read - rows_to_skip, _file_itm_data.rows_to_read);
  _file_itm_data.rows_to_skip = 0;

  // Set up table for converting timestamp columns from local to UTC time
  auto const tz_table = [&, &selected_stripes = selected_stripes] {
    auto const has_timestamp_column = std::any_of(
      _selected_columns.levels.cbegin(), _selected_columns.levels.cend(), [&](auto const& col_lvl) {
        return std::any_of(col_lvl.cbegin(), col_lvl.cend(), [&](auto const& col_meta) {
          return _metadata.get_col_type(col_meta.id).kind == TypeKind::TIMESTAMP;
        });
      });

    return has_timestamp_column ? cudf::detail::make_timezone_transition_table(
                                    {}, selected_stripes[0].stripe_footer->writerTimezone, _stream)
                                : std::make_unique<cudf::table>();
  }();

  auto& lvl_stripe_data        = _file_itm_data.lvl_stripe_data;
  auto& null_count_prefix_sums = _file_itm_data.null_count_prefix_sums;
  auto& lvl_chunks             = _file_itm_data.lvl_data_chunks;

  null_count_prefix_sums.clear();

  // TODO: move this to global step
  lvl_chunks.resize(_selected_columns.num_levels());
  _out_buffers.clear();
  _out_buffers.resize(_selected_columns.num_levels());

  //
  //
  //
  // TODO: move this to reader_impl.cu, decomp and decode step
  //  std::size_t num_stripes = selected_stripes.size();
  std::size_t num_stripes = stripe_chunk.count;

  // Iterates through levels of nested columns, child column will be one level down
  // compared to parent column.
  auto& col_meta = *_col_meta;

#if 0
  printf("num_child_rows: (size %d)\n", (int)_col_meta->num_child_rows.size());
  if (_col_meta->num_child_rows.size()) {
    for (auto x : _col_meta->num_child_rows) {
      printf("%d, ", (int)x);
    }
    printf("\n");

    _col_meta->num_child_rows.clear();
  }

  printf("parent_column_data null count: (size %d)\n", (int)_col_meta->parent_column_data.size());
  if (_col_meta->parent_column_data.size()) {
    for (auto x : _col_meta->parent_column_data) {
      printf("%d, ", (int)x.null_count);
    }
    printf("\n");
    _col_meta->parent_column_data.clear();
  }

  printf("parent_column_index: (size %d)\n", (int)_col_meta->parent_column_index.size());
  if (_col_meta->parent_column_index.size()) {
    for (auto x : _col_meta->parent_column_index) {
      printf("%d, ", (int)x);
    }
    printf("\n");
    _col_meta->parent_column_index.clear();
  }

  printf("child_start_row: (size %d)\n", (int)_col_meta->child_start_row.size());
  if (_col_meta->child_start_row.size()) {
    for (auto x : _col_meta->child_start_row) {
      printf("%d, ", (int)x);
    }
    printf("\n");
    _col_meta->child_start_row.clear();
  }

  printf("num_child_rows_per_stripe: (size %d)\n",
         (int)_col_meta->num_child_rows_per_stripe.size());
  if (_col_meta->num_child_rows_per_stripe.size()) {
    for (auto x : _col_meta->num_child_rows_per_stripe) {
      printf("%d, ", (int)x);
    }
    printf("\n");
    _col_meta->num_child_rows_per_stripe.clear();
  }

  printf("rwgrp_meta: (size %d)\n", (int)_col_meta->rwgrp_meta.size());
  if (_col_meta->rwgrp_meta.size()) {
    for (auto x : _col_meta->rwgrp_meta) {
      printf("(%d | %d), ", (int)x.start_row, (int)x.num_rows);
    }
    printf("\n");
  }

#endif

  auto& lvl_stripe_stream_chunks = _file_itm_data.lvl_stripe_stream_chunks;

  for (std::size_t level = 0; level < _selected_columns.num_levels(); ++level) {
    printf("processing level = %d\n", (int)level);

    {
      _stream.synchronize();
      auto peak_mem = mem_stats_logger.peak_memory_usage();
      std::cout << __LINE__ << ", decomp and decode, peak_memory_usage: " << peak_mem << "("
                << (peak_mem * 1.0) / (1024.0 * 1024.0) << " MB)" << std::endl;
    }

    auto const& stripe_stream_chunks      = lvl_stripe_stream_chunks[level];
    auto const [stream_begin, stream_end] = get_range(stripe_stream_chunks, stripe_chunk);

    auto& columns_level = _selected_columns.levels[level];

    // TODO: do it in global step
    // Association between each ORC column and its cudf::column
    std::vector<orc_column_meta> nested_cols;

    // Get a list of column data types
    std::vector<data_type> column_types;
    for (auto& col : columns_level) {
      auto col_type =
        to_cudf_type(_metadata.get_col_type(col.id).kind,
                     _config.use_np_dtypes,
                     _config.timestamp_type.id(),
                     to_cudf_decimal_type(_config.decimal128_columns, _metadata, col.id));
      CUDF_EXPECTS(col_type != type_id::EMPTY, "Unknown type");
      if (col_type == type_id::DECIMAL32 or col_type == type_id::DECIMAL64 or
          col_type == type_id::DECIMAL128) {
        // sign of the scale is changed since cuDF follows c++ libraries like CNL
        // which uses negative scaling, but liborc and other libraries
        // follow positive scaling.
        auto const scale =
          -static_cast<size_type>(_metadata.get_col_type(col.id).scale.value_or(0));
        column_types.emplace_back(col_type, scale);
      } else {
        column_types.emplace_back(col_type);
      }

      // Map each ORC column to its column
      if (col_type == type_id::LIST or col_type == type_id::STRUCT) {
        nested_cols.emplace_back(col);
      }
    }

    auto const num_columns = columns_level.size();
    auto& chunks           = lvl_chunks[level];
    chunks = cudf::detail::hostdevice_2dvector<gpu::ColumnDesc>(num_stripes, num_columns, _stream);
    memset(chunks.base_host_ptr(), 0, chunks.size_bytes());

    {
      _stream.synchronize();
      auto peak_mem = mem_stats_logger.peak_memory_usage();
      std::cout << __LINE__ << ", decomp and decode, peak_memory_usage: " << peak_mem << "("
                << (peak_mem * 1.0) / (1024.0 * 1024.0) << " MB)" << std::endl;
    }

    const bool use_index =
      _config.use_index &&
      // Do stripes have row group index
      _metadata.is_row_grp_idx_present() &&
      // Only use if we don't have much work with complete columns & stripes
      // TODO: Consider nrows, gpu, and tune the threshold
      (rows_to_read > _metadata.get_row_index_stride() && !(_metadata.get_row_index_stride() & 7) &&
       _metadata.get_row_index_stride() != 0 && num_columns * num_stripes < 8 * 128) &&
      // Only use if first row is aligned to a stripe boundary
      // TODO: Fix logic to handle unaligned rows
      (rows_to_skip == 0);

    printf(" use_index: %d\n", (int)use_index);

    // Logically view streams as columns
    auto const& stream_info = _file_itm_data.lvl_stream_info[level];

    null_count_prefix_sums.emplace_back();
    null_count_prefix_sums.back().reserve(_selected_columns.levels[level].size());
    std::generate_n(std::back_inserter(null_count_prefix_sums.back()),
                    _selected_columns.levels[level].size(),
                    [&]() {
                      return cudf::detail::make_zeroed_device_uvector_async<uint32_t>(
                        num_stripes, _stream, rmm::mr::get_current_device_resource());
                    });

    // Tracker for eventually deallocating compressed and uncompressed data
    auto& stripe_data = lvl_stripe_data[level];

    int64_t stripe_start_row = 0;
    int64_t num_dict_entries = 0;
    int64_t num_rowgroups    = 0;

    // TODO: Stripe and stream idx must be by chunk.
    //    std::size_t stripe_idx = 0;
    std::size_t stream_idx = 0;

    for (auto stripe_idx = stripe_start; stripe_idx < stripe_end; ++stripe_idx) {
      //    for (auto const& stripe : selected_stripes) {

      printf("processing stripe_idx = %d\n", (int)stripe_idx);
      auto const& stripe       = selected_stripes[stripe_idx];
      auto const stripe_info   = stripe.stripe_info;
      auto const stripe_footer = stripe.stripe_footer;

      // printf("stripeinfo->indexLength: %d, data: %d\n",
      //        (int)stripe_info->indexLength,
      //        (int)stripe_info->dataLength);

      auto const total_data_size = gather_stream_info_and_column_desc(stripe_idx - stripe_start,
                                                                      level,
                                                                      stripe_info,
                                                                      stripe_footer,
                                                                      col_meta.orc_col_map[level],
                                                                      _metadata.get_types(),
                                                                      use_index,
                                                                      level == 0,
                                                                      &num_dict_entries,
                                                                      &stream_idx,
                                                                      std::nullopt,  // stream_info
                                                                      &chunks);

      auto const is_stripe_data_empty = total_data_size == 0;
      printf("is_stripe_data_empty: %d\n", (int)is_stripe_data_empty);

      CUDF_EXPECTS(not is_stripe_data_empty or stripe_info->indexLength == 0,
                   "Invalid index rowgroup stream data");

      // TODO: Wrong?
      // stripe load_stripe_start?
      auto dst_base = static_cast<uint8_t*>(stripe_data[stripe_idx - load_stripe_start].data());

      // printf("line %d\n", __LINE__);
      // fflush(stdout);

      auto const num_rows_per_stripe = static_cast<int64_t>(stripe_info->numberOfRows);
      printf(" num_rows_per_stripe : %d\n", (int)num_rows_per_stripe);

      auto const rowgroup_id    = num_rowgroups;
      auto stripe_num_rowgroups = 0;
      if (use_index) {
        stripe_num_rowgroups = (num_rows_per_stripe + _metadata.get_row_index_stride() - 1) /
                               _metadata.get_row_index_stride();
      }

      // printf("line %d\n", __LINE__);
      // fflush(stdout);

      // Update chunks to reference streams pointers
      for (std::size_t col_idx = 0; col_idx < num_columns; col_idx++) {
        auto& chunk = chunks[stripe_idx - stripe_start][col_idx];
        // start row, number of rows in a each stripe and total number of rows
        // may change in lower levels of nesting
        chunk.start_row =
          (level == 0)
            ? stripe_start_row
            : col_meta.child_start_row[(stripe_idx - stripe_start) * num_columns + col_idx];
        chunk.num_rows =
          (level == 0)
            ? static_cast<int64_t>(stripe_info->numberOfRows)
            : col_meta
                .num_child_rows_per_stripe[(stripe_idx - stripe_start) * num_columns + col_idx];
        printf("col idx: %d, start_row: %d, num rows: %d\n",
               (int)col_idx,
               (int)chunk.start_row,
               (int)chunk.num_rows);

        chunk.column_num_rows = (level == 0) ? rows_to_read : col_meta.num_child_rows[col_idx];
        chunk.parent_validity_info =
          (level == 0) ? column_validity_info{} : col_meta.parent_column_data[col_idx];
        chunk.parent_null_count_prefix_sums =
          (level == 0)
            ? nullptr
            : null_count_prefix_sums[level - 1][col_meta.parent_column_index[col_idx]].data();
        chunk.encoding_kind = stripe_footer->columns[columns_level[col_idx].id].kind;
        chunk.type_kind =
          _metadata.per_file_metadata[stripe.source_idx].ff.types[columns_level[col_idx].id].kind;

        printf("type: %d\n", (int)chunk.type_kind);

        // num_child_rows for a struct column will be same, for other nested types it will be
        // calculated.
        chunk.num_child_rows = (chunk.type_kind != orc::STRUCT) ? 0 : chunk.num_rows;
        chunk.dtype_id       = column_types[col_idx].id();
        chunk.decimal_scale  = _metadata.per_file_metadata[stripe.source_idx]
                                .ff.types[columns_level[col_idx].id]
                                .scale.value_or(0);

        chunk.rowgroup_id   = rowgroup_id;
        chunk.dtype_len     = (column_types[col_idx].id() == type_id::STRING)
                                ? sizeof(string_index_pair)
                              : ((column_types[col_idx].id() == type_id::LIST) or
                             (column_types[col_idx].id() == type_id::STRUCT))
                                ? sizeof(size_type)
                                : cudf::size_of(column_types[col_idx]);
        chunk.num_rowgroups = stripe_num_rowgroups;
        // printf("stripe_num_rowgroups: %d\n", (int)stripe_num_rowgroups);

        if (chunk.type_kind == orc::TIMESTAMP) {
          chunk.timestamp_type_id = _config.timestamp_type.id();
        }
        if (not is_stripe_data_empty) {
          for (int k = 0; k < gpu::CI_NUM_STREAMS; k++) {
            chunk.streams[k] = dst_base + stream_info[chunk.strm_id[k] + stream_begin].dst_pos;
            // printf("chunk.streams[%d] of chunk.strm_id[%d], stripe %d | %d, collect from %d\n",
            //        (int)k,
            //        (int)chunk.strm_id[k],
            //        (int)stripe_idx,
            //        (int)stripe_start,
            //        (int)(chunk.strm_id[k] + stream_begin));
          }
        }
      }

      // printf("line %d\n", __LINE__);
      // fflush(stdout);

      stripe_start_row += num_rows_per_stripe;
      num_rowgroups += stripe_num_rowgroups;

      //      stripe_idx++;
    }  // for (stripe : selected_stripes)

    // printf("line %d\n", __LINE__);
    // fflush(stdout);

    if (stripe_data.empty()) { continue; }

    // Process dataset chunk pages into output columns
    auto row_groups =
      cudf::detail::hostdevice_2dvector<gpu::RowGroup>(num_rowgroups, num_columns, _stream);
    if (level > 0 and row_groups.size().first) {
      cudf::host_span<gpu::RowGroup> row_groups_span(row_groups.base_host_ptr(),
                                                     num_rowgroups * num_columns);
      auto& rw_grp_meta = col_meta.rwgrp_meta;

      // Update start row and num rows per row group
      std::transform(rw_grp_meta.begin(),
                     rw_grp_meta.end(),
                     row_groups_span.begin(),
                     rw_grp_meta.begin(),
                     [&](auto meta, auto& row_grp) {
                       row_grp.num_rows  = meta.num_rows;
                       row_grp.start_row = meta.start_row;
                       return meta;
                     });
    }

    // printf("line %d\n", __LINE__);
    // fflush(stdout);

    // Setup row group descriptors if using indexes
    if (_metadata.per_file_metadata[0].ps.compression != orc::NONE) {
      // printf("decompress----------------------\n");
      // printf("line %d\n", __LINE__);
      // fflush(stdout);
      CUDF_EXPECTS(_chunk_read_data.curr_load_stripe_chunk > 0, "ERRRRR");

      {
        _stream.synchronize();
        auto peak_mem = mem_stats_logger.peak_memory_usage();
        std::cout << __LINE__ << ", decomp and decode, peak_memory_usage: " << peak_mem << "("
                  << (peak_mem * 1.0) / (1024.0 * 1024.0) << " MB)" << std::endl;
      }

      auto decomp_data = decompress_stripe_data(
        _chunk_read_data.load_stripe_chunks[_chunk_read_data.curr_load_stripe_chunk - 1],
        stripe_chunk,
        _file_itm_data.compinfo_map,
        *_metadata.per_file_metadata[0].decompressor,
        stripe_data,
        stream_info,
        chunks,
        row_groups,
        num_stripes,
        _metadata.get_row_index_stride(),
        level == 0,
        _stream);
      // stripe_data.clear();
      // stripe_data.push_back(std::move(decomp_data));

      // TODO: only reset each one if the new size/type are different.
      stripe_data[stripe_start - load_stripe_start] = std::move(decomp_data);
      for (int64_t i = 1; i < stripe_chunk.count; ++i) {
        stripe_data[i + stripe_start - load_stripe_start] = {};
      }

      {
        _stream.synchronize();
        auto peak_mem = mem_stats_logger.peak_memory_usage();
        std::cout << __LINE__ << ", decomp and decode, peak_memory_usage: " << peak_mem << "("
                  << (peak_mem * 1.0) / (1024.0 * 1024.0) << " MB)" << std::endl;
      }

      // printf("line %d\n", __LINE__);
      // fflush(stdout);

    } else {
      // printf("no decompression----------------------\n");

      if (row_groups.size().first) {
        // printf("line %d\n", __LINE__);
        // fflush(stdout);
        chunks.host_to_device_async(_stream);
        row_groups.host_to_device_async(_stream);
        row_groups.host_to_device_async(_stream);
        gpu::ParseRowGroupIndex(row_groups.base_device_ptr(),
                                nullptr,
                                chunks.base_device_ptr(),
                                num_columns,
                                num_stripes,
                                _metadata.get_row_index_stride(),
                                level == 0,
                                _stream);
      }
    }

    // printf("line %d\n", __LINE__);
    // fflush(stdout);

    {
      _stream.synchronize();
      auto peak_mem = mem_stats_logger.peak_memory_usage();
      std::cout << __LINE__ << ", decomp and decode, peak_memory_usage: " << peak_mem << "("
                << (peak_mem * 1.0) / (1024.0 * 1024.0) << " MB)" << std::endl;
    }

    // TODO: do not clear but reset each one.
    // and only reset if the new size/type are different.
    _out_buffers[level].clear();

    {
      _stream.synchronize();
      auto peak_mem = mem_stats_logger.peak_memory_usage();
      std::cout << __LINE__ << ", decomp and decode, peak_memory_usage: " << peak_mem << "("
                << (peak_mem * 1.0) / (1024.0 * 1024.0) << " MB)" << std::endl;
    }

    for (std::size_t i = 0; i < column_types.size(); ++i) {
      bool is_nullable = false;
      for (std::size_t j = 0; j < num_stripes; ++j) {
        if (chunks[j][i].strm_len[gpu::CI_PRESENT] != 0) {
          printf("   is nullable\n");
          is_nullable = true;
          break;
        }
      }
      auto is_list_type = (column_types[i].id() == type_id::LIST);
      auto n_rows       = (level == 0) ? rows_to_read : col_meta.num_child_rows[i];

      // printf("  create col, num rows: %d\n", (int)n_rows);

      {
        _stream.synchronize();
        auto peak_mem = mem_stats_logger.peak_memory_usage();
        std::cout << __LINE__ << ", decomp and decode, peak_memory_usage: " << peak_mem << "("
                  << (peak_mem * 1.0) / (1024.0 * 1024.0) << " MB)" << std::endl;
      }

      // For list column, offset column will be always size + 1
      if (is_list_type) n_rows++;
      _out_buffers[level].emplace_back(column_types[i], n_rows, is_nullable, _stream, _mr);

      {
        _stream.synchronize();
        auto peak_mem = mem_stats_logger.peak_memory_usage();
        std::cout << __LINE__ << ", buffer size: " << n_rows
                  << ", decomp and decode, peak_memory_usage: " << peak_mem << "("
                  << (peak_mem * 1.0) / (1024.0 * 1024.0) << " MB)" << std::endl;
      }
    }

    // printf("line %d\n", __LINE__);
    // fflush(stdout);

    {
      _stream.synchronize();
      auto peak_mem = mem_stats_logger.peak_memory_usage();
      std::cout << __LINE__ << ", decomp and decode, peak_memory_usage: " << peak_mem << "("
                << (peak_mem * 1.0) / (1024.0 * 1024.0) << " MB)" << std::endl;
    }

    decode_stream_data(num_dict_entries,
                       rows_to_skip,
                       _metadata.get_row_index_stride(),
                       level,
                       tz_table->view(),
                       chunks,
                       row_groups,
                       _out_buffers[level],
                       _stream,
                       _mr);

    {
      _stream.synchronize();
      auto peak_mem = mem_stats_logger.peak_memory_usage();
      std::cout << __LINE__ << ", decomp and decode, peak_memory_usage: " << peak_mem << "("
                << (peak_mem * 1.0) / (1024.0 * 1024.0) << " MB)" << std::endl;
    }

    // printf("line %d\n", __LINE__);
    // fflush(stdout);

    if (nested_cols.size()) {
      printf("have nested col\n");

      // Extract information to process nested child columns
      scan_null_counts(chunks, null_count_prefix_sums[level], _stream);

      row_groups.device_to_host_sync(_stream);
      aggregate_child_meta(stripe_start,
                           level,
                           _selected_columns,
                           chunks,
                           row_groups,
                           nested_cols,
                           _out_buffers[level],
                           col_meta);

      // ORC stores number of elements at each row, so we need to generate offsets from that
      std::vector<list_buffer_data> buff_data;
      std::for_each(
        _out_buffers[level].begin(), _out_buffers[level].end(), [&buff_data](auto& out_buffer) {
          if (out_buffer.type.id() == type_id::LIST) {
            auto data = static_cast<size_type*>(out_buffer.data());
            buff_data.emplace_back(list_buffer_data{data, out_buffer.size});
          }
        });

      if (not buff_data.empty()) { generate_offsets_for_list(buff_data, _stream); }
    }

    // printf("line %d\n", __LINE__);
    // fflush(stdout);
  }  // end loop level

  {
    _stream.synchronize();
    auto peak_mem = mem_stats_logger.peak_memory_usage();
    std::cout << __LINE__ << ", decomp and decode, peak_memory_usage: " << peak_mem << "("
              << (peak_mem * 1.0) / (1024.0 * 1024.0) << " MB)" << std::endl;
  }

  std::vector<std::unique_ptr<column>> out_columns;
  _out_metadata = get_meta_with_user_data();
  std::transform(
    _selected_columns.levels[0].begin(),
    _selected_columns.levels[0].end(),
    std::back_inserter(out_columns),
    [&](auto const& orc_col_meta) {
      _out_metadata.schema_info.emplace_back("");
      auto col_buffer = assemble_buffer(
        orc_col_meta.id, 0, *_col_meta, _metadata, _selected_columns, _out_buffers, _stream, _mr);
      return make_column(col_buffer, &_out_metadata.schema_info.back(), std::nullopt, _stream);
    });
  _chunk_read_data.decoded_table = std::make_unique<table>(std::move(out_columns));

  // TODO: do not clear but reset each one.
  // and only reset if the new size/type are different.
  // This clear is just to check if there is memory leak.
  for (std::size_t level = 0; level < _selected_columns.num_levels(); ++level) {
    _out_buffers[level].clear();

    auto& stripe_data = lvl_stripe_data[level];

    if (_metadata.per_file_metadata[0].ps.compression != orc::NONE) {
      stripe_data[stripe_start - load_stripe_start] = {};
    } else {
      for (int64_t i = 0; i < stripe_chunk.count; ++i) {
        stripe_data[i + stripe_start - load_stripe_start] = {};
      }
    }
  }

  {
    _stream.synchronize();
    auto peak_mem = mem_stats_logger.peak_memory_usage();
    std::cout << __LINE__ << ", decomp and decode, peak_memory_usage: " << peak_mem << "("
              << (peak_mem * 1.0) / (1024.0 * 1024.0) << " MB)" << std::endl;
  }

  // printf("col: \n");
  // cudf::test::print(_chunk_read_data.decoded_table->get_column(0).view());

  // DEBUG only
  // _chunk_read_data.output_size_limit = _chunk_read_data.data_read_limit / 3;

  _chunk_read_data.curr_output_table_chunk = 0;
  _chunk_read_data.output_table_chunks =
    _chunk_read_data.output_size_limit == 0
      ? std::vector<chunk>{chunk{0, _chunk_read_data.decoded_table->num_rows()}}
      : find_table_splits(_chunk_read_data.decoded_table->view(),
                          _chunk_read_data.output_row_granularity,
                          _chunk_read_data.output_size_limit,
                          _stream);

  auto& splits = _chunk_read_data.output_table_chunks;
  printf("------------\nSplits decoded table (/total num rows = %d): \n",
         (int)_chunk_read_data.decoded_table->num_rows());
  for (size_t idx = 0; idx < splits.size(); idx++) {
    printf("{%ld, %ld}\n", splits[idx].start_idx, splits[idx].count);
  }
  fflush(stdout);

  {
    _stream.synchronize();
    auto peak_mem = mem_stats_logger.peak_memory_usage();
    std::cout << "decomp and decode, peak_memory_usage: " << peak_mem << "("
              << (peak_mem * 1.0) / (1024.0 * 1024.0) << " MB)" << std::endl;
  }
}

void reader::impl::prepare_data(int64_t skip_rows,
                                std::optional<size_type> const& num_rows_opt,
                                std::vector<std::vector<size_type>> const& stripes)
{
  // Selected columns at different levels of nesting are stored in different elements
  // of `selected_columns`; thus, size == 1 means no nested columns
  CUDF_EXPECTS(skip_rows == 0 or _selected_columns.num_levels() == 1,
               "skip_rows is not supported by nested columns");

  // There are no columns in the table.
  if (_selected_columns.num_levels() == 0) { return; }

  std::cout << "call global, skip = " << skip_rows << std::endl;

  global_preprocess(skip_rows, num_rows_opt, stripes);

  if (!_chunk_read_data.more_table_chunk_to_output()) {
    if (!_chunk_read_data.more_stripe_to_decode() && _chunk_read_data.more_stripe_to_load()) {
      printf("load more data\n\n");
      load_data();
    }

    if (_chunk_read_data.more_stripe_to_decode()) {
      printf("decode more data\n\n");
      decompress_and_decode();
    }
  }

  printf("done load and decode data\n\n");

  // decompress_and_decode();
  // while (_chunk_read_data.more_stripe_to_decode()) {
  //   decompress_and_decode();
  //   _file_itm_data.out_buffers.push_back(std::move(_out_buffers));
  // }
}

table_with_metadata reader::impl::make_output_chunk()
{
  {
    _stream.synchronize();
    auto peak_mem = mem_stats_logger.peak_memory_usage();
    std::cout << "start to make out, peak_memory_usage: " << peak_mem << "("
              << (peak_mem * 1.0) / (1024.0 * 1024.0) << " MB)" << std::endl;
  }

  // There is no columns in the table.
  if (_selected_columns.num_levels() == 0) { return {std::make_unique<table>(), table_metadata{}}; }

  // If no rows or stripes to read, return empty columns
  if (_file_itm_data.has_no_data() || !_chunk_read_data.more_table_chunk_to_output()) {
    printf("has no next\n");
    std::vector<std::unique_ptr<column>> out_columns;
    auto out_metadata = get_meta_with_user_data();
    std::transform(_selected_columns.levels[0].begin(),
                   _selected_columns.levels[0].end(),
                   std::back_inserter(out_columns),
                   [&](auto const& col_meta) {
                     out_metadata.schema_info.emplace_back("");
                     return create_empty_column(col_meta.id,
                                                _metadata,
                                                _config.decimal128_columns,
                                                _config.use_np_dtypes,
                                                _config.timestamp_type,
                                                out_metadata.schema_info.back(),
                                                _stream);
                   });
    return {std::make_unique<table>(std::move(out_columns)), std::move(out_metadata)};
  }

#if 1
  auto out_table = [&] {
    if (_chunk_read_data.output_table_chunks.size() == 1) {
      _chunk_read_data.curr_output_table_chunk++;
      printf("one chunk, no more table---------------------------------\n");
      return std::move(_chunk_read_data.decoded_table);
    }

    {
      _stream.synchronize();
      auto peak_mem = mem_stats_logger.peak_memory_usage();
      std::cout << "prepare to make out, peak_memory_usage: " << peak_mem << "("
                << (peak_mem * 1.0) / (1024.0 * 1024.0) << " MB)" << std::endl;
    }

    auto const out_chunk =
      _chunk_read_data.output_table_chunks[_chunk_read_data.curr_output_table_chunk++];
    auto const out_tview =
      cudf::detail::slice(_chunk_read_data.decoded_table->view(),
                          {static_cast<size_type>(out_chunk.start_idx),
                           static_cast<size_type>(out_chunk.start_idx + out_chunk.count)},
                          _stream)[0];
    {
      _stream.synchronize();
      auto peak_mem = mem_stats_logger.peak_memory_usage();
      std::cout << "done make out, peak_memory_usage: " << peak_mem << "("
                << (peak_mem * 1.0) / (1024.0 * 1024.0) << " MB)" << std::endl;
    }

    return std::make_unique<table>(out_tview, _stream, _mr);
  }();

#endif

  if (!_chunk_read_data.has_next()) {
    static int count{0};
    count++;
    _stream.synchronize();
    auto peak_mem = mem_stats_logger.peak_memory_usage();
    std::cout << "complete, " << count << ", peak_memory_usage: " << peak_mem
              << " , MB = " << (peak_mem * 1.0) / (1024.0 * 1024.0) << std::endl;
  } else {
    _stream.synchronize();
    auto peak_mem = mem_stats_logger.peak_memory_usage();
    std::cout << "done, partial, peak_memory_usage: " << peak_mem
              << " , MB = " << (peak_mem * 1.0) / (1024.0 * 1024.0) << std::endl;
  }

  return {std::move(out_table), _out_metadata};
}

table_metadata reader::impl::get_meta_with_user_data()
{
  if (_meta_with_user_data) { return table_metadata{*_meta_with_user_data}; }

  // Copy user data to the output metadata.
  table_metadata out_metadata;
  out_metadata.per_file_user_data.reserve(_metadata.per_file_metadata.size());
  std::transform(_metadata.per_file_metadata.cbegin(),
                 _metadata.per_file_metadata.cend(),
                 std::back_inserter(out_metadata.per_file_user_data),
                 [](auto const& meta) {
                   std::unordered_map<std::string, std::string> kv_map;
                   std::transform(meta.ff.metadata.cbegin(),
                                  meta.ff.metadata.cend(),
                                  std::inserter(kv_map, kv_map.end()),
                                  [](auto const& kv) {
                                    return std::pair{kv.name, kv.value};
                                  });
                   return kv_map;
                 });
  out_metadata.user_data = {out_metadata.per_file_user_data[0].begin(),
                            out_metadata.per_file_user_data[0].end()};

  // Save the output table metadata into `_meta_with_user_data` for reuse next time.
  _meta_with_user_data = std::make_unique<table_metadata>(out_metadata);

  return out_metadata;
}

reader::impl::impl(std::vector<std::unique_ptr<datasource>>&& sources,
                   orc_reader_options const& options,
                   rmm::cuda_stream_view stream,
                   rmm::mr::device_memory_resource* mr)
  : reader::impl::impl(0UL, 0UL, std::move(sources), options, stream, mr)
{
}

reader::impl::impl(std::size_t output_size_limit,
                   std::size_t data_read_limit,
                   std::vector<std::unique_ptr<datasource>>&& sources,
                   orc_reader_options const& options,
                   rmm::cuda_stream_view stream,
                   rmm::mr::device_memory_resource* mr)
  : reader::impl::impl(output_size_limit,
                       data_read_limit,
                       DEFAULT_OUTPUT_ROW_GRANULARITY,
                       std::move(sources),
                       options,
                       stream,
                       mr)
{
}

reader::impl::impl(std::size_t output_size_limit,
                   std::size_t data_read_limit,
                   size_type output_row_granularity,
                   std::vector<std::unique_ptr<datasource>>&& sources,
                   orc_reader_options const& options,
                   rmm::cuda_stream_view stream,
                   rmm::mr::device_memory_resource* mr)
  : _stream(stream),
    _mr(mr),
    _config{options.get_timestamp_type(),
            options.is_enabled_use_index(),
            options.is_enabled_use_np_dtypes(),
            options.get_decimal128_columns(),
            options.get_skip_rows(),
            options.get_num_rows(),
            options.get_stripes()},
    _col_meta{std::make_unique<reader_column_meta>()},
    _sources(std::move(sources)),
    _metadata{_sources, stream},
    _selected_columns{_metadata.select_columns(options.get_columns())},
    _chunk_read_data{
      output_size_limit,
      data_read_limit,
      output_row_granularity > 0 ? output_row_granularity : DEFAULT_OUTPUT_ROW_GRANULARITY},
    mem_stats_logger(mr)
{
  printf("construct reader , limit = %d, %d, gradunarity %d \n",

         (int)output_size_limit,
         (int)data_read_limit,
         (int)output_row_granularity

  );
}

table_with_metadata reader::impl::read(int64_t skip_rows,
                                       std::optional<size_type> const& num_rows_opt,
                                       std::vector<std::vector<size_type>> const& stripes)
{
  prepare_data(skip_rows, num_rows_opt, stripes);
  return make_output_chunk();
}

bool reader::impl::has_next()
{
  printf("==================query has next \n");
  prepare_data(_config.skip_rows, _config.num_read_rows, _config.selected_stripes);

  printf("has next: %d\n", (int)_chunk_read_data.has_next());
  return _chunk_read_data.has_next();
}

table_with_metadata reader::impl::read_chunk()
{
  printf("==================call read chunk\n");
  {
    _stream.synchronize();
    auto peak_mem = mem_stats_logger.peak_memory_usage();
    std::cout << "\n\n\n------------start read chunk, peak_memory_usage: " << peak_mem << "("
              << (peak_mem * 1.0) / (1024.0 * 1024.0) << " MB)" << std::endl;
  }

  {
    static int count{0};
    ++count;

#if 0
    if (count == 3) {
      _file_itm_data.lvl_stripe_data.clear();
      {
        _stream.synchronize();
        auto peak_mem = mem_stats_logger.peak_memory_usage();
        std::cout << "clear all, peak_memory_usage: " << peak_mem << "("
                  << (peak_mem * 1.0) / (1024.0 * 1024.0) << " MB)" << std::endl;
      }
      exit(0);
    }
#endif
  }

  prepare_data(_config.skip_rows, _config.num_read_rows, _config.selected_stripes);

  {
    _stream.synchronize();
    auto peak_mem = mem_stats_logger.peak_memory_usage();
    std::cout << "done prepare data, peak_memory_usage: " << peak_mem << "("
              << (peak_mem * 1.0) / (1024.0 * 1024.0) << " MB)" << std::endl;
  }

  return make_output_chunk();
}

}  // namespace cudf::io::orc::detail
