/*
 * Copyright (c) 2022-2024, NVIDIA CORPORATION.
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

#include "reader_impl.hpp"

#include <rmm/resource_ref.hpp>

namespace cudf::io::parquet::detail {

reader::reader() = default;

reader::reader(std::vector<std::unique_ptr<datasource>>&& sources,
               parquet_reader_options const& options,
               rmm::cuda_stream_view stream,
               rmm::device_async_resource_ref mr)
  : _impl(std::make_unique<impl>(std::move(sources), options, stream, mr))
{
}

reader::~reader() = default;

table_with_metadata reader::read(parquet_reader_options const& options)
{
  // if the user has specified custom row bounds
  bool const uses_custom_row_bounds =
    options.get_num_rows().has_value() || options.get_skip_rows() != 0;
  return _impl->read(options.get_skip_rows(),
                     options.get_num_rows(),
                     uses_custom_row_bounds,
                     options.get_row_groups(),
                     options.get_filter());
}

chunked_reader::chunked_reader(std::size_t chunk_read_limit,
                               std::size_t pass_read_limit,
                               std::vector<std::unique_ptr<datasource>>&& sources,
                               parquet_reader_options const& options,
                               rmm::cuda_stream_view stream,
                               rmm::device_async_resource_ref mr)
{
  _impl = std::make_unique<impl>(
    chunk_read_limit, pass_read_limit, std::move(sources), options, stream, mr);
}

chunked_reader::~chunked_reader() = default;

bool chunked_reader::has_next(parquet_reader_options const& options) const
{
  return _impl->has_next(options.get_skip_rows(),
                         options.get_num_rows(),
                         options.get_row_groups(),
                         options.get_filter());
}

table_with_metadata chunked_reader::read_chunk(parquet_reader_options const& options) const
{
  return _impl->read_chunk(options.get_skip_rows(),
                           options.get_num_rows(),
                           options.get_row_groups(),
                           options.get_filter());
}

}  // namespace cudf::io::parquet::detail
