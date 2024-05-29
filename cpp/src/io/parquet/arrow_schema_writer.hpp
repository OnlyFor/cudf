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

/**
 * @file arrow_schema_writer.hpp
 * @brief Arrow IPC schema writer implementation
 */

#pragma once

#include <cudf/detail/utilities/linked_column.hpp>
#include <cudf/io/data_sink.hpp>
#include <cudf/io/detail/parquet.hpp>
#include <cudf/strings/detail/utilities.hpp>
#include <cudf/types.hpp>

#include <string>
#include <vector>

namespace cudf::io::parquet::detail {

using namespace cudf::io::detail;

/**
 * @brief Returns ``true`` if the column is nullable or if the write mode is not
 *        set to write the table all at once instead of chunked
 *
 * @param column A view of the column
 * @param column_metadata Metadata of the column
 * @param write_mode Flag to indicate that we are guaranteeing a single table write
 *
 * @return Whether the column is nullable.
 */
[[nodiscard]] inline bool is_col_nullable(cudf::detail::LinkedColPtr const& column,
                                          column_in_metadata const& column_metadata,
                                          single_write_mode write_mode)
{
  if (column_metadata.is_nullability_defined()) {
    CUDF_EXPECTS(column_metadata.nullable() or column->null_count() == 0,
                 "Mismatch in metadata prescribed nullability and input column. "
                 "Metadata for input column with nulls cannot prescribe nullability = false");
    return column_metadata.nullable();
  }
  // For chunked write, when not provided nullability, we assume the worst case scenario
  // that all columns are nullable.
  return write_mode == single_write_mode::NO or column->nullable();
}

/**
 * @brief Construct and return arrow schema from input parquet schema
 *
 * Recursively traverses through parquet schema to construct the arrow schema tree.
 * Serializes the arrow schema tree and stores it as the header (or metadata) of
 * an otherwise empty ipc message using flatbuffers. The ipc message is then prepended
 * with header size (padded for 16 byte alignment) and a continuation string. The final
 * string is base64 encoded and returned.
 *
 * @param linked_columns Vector of table column views
 * @param metadata Metadata of the columns of the table
 * @param write_mode Flag to indicate that we are guaranteeing a single table write
 * @param utc_timestamps Flag to indicate if timestamps are UTC
 * @param int96_timestamps Flag to indicate if timestamps was written as INT96
 *
 * @return The constructed arrow ipc message string
 */
std::string construct_arrow_schema_ipc_message(cudf::detail::LinkedColVector const& linked_columns,
                                               table_input_metadata const& metadata,
                                               single_write_mode const write_mode,
                                               bool const utc_timestamps,
                                               bool const int96_timestamps);

}  // namespace cudf::io::parquet::detail
