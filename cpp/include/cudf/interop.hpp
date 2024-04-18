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

// We disable warning 611 because the `arrow::TableBatchReader` only partially
// override the `ReadNext` method of `arrow::RecordBatchReader::ReadNext`
// triggering warning 611-D from nvcc.
#ifdef __CUDACC__
#pragma nv_diag_suppress 611
#pragma nv_diag_suppress 2810
#endif
#include <arrow/api.h>
#ifdef __CUDACC__
#pragma nv_diag_default 611
#pragma nv_diag_default 2810
#endif

#include <cudf/column/column.hpp>
#include <cudf/detail/transform.hpp>
#include <cudf/table/table.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/types.hpp>
#include <cudf/utilities/span.hpp>

#include <rmm/mr/device/per_device_resource.hpp>

struct DLManagedTensor;

struct ArrowDeviceArray;

struct ArrowSchema;

namespace cudf {
/**
 * @addtogroup interop_dlpack
 * @{
 * @file
 */

/**
 * @brief Convert a DLPack DLTensor into a cudf table
 *
 * The `device_type` of the DLTensor must be `kDLCPU`, `kDLCuda`, or
 * `kDLCUDAHost`, and `device_id` must match the current device. The `ndim`
 * must be set to 1 or 2. The `dtype` must have 1 lane and the bitsize must
 * match a supported `cudf::data_type`.
 *
 * @note The managed tensor is not deleted by this function.
 *
 * @throw cudf::logic_error if the any of the DLTensor fields are unsupported
 *
 * @param managed_tensor a 1D or 2D column-major (Fortran order) tensor
 * @param mr Device memory resource used to allocate the returned table's device memory
 *
 * @return Table with a copy of the tensor data
 */
std::unique_ptr<table> from_dlpack(
  DLManagedTensor const* managed_tensor,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

/**
 * @brief Convert a cudf table into a DLPack DLTensor
 *
 * All columns must have the same data type and this type must be numeric. The
 * columns may be nullable, but the null count must be zero. If the input table
 * is empty or has zero rows, the result will be nullptr.
 *
 * @note The `deleter` method of the returned `DLManagedTensor` must be used to
 * free the memory allocated for the tensor.
 *
 * @throw cudf::logic_error if the data types are not equal or not numeric,
 * or if any of columns have non-zero null count
 *
 * @param input Table to convert to DLPack
 * @param mr Device memory resource used to allocate the returned DLPack tensor's device memory
 *
 * @return 1D or 2D DLPack tensor with a copy of the table data, or nullptr
 */
DLManagedTensor* to_dlpack(
  table_view const& input,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

/** @} */  // end of group

/**
 * @addtogroup interop_arrow
 * @{
 * @file
 */

/**
 * @brief Detailed metadata information for arrow array.
 *
 * As of now this contains only name in the hierarchy of children of cudf column,
 * but in future this can be updated as per requirement.
 */
struct column_metadata {
  std::string name;                            ///< Name of the column
  std::vector<column_metadata> children_meta;  ///< Metadata of children of the column

  /**
   * @brief Construct a new column metadata object
   *
   * @param _name Name of the column
   */
  column_metadata(std::string const& _name) : name(_name) {}
  column_metadata() = default;
};

/**
 * @brief Create `arrow::Table` from cudf table `input`
 *
 * Converts the `cudf::table_view` to `arrow::Table` with the provided
 * metadata `column_names`.
 *
 * @throws cudf::logic_error if `column_names` size doesn't match with number of columns.
 *
 * @param input table_view that needs to be converted to arrow Table
 * @param metadata Contains hierarchy of names of columns and children
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @param ar_mr arrow memory pool to allocate memory for arrow Table
 * @return arrow Table generated from `input`
 *
 * @note For decimals, since the precision is not stored for them in libcudf,
 * it will be converted to an Arrow decimal128 that has the widest-precision the cudf decimal type
 * supports. For example, numeric::decimal32 will be converted to Arrow decimal128 of the precision
 * 9 which is the maximum precision for 32-bit types. Similarly, numeric::decimal128 will be
 * converted to Arrow decimal128 of the precision 38.
 */
std::shared_ptr<arrow::Table> to_arrow(table_view input,
                                       std::vector<column_metadata> const& metadata = {},
                                       rmm::cuda_stream_view stream = cudf::get_default_stream(),
                                       arrow::MemoryPool* ar_mr     = arrow::default_memory_pool());

/**
 * @brief Create `arrow::Scalar` from cudf scalar `input`
 *
 * Converts the `cudf::scalar` to `arrow::Scalar`.
 *
 * @param input scalar that needs to be converted to arrow Scalar
 * @param metadata Contains hierarchy of names of columns and children
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @param ar_mr arrow memory pool to allocate memory for arrow Scalar
 * @return arrow Scalar generated from `input`
 *
 * @note For decimals, since the precision is not stored for them in libcudf,
 * it will be converted to an Arrow decimal128 that has the widest-precision the cudf decimal type
 * supports. For example, numeric::decimal32 will be converted to Arrow decimal128 of the precision
 * 9 which is the maximum precision for 32-bit types. Similarly, numeric::decimal128 will be
 * converted to Arrow decimal128 of the precision 38.
 */
std::shared_ptr<arrow::Scalar> to_arrow(cudf::scalar const& input,
                                        column_metadata const& metadata = {},
                                        rmm::cuda_stream_view stream = cudf::get_default_stream(),
                                        arrow::MemoryPool* ar_mr = arrow::default_memory_pool());

/**
 * @brief typedef for a unique_ptr to an ArrowSchema with custom deleter
 *
 */
using unique_schema_t = std::unique_ptr<ArrowSchema, void (*)(ArrowSchema*)>;

/**
 * @brief typedef for a unique_ptr to an ArrowDeviceArray with a custom deleter
 *
 */
using unique_device_array_t = std::unique_ptr<ArrowDeviceArray, void (*)(ArrowDeviceArray*)>;

/**
 * @brief Create ArrowSchema from cudf table and metadata
 *
 * Populates and returns an ArrowSchema C struct using a table and metadata.
 *
 * @note For decimals, since the precision is not stored for them in libcudf,
 * decimals will be converted to an Arrow decimal128 which has the widest precision that cudf
 * decimal type supports. For example, `numeric::decimal32` will be converted to Arrow decimal128
 * with the precision of 9 which is the maximum precision for 32-bit types. Similarly,
 * `numeric::decimal128` will be converted to Arrow decimal128 with the precision of 38.
 *
 * @param input Table to create a schema from
 * @param metadata Contains the hierarchy of names of columns and children
 * @return ArrowSchema generated from `input`
 */
unique_schema_t to_arrow_schema(cudf::table_view const& input,
                                cudf::host_span<column_metadata const> metadata);

/**
 * @brief Create `ArrowDeviceArray` from cudf table and metadata
 *
 * Populates the C struct ArrowDeviceArray without performing copies if possible.
 * This maintains the data on the GPU device and gives ownership of the table
 * and its buffers to the ArrowDeviceArray struct.
 *
 * After calling this function, the release callback on the returned ArrowDeviceArray
 * must be called to clean up the memory.
 *
 * @note For decimals, since the precision is not stored for them in libcudf
 * it will be converted to an Arrow decimal128 with the widest-precision the cudf decimal type
 * supports. For example, numeric::decimal32 will be converted to Arrow decimal128 of the precision
 * 9 which is the maximum precision for 32-bit types. Similarly, numeric::decimal128 will be
 * converted to Arrow decimal128 of the precision 38.
 *
 * @note Copies will be performed in the cases where cudf differs from Arrow
 * such as in the representation of bools (Arrow uses a bitmap, cudf uses 1-byte per value).
 *
 * @param table Input table, ownership of the data will be moved to the result
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @param mr Device memory resource used for any allocations during conversion
 * @return ArrowDeviceArray which will have ownership of the GPU data, consumer must call release
 */
unique_device_array_t to_arrow_device(
  cudf::table&& table,
  rmm::cuda_stream_view stream        = cudf::get_default_stream(),
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

/**
 * @brief Create `ArrowDeviceArray` from cudf column and metadata
 *
 * Populates the C struct ArrowDeviceArray without performing copies if possible.
 * This maintains the data on the GPU device and gives ownership of the table
 * and its buffers to the ArrowDeviceArray struct.
 *
 * After calling this function, the release callback on the returned ArrowDeviceArray
 * must be called to clean up the memory.
 *
 * @note For decimals, since the precision is not stored for them in libcudf
 * it will be converted to an Arrow decimal128 with the widest-precision the cudf decimal type
 * supports. For example, numeric::decimal32 will be converted to Arrow decimal128 of the precision
 * 9 which is the maximum precision for 32-bit types. Similar, numeric::decimal128 will be
 * converted to Arrow decimal128 of the precision 38.
 *
 * @note Copies will be performed in the cases where cudf differs from Arrow such as
 * in the representation of bools (Arrow uses a bitmap, cudf uses 1 byte per value).
 *
 * @param col Input column, ownership of the data will be moved to the result
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @param mr Device memory resource used for any allocations during conversion
 * @return ArrowDeviceArray which will have ownership of the GPU data
 */
unique_device_array_t to_arrow_device(
  cudf::column&& col,
  rmm::cuda_stream_view stream        = cudf::get_default_stream(),
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

/**
 * @brief Create `cudf::table` from given arrow Table input
 *
 * @param input arrow:Table that needs to be converted to `cudf::table`
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @param mr    Device memory resource used to allocate `cudf::table`
 * @return cudf table generated from given arrow Table
 */

std::unique_ptr<table> from_arrow(
  arrow::Table const& input,
  rmm::cuda_stream_view stream        = cudf::get_default_stream(),
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

/**
 * @brief Create `cudf::scalar` from given arrow Scalar input
 *
 * @param input `arrow::Scalar` that needs to be converted to `cudf::scalar`
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @param mr    Device memory resource used to allocate `cudf::scalar`
 * @return cudf scalar generated from given arrow Scalar
 */

std::unique_ptr<cudf::scalar> from_arrow(
  arrow::Scalar const& input,
  rmm::cuda_stream_view stream        = cudf::get_default_stream(),
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

/**
 * @brief typedef for a vector of owning columns, used for conversion from ArrowDeviceArray
 *
 */
using owned_columns_t = std::vector<std::unique_ptr<cudf::column>>;

/**
 * @brief functor for a custom deleter to a unique_ptr of table_view
 *
 * When converting from an ArrowDeviceArray, there are cases where data can't
 * be zero-copy (i.e. bools or non-UINT32 dictionary indices). This custom deleter
 * is used to maintain ownership over the data allocated since a `cudf::table_view`
 * doesn't hold ownership.
 */
template <typename ViewType>
struct custom_view_deleter {
  /**
   * @brief Construct a new custom view deleter object
   *
   * @param owned Vector of owning columns
   */
  explicit custom_view_deleter(owned_columns_t&& owned) : owned_mem_{std::move(owned)} {}

  /**
   * @brief operator to delete the unique_ptr
   *
   * @param ptr Pointer to the object to be deleted
   */
  void operator()(ViewType* ptr) const { delete ptr; }

  owned_columns_t owned_mem_;  ///< Owned columns that must be deleted.
};

/**
 * @brief typedef for a unique_ptr to a `cudf::table_view` with custom deleter
 *
 */
using unique_table_view_t =
  std::unique_ptr<cudf::table_view, custom_view_deleter<cudf::table_view>>;

/**
 * @brief Create `cudf::table_view` from given `ArrowDeviceArray` and `ArrowSchema`
 *
 * Constructs a non-owning `cudf::table_view` using `ArrowDeviceArray` and `ArrowSchema`,
 * data must be accessible to the CUDA device. Because the resulting `cudf::table_view` will
 * not own the data, the `ArrowDeviceArray` must be kept alive for the lifetime of the result.
 * It is the responsibility of callers to ensure they call the release callback on the
 * `ArrowDeviceArray` after it is no longer needed, and that the `cudf::table_view` is not
 * accessed after this happens.
 *
 * @throws cudf::logic_error if device_type is not `ARROW_DEVICE_CUDA`, `ARROW_DEVICE_CUDA_HOST`
 * or `ARROW_DEVICE_CUDA_MANAGED`
 *
 * @throws cudf::data_type_error if the input array is not a struct array, non-struct
 * arrays should be passed to `from_arrow_device_column` instead.
 *
 * @throws cudf::data_type_error if the input arrow data type is not supported.
 *
 * Each child of the input struct will be the columns of the resulting table_view.
 *
 * @note The custom deleter used for the unique_ptr to the table_view maintains ownership
 * over any memory which is allocated, such as converting boolean columns from the bitmap
 * used by Arrow to the 1-byte per value for cudf.
 *
 * @note If the input `ArrowDeviceArray` contained a non-null sync_event it is assumed
 * to be a `cudaEvent_t*` and the passed in stream will have `cudaStreamWaitEvent` called
 * on it with the event. This function, however, will not explicitly synchronize on the
 * stream.
 *
 * @param schema `ArrowSchema` pointer to object describing the type of the device array
 * @param input `ArrowDeviceArray` pointer to object owning the Arrow data
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @param mr Device memory resource used to perform any allocations
 * @return `cudf::table_view` generated from given Arrow data
 */
unique_table_view_t from_arrow_device(
  ArrowSchema const* schema,
  ArrowDeviceArray const* input,
  rmm::cuda_stream_view stream        = cudf::get_default_stream(),
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

/**
 * @brief typedef for a unique_ptr to a `cudf::column_view` with custom deleter
 *
 */
using unique_column_view_t =
  std::unique_ptr<cudf::column_view, custom_view_deleter<cudf::column_view>>;

/**
 * @brief Create `cudf::column_view` from given `ArrowDeviceArray` and `ArrowSchema`
 *
 * Constructs a non-owning `cudf::column_view` using `ArrowDeviceArray` and `ArrowSchema`,
 * data must be accessible to the CUDA device. Because the resulting `cudf::column_view` will
 * not own the data, the `ArrowDeviceArray` must be kept alive for the lifetime of the result.
 * It is the responsibility of callers to ensure they call the release callback on the
 * `ArrowDeviceArray` after it is no longer needed, and that the `cudf::column_view` is not
 * accessed after this happens.
 *
 * @throws cudf::logic_error if device_type is not `ARROW_DEVICE_CUDA`, `ARROW_DEVICE_CUDA_HOST`
 * or `ARROW_DEVICE_CUDA_MANAGED`
 *
 * @throws cudf::data_type_error input arrow data type is not supported.
 *
 * @note The custom deleter used for the unique_ptr to the table_view maintains ownership
 * over any memory which is allocated, such as converting boolean columns from the bitmap
 * used by Arrow to the 1-byte per value for cudf.
 *
 * @note If the input `ArrowDeviceArray` contained a non-null sync_event it is assumed
 * to be a `cudaEvent_t*` and the passed in stream will have `cudaStreamWaitEvent` called
 * on it with the event. This function, however, will not explicitly synchronize on the
 * stream.
 *
 * @param schema `ArrowSchema` pointer to object describing the type of the device array
 * @param input `ArrowDeviceArray` pointer to object owning the Arrow data
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @param mr Device memory resource used to perform any allocations
 * @return `cudf::column_view` generated from given Arrow data
 */
unique_column_view_t from_arrow_device_column(
  ArrowSchema const* schema,
  ArrowDeviceArray const* input,
  rmm::cuda_stream_view stream        = cudf::get_default_stream(),
  rmm::mr::device_memory_resource* mr = rmm::mr::get_current_device_resource());

/** @} */  // end of group
}  // namespace cudf
