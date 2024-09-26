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

#include <cudf/detail/utilities/cuda_memcpy.hpp>
#include <cudf/detail/utilities/host_vector.hpp>
#include <cudf/detail/utilities/vector_factories.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/device_scalar.hpp>
#include <rmm/resource_ref.hpp>

namespace CUDF_EXPORT cudf {
namespace detail {

template <typename T>
class device_scalar : public rmm::device_scalar<T> {
 public:
  ~device_scalar() = default;

  device_scalar(device_scalar&&) noexcept            = default;
  device_scalar& operator=(device_scalar&&) noexcept = default;

  device_scalar(device_scalar const&)            = delete;
  device_scalar& operator=(device_scalar const&) = delete;

  device_scalar() = delete;

  explicit device_scalar(
    rmm::cuda_stream_view stream,
    rmm::device_async_resource_ref mr = cudf::get_current_device_resource_ref())
    : rmm::device_scalar<T>(stream, mr)
  {
  }

  explicit device_scalar(
    T const& initial_value,
    rmm::cuda_stream_view stream,
    rmm::device_async_resource_ref mr = cudf::get_current_device_resource_ref())
    : rmm::device_scalar<T>(initial_value, stream, mr)
  {
  }

  device_scalar(device_scalar const& other,
                rmm::cuda_stream_view stream,
                rmm::device_async_resource_ref mr = cudf::get_current_device_resource_ref())
    : rmm::device_scalar<T>(other, stream, mr)
  {
  }

  [[nodiscard]] T value(rmm::cuda_stream_view stream) const
  {
    auto h_value         = make_host_vector<T>(1, stream);
    auto const is_pinned = h_value.get_allocator().is_device_accessible();
    // TODO replace with from_device
    cuda_memcpy_async(h_value.data(),
                      this->data(),
                      sizeof(T),
                      is_pinned ? host_memory_kind::PINNED : host_memory_kind::PAGEABLE,
                      stream);
    stream.synchronize();
    return h_value[0];
  }
};

}  // namespace detail
}  // namespace CUDF_EXPORT cudf