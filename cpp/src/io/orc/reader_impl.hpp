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

#include "aggregate_orc_metadata.hpp"
#include "reader_impl_chunking.hpp"

#include <cudf/io/datasource.hpp>
#include <cudf/io/detail/orc.hpp>
#include <cudf/io/orc.hpp>

#include <rmm/cuda_stream_view.hpp>

#include <io/utilities/column_buffer.hpp>

#include <memory>
#include <optional>
#include <vector>

namespace cudf::io::orc::detail {

struct reader_column_meta;

/**
 * @brief Implementation for ORC reader.
 */
class reader::impl {
 public:
  /**
   * @brief Constructor from a dataset source with reader options.
   *
   * @param sources Dataset sources
   * @param options Settings for controlling reading behavior
   * @param stream CUDA stream used for device memory operations and kernel launches
   * @param mr Device memory resource to use for device memory allocation
   */
  explicit impl(std::vector<std::unique_ptr<datasource>>&& sources,
                orc_reader_options const& options,
                rmm::cuda_stream_view stream,
                rmm::mr::device_memory_resource* mr);

  /**
   * @copydoc cudf::io::orc::detail::chunked_reader
   */
  explicit impl(std::size_t output_size_limit,
                std::size_t data_read_limit,
                std::vector<std::unique_ptr<datasource>>&& sources,
                orc_reader_options const& options,
                rmm::cuda_stream_view stream,
                rmm::mr::device_memory_resource* mr);

  /**
   * @brief Read an entire set or a subset of data and returns a set of columns
   *
   * @param skip_rows Number of rows to skip from the start
   * @param num_rows_opt Optional number of rows to read, or `std::nullopt` to read all rows
   * @param stripes Indices of individual stripes to load if non-empty
   * @return The set of columns along with metadata
   */
  table_with_metadata read(uint64_t skip_rows,
                           std::optional<size_type> const& num_rows_opt,
                           std::vector<std::vector<size_type>> const& stripes);

  /**
   * @copydoc cudf::io::chunked_orc_reader::has_next
   */
  bool has_next();

  /**
   * @copydoc cudf::io::chunked_orc_reader::read_chunk
   */
  table_with_metadata read_chunk();

 private:
  /**
   * @brief Perform all the necessary data preprocessing before creating an output table.
   *
   * This is the proxy to call all other data preprocessing functions, which are prerequisite
   * for generating an output table.
   *
   * @param skip_rows Number of rows to skip from the start
   * @param num_rows_opt Optional number of rows to read, or `std::nullopt` to read all rows
   * @param stripes Indices of individual stripes to load if non-empty
   */
  void prepare_data(uint64_t skip_rows,
                    std::optional<size_type> const& num_rows_opt,
                    std::vector<std::vector<size_type>> const& stripes);

  /**
   * @brief Perform a global preprocessing step that executes exactly once for the entire duration
   * of the reader.
   *
   * TODO: rewrite, not use "ensure".
   *
   * In this step, the metadata of all stripes in the data source is parsed, and information about
   * data streams for all selected columns in alls tripes are generated. If the reader has a data
   * read limit, data size of all stripes are used to determine the chunks of consecutive
   * stripes for reading each time using the `load_data()` step. This is to ensure that loading
   * these stripes will not exceed a fixed portion the data read limit.
   */
  void global_preprocess(uint64_t skip_rows,
                         std::optional<size_type> const& num_rows_opt,
                         std::vector<std::vector<size_type>> const& stripes);

  /**
   * @brief Load stripes from the input source and store the data in the internal buffers.
   *
   * If there is a data read limit, only a chunk of stripes are read at a time such that
   * their total data size does not exceed a fixed portion of the limit. Then, the data is
   * probed to determine the uncompressed sizes for these loaded stripes, which are in turn
   * used to determine a subset of stripes to decompress and decode in the next step
   * `decompress_and_decode()`.
   * This is to ensure that loading data together with decompression and decoding will not exceed
   * the data read limit.
   */
  void load_data();

  /**
   * @brief Decompress and decode the data in the internal buffers, and store the result into
   * an internal table.
   *
   * If there is a data read limit, only a chunk of stripes are decompressed and decoded at a time.
   * Then, the result is stored in an internal table, and sizes of its rows are computed
   * to determine slices of rows to return as the output table in the final step
   * `make_output_chunk`.
   */
  void decompress_and_decode();

  /**
   * @brief Create the output table from the internal buffers and return it along with metadata.
   *
   * This function is called internally and expects all preprocessing steps have already been done.
   *
   * @return The output table along with columns' metadata
   */
  table_with_metadata make_output_chunk();

  /**
   * @brief Create the output table metadata from file metadata.
   *
   * @return Columns' metadata to output with the table read from file
   */
  table_metadata make_output_metadata();

  rmm::cuda_stream_view const _stream;
  rmm::mr::device_memory_resource* const _mr;

  // Reader configs
  struct {
    data_type timestamp_type;  // Override output timestamp resolution
    bool use_index;            // Enable or disable attempt to use row index for parsing
    bool use_np_dtypes;        // Enable or disable the conversion to numpy-compatible dtypes
    std::vector<std::string> decimal128_columns;  // Control decimals conversion
  } const _config;

  // Intermediate data for internal processing.
  std::unique_ptr<reader_column_meta> const _col_meta;  // Track of orc mapping and child details
  std::vector<std::unique_ptr<datasource>> const _sources;  // Unused but owns data for `_metadata`
  aggregate_orc_metadata _metadata;
  column_hierarchy const _selected_columns;  // Construct from `_metadata` thus declare after it
  file_intermediate_data _file_itm_data;
  chunk_read_data _chunk_read_data;
  std::unique_ptr<table_metadata> _out_metadata;
  std::vector<std::vector<cudf::io::detail::column_buffer>> _out_buffers;
};

}  // namespace cudf::io::orc::detail
