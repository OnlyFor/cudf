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
#pragma once

#include <cudf/detail/aggregation/result_cache.hpp>
#include <cudf/groupby.hpp>
#include <cudf/types.hpp>
#include <cudf/utilities/span.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/mr/device/device_memory_resource.hpp>

namespace cudf::groupby::detail::hash {
/**
 * @brief Gather sparse results into dense using `gather_map` and add to
 * `dense_cache`
 *
 * @see groupby_null_templated()
 */
template <typename SetType>
void sparse_to_dense_results(bitmask_type const* row_bitmask,
                             host_span<aggregation_request const> requests,
                             cudf::detail::result_cache* sparse_results,
                             cudf::detail::result_cache* dense_results,
                             device_span<size_type const> gather_map,
                             SetType set,
                             bool skip_rows_with_nulls,
                             rmm::cuda_stream_view stream,
                             rmm::device_async_resource_ref mr);
}  // namespace cudf::groupby::detail::hash
