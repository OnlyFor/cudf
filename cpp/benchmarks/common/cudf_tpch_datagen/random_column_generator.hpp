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

#include <cudf/column/column.hpp>

#include <string>

namespace cudf {
namespace datagen {

/**
 * @brief Generate a column of random strings
 *
 * @param lower The lower bound of the length of the strings
 * @param upper The upper bound of the length of the strings
 * @param num_rows The number of rows in the column
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @param mr Device memory resource used to allocate the returned column's device memory
 */
std::unique_ptr<cudf::column> generate_random_string_column(
  cudf::size_type lower,
  cudf::size_type upper,
  cudf::size_type num_rows,
  rmm::cuda_stream_view stream      = cudf::get_default_stream(),
  rmm::device_async_resource_ref mr = rmm::mr::get_current_device_resource());

/**
 * @brief Generate a column of random numbers
 *
 * @param lower The lower bound of the random numbers
 * @param upper The upper bound of the random numbers
 * @param num_rows The number of rows in the column
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @param mr Device memory resource used to allocate the returned column's device memory
 */
template <typename T>
std::unique_ptr<cudf::column> generate_random_numeric_column(
  T lower,
  T upper,
  cudf::size_type num_rows,
  rmm::cuda_stream_view stream      = cudf::get_default_stream(),
  rmm::device_async_resource_ref mr = rmm::mr::get_current_device_resource());

/**
 * @brief Generate a primary key column
 *
 * @param start The starting value of the primary key
 * @param num_rows The number of rows in the column
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @param mr Device memory resource used to allocate the returned column's device memory
 */
std::unique_ptr<cudf::column> generate_primary_key_column(
  cudf::scalar const& start,
  cudf::size_type num_rows,
  rmm::cuda_stream_view stream      = cudf::get_default_stream(),
  rmm::device_async_resource_ref mr = rmm::mr::get_current_device_resource());

/**
 * @brief Generate a column where all the rows have the same string value
 *
 * @param value The string value to fill the column with
 * @param num_rows The number of rows in the column
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @param mr Device memory resource used to allocate the returned column's device memory
 */
std::unique_ptr<cudf::column> generate_repeat_string_column(
  std::string const& value,
  cudf::size_type num_rows,
  rmm::cuda_stream_view stream      = cudf::get_default_stream(),
  rmm::device_async_resource_ref mr = rmm::mr::get_current_device_resource());

/**
 * @brief Generate a column by randomly choosing from set of strings
 *
 * @param set The set of strings to choose from
 * @param num_rows The number of rows in the column
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @param mr Device memory resource used to allocate the returned column's device memory
 */
std::unique_ptr<cudf::column> generate_random_string_column_from_set(
  cudf::host_span<const char* const> set,
  cudf::size_type num_rows,
  rmm::cuda_stream_view stream      = cudf::get_default_stream(),
  rmm::device_async_resource_ref mr = rmm::mr::get_current_device_resource());

/**
 * @brief Generate a column consisting of a repeating sequence of integers
 *
 * @param limit The upper limit of the repeating sequence
 * @param num_rows The number of rows in the column
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @param mr Device memory resource used to allocate the returned column's device memory
 */
template <typename T>
std::unique_ptr<cudf::column> generate_repeat_sequence_column(
  T seq_length,
  bool zero_indexed,
  cudf::size_type num_rows,
  rmm::cuda_stream_view stream      = cudf::get_default_stream(),
  rmm::device_async_resource_ref mr = rmm::mr::get_current_device_resource());

}  // namespace datagen
}  // namespace cudf
