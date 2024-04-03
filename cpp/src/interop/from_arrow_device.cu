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

#include <cudf/column/column_view.hpp>
#include <cudf/detail/interop.hpp>
#include <cudf/detail/null_mask.hpp>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/detail/transform.hpp>
#include <cudf/detail/unary.hpp>
#include <cudf/interop.hpp>
#include <cudf/interop/detail/arrow.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/types.hpp>
#include <cudf/utilities/default_stream.hpp>
#include <cudf/utilities/traits.hpp>
#include <cudf/utilities/type_dispatcher.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/device_buffer.hpp>

#include <nanoarrow/nanoarrow.h>
#include <nanoarrow/nanoarrow.hpp>

namespace cudf {

namespace detail {
data_type arrow_to_cudf_type(const ArrowSchemaView* arrow_view)
{
  switch (arrow_view->type) {
    case NANOARROW_TYPE_NA: return data_type(type_id::EMPTY);
    case NANOARROW_TYPE_BOOL: return data_type(type_id::BOOL8);
    case NANOARROW_TYPE_INT8: return data_type(type_id::INT8);
    case NANOARROW_TYPE_INT16: return data_type(type_id::INT16);
    case NANOARROW_TYPE_INT32: return data_type(type_id::INT32);
    case NANOARROW_TYPE_INT64: return data_type(type_id::INT64);
    case NANOARROW_TYPE_UINT8: return data_type(type_id::UINT8);
    case NANOARROW_TYPE_UINT16: return data_type(type_id::UINT16);
    case NANOARROW_TYPE_UINT32: return data_type(type_id::UINT32);
    case NANOARROW_TYPE_UINT64: return data_type(type_id::UINT64);
    case NANOARROW_TYPE_FLOAT: return data_type(type_id::FLOAT32);
    case NANOARROW_TYPE_DOUBLE: return data_type(type_id::FLOAT64);
    case NANOARROW_TYPE_DATE32: return data_type(type_id::TIMESTAMP_DAYS);
    case NANOARROW_TYPE_STRING: return data_type(type_id::STRING);
    case NANOARROW_TYPE_LIST: return data_type(type_id::LIST);
    case NANOARROW_TYPE_DICTIONARY: return data_type(type_id::DICTIONARY32);
    case NANOARROW_TYPE_STRUCT: return data_type(type_id::STRUCT);
    case NANOARROW_TYPE_TIMESTAMP: {
      switch (arrow_view->time_unit) {
        case NANOARROW_TIME_UNIT_SECOND: return data_type(type_id::TIMESTAMP_SECONDS);
        case NANOARROW_TIME_UNIT_MILLI: return data_type(type_id::TIMESTAMP_MILLISECONDS);
        case NANOARROW_TIME_UNIT_MICRO: return data_type(type_id::TIMESTAMP_MICROSECONDS);
        case NANOARROW_TIME_UNIT_NANO: return data_type(type_id::TIMESTAMP_NANOSECONDS);
        default: CUDF_FAIL("Unsupported timestamp unit in arrow");
      }
    }
    case NANOARROW_TYPE_DURATION: {
      switch (arrow_view->time_unit) {
        case NANOARROW_TIME_UNIT_SECOND: return data_type(type_id::DURATION_SECONDS);
        case NANOARROW_TIME_UNIT_MILLI: return data_type(type_id::DURATION_MILLISECONDS);
        case NANOARROW_TIME_UNIT_MICRO: return data_type(type_id::DURATION_MICROSECONDS);
        case NANOARROW_TIME_UNIT_NANO: return data_type(type_id::DURATION_NANOSECONDS);
        default: CUDF_FAIL("Unsupported duration unit in arrow");
      }
    }
    case NANOARROW_TYPE_DECIMAL128:
      return data_type{type_id::DECIMAL128, -arrow_view->decimal_scale};
    default: CUDF_FAIL("Unsupported type_id conversion to cudf");
  }
}

namespace {
struct dispatch_to_cudf_column {
  template <typename T, CUDF_ENABLE_IF(not is_rep_layout_compatible<T>())>
  std::tuple<column_view, owned_columns_t> operator()(ArrowSchemaView*,
                                                      const ArrowArray*,
                                                      data_type,
                                                      bool,
                                                      rmm::cuda_stream_view,
                                                      rmm::mr::device_memory_resource*)
  {
    CUDF_FAIL("Unsupported type in from_arrow_device");
  }

  template <typename T, CUDF_ENABLE_IF(is_rep_layout_compatible<T>())>
  std::tuple<column_view, owned_columns_t> operator()(ArrowSchemaView* schema,
                                                      const ArrowArray* input,
                                                      data_type type,
                                                      bool skip_mask,
                                                      rmm::cuda_stream_view,
                                                      rmm::mr::device_memory_resource*)
  {
    size_type const num_rows = input->length;
    size_type const offset   = input->offset;
    auto const has_nulls     = skip_mask ? false : input->null_count > 0;
    bitmask_type const* null_mask =
      has_nulls ? reinterpret_cast<bitmask_type const*>(input->buffers[0]) : nullptr;
    auto data_buffer = input->buffers[1];
    return std::make_tuple<column_view, owned_columns_t>({type,
                                                          num_rows,
                                                          data_buffer,
                                                          null_mask,
                                                          static_cast<size_type>(input->null_count),
                                                          static_cast<size_type>(offset)},
                                                         {});
  }
};

column_view get_empty_type_column(size_type size)
{
  return {data_type(type_id::EMPTY), size, nullptr, nullptr, size};
}

std::tuple<column_view, owned_columns_t> get_column(ArrowSchemaView* schema,
                                                    const ArrowArray* input,
                                                    data_type type,
                                                    bool skip_mask,
                                                    rmm::cuda_stream_view stream,
                                                    rmm::mr::device_memory_resource* mr);

template <>
std::tuple<column_view, owned_columns_t> dispatch_to_cudf_column::operator()<bool>(
  ArrowSchemaView* schema,
  const ArrowArray* input,
  data_type type,
  bool skip_mask,
  rmm::cuda_stream_view stream,
  rmm::mr::device_memory_resource* mr)
{
  if (input->length == 0) {
    return std::make_tuple<column_view, owned_columns_t>({type, 0, nullptr, nullptr, 0}, {});
  }
  auto out_col         = mask_to_bools(reinterpret_cast<bitmask_type const*>(input->buffers[1]),
                               input->offset,
                               input->offset + input->length,
                               stream,
                               mr);
  auto const has_nulls = skip_mask ? false : input->null_count > 0;
  if (has_nulls) {
    auto out_mask =
      cudf::detail::copy_bitmask(reinterpret_cast<bitmask_type const*>(input->buffers[0]),
                                 input->offset,
                                 input->offset + input->length,
                                 stream,
                                 mr);
    out_col->set_null_mask(std::move(out_mask), input->null_count);
  }

  auto out_view = out_col->view();
  owned_columns_t owned;
  owned.emplace_back(std::move(out_col));
  return std::make_tuple<column_view, owned_columns_t>(std::move(out_view), std::move(owned));
}

template <>
std::tuple<column_view, owned_columns_t> dispatch_to_cudf_column::operator()<cudf::string_view>(
  ArrowSchemaView* schema,
  const ArrowArray* input,
  data_type type,
  bool skip_mask,
  rmm::cuda_stream_view stream,
  rmm::mr::device_memory_resource* mr)
{
  if (input->length == 0) {
    return std::make_tuple<column_view, owned_columns_t>({type, 0, nullptr, nullptr, 0}, {});
  }

  auto offsets_view = column_view{data_type(type_id::INT32),
                                  static_cast<size_type>(input->length) + 1,
                                  input->buffers[1],
                                  nullptr,
                                  0,
                                  static_cast<size_type>(input->offset)};
  return std::make_tuple<column_view, owned_columns_t>(
    {type,
     static_cast<size_type>(input->length),
     input->buffers[2],
     skip_mask || input->null_count <= 0 ? nullptr
                                         : reinterpret_cast<bitmask_type const*>(input->buffers[0]),
     static_cast<size_type>(input->null_count),
     static_cast<size_type>(input->offset),
     {offsets_view}},
    {});
}

template <>
std::tuple<column_view, owned_columns_t> dispatch_to_cudf_column::operator()<cudf::dictionary32>(
  ArrowSchemaView* schema,
  const ArrowArray* input,
  data_type type,
  bool skip_mask,
  rmm::cuda_stream_view stream,
  rmm::mr::device_memory_resource* mr)
{
  ArrowSchemaView keys_schema_view;
  NANOARROW_THROW_NOT_OK(
    ArrowSchemaViewInit(&keys_schema_view, schema->schema->dictionary, nullptr));

  auto const keys_type = arrow_to_cudf_type(&keys_schema_view);
  auto [keys_view, owned_cols] =
    get_column(&keys_schema_view, input->dictionary, keys_type, true, stream, mr);

  auto const dict_indices_type = [&schema]() -> data_type {
    switch (schema->storage_type) {
      case NANOARROW_TYPE_INT8: return data_type(type_id::INT8);
      case NANOARROW_TYPE_INT16: return data_type(type_id::INT16);
      case NANOARROW_TYPE_INT32: return data_type(type_id::INT32);
      case NANOARROW_TYPE_INT64: return data_type(type_id::INT64);
      case NANOARROW_TYPE_UINT8: return data_type(type_id::UINT8);
      case NANOARROW_TYPE_UINT16: return data_type(type_id::UINT16);
      case NANOARROW_TYPE_UINT32: return data_type(type_id::UINT32);
      case NANOARROW_TYPE_UINT64: return data_type(type_id::UINT64);
      default: CUDF_FAIL("Unsupported type_id for dictionary indices");
    }
  }();

  column_view indices_view = column_view{dict_indices_type,
                                         static_cast<size_type>(input->length),
                                         input->buffers[1],
                                         nullptr,
                                         0,
                                         static_cast<size_type>(input->offset)};
  // need to cast the indices to uint32 instead of just using them as-is
  if (dict_indices_type != data_type{type_id::UINT32}) {
    // there should not be any nulls with indices, so we can just be very simple here
    auto indices_col = cudf::detail::cast(indices_view, data_type{type_id::UINT32}, stream, mr);
    indices_view     = indices_col->view();
    owned_cols.emplace_back(std::move(indices_col));
  }

  return std::make_tuple<column_view, owned_columns_t>(
    column_view{type,
                static_cast<size_type>(input->length),
                nullptr,
                reinterpret_cast<bitmask_type const*>(input->buffers[0]),
                static_cast<size_type>(input->null_count),
                static_cast<size_type>(input->offset),
                {indices_view, keys_view}},
    std::move(owned_cols));
}

template <>
std::tuple<column_view, owned_columns_t> dispatch_to_cudf_column::operator()<cudf::struct_view>(
  ArrowSchemaView* schema,
  const ArrowArray* input,
  data_type type,
  bool skip_mask,
  rmm::cuda_stream_view stream,
  rmm::mr::device_memory_resource* mr)
{
  std::vector<column_view> children;
  owned_columns_t out_owned_cols;
  std::transform(
    input->children,
    input->children + input->n_children,
    schema->schema->children,
    std::back_inserter(children),
    [&out_owned_cols, &stream, &mr](ArrowArray const* child, ArrowSchema const* child_schema) {
      ArrowSchemaView view;
      NANOARROW_THROW_NOT_OK(ArrowSchemaViewInit(&view, child_schema, nullptr));
      auto type              = arrow_to_cudf_type(&view);
      auto [out_view, owned] = get_column(&view, child, type, false, stream, mr);
      if (out_owned_cols.empty()) {
        out_owned_cols = std::move(owned);
      } else {
        out_owned_cols.insert(std::end(out_owned_cols),
                              std::make_move_iterator(std::begin(owned)),
                              std::make_move_iterator(std::end(owned)));
      }
      return out_view;
    });

  return std::make_tuple<column_view, owned_columns_t>(
    {type,
     static_cast<size_type>(input->length),
     nullptr,
     reinterpret_cast<bitmask_type const*>(input->buffers[0]),
     static_cast<size_type>(input->null_count),
     static_cast<size_type>(input->offset),
     std::move(children)},
    std::move(out_owned_cols));
}

template <>
std::tuple<column_view, owned_columns_t> dispatch_to_cudf_column::operator()<cudf::list_view>(
  ArrowSchemaView* schema,
  const ArrowArray* input,
  data_type type,
  bool skip_mask,
  rmm::cuda_stream_view stream,
  rmm::mr::device_memory_resource* mr)
{
  auto offsets_view = column_view{data_type(type_id::INT32),
                                  static_cast<size_type>(input->length) + 1,
                                  input->buffers[1],
                                  nullptr,
                                  0,
                                  static_cast<size_type>(input->offset)};

  ArrowSchemaView child_schema_view;
  NANOARROW_THROW_NOT_OK(
    ArrowSchemaViewInit(&child_schema_view, schema->schema->children[0], nullptr));
  auto child_type = arrow_to_cudf_type(&child_schema_view);
  auto [child_view, owned] =
    get_column(&child_schema_view, input->children[0], child_type, false, stream, mr);

  return std::make_tuple<column_view, owned_columns_t>(
    {type,
     static_cast<size_type>(input->length),
     nullptr,
     reinterpret_cast<bitmask_type const*>(input->buffers[0]),
     static_cast<size_type>(input->null_count),
     static_cast<size_type>(input->offset),
     {offsets_view, child_view}},
    std::move(owned));
}

std::tuple<column_view, owned_columns_t> get_column(ArrowSchemaView* schema,
                                                    const ArrowArray* input,
                                                    data_type type,
                                                    bool skip_mask,
                                                    rmm::cuda_stream_view stream,
                                                    rmm::mr::device_memory_resource* mr)
{
  return type.id() != type_id::EMPTY
           ? std::move(type_dispatcher(
               type, dispatch_to_cudf_column{}, schema, input, type, skip_mask, stream, mr))
           : std::make_tuple<column_view, owned_columns_t>(get_empty_type_column(input->length),
                                                           {});
}

}  // namespace

unique_table_view_t from_arrow_device(ArrowSchemaView* schema,
                                      const ArrowDeviceArray* input,
                                      rmm::cuda_stream_view stream,
                                      rmm::mr::device_memory_resource* mr)
{
  if (input->sync_event != nullptr) {
    cudaStreamWaitEvent(stream.value(), *reinterpret_cast<cudaEvent_t*>(input->sync_event));
  }

  std::vector<column_view> columns;
  owned_columns_t owned_mem;

  auto type = arrow_to_cudf_type(schema);
  if (type != data_type(type_id::STRUCT)) {
    auto [colview, owned] = get_column(schema, &input->array, type, false, stream, mr);
    columns.push_back(colview);
    owned_mem = std::move(owned);
  } else {
    std::transform(
      input->array.children,
      input->array.children + input->array.n_children,
      schema->schema->children,
      std::back_inserter(columns),
      [&owned_mem, &stream, &mr](ArrowArray const* child, ArrowSchema const* child_schema) {
        ArrowSchemaView view;
        NANOARROW_THROW_NOT_OK(ArrowSchemaViewInit(&view, child_schema, nullptr));
        auto type              = arrow_to_cudf_type(&view);
        auto [out_view, owned] = get_column(&view, child, type, false, stream, mr);
        if (owned_mem.empty()) {
          owned_mem = std::move(owned);
        } else {
          owned_mem.insert(std::end(owned_mem),
                           std::make_move_iterator(std::begin(owned)),
                           std::make_move_iterator(std::end(owned)));
        }
        return out_view;
      });
  }

  return unique_table_view_t{new table_view{columns}, custom_view_deleter{std::move(owned_mem)}};
}

}  // namespace detail

unique_table_view_t from_arrow_device(const ArrowSchema* schema,
                                      const ArrowDeviceArray* input,
                                      rmm::cuda_stream_view stream,
                                      rmm::mr::device_memory_resource* mr)
{
  CUDF_EXPECTS(schema != nullptr && input != nullptr,
               "input ArrowSchema and ArrowDeviceArray must not be NULL");
  CUDF_EXPECTS(input->device_type == ARROW_DEVICE_CUDA ||
                 input->device_type == ARROW_DEVICE_CUDA_HOST ||
                 input->device_type == ARROW_DEVICE_CUDA_MANAGED,
               "ArrowDeviceArray memory must be accessible to CUDA");

  CUDF_FUNC_RANGE();

  ArrowSchemaView view;
  NANOARROW_THROW_NOT_OK(ArrowSchemaViewInit(&view, schema, nullptr));
  return detail::from_arrow_device(&view, input, stream, mr);
}

}  // namespace cudf
