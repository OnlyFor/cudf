/*
 * Copyright (c) 2020-2024, NVIDIA CORPORATION.
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

#pragma once

#include "cudf/types.hpp"
#include "helpers.cuh"
#include "single_pass_functors.cuh"

#include <cudf/detail/cuco_helpers.hpp>
#include <cudf/detail/utilities/cuda.cuh>
#include <cudf/detail/utilities/integer_utils.hpp>

namespace cudf::groupby::detail::hash {

__device__ void calculate_columns_to_aggregate(int& col_start,
                                               int& col_end,
                                               cudf::mutable_table_device_view output_values,
                                               int num_input_cols,
                                               std::byte** s_aggregates_pointer,
                                               bool** s_aggregates_valid_pointer,
                                               std::byte* shared_set_aggregates,
                                               cudf::size_type cardinality,
                                               int total_agg_size)
{
  if (threadIdx.x == 0) {
    col_start           = col_end;
    int bytes_allocated = 0;
    int valid_col_size  = round_to_multiple_of_8(sizeof(bool) * cardinality);
    while ((bytes_allocated < total_agg_size) && (col_end < num_input_cols)) {
      int next_col_size =
        round_to_multiple_of_8(sizeof(output_values.column(col_end).type()) * cardinality);
      int next_col_total_size = valid_col_size + next_col_size;
      if (bytes_allocated + next_col_total_size > total_agg_size) { break; }
      s_aggregates_pointer[col_end] = shared_set_aggregates + bytes_allocated;
      s_aggregates_valid_pointer[col_end] =
        reinterpret_cast<bool*>(shared_set_aggregates + bytes_allocated + next_col_size);
      bytes_allocated += next_col_total_size;
      col_end++;
    }
  }
}

__device__ void initialize_shared_memory_aggregates(int col_start,
                                                    int col_end,
                                                    cudf::mutable_table_device_view output_values,
                                                    std::byte** s_aggregates_pointer,
                                                    bool** s_aggregates_valid_pointer,
                                                    cudf::size_type cardinality,
                                                    cudf::aggregation::Kind const* aggs)
{
  for (auto col_idx = col_start; col_idx < col_end; col_idx++) {
    for (auto idx = threadIdx.x; idx < cardinality; idx += blockDim.x) {
      cudf::detail::dispatch_type_and_aggregation(output_values.column(col_idx).type(),
                                                  aggs[col_idx],
                                                  initialize_shmem{},
                                                  s_aggregates_pointer[col_idx],
                                                  idx,
                                                  s_aggregates_valid_pointer[col_idx]);
    }
  }
}

__device__ void compute_pre_aggregrates(int col_start,
                                        int col_end,
                                        cudf::table_device_view input_values,
                                        cudf::size_type num_input_rows,
                                        cudf::size_type* local_mapping_index,
                                        std::byte** s_aggregates_pointer,
                                        bool** s_aggregates_valid_pointer,
                                        cudf::aggregation::Kind const* aggs)
{
  for (auto cur_idx = blockDim.x * blockIdx.x + threadIdx.x; cur_idx < num_input_rows;
       cur_idx += blockDim.x * gridDim.x) {
    auto map_idx = local_mapping_index[cur_idx];

    for (auto col_idx = col_start; col_idx < col_end; col_idx++) {
      auto input_col = input_values.column(col_idx);

      cudf::detail::dispatch_type_and_aggregation(input_col.type(),
                                                  aggs[col_idx],
                                                  shmem_element_aggregator{},
                                                  s_aggregates_pointer[col_idx],
                                                  map_idx,
                                                  s_aggregates_valid_pointer[col_idx],
                                                  input_col,
                                                  cur_idx);
    }
  }
}

__device__ void compute_final_aggregates(int col_start,
                                         int col_end,
                                         cudf::table_device_view input_values,
                                         cudf::mutable_table_device_view output_values,
                                         cudf::size_type cardinality,
                                         cudf::size_type* global_mapping_index,
                                         std::byte** s_aggregates_pointer,
                                         bool** s_aggregates_valid_pointer,
                                         cudf::aggregation::Kind const* aggs)
{
  for (auto cur_idx = threadIdx.x; cur_idx < cardinality; cur_idx += blockDim.x) {
    auto out_idx = global_mapping_index[blockIdx.x * GROUPBY_SHM_MAX_ELEMENTS + cur_idx];
    for (auto col_idx = col_start; col_idx < col_end; col_idx++) {
      auto output_col = output_values.column(col_idx);

      cudf::detail::dispatch_type_and_aggregation(input_values.column(col_idx).type(),
                                                  aggs[col_idx],
                                                  gmem_element_aggregator{},
                                                  output_col,
                                                  out_idx,
                                                  input_values.column(col_idx),
                                                  s_aggregates_pointer[col_idx],
                                                  cur_idx,
                                                  s_aggregates_valid_pointer[col_idx]);
    }
  }
}

/* Takes the local_mapping_index and global_mapping_index to compute
 * pre (shared) and final (global) aggregates*/
CUDF_KERNEL void compute_aggregates(cudf::size_type* local_mapping_index,
                                    cudf::size_type* global_mapping_index,
                                    cudf::size_type* block_cardinality,
                                    cudf::table_device_view input_values,
                                    cudf::mutable_table_device_view output_values,
                                    cudf::size_type num_input_rows,
                                    cudf::aggregation::Kind const* aggs,
                                    int total_agg_size,
                                    int pointer_size)
{
  cudf::size_type cardinality = block_cardinality[blockIdx.x];
  if (cardinality >= GROUPBY_CARDINALITY_THRESHOLD) { return; }
  int num_input_cols = output_values.num_columns();
  extern __shared__ std::byte shared_set_aggregates[];
  std::byte** s_aggregates_pointer =
    reinterpret_cast<std::byte**>(shared_set_aggregates + total_agg_size);
  bool** s_aggregates_valid_pointer =
    reinterpret_cast<bool**>(shared_set_aggregates + total_agg_size + pointer_size);
  __shared__ int col_start;
  __shared__ int col_end;
  if (threadIdx.x == 0) {
    col_start = 0;
    col_end   = 0;
  }
  __syncthreads();
  while (col_end < num_input_cols) {
    calculate_columns_to_aggregate(col_start,
                                   col_end,
                                   output_values,
                                   num_input_cols,
                                   s_aggregates_pointer,
                                   s_aggregates_valid_pointer,
                                   shared_set_aggregates,
                                   cardinality,
                                   total_agg_size);
    __syncthreads();
    initialize_shared_memory_aggregates(col_start,
                                        col_end,
                                        output_values,
                                        s_aggregates_pointer,
                                        s_aggregates_valid_pointer,
                                        cardinality,
                                        aggs);
    __syncthreads();
    compute_pre_aggregrates(col_start,
                            col_end,
                            input_values,
                            num_input_rows,
                            local_mapping_index,
                            s_aggregates_pointer,
                            s_aggregates_valid_pointer,
                            aggs);
    __syncthreads();
    compute_final_aggregates(col_start,
                             col_end,
                             input_values,
                             output_values,
                             cardinality,
                             global_mapping_index,
                             s_aggregates_pointer,
                             s_aggregates_valid_pointer,
                             aggs);
    __syncthreads();
  }
}

template <typename SetType>
__device__ void find_local_mapping(cudf::size_type cur_idx,
                                   cudf::size_type num_input_rows,
                                   cudf::size_type* cardinality,
                                   SetType shared_set,
                                   cudf::size_type* local_mapping_index,
                                   cudf::size_type* shared_set_indices)
{
  cudf::size_type result_idx;
  bool inserted;
  if (cur_idx < num_input_rows) {
    auto const result = shared_set.insert_and_find(cur_idx);
    result_idx        = *result.first;
    inserted          = result.second;
    // inserted a new element
    if (result.second) {
      auto shared_set_index                = atomicAdd(cardinality, 1);
      shared_set_indices[shared_set_index] = cur_idx;
      local_mapping_index[cur_idx]         = shared_set_index;
    }
  }
  // Syncing the thread block is needed so that updates in `local_mapping_index` are visible to all
  // threads in the thread block.
  __syncthreads();
  if (cur_idx < num_input_rows) {
    // element was already in set
    if (!inserted) { local_mapping_index[cur_idx] = local_mapping_index[result_idx]; }
  }
}

template <typename SetType>
__device__ void find_global_mapping(cudf::size_type cur_idx,
                                    SetType global_set,
                                    cudf::size_type* shared_set_indices,
                                    cudf::size_type* global_mapping_index)
{
  auto input_idx = shared_set_indices[cur_idx];
  auto result    = global_set.insert_and_find(input_idx);
  global_mapping_index[blockIdx.x * GROUPBY_SHM_MAX_ELEMENTS + cur_idx] = *result.first;
}

/*
 * Inserts keys into the shared memory hash set, and stores the row index of the local
 * pre-aggregate table in `local_mapping_index`. If the number of unique keys found in a
 * threadblock exceeds `GROUPBY_CARDINALITY_THRESHOLD`, the threads in that block will exit without
 * updating `global_set` or setting `global_mapping_index`. Else, we insert the unique keys found to
 * the global hash set, and save the row index of the global sparse table in `global_mapping_index`.
 */
template <class SetRef, typename GlobalSetType, class WindowExtent>
CUDF_KERNEL void compute_mapping_indices(GlobalSetType global_set,
                                         cudf::size_type num_input_rows,
                                         WindowExtent window_extent,
                                         cudf::size_type* local_mapping_index,
                                         cudf::size_type* global_mapping_index,
                                         cudf::size_type* block_cardinality,
                                         bool* direct_aggregations)
{
  __shared__ cudf::size_type shared_set_indices[GROUPBY_SHM_MAX_ELEMENTS];

  // Shared set initialization
  __shared__ typename SetRef::window_type windows[window_extent.value()];
  auto storage     = SetRef::storage_ref_type(window_extent, windows);
  auto shared_set  = SetRef(cuco::empty_key<cudf::size_type>{cudf::detail::CUDF_SIZE_TYPE_SENTINEL},
                           global_set.key_eq(),
                           probing_scheme_type{global_set.hash_function()},
                            {},
                           storage);
  auto const block = cooperative_groups::this_thread_block();
  shared_set.initialize(block);
  block.sync();

  auto shared_insert_ref = std::move(shared_set).with(cuco::insert_and_find);

  __shared__ cudf::size_type cardinality;

  if (block.thread_rank() == 0) { cardinality = 0; }

  block.sync();

  auto const stride = cudf::detail::grid_1d::grid_stride();

  for (auto cur_idx = cudf::detail::grid_1d::global_thread_id();
       cur_idx - block.thread_rank() < num_input_rows;
       cur_idx += stride) {
    find_local_mapping(cur_idx,
                       num_input_rows,
                       &cardinality,
                       shared_insert_ref,
                       local_mapping_index,
                       shared_set_indices);

    block.sync();

    if (cardinality >= GROUPBY_CARDINALITY_THRESHOLD) {
      if (block.thread_rank() == 0) { *direct_aggregations = true; }
      break;
    }

    block.sync();
  }

  // Insert unique keys from shared to global hash set
  if (cardinality < GROUPBY_CARDINALITY_THRESHOLD) {
    for (auto cur_idx = block.thread_rank(); cur_idx < cardinality;
         cur_idx += block.num_threads()) {
      find_global_mapping(cur_idx, global_set, shared_set_indices, global_mapping_index);
    }
  }

  if (block.thread_rank() == 0) { block_cardinality[block.group_index().x] = cardinality; }
}

}  // namespace cudf::groupby::detail::hash
