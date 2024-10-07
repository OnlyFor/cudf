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
#include "page_data.cuh"
#include "page_decode.cuh"
#include "parquet_gpu.hpp"
#include "rle_stream.cuh"

#include <cudf/detail/utilities/cuda.cuh>

namespace cudf::io::parquet::detail {

namespace {

// Unlike cub's algorithm, this provides warp-wide and block-wide results simultaneously.
// Also, this provides the ability to compute warp_bits & lane_mask manually, which we need for
// lists.
struct block_scan_results {
  uint32_t warp_bits;
  int thread_count_within_warp;
  int warp_count;

  int thread_count_within_block;
  int block_count;
};

template <int decode_block_size>
__device__ inline static void scan_block_exclusive_sum(int thread_bit, block_scan_results& results)
{
  int const t = threadIdx.x;
  int const warp_index     = t / cudf::detail::warp_size;
  int const warp_lane      = t % cudf::detail::warp_size;
  uint32_t const lane_mask = (uint32_t(1) << warp_lane) - 1;

  uint32_t warp_bits = ballot(thread_bit);
  scan_block_exclusive_sum<decode_block_size>(warp_bits, warp_lane, warp_index, lane_mask, results);
}

template <int decode_block_size>
__device__ inline static void scan_block_exclusive_sum(uint32_t warp_bits, int warp_lane, int warp_index, uint32_t lane_mask, block_scan_results& results)
{
  //Compute # warps
  constexpr int num_warps = decode_block_size / cudf::detail::warp_size;
  
  //Compute the warp-wide results
  results.warp_bits                = warp_bits;
  results.warp_count               = __popc(results.warp_bits);
  results.thread_count_within_warp = __popc(results.warp_bits & lane_mask);

  //Share the warp counts amongst the block threads
  __shared__ int warp_counts[num_warps];
  if (warp_lane == 0) { warp_counts[warp_index] = results.warp_count; }
  __syncthreads();

  //Compute block-wide results
  results.block_count               = 0;
  results.thread_count_within_block = results.thread_count_within_warp;
  for (int warp_idx = 0; warp_idx < num_warps; ++warp_idx) {
    results.block_count += warp_counts[warp_idx];
    if (warp_idx < warp_index) { results.thread_count_within_block += warp_counts[warp_idx]; }
  }
}

template <int block_size, bool has_lists_t, typename state_buf>
__device__ inline void gpuDecodeFixedWidthValues(
  page_state_s* s, state_buf* const sb, int start, int end, int t)
{
  constexpr int num_warps      = block_size / cudf::detail::warp_size;
  constexpr int max_batch_size = num_warps * cudf::detail::warp_size;

  PageNestingDecodeInfo* nesting_info_base = s->nesting_info;
  int const dtype                          = s->col.physical_type;

  int const leaf_level_index = s->col.max_nesting_depth - 1;
  uint32_t dtype_len = s->dtype_len;
  auto const data_out = nesting_info_base[leaf_level_index].data_out;
  uint32_t const skipped_leaf_values = s->page.skipped_leaf_values;

  static constexpr bool enable_print = false;
  static constexpr bool enable_print_range_error = false;
//  static constexpr bool enable_print_large_list = true;

  if constexpr (enable_print) {
    if(t == 0) { printf("DECODE VALUES: start %d, end %d, first_row %d, leaf_level_index %d, dtype_len %u, "
      "data_out %p, dict_base %p, dict_size %d, dict_bits %d, dict_val %d, data_start %p, skipped_leaf_values %u, input_row_count %d\n", 
      start, end, s->first_row, leaf_level_index, dtype_len, data_out, s->dict_base, s->dict_bits, s->dict_val, 
      s->dict_size, s->data_start, skipped_leaf_values, s->input_row_count);
    }
  }

  // decode values
  int pos = start;
  while (pos < end) {
    int const batch_size = min(max_batch_size, end - pos);

    int const target_pos = pos + batch_size;
    int src_pos    = pos + t;

    // the position in the output column/buffer
//Index from rolling buffer of values (which doesn't include nulls) to final array (which includes gaps for nulls)
    auto offset = sb->nz_idx[rolling_index<state_buf::nz_buf_size>(src_pos)];
    int dst_pos = offset;
    if constexpr (!has_lists_t) {
      dst_pos -= s->first_row;
    }

    if constexpr (has_lists_t && enable_print_range_error) {
      if((dst_pos < 0) && (src_pos < target_pos)) { printf("WHOA: decode dst_pos %d out of bounds, src_pos %d, start %d\n", dst_pos, src_pos, start); }
    }

    int dict_idx = rolling_index<state_buf::dict_buf_size>(src_pos + skipped_leaf_values);
    int dict_pos = sb->dict_idx[dict_idx];
    if constexpr (enable_print) {
      if(t == 0) { 
        printf("DECODE OFFSETS: pos %d, src_pos %d, offset %d, dst_pos %d, target_pos %d, dict_idx %d, dict_pos %d\n", 
          pos, src_pos, offset, dst_pos, target_pos, dict_idx, dict_pos);
      }
    }

    // target_pos will always be properly bounded by num_rows, but dst_pos may be negative (values
    // before first_row) in the flat hierarchy case.
    if (src_pos < target_pos && dst_pos >= 0) {
      // nesting level that is storing actual leaf values

      // src_pos represents the logical row position we want to read from. But in the case of
      // nested hierarchies (lists), there is no 1:1 mapping of rows to values.  So our true read position
      // has to take into account the # of values we have to skip in the page to get to the
      // desired logical row.  For flat hierarchies, skipped_leaf_values will always be 0.
      if constexpr (has_lists_t) {
        src_pos += skipped_leaf_values;
      }

      void* dst = data_out + static_cast<size_t>(dst_pos) * dtype_len;
      if constexpr (enable_print) {
        if(dst_pos == 0) {
          printf("WRITTEN TO dst_pos ZERO: t %d, data_out %p, dst %p, src_pos %d, dict_idx %d, dict_pos %d, dict_base %p\n", 
            t, data_out, dst, src_pos, dict_idx, dict_pos, s->dict_base);
        }
      }

      if (s->col.logical_type.has_value() && s->col.logical_type->type == LogicalType::DECIMAL) {
        switch (dtype) {
          case INT32: gpuOutputFast(s, sb, src_pos, static_cast<uint32_t*>(dst)); break;
          case INT64: gpuOutputFast(s, sb, src_pos, static_cast<uint2*>(dst)); break;
          default:
            if (s->dtype_len_in <= sizeof(int32_t)) {
              gpuOutputFixedLenByteArrayAsInt(s, sb, src_pos, static_cast<int32_t*>(dst));
            } else if (s->dtype_len_in <= sizeof(int64_t)) {
              gpuOutputFixedLenByteArrayAsInt(s, sb, src_pos, static_cast<int64_t*>(dst));
            } else {
              gpuOutputFixedLenByteArrayAsInt(s, sb, src_pos, static_cast<__int128_t*>(dst));
            }
            break;
        }
      } else if (dtype == INT96) {
        gpuOutputInt96Timestamp(s, sb, src_pos, static_cast<int64_t*>(dst));
      } else if (dtype_len == 8) {
        if (s->dtype_len_in == 4) {
          // Reading INT32 TIME_MILLIS into 64-bit DURATION_MILLISECONDS
          // TIME_MILLIS is the only duration type stored as int32:
          // https://github.com/apache/parquet-format/blob/master/LogicalTypes.md#deprecated-time-convertedtype
          gpuOutputFast(s, sb, src_pos, static_cast<uint32_t*>(dst));
        } else if (s->ts_scale) {
          gpuOutputInt64Timestamp(s, sb, src_pos, static_cast<int64_t*>(dst));
        } else {
          gpuOutputFast(s, sb, src_pos, static_cast<uint2*>(dst));
        }
      } else if (dtype_len == 4) {
        gpuOutputFast(s, sb, src_pos, static_cast<uint32_t*>(dst));
      } else {
        gpuOutputGeneric(s, sb, src_pos, static_cast<uint8_t*>(dst), dtype_len);
      }
/*
      if constexpr (enable_print_large_list) {
        if (dtype == INT32) {
          int value_stored = *static_cast<uint32_t*>(dst);
          int overall_index = blockIdx.x * 20000 * 4 + src_pos;
          if((overall_index % 1024) != value_stored) {
            printf("WHOA BAD VALUE: WROTE %d to %d!\n", value_stored, overall_index);
          }
        }
      }
      */
    }

    pos += batch_size;
  }
}

template <int block_size, bool has_lists_t, typename state_buf>
struct decode_fixed_width_values_func {
  __device__ inline void operator()(page_state_s* s, state_buf* const sb, int start, int end, int t)
  {
    gpuDecodeFixedWidthValues<block_size, has_lists_t, state_buf>(s, sb, start, end, t);
  }
};

template <int block_size, bool has_lists_t, typename state_buf>
__device__ inline void gpuDecodeFixedWidthSplitValues(
  page_state_s* s, state_buf* const sb, int start, int end, int t)
{
  using cudf::detail::warp_size;
  constexpr int num_warps      = block_size / warp_size;
  constexpr int max_batch_size = num_warps * warp_size;

  PageNestingDecodeInfo* nesting_info_base = s->nesting_info;
  int const dtype                          = s->col.physical_type;
  auto const data_len                      = thrust::distance(s->data_start, s->data_end);
  auto const num_values                    = data_len / s->dtype_len_in;
  uint32_t const skipped_leaf_values = s->page.skipped_leaf_values;

  // decode values
  int pos = start;
  while (pos < end) {
    int const batch_size = min(max_batch_size, end - pos);

    int const target_pos = pos + batch_size;
    int src_pos    = pos + t;

    // the position in the output column/buffer
    int dst_pos = sb->nz_idx[rolling_index<state_buf::nz_buf_size>(src_pos)];
    if constexpr (!has_lists_t) {
      dst_pos -= s->first_row;
    }

    // target_pos will always be properly bounded by num_rows, but dst_pos may be negative (values
    // before first_row) in the flat hierarchy case.
    if (src_pos < target_pos && dst_pos >= 0) {
      // nesting level that is storing actual leaf values
      int const leaf_level_index = s->col.max_nesting_depth - 1;

      // src_pos represents the logical row position we want to read from. But in the case of
      // nested hierarchies (lists), there is no 1:1 mapping of rows to values.  So our true read position
      // has to take into account the # of values we have to skip in the page to get to the
      // desired logical row.  For flat hierarchies, skipped_leaf_values will always be 0.
      if constexpr (has_lists_t) {
        src_pos += skipped_leaf_values;
      }

      uint32_t dtype_len = s->dtype_len;
      uint8_t const* src = s->data_start + src_pos;
      uint8_t* dst =
        nesting_info_base[leaf_level_index].data_out + static_cast<size_t>(dst_pos) * dtype_len;
      auto const is_decimal =
        s->col.logical_type.has_value() and s->col.logical_type->type == LogicalType::DECIMAL;

      // Note: non-decimal FIXED_LEN_BYTE_ARRAY will be handled in the string reader
      if (is_decimal) {
        switch (dtype) {
          case INT32: gpuOutputByteStreamSplit<int32_t>(dst, src, num_values); break;
          case INT64: gpuOutputByteStreamSplit<int64_t>(dst, src, num_values); break;
          case FIXED_LEN_BYTE_ARRAY:
            if (s->dtype_len_in <= sizeof(int32_t)) {
              gpuOutputSplitFixedLenByteArrayAsInt(
                reinterpret_cast<int32_t*>(dst), src, num_values, s->dtype_len_in);
              break;
            } else if (s->dtype_len_in <= sizeof(int64_t)) {
              gpuOutputSplitFixedLenByteArrayAsInt(
                reinterpret_cast<int64_t*>(dst), src, num_values, s->dtype_len_in);
              break;
            } else if (s->dtype_len_in <= sizeof(__int128_t)) {
              gpuOutputSplitFixedLenByteArrayAsInt(
                reinterpret_cast<__int128_t*>(dst), src, num_values, s->dtype_len_in);
              break;
            }
            // unsupported decimal precision
            [[fallthrough]];

          default: s->set_error_code(decode_error::UNSUPPORTED_ENCODING);
        }
      } else if (dtype_len == 8) {
        if (s->dtype_len_in == 4) {
          // Reading INT32 TIME_MILLIS into 64-bit DURATION_MILLISECONDS
          // TIME_MILLIS is the only duration type stored as int32:
          // https://github.com/apache/parquet-format/blob/master/LogicalTypes.md#deprecated-time-convertedtype
          gpuOutputByteStreamSplit<int32_t>(dst, src, num_values);
          // zero out most significant bytes
          memset(dst + 4, 0, 4);
        } else if (s->ts_scale) {
          gpuOutputSplitInt64Timestamp(
            reinterpret_cast<int64_t*>(dst), src, num_values, s->ts_scale);
        } else {
          gpuOutputByteStreamSplit<int64_t>(dst, src, num_values);
        }
      } else if (dtype_len == 4) {
        gpuOutputByteStreamSplit<int32_t>(dst, src, num_values);
      } else {
        s->set_error_code(decode_error::UNSUPPORTED_ENCODING);
      }
    }

    pos += batch_size;
  }
}

template <int block_size, bool has_lists_t, typename state_buf>
struct decode_fixed_width_split_values_func {
  __device__ inline void operator()(page_state_s* s, state_buf* const sb, int start, int end, int t)
  {
    gpuDecodeFixedWidthSplitValues<block_size, has_lists_t, state_buf>(s, sb, start, end, t);
  }
};

template <int decode_block_size, typename level_t, typename state_buf>
static __device__ int gpuUpdateValidityAndRowIndicesNested(
  int32_t target_value_count, page_state_s* s, state_buf* sb, level_t const* const def, int t)
{
  constexpr int num_warps      = decode_block_size / cudf::detail::warp_size;
  constexpr int max_batch_size = num_warps * cudf::detail::warp_size;

  // how many (input) values we've processed in the page so far
  int value_count = s->input_value_count;

  // cap by last row so that we don't process any rows past what we want to output.
  int const first_row                 = s->first_row;
  int const last_row                  = first_row + s->num_rows;
  int const capped_target_value_count = min(target_value_count, last_row);

  static constexpr bool enable_print = false;
  if constexpr (enable_print) {
    if (t == 0) { printf("NESTED: s->input_value_count %d, first_row %d, last_row %d, target_value_count %d, capped_target_value_count %d\n", 
      s->input_value_count, first_row, last_row, target_value_count, capped_target_value_count); }
  }

  int const row_index_lower_bound = s->row_index_lower_bound;

  int const max_depth       = s->col.max_nesting_depth - 1;
  auto& max_depth_ni        = s->nesting_info[max_depth];
  int max_depth_valid_count = max_depth_ni.valid_count;

  __syncthreads();

  while (value_count < capped_target_value_count) {
    if constexpr (enable_print) {
      if(t == 0) { printf("NESTED VALUE COUNT: %d\n", value_count); }
    }
    int const batch_size = min(max_batch_size, capped_target_value_count - value_count);

    // definition level
    int d = 1;
    if (t >= batch_size) {
      d = -1;
    } else if (def) {
      d = static_cast<int>(def[rolling_index<state_buf::nz_buf_size>(value_count + t)]);
    }

    int const thread_value_count = t;
    int const block_value_count  = batch_size;

    // compute our row index, whether we're in row bounds, and validity
    int const row_index           = thread_value_count + value_count;
    int const in_row_bounds       = (row_index >= row_index_lower_bound) && (row_index < last_row);
    int const in_write_row_bounds = ballot(row_index >= first_row && row_index < last_row);
    int const write_start = __ffs(in_write_row_bounds) - 1;  // first bit in the warp to store

    if constexpr (enable_print) {
      if(t == 0) { printf("NESTED ROWS: row_index %d, row_index_lower_bound %d, last_row %d, in_row_bounds %d\n", 
        row_index, row_index_lower_bound, last_row, in_row_bounds); }
    }

    // iterate by depth
    for (int d_idx = 0; d_idx <= max_depth; d_idx++) {
      auto& ni = s->nesting_info[d_idx];

      int const is_valid = ((d >= ni.max_def_level) && in_row_bounds) ? 1 : 0;

      // thread and block validity count
      using block_scan = cub::BlockScan<int, decode_block_size>;
      __shared__ typename block_scan::TempStorage scan_storage;
      int thread_valid_count, block_valid_count;
      block_scan(scan_storage).ExclusiveSum(is_valid, thread_valid_count, block_valid_count);

      // validity is processed per-warp
      //
      // nested schemas always read and write to the same bounds (that is, read and write
      // positions are already pre-bounded by first_row/num_rows). flat schemas will start reading
      // at the first value, even if that is before first_row, because we cannot trivially jump to
      // the correct position to start reading. since we are about to write the validity vector
      // here we need to adjust our computed mask to take into account the write row bounds.
      int warp_null_count = 0;
      if (ni.valid_map != nullptr) {
        uint32_t const warp_validity_mask = ballot(is_valid);
        // lane 0 from each warp writes out validity
        if ((write_start >= 0) && ((t % cudf::detail::warp_size) == 0)) {
          int const valid_map_offset = ni.valid_map_offset;
          int const vindex     = value_count + thread_value_count;  // absolute input value index
          int const bit_offset = (valid_map_offset + vindex + write_start) -
                                 first_row;  // absolute bit offset into the output validity map
          int const write_end =
            cudf::detail::warp_size - __clz(in_write_row_bounds);  // last bit in the warp to store
          int const bit_count = write_end - write_start;
          warp_null_count     = bit_count - __popc(warp_validity_mask >> write_start);

          store_validity(bit_offset, ni.valid_map, warp_validity_mask >> write_start, bit_count);
        }
      }

      // sum null counts. we have to do it this way instead of just incrementing by (value_count -
      // valid_count) because valid_count also includes rows that potentially start before our row
      // bounds. if we could come up with a way to clean that up, we could remove this and just
      // compute it directly at the end of the kernel.
      size_type const block_null_count =
        cudf::detail::single_lane_block_sum_reduce<decode_block_size, 0>(warp_null_count);
      if (t == 0) { ni.null_count += block_null_count; }

      // if this is valid and we're at the leaf, output dst_pos
      if (d_idx == max_depth) {
        if (is_valid) {
          int const dst_pos = value_count + thread_value_count;
          int const src_pos = max_depth_valid_count + thread_valid_count;
          sb->nz_idx[rolling_index<state_buf::nz_buf_size>(src_pos)] = dst_pos;
          if constexpr (enable_print) {
            if(t == 0) {printf("NESTED STORE: first_row %d, row_index %d dst_pos %d, src_pos %d\n", 
              first_row, row_index, dst_pos, src_pos);}
          }
        }
        // update stuff
        max_depth_valid_count += block_valid_count;
      }

    }  // end depth loop

    value_count += block_value_count;
  }  // end loop

  if (t == 0) {
    // update valid value count for decoding and total # of values we've processed
    max_depth_ni.valid_count = max_depth_valid_count;
    s->nz_count              = max_depth_valid_count;
    s->input_value_count     = value_count;
    s->input_row_count       = value_count;
  }

  return max_depth_valid_count;
}

template <int decode_block_size, typename level_t, typename state_buf>
static __device__ int gpuUpdateValidityAndRowIndicesFlat(
  int32_t target_value_count, page_state_s* s, state_buf* sb, level_t const* const def, int t)
{
  constexpr int num_warps      = decode_block_size / cudf::detail::warp_size;
  constexpr int max_batch_size = num_warps * cudf::detail::warp_size;

  auto& ni = s->nesting_info[0];

  // how many (input) values we've processed in the page so far
  int value_count = s->input_value_count;
  int valid_count = ni.valid_count;

  // cap by last row so that we don't process any rows past what we want to output.
  int const first_row                 = s->first_row;
  int const last_row                  = first_row + s->num_rows;
  int const capped_target_value_count = min(target_value_count, last_row);

  static constexpr bool enable_print = false;
  if constexpr (enable_print) {
    if (t == 0) { printf("FLAT: s->input_value_count %d, first_row %d, last_row %d, target_value_count %d, capped_target_value_count %d\n", 
      s->input_value_count, first_row, last_row, target_value_count, capped_target_value_count); }
  }

  int const valid_map_offset      = ni.valid_map_offset;
  int const row_index_lower_bound = s->row_index_lower_bound;

  __syncthreads();

  while (value_count < capped_target_value_count) {
    if constexpr (enable_print) {
      if(t == 0) { printf("FLAT VALUE COUNT: %d\n", value_count); }
    }

    int const batch_size = min(max_batch_size, capped_target_value_count - value_count);

    int const thread_value_count = t;
    int const block_value_count  = batch_size;

    // compute our row index, whether we're in row bounds, and validity
    int const row_index     = thread_value_count + value_count;
    int const in_row_bounds = (row_index >= row_index_lower_bound) && (row_index < last_row);

    // use definition level & row bounds to determine if is valid
    int is_valid;
    if (t >= batch_size) {
      is_valid = 0;
    } else if (def) {
      int const def_level =
        static_cast<int>(def[rolling_index<state_buf::nz_buf_size>(value_count + t)]);
      is_valid = ((def_level > 0) && in_row_bounds) ? 1 : 0;
    } else {
      is_valid = in_row_bounds;
    }

    // thread and block validity count
    using block_scan = cub::BlockScan<int, decode_block_size>;
    __shared__ typename block_scan::TempStorage scan_storage;
    int thread_valid_count, block_valid_count;
    block_scan(scan_storage).ExclusiveSum(is_valid, thread_valid_count, block_valid_count);
    uint32_t const warp_validity_mask = ballot(is_valid);

    // validity is processed per-warp
    //
    // nested schemas always read and write to the same bounds (that is, read and write
    // positions are already pre-bounded by first_row/num_rows). flat schemas will start reading
    // at the first value, even if that is before first_row, because we cannot trivially jump to
    // the correct position to start reading. since we are about to write the validity vector
    // here we need to adjust our computed mask to take into account the write row bounds.
    int const in_write_row_bounds = ballot(row_index >= first_row && row_index < last_row);
    int const write_start = __ffs(in_write_row_bounds) - 1;  // first bit in the warp to store
    int warp_null_count   = 0;
    // lane 0 from each warp writes out validity
    if ((write_start >= 0) && ((t % cudf::detail::warp_size) == 0)) {
      int const vindex     = value_count + thread_value_count;  // absolute input value index
      int const bit_offset = (valid_map_offset + vindex + write_start) -
                             first_row;  // absolute bit offset into the output validity map
      int const write_end =
        cudf::detail::warp_size - __clz(in_write_row_bounds);  // last bit in the warp to store
      int const bit_count = write_end - write_start;
      warp_null_count     = bit_count - __popc(warp_validity_mask >> write_start);

      store_validity(bit_offset, ni.valid_map, warp_validity_mask >> write_start, bit_count);
    }

    // sum null counts. we have to do it this way instead of just incrementing by (value_count -
    // valid_count) because valid_count also includes rows that potentially start before our row
    // bounds. if we could come up with a way to clean that up, we could remove this and just
    // compute it directly at the end of the kernel.
    size_type const block_null_count =
      cudf::detail::single_lane_block_sum_reduce<decode_block_size, 0>(warp_null_count);
    if (t == 0) { ni.null_count += block_null_count; }

    // output offset
    if (is_valid) {
      int const dst_pos = value_count + thread_value_count;
      int const src_pos = valid_count + thread_valid_count;

      sb->nz_idx[rolling_index<state_buf::nz_buf_size>(src_pos)] = dst_pos;
    }

    // update stuff
    value_count += block_value_count;
    valid_count += block_valid_count;
  }

  if (t == 0) {
    // update valid value count for decoding and total # of values we've processed
    ni.valid_count       = valid_count;
    ni.value_count       = value_count;
    s->nz_count          = valid_count;
    s->input_value_count = value_count;
    s->input_row_count   = value_count;
  }

  return valid_count;
}

template <int decode_block_size, typename state_buf>
static __device__ int gpuUpdateValidityAndRowIndicesNonNullable(int32_t target_value_count,
                                                                page_state_s* s,
                                                                state_buf* sb,
                                                                int t)
{
  constexpr int num_warps      = decode_block_size / cudf::detail::warp_size;
  constexpr int max_batch_size = num_warps * cudf::detail::warp_size;

  // cap by last row so that we don't process any rows past what we want to output.
  int const first_row                 = s->first_row;
  int const last_row                  = first_row + s->num_rows;
  int const capped_target_value_count = min(target_value_count, last_row);
  int const row_index_lower_bound     = s->row_index_lower_bound;

  // how many (input) values we've processed in the page so far
  int value_count = s->input_value_count;

  int const max_depth = s->col.max_nesting_depth - 1;
  auto& ni            = s->nesting_info[max_depth];
  int valid_count     = ni.valid_count;

  __syncthreads();

  while (value_count < capped_target_value_count) {
    int const batch_size = min(max_batch_size, capped_target_value_count - value_count);

    int const thread_value_count = t;
    int const block_value_count  = batch_size;

    // compute our row index, whether we're in row bounds, and validity
    int const row_index     = thread_value_count + value_count;
    int const in_row_bounds = (row_index >= row_index_lower_bound) && (row_index < last_row);

    int const is_valid           = in_row_bounds;
    int const thread_valid_count = thread_value_count;
    int const block_valid_count  = block_value_count;

    // if this is valid and we're at the leaf, output dst_pos
    if (is_valid) {
      // for non-list types, the value count is always the same across
      int const dst_pos = value_count + thread_value_count;
      int const src_pos = valid_count + thread_valid_count;

      sb->nz_idx[rolling_index<state_buf::nz_buf_size>(src_pos)] = dst_pos;
    }

    // update stuff
    value_count += block_value_count;
    valid_count += block_valid_count;
  }  // end loop

  if (t == 0) {
    // update valid value count for decoding and total # of values we've processed
    ni.valid_count       = valid_count;
    ni.value_count       = value_count;
    s->nz_count          = valid_count;
    s->input_value_count = value_count;
    s->input_row_count   = value_count;
  }

  return valid_count;
}

template <int decode_block_size, bool nullable, typename level_t, typename state_buf>
static __device__ int gpuUpdateValidityAndRowIndicesLists(
  int32_t target_value_count, page_state_s* s, state_buf* sb, level_t const* const def, 
  level_t const* const rep, int t)
{
  //What is the output of this? Validity bits and offsets to list starts
  constexpr int num_warps      = decode_block_size / cudf::detail::warp_size;
  constexpr int max_batch_size = num_warps * cudf::detail::warp_size;

  // how many (input) values we've processed in the page so far, prior to this loop iteration
  int value_count = s->input_value_count;

  static constexpr bool enable_print = false;
  static constexpr bool enable_print_range_error = false;
  static constexpr bool enable_print_large_list = false;

  // how many rows we've processed in the page so far
  int input_row_count = s->input_row_count;
  if constexpr (enable_print) {
    if (t == 0) { printf("value_count %d, input_row_count %d\n", value_count, input_row_count); }
  }

  // cap by last row so that we don't process any rows past what we want to output.
  int const first_row                 = s->first_row;
  int const last_row                  = first_row + s->num_rows;
  if constexpr (enable_print) {
    if (t == 0) { printf("LIST s->input_value_count %d, first_row %d, last_row %d, target_value_count %d\n", 
      s->input_value_count, first_row, last_row, target_value_count); }
  }

  int const row_index_lower_bound = s->row_index_lower_bound;
  int const max_depth = s->col.max_nesting_depth - 1;
  int max_depth_valid_count = s->nesting_info[max_depth].valid_count;

  __syncthreads();
  
  int const warp_index     = t / cudf::detail::warp_size;
  int const warp_lane      = t % cudf::detail::warp_size;
  bool const is_first_lane = (warp_lane == 0);

  while (value_count < target_value_count) {

    if constexpr (enable_print) {
      if(t == 0) { printf("LIST VALUE COUNT: %d\n", value_count); }
    }
    bool const within_batch = value_count + t < target_value_count;

    // get definition level, use repitition level to get start/end depth
    // different for each thread, as each thread has a different r/d
    int def_level = -1, start_depth = -1, end_depth = -1;
    if (within_batch) {
      int const index = rolling_index<state_buf::nz_buf_size>(value_count + t);
      int rep_level = static_cast<int>(rep[index]);
      if constexpr (nullable) {
        def_level = static_cast<int>(def[index]);
        end_depth = s->nesting_info[def_level].end_depth;
      } else {
        end_depth = max_depth;
      }

      //computed by generate_depth_remappings()
      if constexpr (enable_print || enable_print_range_error) {
        if((rep_level < 0) || (rep_level > max_depth)) {
          printf("WHOA: rep level %d out of bounds %d!\n", rep_level, max_depth);
        }
        if(nullable && ((def_level < 0)/* || (def_level > (max_depth + 1)) */ )) {
          printf("WHOA: def level %d out of bounds (max_depth %d) (index %d)!\n", def_level, max_depth, index);
        }
      }

      start_depth = s->nesting_info[rep_level].start_depth;
      if constexpr (enable_print || enable_print_range_error) {
        if((start_depth < 0) || (start_depth > (max_depth + 1))) {
          printf("WHOA: start_depth %d out of bounds (max_depth %d) (index %d)!\n", start_depth, max_depth, index);
        }
        if((end_depth < 0) || (end_depth > (max_depth + 1))) {
          printf("WHOA: end_depth %d out of bounds (max_depth %d) (index %d)!\n", end_depth, max_depth, index);
        }
      }
      if constexpr (enable_print) {
        if (t == 0) { printf("t %d, def_level %d, rep_level %d, start_depth %d, end_depth %d, max_depth %d\n", \
          t, def_level, rep_level, start_depth, end_depth, max_depth); }
      }
    }

    //Determine value count & row index
    // track (page-relative) row index for the thread so we can compare against input bounds
    // keep track of overall # of rows we've read.
    int const is_new_row = start_depth == 0 ? 1 : 0;
    int num_prior_new_rows, total_num_new_rows;
    {
      block_scan_results new_row_scan_results;
      scan_block_exclusive_sum<decode_block_size>(is_new_row, new_row_scan_results);
      num_prior_new_rows = new_row_scan_results.thread_count_within_block;
      total_num_new_rows = new_row_scan_results.block_count;
    }

if constexpr (enable_print_large_list) {
  if(within_batch && (bool(is_new_row) != (t % 4 == 0))) {
    printf("CUB GARBAGE: blockIdx.x %d, value_count %d, target_value_count %d, t %d, is_new_row %d, start_depth %d\n", 
      blockIdx.x, value_count, target_value_count, t, is_new_row, start_depth);
  }
  if(within_batch && (num_prior_new_rows != ((t + 3) / 4))) {
    printf("CUB GARBAGE: blockIdx.x %d, value_count %d, target_value_count %d, t %d, num_prior_new_rows %d\n", 
      blockIdx.x, value_count, target_value_count, t, num_prior_new_rows);
  }
  if((value_count + 128 <= target_value_count) && (total_num_new_rows != 32)) {
    printf("CUB GARBAGE: blockIdx.x %d, value_count %d, target_value_count %d, t %d, total_num_new_rows %d\n", 
      blockIdx.x, value_count, target_value_count, t, total_num_new_rows);
  }
}

    if constexpr (enable_print) {
      if (t == 0) { printf("num_prior_new_rows %d, total_num_new_rows %d\n", num_prior_new_rows, total_num_new_rows); }
    }

    int const row_index = input_row_count + (num_prior_new_rows + is_new_row - 1);
    input_row_count += total_num_new_rows;
    int const in_row_bounds = (row_index >= row_index_lower_bound) && (row_index < last_row);

    // thread and block value count

    // if we are within the range of nesting levels we should be adding value indices for
    // is from/in current rep level to/in the rep level AT the depth with the def value
    int in_nesting_bounds = ((0 >= start_depth && 0 <= end_depth) && in_row_bounds) ? 1 : 0;

    if constexpr (enable_print) {
      if(t == 0) { printf("LIST ROWS: row_index %d, row_index_lower_bound %d, last_row %d, in_row_bounds %d, in_nesting_bounds %d\n", 
        row_index, row_index_lower_bound, last_row, in_row_bounds, in_nesting_bounds); }
      if (t < 32) { printf("t %d, is_new_row %d, num_prior_new_rows %d, row_index %d, in_row_bounds %d\n", 
        t, is_new_row, num_prior_new_rows, row_index, in_row_bounds); }
    }

    // queries is_valid from all threads, stores prior total and total total

    //WARP VALUE COUNT:
    int thread_value_count_within_warp, warp_value_count, thread_value_count, block_value_count;
    {
      block_scan_results value_count_scan_results;
      scan_block_exclusive_sum<decode_block_size>(in_nesting_bounds, value_count_scan_results);

      thread_value_count_within_warp = value_count_scan_results.thread_count_within_warp;
      warp_value_count = value_count_scan_results.warp_count;
      thread_value_count = value_count_scan_results.thread_count_within_block;
      block_value_count = value_count_scan_results.block_count;
    }

if constexpr (enable_print_large_list) {
  if(within_batch && in_row_bounds && (in_nesting_bounds != (t % 4 == 0))) {
    printf("CUB GARBAGE: blockIdx.x %d, value_count %d, target_value_count %d, t %d, in_nesting_bounds %d, start_depth %d, end_depth %d, "
      "in_row_bounds %d, row_index %d, input_row_count %d, row_index_lower_bound %d, last_row %d, first_row %d, s->num_rows %d\n", 
      blockIdx.x, value_count, target_value_count, t, in_nesting_bounds, start_depth, end_depth, in_row_bounds, row_index, input_row_count, 
      row_index_lower_bound, last_row, first_row, s->num_rows);
  }
  if(within_batch && in_row_bounds && (thread_value_count != ((t + 3) / 4))) {
    printf("CUB GARBAGE: blockIdx.x %d, value_count %d, target_value_count %d, t %d, thread_value_count %d\n", 
      blockIdx.x, value_count, target_value_count, t, thread_value_count);
  }
  if((value_count + 128 <= target_value_count) && (input_row_count + total_num_new_rows <= last_row) && (block_value_count != 32)) {
    printf("CUB GARBAGE: blockIdx.x %d, value_count %d, target_value_count %d, t %d, block_value_count %d\n", 
      blockIdx.x, value_count, target_value_count, t, block_value_count);
  }
}

    if constexpr (enable_print) {
      if (t == 0) { printf("block_value_count %d\n", block_value_count); }
      if (t < 32) { printf("t %d, thread_value_count %d, in_nesting_bounds %d\n", 
        t, thread_value_count, in_nesting_bounds); }
    }

    // column is either nullable or is a list (or both): iterate by depth
    for (int d_idx = 0; d_idx <= max_depth; d_idx++) {

      auto& ni = s->nesting_info[d_idx];

      // everything up to the max_def_level is a non-null value
      int is_valid;
      if constexpr (nullable) {
        is_valid = ((def_level >= ni.max_def_level) && in_nesting_bounds) ? 1 : 0;
      } else {
        is_valid = in_nesting_bounds;
      }

      if constexpr (enable_print) {
        if (t == 0) { printf("nullable %d, depth %d, max_depth %d, max_def_level %d, value_count %d\n", 
          int(nullable), d_idx, max_depth, ni.max_def_level, value_count); }
        if (t < 32) { printf("t %d, def_level %d, in_nesting_bounds %d, is_valid %d\n", 
          t, def_level, in_nesting_bounds, is_valid); }
      }

      // thread and block validity count
      // queries is_valid of all threads, stores prior total and total total

      // for nested lists, it's more complicated.  This block will visit 128 incoming values,
      // however not all of them will necessarily represent a value at this nesting level. so
      // the validity bit for thread t might actually represent output value t-6. the correct
      // position for thread t's bit is thread_value_count. 


//WARP VALID COUNT:
        // for nested schemas, it's more complicated.  This warp will visit 32 incoming values,
        // however not all of them will necessarily represent a value at this nesting level. so
        // the validity bit for thread t might actually represent output value t-6. the correct
        // position for thread t's bit is thread_value_count. for cuda 11 we could use
        // __reduce_or_sync(), but until then we have to do a warp reduce.
        uint32_t const warp_valid_mask = WarpReduceOr32((uint32_t)is_valid << thread_value_count_within_warp);
        int thread_valid_count, block_valid_count;
        {
          auto thread_mask = (uint32_t(1) << thread_value_count_within_warp) - 1;

          block_scan_results valid_count_scan_results;
          scan_block_exclusive_sum<decode_block_size>(warp_valid_mask, warp_lane, warp_index, thread_mask, valid_count_scan_results);
          thread_valid_count = valid_count_scan_results.thread_count_within_block;
          block_valid_count = valid_count_scan_results.block_count;
        }

if constexpr (enable_print_large_list) {
  if(within_batch && in_row_bounds && (((d_idx == 0) && (is_valid != (t % 4 == 0))) || ((d_idx == 1) && !is_valid))) {
    printf("CUB GARBAGE: blockIdx.x %d, value_count %d, target_value_count %d, t %d, d_idx %d, is_valid %d, in_nesting_bounds %d\n", 
      blockIdx.x, value_count, target_value_count, t, d_idx, is_valid, in_nesting_bounds);
  }
  if (within_batch && in_row_bounds && (((d_idx == 0) && (thread_valid_count != ((t + 3)/ 4))) || ((d_idx == 1) && (thread_valid_count != t)))) {
    printf("CUB GARBAGE: blockIdx.x %d, value_count %d, target_value_count %d, t %d, d_idx %d, thread_valid_count %d\n", 
      blockIdx.x, value_count, target_value_count, t, d_idx, thread_valid_count);
  }
  if((value_count + 128 <= target_value_count) && (input_row_count + total_num_new_rows <= last_row) && (((d_idx == 0) && (block_valid_count != 32)) || ((d_idx == 1) && (block_valid_count != 128)))) {
    printf("CUB GARBAGE: blockIdx.x %d, value_count %d, target_value_count %d, t %d, d_idx %d, block_valid_count %d\n", 
      blockIdx.x, value_count, target_value_count, t, d_idx, block_valid_count);
  }
}

      if constexpr (enable_print) {
        if((block_valid_count == 0) && (t == 0) && (d_idx == max_depth)) { 
          printf("EMPTY VALID MASK: def_level %d, max_def_level %d, in_nesting_bounds %d, start_depth %d, "
            "end_depth %d, in_row_bounds %d, row_index %d, row_index_lower_bound %d, last_row %d, input_row_count %d\n", 
            def_level, ni.max_def_level, in_nesting_bounds, start_depth, end_depth, in_row_bounds, row_index, 
            row_index_lower_bound, last_row, input_row_count); }

        if (t == 0) { printf("block_valid_count %u\n", int(block_valid_count)); }
        if (t < 32) { printf("t %d, thread_valid_count %d\n", t, thread_valid_count); }
      }

      // compute warp and thread value counts for the -next- nesting level. we need to
      // do this for nested schemas so that we can emit an offset for the -current- nesting
      // level. more concretely : the offset for the current nesting level == current length of the
      // next nesting level
      int next_thread_value_count_within_warp = 0, next_warp_value_count = 0;
      int next_thread_value_count = 0, next_block_value_count = 0;
      int next_in_nesting_bounds = 0;
      if (d_idx < max_depth) {
        //mask is different between depths
        next_in_nesting_bounds = 
          (d_idx + 1 >= start_depth && d_idx + 1 <= end_depth && in_row_bounds) ? 1 : 0;

//NEXT WARP VALUE COUNT:
        {
          block_scan_results next_value_count_scan_results;
          scan_block_exclusive_sum<decode_block_size>(next_in_nesting_bounds, next_value_count_scan_results);

          next_thread_value_count_within_warp = next_value_count_scan_results.thread_count_within_warp;
          next_warp_value_count = next_value_count_scan_results.warp_count;
          next_thread_value_count = next_value_count_scan_results.thread_count_within_block;
          next_block_value_count = next_value_count_scan_results.block_count;
        }

if constexpr (enable_print_large_list) {
  if(within_batch && in_row_bounds && (next_in_nesting_bounds != 1)) {
    printf("CUB GARBAGE: blockIdx.x %d, value_count %d, target_value_count %d, t %d, next_in_nesting_bounds %d, start_depth %d, end_depth %d, in_row_bounds %d, row_index %d, input_row_count %d\n", 
      blockIdx.x, value_count, target_value_count, t, next_in_nesting_bounds, start_depth, end_depth, in_row_bounds, row_index, input_row_count);
  }
  if(within_batch && in_row_bounds && (next_thread_value_count != t)) {
    printf("CUB GARBAGE: blockIdx.x %d, value_count %d, target_value_count %d, t %d, next_thread_value_count %d\n", 
      blockIdx.x, value_count, target_value_count, t, next_thread_value_count);
  }
  if((value_count + 128 <= target_value_count) && (input_row_count + total_num_new_rows <= last_row) && (next_block_value_count != 128)) {
    printf("CUB GARBAGE: blockIdx.x %d, value_count %d, target_value_count %d, t %d, next_block_value_count %d\n", 
      blockIdx.x, value_count, target_value_count, t, next_block_value_count);
  }
}

        if constexpr (enable_print) {
          if (t == 0) { printf("next depth %d, next_block_value_count %d\n", d_idx + 1, next_block_value_count); }
          if (t < 32) { printf("t %d, start_depth %d, end_depth %d, in_row_bounds %d, next_in_nesting_bounds %d\n", 
            t, start_depth, end_depth, in_row_bounds, next_in_nesting_bounds); }
          if (t < 32) { printf("t %d, next_thread_value_count %d\n", t, next_thread_value_count); }
        }

        // if we're -not- at a leaf column and we're within nesting/row bounds
        // and we have a valid data_out pointer, it implies this is a list column, so
        // emit an offset.
        if (in_nesting_bounds && ni.data_out != nullptr) {
          const auto& next_ni = s->nesting_info[d_idx + 1];
          int const idx             = ni.value_count + thread_value_count;
          cudf::size_type const ofs = next_ni.value_count + next_thread_value_count + next_ni.page_start_value;

          //STORE THE OFFSET FOR THE NEW LIST LOCATION
          (reinterpret_cast<cudf::size_type*>(ni.data_out))[idx] = ofs;

/*
if constexpr (enable_print_large_list) {
  int overall_index = 4*(blockIdx.x * 20000 + idx);
  if(overall_index != ofs) {
    printf("WHOA BAD OFFSET\n");
    printf("WHOA BAD OFFSET: WROTE %d to %d! t %d, blockIdx.x %d, idx %d, d_idx %d, start_depth %d, end_depth %d, max_depth %d, "
      "in_row_bounds %d, in_nesting_bounds %d, next_in_nesting_bounds %d, row_index %d, row_index_lower_bound %d, last_row %d, "
      "input_row_count %d, num_prior_new_rows %d, is_new_row %d, total_num_new_rows %d, def_level %d, ni.value_count %d, "
      "thread_value_count %d, next_ni.value_count %d, next_thread_value_count %d, next_ni.page_start_value %d, value_count %d, "
      "target_value_count %d, block_value_count %d, next_block_value_count %d\n", 
      ofs, overall_index, t, blockIdx.x, idx, d_idx, start_depth, end_depth, max_depth, in_row_bounds, in_nesting_bounds, 
      next_in_nesting_bounds, row_index, row_index_lower_bound, last_row, input_row_count, num_prior_new_rows, is_new_row, 
      total_num_new_rows, def_level, ni.value_count, thread_value_count, next_ni.value_count, 
      next_thread_value_count, next_ni.page_start_value, value_count, target_value_count, block_value_count, next_block_value_count);
  }
}
*/
          if constexpr (enable_print || enable_print_range_error) {
            if((idx < 0) || (idx > 50000)){ printf("WHOA: offset index %d out of bounds!\n", idx); }
            if(ofs < 0){ printf("WHOA: offset value %d out of bounds!\n", ofs); }
          }

          if constexpr (enable_print) {
            if(idx < 0) { printf("WHOA: offset index out of bounds!\n"); }
            if (t < 32) { printf("OFFSETS: t %d, idx %d, next value count %d, next page_start_value %d, ofs %d\n", 
              t, idx, next_ni.value_count, next_ni.page_start_value, ofs); }
          }
        }
      }

      // validity is processed per-warp (on lane 0's), because writes are atomic
      //
      // nested schemas always read and write to the same bounds 
      // (that is, read and write positions are already pre-bounded by first_row/num_rows). 
      // since we are about to write the validity vector
      // here we need to adjust our computed mask to take into account the write row bounds.
      if constexpr (nullable) {
//TODO: Consider OR'ING for next_thread_value_count and popc() for next_thread_value_count
//so that we don't have to take a ballot here. Is uint128 so may deconstruct to this anyway ...

        if(is_first_lane && (ni.valid_map != nullptr) && (warp_value_count > 0)) {
          // last bit in the warp to store //in old is warp_valid_mask_bit_count
//so it's a count of everything in nesting bounds, though bits can be zero if NULL at this level            

          // absolute bit offset into the output validity map
          //is cumulative sum of warp_value_count at the given nesting depth
          // DON'T subtract by first_row: since it's lists it's not 1-row-per-value
          int const bit_offset = ni.valid_map_offset + thread_value_count;
          store_validity(bit_offset, ni.valid_map, warp_valid_mask, warp_value_count);

          if constexpr (enable_print) {
              printf("STORE VALIDITY: t %d, depth %d, thread_value_count %d, valid_map_offset %d, bit_offset %d, warp_value_count %d, warp_valid_mask %u\n", 
                t, d_idx, thread_value_count, ni.valid_map_offset, bit_offset, warp_value_count, warp_valid_mask);
            }
        }

        if (t == 0) { 
          size_type const block_null_count = block_value_count - block_valid_count;
          if constexpr (enable_print) {
            if (t == 0) { printf("BLOCK NULLS: depth %d, prior %d, block_null_count %u\n", 
              d_idx, ni.null_count, block_null_count); }
          }
          ni.null_count += block_null_count;
        }
      }

      // if this is valid and we're at the leaf, output dst_pos
      // Read these before the sync, so that when thread 0 modifies them we've already read their values
      int current_value_count = ni.value_count;
      __syncthreads();  // handle modification of ni.value_count from below
      if (d_idx == max_depth) {
        if (is_valid) {
          // for non-list types, the value count is always the same across
          int const dst_pos = current_value_count + thread_value_count;
          int const src_pos = max_depth_valid_count + thread_valid_count;
          int const output_index = rolling_index<state_buf::nz_buf_size>(src_pos);

          if constexpr (enable_print || enable_print_range_error) {
            if((output_index < 0) || (output_index >= state_buf::nz_buf_size)) {
              printf("WHOA: output index STORE %d out of bounds!\n", output_index);
            }
            if(dst_pos < 0) { printf("WHOA: dst_pos STORE %d out of bounds!\n", dst_pos); }
          }

          if constexpr (enable_print) {
            if (t == 0) { printf("ni.value_count %d, max_depth_valid_count %d\n", int(ni.value_count), max_depth_valid_count); }
            if (t < 32) { printf("t %d, src_pos %d, output_index %d\n", t, src_pos, output_index); }

            if((t == 0) && (src_pos == 0)) {printf("SPECIAL: output_index %d, dst_pos %d, ni.value_count %d, max_depth_valid_count %d, thread_value_count %d, thread_valid_count %d\n", 
              output_index, dst_pos, ni.value_count, max_depth_valid_count, thread_value_count, thread_valid_count);}

            if (t == 0) { printf("OUTPUT_INDICES: output_index %d, dst_pos %d\n", output_index, dst_pos); }
          }

          //Index from rolling buffer of values (which doesn't include nulls) to final array (which includes gaps for nulls)        
          sb->nz_idx[output_index] = dst_pos;
        }
        max_depth_valid_count += block_valid_count;
      }

      // update stuff
      if (t == 0) {
        ni.value_count += block_value_count;
        ni.valid_map_offset += block_value_count;
      }
      __syncthreads();  // handle modification of ni.value_count from below

      // propagate value counts for the next depth level
      block_value_count  = next_block_value_count;
      thread_value_count = next_thread_value_count;
      in_nesting_bounds  = next_in_nesting_bounds;
      warp_value_count = next_warp_value_count;
      thread_value_count_within_warp = next_thread_value_count_within_warp;
    } //END OF DEPTH LOOP

    if constexpr (enable_print) {
      if (t == 0) { printf("END DEPTH LOOP\n"); }
    }

    int const batch_size = min(max_batch_size, target_value_count - value_count);
    value_count += batch_size;
  }

  if constexpr (enable_print) {
    if (t == 0) { printf("END LOOP\n"); }
  }

  if (t == 0) {
    // update valid value count for decoding and total # of values we've processed
    s->nesting_info[max_depth].valid_count = max_depth_valid_count;
    s->nz_count          = max_depth_valid_count;
    s->input_value_count = value_count;

    // If we have lists # rows != # values
    s->input_row_count = input_row_count;
  }

  return max_depth_valid_count;
}

// is the page marked nullable or not
__device__ inline bool is_nullable(page_state_s* s)
{
  auto const lvl           = level_type::DEFINITION;
  auto const max_def_level = s->col.max_level[lvl];
  return max_def_level > 0;
}

// for a nullable page, check to see if it could have nulls
__device__ inline bool maybe_has_nulls(page_state_s* s)
{
  auto const lvl      = level_type::DEFINITION;
  auto const init_run = s->initial_rle_run[lvl];
  // literal runs, lets assume they could hold nulls
  if (is_literal_run(init_run)) { return true; }

  // repeated run with number of items in the run not equal
  // to the rows in the page, assume that means we could have nulls
  if (s->page.num_input_values != (init_run >> 1)) { return true; }

  auto const lvl_bits = s->col.level_bits[lvl];
  auto const run_val  = lvl_bits == 0 ? 0 : s->initial_rle_value[lvl];

  // the encoded repeated value isn't valid, we have (all) nulls
  return run_val != s->col.max_level[lvl];
}

template <int decode_block_size_t, typename stream_type>
__device__ int skip_decode(stream_type& parquet_stream, int num_to_skip, int t)
{
  static constexpr bool enable_print = false;

  // it could be that (e.g.) we skip 5000 but starting at row 4000 we have a run of length 2000:
  // in that case skip_decode() only skips 4000, and we have to process the remaining 1000 up front
  // modulo 2 * block_size of course, since that's as many as we process at once
  int num_skipped = parquet_stream.skip_decode(t, num_to_skip);
  if constexpr (enable_print) {
    if (t == 0) { printf("SKIPPED: num_skipped %d, for %d\n", num_skipped, num_to_skip); }
  }
  while (num_skipped < num_to_skip) {
    auto const to_decode = min(2 * decode_block_size_t, num_to_skip - num_skipped);
    num_skipped += parquet_stream.decode_next(t, to_decode);
    if constexpr (enable_print) {
      if (t == 0) { printf("EXTRA SKIPPED: to_decode %d, at %d, for %d\n", to_decode, num_skipped, num_to_skip); }
    }
    __syncthreads();
  }

  return num_skipped;
}

/**
 * @brief Kernel for computing fixed width non dictionary column data stored in the pages
 *
 * This function will write the page data and the page data's validity to the
 * output specified in the page's column chunk. If necessary, additional
 * conversion will be performed to translate from the Parquet datatype to
 * desired output datatype.
 *
 * @param pages List of pages
 * @param chunks List of column chunks
 * @param min_row Row index to start reading at
 * @param num_rows Maximum number of rows to read
 * @param error_code Error code to set if an error is encountered
 */
template <typename level_t,
          int decode_block_size_t,
          decode_kernel_mask kernel_mask_t,
          bool has_dict_t,
          bool has_nesting_t,
          bool has_lists_t,
          template <int block_size, bool decode_has_lists_t, typename state_buf>
          typename DecodeValuesFunc>
CUDF_KERNEL void __launch_bounds__(decode_block_size_t)
  gpuDecodePageDataGeneric(PageInfo* pages,
                           device_span<ColumnChunkDesc const> chunks,
                           size_t min_row,
                           size_t num_rows,
                           kernel_error::pointer error_code)
{
  constexpr int rolling_buf_size    = decode_block_size_t * 2;
  constexpr int rle_run_buffer_size = rle_stream_required_run_buffer_size<decode_block_size_t>();

  __shared__ __align__(16) page_state_s state_g;
  using state_buf_t = page_state_buffers_s<rolling_buf_size,  // size of nz_idx buffer
                                           has_dict_t ? rolling_buf_size : 1,
                                           1>;
  __shared__ __align__(16) state_buf_t state_buffers;

  page_state_s* const s = &state_g;
  auto* const sb        = &state_buffers;
  int const page_idx    = blockIdx.x;
  int const t           = threadIdx.x;
  PageInfo* pp          = &pages[page_idx];

  if (!(BitAnd(pages[page_idx].kernel_mask, kernel_mask_t))) { return; }

  // must come after the kernel mask check
  [[maybe_unused]] null_count_back_copier _{s, t};

  if (!setupLocalPageInfo(s,
                          pp,
                          chunks,
                          min_row,
                          num_rows,
                          mask_filter{kernel_mask_t},
                          page_processing_stage::DECODE)) {
    return;
  }

  // if we have no work to do (eg, in a skip_rows/num_rows case) in this page.
  if (s->num_rows == 0) { return; }

  DecodeValuesFunc<decode_block_size_t, has_lists_t, state_buf_t> decode_values;

  bool const should_process_nulls = is_nullable(s) && maybe_has_nulls(s);

  // shared buffer. all shared memory is suballocated out of here
  static constexpr auto align_test = false;
  static constexpr size_t buffer_alignment = align_test ? 128 : 16;
  constexpr int shared_rep_size = has_lists_t ? cudf::util::round_up_unsafe(rle_run_buffer_size *
    sizeof(rle_run<level_t>), buffer_alignment) : 0;
  constexpr int shared_dict_size =
    has_dict_t
      ? cudf::util::round_up_unsafe(rle_run_buffer_size * sizeof(rle_run<uint32_t>), buffer_alignment)
      : 0;
  constexpr int shared_def_size =
    cudf::util::round_up_unsafe(rle_run_buffer_size * sizeof(rle_run<level_t>), buffer_alignment);
  constexpr int shared_buf_size = shared_rep_size + shared_dict_size + shared_def_size;
  __shared__ __align__(buffer_alignment) uint8_t shared_buf[shared_buf_size];

  // setup all shared memory buffers
  int shared_offset = 0;
  rle_run<level_t>* rep_runs = reinterpret_cast<rle_run<level_t>*>(shared_buf + shared_offset);
  if constexpr (has_lists_t){ shared_offset += shared_rep_size; }

  rle_run<uint32_t>* dict_runs = reinterpret_cast<rle_run<uint32_t>*>(shared_buf + shared_offset);
  if constexpr (has_dict_t) { shared_offset += shared_dict_size; }
  rle_run<level_t>* def_runs = reinterpret_cast<rle_run<level_t>*>(shared_buf + shared_offset);

  // initialize the stream decoders (requires values computed in setupLocalPageInfo)
  rle_stream<level_t, decode_block_size_t, rolling_buf_size> def_decoder{def_runs};
  level_t* const def = reinterpret_cast<level_t*>(pp->lvl_decode_buf[level_type::DEFINITION]);
  if (should_process_nulls) {
    def_decoder.init(s->col.level_bits[level_type::DEFINITION],
                     s->abs_lvl_start[level_type::DEFINITION],
                     s->abs_lvl_end[level_type::DEFINITION],
                     def,
                     s->page.num_input_values);
  }
  
  rle_stream<level_t, decode_block_size_t, rolling_buf_size> rep_decoder{rep_runs};
  level_t* const rep = reinterpret_cast<level_t*>(pp->lvl_decode_buf[level_type::REPETITION]);
  if constexpr (has_lists_t){
    rep_decoder.init(s->col.level_bits[level_type::REPETITION],
                     s->abs_lvl_start[level_type::REPETITION],
                     s->abs_lvl_end[level_type::REPETITION],
                     rep,
                     s->page.num_input_values);
  }

  static constexpr bool enable_print = false;

  rle_stream<uint32_t, decode_block_size_t, rolling_buf_size> dict_stream{dict_runs};
  if constexpr (has_dict_t) {
    dict_stream.init(
      s->dict_bits, s->data_start, s->data_end, sb->dict_idx, s->page.num_input_values);
    if constexpr (enable_print) {
      if(t == 0) { printf("INIT DICT: dict_bits %d, data_start %p, data_end %p, dict_idx %p, page.num_input_values %d, s->dict_pos %d \n", 
        s->dict_bits, s->data_start, s->data_end, sb->dict_idx, s->page.num_input_values, s->dict_pos); }
    }
  }

  if constexpr (enable_print) {
    if((t == 0) && (page_idx == 0)){
      printf("SIZES: shared_rep_size %d, shared_dict_size %d, shared_def_size %d\n", shared_rep_size, shared_dict_size, shared_def_size);
    }
    if constexpr (has_lists_t){
      printf("Is fixed list page\n");
    } else {
      printf("Is fixed non-list page\n");
    }
  }

  // We use two counters in the loop below: processed_count and valid_count.
  // - processed_count: number of values out of num_input_values that we have decoded so far.
  //   the definition stream returns the number of total rows it has processed in each call
  //   to decode_next and we accumulate in process_count.
  // - valid_count: number of non-null values we have decoded so far. In each iteration of the
  //   loop below, we look at the number of valid items (which could be all for non-nullable),
  //   and valid_count is that running count.
  int processed_count = 0;
  int valid_count     = 0;
  // the core loop. decode batches of level stream data using rle_stream objects
  // and pass the results to gpuDecodeValues

  //For lists (which can have skipped values, skip ahead in the decoding so that we don't repeat work
  if constexpr (has_lists_t){
    if(s->page.skipped_leaf_values > 0) {
      if (should_process_nulls) {
        skip_decode<decode_block_size_t>(def_decoder, s->page.skipped_leaf_values, t);
      }
      processed_count = skip_decode<decode_block_size_t>(rep_decoder, s->page.skipped_leaf_values, t);
      if constexpr (has_dict_t) {
        skip_decode<decode_block_size_t>(dict_stream, s->page.skipped_leaf_values, t);
      }
    }
  }

  if constexpr (enable_print) {
    if(t == 0) { printf("page_idx %d, should_process_nulls %d, has_lists_t %d, has_dict_t %d, num_rows %lu, page.num_input_values %d\n", 
      page_idx, int(should_process_nulls), int(has_lists_t), int(has_dict_t), num_rows, s->page.num_input_values); }
  }

  auto print_nestings = [&](bool is_post){
    if constexpr (enable_print) {
      auto print_nesting_level = [&](const PageNestingDecodeInfo& ni) {
        printf("page_idx %d, max_def_level %d, start_depth %d, end_depth %d, page_start_value %d, null_count %d, "
          "valid_map_offset %d, valid_count %d, value_count %d\n", 
          page_idx, ni.max_def_level, ni.start_depth, ni.end_depth, ni.page_start_value, ni.null_count, 
          ni.valid_map_offset, ni.valid_count, ni.value_count);
      };

      if(t == 0) {
        printf("POST %d NESTING 0: ", int(is_post));
        print_nesting_level(s->nesting_info[0]);
        printf("POST %d NESTING 1: ", int(is_post));
        print_nesting_level(s->nesting_info[1]);
        //printf("POST %d NESTING 2: ", int(is_post));
        //print_nesting_level(s->nesting_info[2]);
      }
    }
  };

  print_nestings(false);
  if constexpr (enable_print) {
    if(t == 0) {printf("LOOP START page_idx %d\n", page_idx);}
  }

  int last_row = s->first_row + s->num_rows;
  while ((s->error == 0) && (processed_count < s->page.num_input_values) &&
         (s->input_row_count <= last_row)) {
    int next_valid_count;

    // only need to process definition levels if this is a nullable column
    if (should_process_nulls) {
      processed_count += def_decoder.decode_next(t);
      __syncthreads();

      if constexpr (has_lists_t) {
        rep_decoder.decode_next(t);
        __syncthreads();

        int value_count = s->input_value_count;
        next_valid_count = gpuUpdateValidityAndRowIndicesLists<decode_block_size_t, true, level_t>(
          processed_count, s, sb, def, rep, t);
        if constexpr (enable_print) {
          if(t == 0) { printf("LISTS NEXT: next_valid_count %d\n", next_valid_count); }
          if(t == 0) { printf("PROCESSING: page total values %d, num_input_values %d, pre value_count %d, post value_count %d, "
            "processed_count %d, valid_count %d, next_valid_count %d\n", 
            s->page.num_input_values, s->input_value_count, value_count, s->input_value_count, processed_count, valid_count, next_valid_count); }
        }
      } else if constexpr (has_nesting_t) {
        next_valid_count = gpuUpdateValidityAndRowIndicesNested<decode_block_size_t, level_t>(
          processed_count, s, sb, def, t);
        if constexpr (enable_print) {
          if(t == 0) { printf("NESTED NEXT: next_valid_count %d\n", next_valid_count); }
        }
      } else {
        next_valid_count = gpuUpdateValidityAndRowIndicesFlat<decode_block_size_t, level_t>(
          processed_count, s, sb, def, t);
      }
    }
    // if we wanted to split off the skip_rows/num_rows case into a separate kernel, we could skip
    // this function call entirely since all it will ever generate is a mapping of (i -> i) for
    // nz_idx.  gpuDecodeFixedWidthValues would be the only work that happens.
    else {
      if constexpr (has_lists_t) {
        processed_count += rep_decoder.decode_next(t);
        __syncthreads();

        next_valid_count =
          gpuUpdateValidityAndRowIndicesLists<decode_block_size_t, false, level_t>(
            processed_count, s, sb, nullptr, rep, t);
      } else {
        processed_count += min(rolling_buf_size, s->page.num_input_values - processed_count);
        next_valid_count = gpuUpdateValidityAndRowIndicesNonNullable<decode_block_size_t>(processed_count, s, sb, t);
      }
    }
    __syncthreads();

    // if we have dictionary data
    if constexpr (has_dict_t) {
      // We want to limit the number of dictionary items we decode, that correspond to
      // the rows we have processed in this iteration that are valid.
      // We know the number of valid rows to process with: next_valid_count - valid_count.
      dict_stream.decode_next(t, next_valid_count - valid_count);
      __syncthreads();
    }

    // decode the values themselves
    decode_values(s, sb, valid_count, next_valid_count, t);
    __syncthreads();

    valid_count = next_valid_count;

    if constexpr (enable_print) {
      if(t == 0) { printf("LOOP: processed_count %d, #page values %d, error %d\n", 
        processed_count, s->page.num_input_values, s->error); }
    }
  }
  if (t == 0 and s->error != 0) { set_error(s->error, error_code); }

  print_nestings(true);
}

}  // anonymous namespace

void __host__ DecodePageDataFixed(cudf::detail::hostdevice_span<PageInfo> pages,
                                  cudf::detail::hostdevice_span<ColumnChunkDesc const> chunks,
                                  size_t num_rows,
                                  size_t min_row,
                                  int level_type_size,
                                  bool has_nesting,
                                  bool is_list,
                                  kernel_error::pointer error_code,
                                  rmm::cuda_stream_view stream)
{
  constexpr int decode_block_size = 128;

  dim3 dim_block(decode_block_size, 1);
  dim3 dim_grid(pages.size(), 1);  // 1 threadblock per page
  if (level_type_size == 1) {
    if (is_list) {
      gpuDecodePageDataGeneric<uint8_t,
                               decode_block_size,
                               decode_kernel_mask::FIXED_WIDTH_NO_DICT_LIST,
                               false,
                               true,
                               true,
                               decode_fixed_width_values_func>
        <<<dim_grid, dim_block, 0, stream.value()>>>(
          pages.device_ptr(), chunks, min_row, num_rows, error_code);
    } else if (has_nesting) {
      gpuDecodePageDataGeneric<uint8_t,
                               decode_block_size,
                               decode_kernel_mask::FIXED_WIDTH_NO_DICT_NESTED,
                               false,
                               true,
                               false,
                               decode_fixed_width_values_func>
        <<<dim_grid, dim_block, 0, stream.value()>>>(
          pages.device_ptr(), chunks, min_row, num_rows, error_code);
    } else {
      gpuDecodePageDataGeneric<uint8_t,
                               decode_block_size,
                               decode_kernel_mask::FIXED_WIDTH_NO_DICT,
                               false,
                               false,
                               false,
                               decode_fixed_width_values_func>
        <<<dim_grid, dim_block, 0, stream.value()>>>(
          pages.device_ptr(), chunks, min_row, num_rows, error_code);
    }
  } else {
    if (is_list) {
      gpuDecodePageDataGeneric<uint16_t,
                               decode_block_size,
                               decode_kernel_mask::FIXED_WIDTH_NO_DICT_LIST,
                               false,
                               true,
                               true,
                               decode_fixed_width_values_func>
        <<<dim_grid, dim_block, 0, stream.value()>>>(
          pages.device_ptr(), chunks, min_row, num_rows, error_code);
    } else if (has_nesting) {
      gpuDecodePageDataGeneric<uint16_t,
                               decode_block_size,
                               decode_kernel_mask::FIXED_WIDTH_NO_DICT_NESTED,
                               false,
                               true,
                               false,
                               decode_fixed_width_values_func>
        <<<dim_grid, dim_block, 0, stream.value()>>>(
          pages.device_ptr(), chunks, min_row, num_rows, error_code);
    } else {
      gpuDecodePageDataGeneric<uint16_t,
                               decode_block_size,
                               decode_kernel_mask::FIXED_WIDTH_NO_DICT,
                               false,
                               false,
                               false,
                               decode_fixed_width_values_func>
        <<<dim_grid, dim_block, 0, stream.value()>>>(
          pages.device_ptr(), chunks, min_row, num_rows, error_code);
    }
  }
}

void __host__ DecodePageDataFixedDict(cudf::detail::hostdevice_span<PageInfo> pages,
                                      cudf::detail::hostdevice_span<ColumnChunkDesc const> chunks,
                                      size_t num_rows,
                                      size_t min_row,
                                      int level_type_size,
                                      bool has_nesting,
                                      bool is_list,
                                      kernel_error::pointer error_code,
                                      rmm::cuda_stream_view stream)
{
  constexpr int decode_block_size = 128;

  dim3 dim_block(decode_block_size, 1);  // decode_block_size = 128 threads per block
  dim3 dim_grid(pages.size(), 1);        // 1 thread block per page => # blocks

  if (level_type_size == 1) {
    if (is_list) {
      gpuDecodePageDataGeneric<uint8_t,
                               decode_block_size,
                               decode_kernel_mask::FIXED_WIDTH_DICT_LIST,
                               true,
                               true,
                               true,
                               decode_fixed_width_values_func>
        <<<dim_grid, dim_block, 0, stream.value()>>>(
          pages.device_ptr(), chunks, min_row, num_rows, error_code);
    } else if (has_nesting) {
      gpuDecodePageDataGeneric<uint8_t,
                               decode_block_size,
                               decode_kernel_mask::FIXED_WIDTH_DICT_NESTED,
                               true,
                               true,
                               false,
                               decode_fixed_width_values_func>
        <<<dim_grid, dim_block, 0, stream.value()>>>(
          pages.device_ptr(), chunks, min_row, num_rows, error_code);
    } else {
      gpuDecodePageDataGeneric<uint8_t,
                               decode_block_size,
                               decode_kernel_mask::FIXED_WIDTH_DICT,
                               true,
                               false,
                               false,
                               decode_fixed_width_values_func>
        <<<dim_grid, dim_block, 0, stream.value()>>>(
          pages.device_ptr(), chunks, min_row, num_rows, error_code);
    }
  } else {
    if (is_list) {
      gpuDecodePageDataGeneric<uint16_t,
                               decode_block_size,
                               decode_kernel_mask::FIXED_WIDTH_DICT_LIST,
                               true,
                               true,
                               true,
                               decode_fixed_width_values_func>
        <<<dim_grid, dim_block, 0, stream.value()>>>(
          pages.device_ptr(), chunks, min_row, num_rows, error_code);
    } else if (has_nesting) {
      gpuDecodePageDataGeneric<uint16_t,
                               decode_block_size,
                               decode_kernel_mask::FIXED_WIDTH_DICT_NESTED,
                               true,
                               true,
                               false,
                               decode_fixed_width_values_func>
        <<<dim_grid, dim_block, 0, stream.value()>>>(
          pages.device_ptr(), chunks, min_row, num_rows, error_code);
    } else {
      gpuDecodePageDataGeneric<uint16_t,
                               decode_block_size,
                               decode_kernel_mask::FIXED_WIDTH_DICT,
                               true,
                               false,
                               true,
                               decode_fixed_width_values_func>
        <<<dim_grid, dim_block, 0, stream.value()>>>(
          pages.device_ptr(), chunks, min_row, num_rows, error_code);
    }
  }
}

void __host__
DecodeSplitPageFixedWidthData(cudf::detail::hostdevice_span<PageInfo> pages,
                              cudf::detail::hostdevice_span<ColumnChunkDesc const> chunks,
                              size_t num_rows,
                              size_t min_row,
                              int level_type_size,
                              bool has_nesting,
                              bool is_list,
                              kernel_error::pointer error_code,
                              rmm::cuda_stream_view stream)
{
  constexpr int decode_block_size = 128;

  dim3 dim_block(decode_block_size, 1);  // decode_block_size = 128 threads per block
  dim3 dim_grid(pages.size(), 1);        // 1 thread block per page => # blocks

  if (level_type_size == 1) {
    if (is_list) {
      gpuDecodePageDataGeneric<uint8_t,
                               decode_block_size,
                               decode_kernel_mask::BYTE_STREAM_SPLIT_FIXED_WIDTH_LIST,
                               true,
                               true,
                               true,
                               decode_fixed_width_split_values_func>
        <<<dim_grid, dim_block, 0, stream.value()>>>(
          pages.device_ptr(), chunks, min_row, num_rows, error_code);
    } else if (has_nesting) {
      gpuDecodePageDataGeneric<uint8_t,
                               decode_block_size,
                               decode_kernel_mask::BYTE_STREAM_SPLIT_FIXED_WIDTH_NESTED,
                               false,
                               true,
                               false,
                               decode_fixed_width_split_values_func>
        <<<dim_grid, dim_block, 0, stream.value()>>>(
          pages.device_ptr(), chunks, min_row, num_rows, error_code);
    } else {
      gpuDecodePageDataGeneric<uint8_t,
                               decode_block_size,
                               decode_kernel_mask::BYTE_STREAM_SPLIT_FIXED_WIDTH_FLAT,
                               false,
                               false,
                               false,
                               decode_fixed_width_split_values_func>
        <<<dim_grid, dim_block, 0, stream.value()>>>(
          pages.device_ptr(), chunks, min_row, num_rows, error_code);
    }
  } else {
    if (is_list) {
      gpuDecodePageDataGeneric<uint16_t,
                               decode_block_size,
                               decode_kernel_mask::BYTE_STREAM_SPLIT_FIXED_WIDTH_LIST,
                               true,
                               true,
                               true,
                               decode_fixed_width_split_values_func>
        <<<dim_grid, dim_block, 0, stream.value()>>>(
          pages.device_ptr(), chunks, min_row, num_rows, error_code);
    } else if (has_nesting) {
      gpuDecodePageDataGeneric<uint16_t,
                               decode_block_size,
                               decode_kernel_mask::BYTE_STREAM_SPLIT_FIXED_WIDTH_NESTED,
                               false,
                               true,
                               false,
                               decode_fixed_width_split_values_func>
        <<<dim_grid, dim_block, 0, stream.value()>>>(
          pages.device_ptr(), chunks, min_row, num_rows, error_code);
    } else {
      gpuDecodePageDataGeneric<uint16_t,
                               decode_block_size,
                               decode_kernel_mask::BYTE_STREAM_SPLIT_FIXED_WIDTH_FLAT,
                               false,
                               false,
                               false,
                               decode_fixed_width_split_values_func>
        <<<dim_grid, dim_block, 0, stream.value()>>>(
          pages.device_ptr(), chunks, min_row, num_rows, error_code);
    }
  }
}

}  // namespace cudf::io::parquet::detail
