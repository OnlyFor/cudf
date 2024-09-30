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
#pragma once

#include <cudf/aggregation.hpp>
#include <cudf/table/table_device_view.cuh>
#include <cudf/types.hpp>

#include <rmm/cuda_stream_view.hpp>

#include <cuda_runtime_api.h>

#include <cstddef>

namespace cudf::groupby::detail::hash {

std::pair<bool, size_t> can_use_shmem_aggs(int grid_size) noexcept;

void compute_aggregations(int grid_size,
                          cudf::size_type num_input_rows,
                          bitmask_type const* row_bitmask,
                          bool skip_rows_with_nulls,
                          cudf::size_type* local_mapping_index,
                          cudf::size_type* global_mapping_index,
                          cudf::size_type* block_cardinality,
                          cudf::table_device_view input_values,
                          cudf::mutable_table_device_view output_values,
                          cudf::aggregation::Kind const* d_agg_kinds,
                          size_t shmem_size,
                          rmm::cuda_stream_view stream);

}  // namespace cudf::groupby::detail::hash
