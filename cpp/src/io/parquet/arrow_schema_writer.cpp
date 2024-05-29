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
 * @file arrow_schema_writer.cpp
 * @brief Arrow IPC schema writer implementation
 */

#include "arrow_schema_writer.hpp"

#include "io/parquet/parquet_common.hpp"
#include "io/utilities/base64_utilities.hpp"
#include "ipc/Message_generated.h"
#include "ipc/Schema_generated.h"

#include <cudf/detail/utilities/integer_utils.hpp>
#include <cudf/utilities/error.hpp>
#include <cudf/utilities/type_dispatcher.hpp>

namespace cudf::io::parquet::detail {

// Copied over from arrow source for better code readability
namespace flatbuf       = cudf::io::parquet::flatbuf;
using FlatBufferBuilder = flatbuffers::FlatBufferBuilder;
using DictionaryOffset  = flatbuffers::Offset<flatbuf::DictionaryEncoding>;
using FieldOffset       = flatbuffers::Offset<flatbuf::Field>;
using Offset            = flatbuffers::Offset<void>;
using FBString          = flatbuffers::Offset<flatbuffers::String>;

/**
 * @brief Recursively construct the arrow schema (fields) tree
 *
 * @param fbb The root flatbuffer builder object instance
 * @param column A view of the column
 * @param column_metadata Metadata of the column
 * @param write_mode Flag to indicate that we are guaranteeing a single table write
 * @param utc_timestamps Flag to indicate if timestamps are UTC
 *
 * @return Flatbuffer offset to the constructed field
 */
FieldOffset make_arrow_schema_fields(FlatBufferBuilder& fbb,
                                     cudf::detail::LinkedColPtr const& column,
                                     column_in_metadata const& column_metadata,
                                     single_write_mode const write_mode,
                                     bool const utc_timestamps);

/**
 * @brief Functor to convert cudf column metadata to arrow schema field metadata
 */
struct dispatch_to_flatbuf {
  FlatBufferBuilder& fbb;
  cudf::detail::LinkedColPtr const& col;
  column_in_metadata const& col_meta;
  single_write_mode const write_mode;
  bool const utc_timestamps;
  Offset& field_offset;
  flatbuf::Type& type_type;
  std::vector<FieldOffset>& children;

  template <typename T>
  std::enable_if_t<std::is_same_v<T, bool>, void> operator()()
  {
    type_type    = flatbuf::Type_Bool;
    field_offset = flatbuf::CreateBool(fbb).Union();
  }

  template <typename T>
  std::enable_if_t<std::is_same_v<T, int8_t>, void> operator()()
  {
    type_type    = flatbuf::Type_Int;
    field_offset = flatbuf::CreateInt(fbb, 8, std::numeric_limits<T>::is_signed).Union();
  }

  template <typename T>
  std::enable_if_t<std::is_same_v<T, int16_t>, void> operator()()
  {
    type_type    = flatbuf::Type_Int;
    field_offset = flatbuf::CreateInt(fbb, 16, std::numeric_limits<T>::is_signed).Union();
  }

  template <typename T>
  std::enable_if_t<std::is_same_v<T, int32_t>, void> operator()()
  {
    type_type    = flatbuf::Type_Int;
    field_offset = flatbuf::CreateInt(fbb, 32, std::numeric_limits<T>::is_signed).Union();
  }

  template <typename T>
  std::enable_if_t<std::is_same_v<T, int64_t>, void> operator()()
  {
    type_type    = flatbuf::Type_Int;
    field_offset = flatbuf::CreateInt(fbb, 64, std::numeric_limits<T>::is_signed).Union();
  }

  template <typename T>
  std::enable_if_t<std::is_same_v<T, uint8_t>, void> operator()()
  {
    type_type    = flatbuf::Type_Int;
    field_offset = flatbuf::CreateInt(fbb, 8, std::numeric_limits<T>::is_signed).Union();
  }

  template <typename T>
  std::enable_if_t<std::is_same_v<T, uint16_t>, void> operator()()
  {
    type_type    = flatbuf::Type_Int;
    field_offset = flatbuf::CreateInt(fbb, 16, std::numeric_limits<T>::is_signed).Union();
  }

  template <typename T>
  std::enable_if_t<std::is_same_v<T, uint32_t>, void> operator()()
  {
    type_type    = flatbuf::Type_Int;
    field_offset = flatbuf::CreateInt(fbb, 32, std::numeric_limits<T>::is_signed).Union();
  }

  template <typename T>
  std::enable_if_t<std::is_same_v<T, uint64_t>, void> operator()()
  {
    type_type    = flatbuf::Type_Int;
    field_offset = flatbuf::CreateInt(fbb, 64, std::numeric_limits<T>::is_signed).Union();
  }

  template <typename T>
  std::enable_if_t<std::is_same_v<T, float>, void> operator()()
  {
    type_type    = flatbuf::Type_FloatingPoint;
    field_offset = flatbuf::CreateFloatingPoint(fbb, flatbuf::Precision::Precision_SINGLE).Union();
  }

  template <typename T>
  std::enable_if_t<std::is_same_v<T, double>, void> operator()()
  {
    type_type    = flatbuf::Type_FloatingPoint;
    field_offset = flatbuf::CreateFloatingPoint(fbb, flatbuf::Precision::Precision_DOUBLE).Union();
  }

  template <typename T>
  std::enable_if_t<std::is_same_v<T, cudf::string_view>, void> operator()()
  {
    type_type    = flatbuf::Type_Utf8View;
    field_offset = flatbuf::CreateUtf8View(fbb).Union();
  }

  template <typename T>
  std::enable_if_t<std::is_same_v<T, cudf::timestamp_D> or std::is_same_v<T, cudf::timestamp_s>,
                   void>
  operator()()
  {
    type_type = flatbuf::Type_Timestamp;
    // TODO: Verify if this is the correct logic for UTC
    field_offset = flatbuf::CreateTimestamp(
                     fbb, flatbuf::TimeUnit_SECOND, (utc_timestamps) ? fbb.CreateString("UTC") : 0)
                     .Union();
  }

  template <typename T>
  std::enable_if_t<std::is_same_v<T, cudf::timestamp_ms>, void> operator()()
  {
    type_type = flatbuf::Type_Timestamp;
    // TODO: Verify if this is the correct logic for UTC
    field_offset =
      flatbuf::CreateTimestamp(
        fbb, flatbuf::TimeUnit_MILLISECOND, (utc_timestamps) ? fbb.CreateString("UTC") : 0)
        .Union();
  }

  template <typename T>
  std::enable_if_t<std::is_same_v<T, cudf::timestamp_us>, void> operator()()
  {
    type_type = flatbuf::Type_Timestamp;
    // TODO: Verify if this is the correct logic for UTC
    field_offset =
      flatbuf::CreateTimestamp(
        fbb, flatbuf::TimeUnit_MICROSECOND, (utc_timestamps) ? fbb.CreateString("UTC") : 0)
        .Union();
  }

  template <typename T>
  std::enable_if_t<std::is_same_v<T, cudf::timestamp_ns>, void> operator()()
  {
    type_type = flatbuf::Type_Timestamp;
    // TODO: Verify if this is the correct logic for UTC
    field_offset =
      flatbuf::CreateTimestamp(
        fbb, flatbuf::TimeUnit_NANOSECOND, (utc_timestamps) ? fbb.CreateString("UTC") : 0)
        .Union();
  }

  template <typename T>
  std::enable_if_t<std::is_same_v<T, cudf::duration_D> or std::is_same_v<T, cudf::duration_s>, void>
  operator()()
  {
    type_type    = flatbuf::Type_Duration;
    field_offset = flatbuf::CreateDuration(fbb, flatbuf::TimeUnit_SECOND).Union();
  }

  template <typename T>
  std::enable_if_t<std::is_same_v<T, cudf::duration_ms>, void> operator()()
  {
    type_type    = flatbuf::Type_Duration;
    field_offset = flatbuf::CreateDuration(fbb, flatbuf::TimeUnit_MILLISECOND).Union();
  }

  template <typename T>
  std::enable_if_t<std::is_same_v<T, cudf::duration_us>, void> operator()()
  {
    type_type    = flatbuf::Type_Duration;
    field_offset = flatbuf::CreateDuration(fbb, flatbuf::TimeUnit_MICROSECOND).Union();
  }

  template <typename T>
  std::enable_if_t<std::is_same_v<T, cudf::duration_ns>, void> operator()()
  {
    type_type    = flatbuf::Type_Duration;
    field_offset = flatbuf::CreateDuration(fbb, flatbuf::TimeUnit_NANOSECOND).Union();
  }

  template <typename T>
  std::enable_if_t<cudf::is_fixed_point<T>(), void> operator()()
  {
    if constexpr (std::is_same_v<T, numeric::decimal128>) {
      type_type = flatbuf::Type_Decimal;
      field_offset =
        flatbuf::CreateDecimal(fbb, col_meta.get_decimal_precision(), col->type().scale(), 128)
          .Union();
    }
    // cuDF-PQ writer supports ``decimal32`` and ``decimal64`` types, not directly supported by
    // Arrow without explicit conversion. See more:
    // https://github.com/rapidsai/cudf/blob/branch-24.08/cpp/src/interop/to_arrow.cu#L155.
    else {
      // TODO: Should we fail here or just not write arrow schema?.
      CUDF_FAIL("Fixed point types smaller than `decimal128` are not supported in arrow schema");
    }
  }

  template <typename T>
  std::enable_if_t<cudf::is_nested<T>(), void> operator()()
  {
    // Lists are represented differently in arrow and cuDF.
    // cuDF representation: List<int>: "col_name" : { "list", "element:int" } (2 children)
    // arrow schema representation: List<int>: "col_name" : { "list<item:int>" } (1 child)
    // Hence, we only need to process the second child of the list.
    if constexpr (std::is_same_v<T, cudf::list_view>) {
      children.emplace_back(make_arrow_schema_fields(
        fbb, col->children[1], col_meta.child(1), write_mode, utc_timestamps));
      type_type    = flatbuf::Type_List;
      field_offset = flatbuf::CreateList(fbb).Union();
    }

    // Traverse the struct in DFS manner and process children fields.
    else if constexpr (std::is_same_v<T, cudf::struct_view>) {
      std::transform(thrust::make_counting_iterator(0UL),
                     thrust::make_counting_iterator(col->children.size()),
                     std::back_inserter(children),
                     [&](auto const idx) {
                       return make_arrow_schema_fields(
                         fbb, col->children[idx], col_meta.child(idx), write_mode, utc_timestamps);
                     });
      type_type    = flatbuf::Type_Struct_;
      field_offset = flatbuf::CreateStruct_(fbb).Union();
    }
  }

  template <typename T>
  std::enable_if_t<cudf::is_dictionary<T>(), void> operator()()
  {
    // TODO: Implementing ``dictionary32`` would need ``DictionaryFieldMapper`` and
    // ``FieldPosition`` classes from arrow source to keep track of dictionary encoding paths.
    CUDF_FAIL("Dictionary columns are not supported for writing arrow schema");
  }
};

FieldOffset make_arrow_schema_fields(FlatBufferBuilder& fbb,
                                     cudf::detail::LinkedColPtr const& column,
                                     column_in_metadata const& column_metadata,
                                     single_write_mode const write_mode,
                                     bool const utc_timestamps)
{
  Offset field_offset     = 0;
  flatbuf::Type type_type = flatbuf::Type_NONE;
  std::vector<FieldOffset> children;

  cudf::type_dispatcher(
    column->type(),
    dispatch_to_flatbuf{
      fbb, column, column_metadata, write_mode, utc_timestamps, field_offset, type_type, children});

  auto const fb_name          = fbb.CreateString(column_metadata.get_name());
  auto const fb_children      = fbb.CreateVector(children.data(), children.size());
  auto const is_nullable      = is_col_nullable(column, column_metadata, write_mode);
  DictionaryOffset dictionary = 0;

  // push to field offsets vector
  return flatbuf::CreateField(
    fbb, fb_name, is_nullable, type_type, field_offset, dictionary, fb_children);
}

std::string construct_arrow_schema_ipc_message(cudf::detail::LinkedColVector const& linked_columns,
                                               table_input_metadata const& metadata,
                                               single_write_mode const write_mode,
                                               bool const utc_timestamps)
{
  // Lambda function to convert int32 to a string of uint8 bytes
  auto const convert_int32_to_byte_string = [&](int32_t const value) {
    std::array<uint8_t, sizeof(int32_t)> buffer;
    std::memcpy(buffer.data(), &value, sizeof(int32_t));
    return std::string(reinterpret_cast<char*>(buffer.data()), buffer.size());
  };

  // Instantiate a flatbuffer builder
  FlatBufferBuilder fbb;

  // Create an empty field offset vector
  std::vector<FieldOffset> field_offsets;

  // populate field offsets (aka schema fields)
  std::transform(thrust::make_zip_iterator(
                   thrust::make_tuple(linked_columns.begin(), metadata.column_metadata.begin())),
                 thrust::make_zip_iterator(
                   thrust::make_tuple(linked_columns.end(), metadata.column_metadata.end())),
                 std::back_inserter(field_offsets),
                 [&](auto const& elem) {
                   return make_arrow_schema_fields(
                     fbb, thrust::get<0>(elem), thrust::get<1>(elem), write_mode, utc_timestamps);
                 });

  // Build an arrow:schema flatbuffer using the field offset vector and use it as the header to
  // create an ipc message flatbuffer
  fbb.Finish(flatbuf::CreateMessage(
    fbb,
    flatbuf::MetadataVersion_V5,   /* Metadata version V5 (latest) */
    flatbuf::MessageHeader_Schema, /* Schema type message header */
    flatbuf::CreateSchema(
      fbb, flatbuf::Endianness::Endianness_Little, fbb.CreateVector(field_offsets))
      .Union(),                               /* Build an arrow:schema from the field vector */
    SCHEMA_HEADER_TYPE_IPC_MESSAGE_BODYLENGTH /* Body length is zero for schema type ipc message */
    ));

  // Construct the final string and store it here to use its view in base64_encode
  std::string const ipc_message =
    convert_int32_to_byte_string(IPC_CONTINUATION_TOKEN) +
    // Since the schema type ipc message doesn't have a body, the flatbuffer size is equal to the
    // ipc message's metadata length
    convert_int32_to_byte_string(fbb.GetSize()) +
    std::string(reinterpret_cast<char*>(fbb.GetBufferPointer()), fbb.GetSize());

  // Encode the final ipc message string to base64 and return
  return cudf::io::detail::base64_encode(ipc_message);
}

}  // namespace cudf::io::parquet::detail
