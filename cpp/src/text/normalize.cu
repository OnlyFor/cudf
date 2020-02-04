/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
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

#include <cudf/column/column.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/column/column_factories.hpp>
#include <cudf/column/column_device_view.cuh>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/strings/string_view.cuh>
#include <cudf/text/normalize.hpp>
#include <cudf/utilities/error.hpp>
#include <strings/utilities.cuh>
#include <strings/utilities.hpp>

#include <text/utilities/tokenize_ops.cuh>

#include <thrust/transform.h>

namespace cudf
{
namespace nvtext
{
namespace detail
{
namespace
{

// Kernel operator for normalizing whitespace
struct normalize_spaces_fn : base_tokenator
{
    column_device_view d_strings;
    int32_t const* d_offsets{};
    char* d_buffer{};

    normalize_spaces_fn( column_device_view d_strings,
                         int32_t const* d_offsets = nullptr,
                         char* d_buffer = nullptr )
        : d_strings(d_strings), d_offsets(d_offsets), d_buffer(d_buffer) {}
    //
    __device__ int32_t operator()(unsigned int idx)
    {
        if( d_strings.is_null(idx) )
            return 0;
        string_view single_space(" ",1);
        string_view d_str = d_strings.element<string_view>(idx);
        // output buffer
        char* buffer = d_offsets ? d_buffer + d_offsets[idx] : nullptr;
        char* optr = buffer; // running output pointer
        int nbytes = 0, spos = 0, epos = d_str.length();
        bool spaces = true;
        auto itr = d_str.begin();
        while( next_token(d_str,spaces,itr,spos,epos) )
        {
            int spos_bo = d_str.byte_offset(spos); // convert char pos
            int epos_bo = d_str.byte_offset(epos); // to byte offset
            nbytes += epos_bo - spos_bo + 1; // include a space per token
            if( !buffer )
            {
                string_view token( d_str.data() + spos_bo, epos_bo - spos_bo );
                if( optr != buffer )
                    optr = strings::detail::copy_string(optr,single_space); // add just one space
                optr = strings::detail::copy_string(optr,token); // copy token
            }
            spos = epos + 1;
            //epos = dstr->chars_count();
            ++itr; // next character
        }
        return (nbytes>0) ? nbytes-1:0; // remove trailing space
    }
};

} // namspace

//
std::unique_ptr<column> normalize_spaces( strings_column_view const& strings,
                                          rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource(),
                                          cudaStream_t stream = 0 )
{
    size_type strings_count = strings.size();
    if( strings_count == 0 )
        return make_empty_column(data_type{STRING});

    auto execpol = rmm::exec_policy(stream);
    auto strings_column = column_device_view::create(strings.parent(), stream);
    auto d_strings = *strings_column;

    rmm::device_buffer null_mask = copy_bitmask( strings.parent(), stream, mr );
    auto offsets_transformer_itr = thrust::make_transform_iterator( thrust::make_counting_iterator<int32_t>(0),
        normalize_spaces_fn{d_strings} );
    auto offsets_column = strings::detail::make_offsets_child_column(offsets_transformer_itr,
                                       offsets_transformer_itr+strings_count,
                                       mr, stream);
    auto d_offsets = offsets_column->view().data<int32_t>();

    // build the chars column -- convert characters based on case_flag parameter
    size_type bytes = thrust::device_pointer_cast(d_offsets)[strings_count];
    auto chars_column = strings::detail::create_chars_child_column( strings_count, strings.null_count(), bytes, mr, stream );
    auto d_chars = chars_column->mutable_view().data<char>();
    thrust::for_each_n(execpol->on(stream),
        thrust::make_counting_iterator<size_type>(0), strings_count,
        normalize_spaces_fn{d_strings, d_offsets, d_chars} );
    //
    return make_strings_column(strings_count, std::move(offsets_column), std::move(chars_column),
                               strings.null_count(), std::move(null_mask), stream, mr);
}

} // namespace detail

// external APIs

std::unique_ptr<column> normalize_spaces( strings_column_view const& strings,
                                          rmm::mr::device_memory_resource* mr )
{
    return detail::normalize_spaces( strings, mr );
}

} // namespace nvtext
} // namespace cudf
