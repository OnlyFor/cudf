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

#include <cudf_test/base_fixture.hpp>
#include <cudf_test/column_utilities.hpp>
#include <cudf_test/column_wrapper.hpp>
#include <cudf_test/default_stream.hpp>
#include <cudf_test/table_utilities.hpp>
#include <cudf_test/type_lists.hpp>

#include <cudf/ast/expressions.hpp>
#include <cudf/column/column.hpp>
#include <cudf/column/column_factories.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/detail/utilities/integer_utils.hpp>
#include <cudf/transform.hpp>
#include <cudf/types.hpp>

#include <rmm/exec_policy.hpp>

#include <cuda/functional>
#include <thrust/fill.h>
#include <thrust/functional.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/reduce.h>
#include <thrust/tabulate.h>
#include <thrust/transform.h>

#include <numeric>

class TransformTest : public cudf::test::BaseFixture {};

template <class dtype, class Op, class Data>
void test_udf(char const udf[], Op op, Data data_init, cudf::size_type size, bool is_ptx)
{
  auto all_valid = cudf::detail::make_counting_transform_iterator(0, [](auto i) { return true; });
  auto data_iter = cudf::detail::make_counting_transform_iterator(0, data_init);

  cudf::test::fixed_width_column_wrapper<dtype, typename decltype(data_iter)::value_type> in(
    data_iter, data_iter + size, all_valid);

  std::unique_ptr<cudf::column> out = cudf::transform(
    in, udf, cudf::data_type(cudf::type_to_id<dtype>()), is_ptx, cudf::test::get_default_stream());

  ASSERT_UNARY<dtype, dtype>(out->view(), in, op);
}

TEST_F(TransformTest, Transform)
{
  char const* cuda =
    R"***(
__device__ inline void    fdsf   (
       float* C,
       float a
)
{
  *C = a*a*a*a;
}
)***";

  char const* ptx =
    R"***(
//
// Generated by NVIDIA NVVM Compiler
//
// Compiler Build ID: CL-24817639
// Cuda compilation tools, release 10.0, V10.0.130
// Based on LLVM 3.4svn
//

.version 6.3
.target sm_70
.address_size 64

	// .globl	_ZN8__main__7add$241Ef
.common .global .align 8 .u64 _ZN08NumbaEnv8__main__7add$241Ef;
.common .global .align 8 .u64 _ZN08NumbaEnv5numba7targets7numbers14int_power_impl12$3clocals$3e13int_power$242Efx;

.visible .func  (.param .b32 func_retval0) _ZN8__main__7add$241Ef(
	.param .b64 _ZN8__main__7add$241Ef_param_0,
	.param .b32 _ZN8__main__7add$241Ef_param_1
)
{
	.reg .f32 	%f<4>;
	.reg .b32 	%r<2>;
	.reg .b64 	%rd<2>;


	ld.param.u64 	%rd1, [_ZN8__main__7add$241Ef_param_0];
	ld.param.f32 	%f1, [_ZN8__main__7add$241Ef_param_1];
	mul.f32 	%f2, %f1, %f1;
	mul.f32 	%f3, %f2, %f2;
	st.f32 	[%rd1], %f3;
	mov.u32 	%r1, 0;
	st.param.b32	[func_retval0+0], %r1;
	ret;
}
)***";

  auto op        = [](float a) { return a * a * a * a; };
  auto data_init = [](cudf::size_type row) { return row % 3; };

  test_udf<float>(cuda, op, data_init, 500, false);
  test_udf<float>(ptx, op, data_init, 500, true);
}

TEST_F(TransformTest, ComputeColumn)
{
  auto c_0   = cudf::test::fixed_width_column_wrapper<cudf::size_type>{3, 20, 1, 50};
  auto c_1   = cudf::test::fixed_width_column_wrapper<cudf::size_type>{10, 7, 20, 0};
  auto table = cudf::table_view{{c_0, c_1}};

  auto col_ref_0  = cudf::ast::column_reference(0);
  auto col_ref_1  = cudf::ast::column_reference(1);
  auto expression = cudf::ast::operation(cudf::ast::ast_operator::ADD, col_ref_0, col_ref_1);

  auto expected = cudf::test::fixed_width_column_wrapper<cudf::size_type>{13, 27, 21, 50};
  auto result   = cudf::compute_column(table, expression, cudf::test::get_default_stream());

  CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, result->view());
}

TEST_F(TransformTest, BoolsToMask)
{
  std::vector<bool> input({1, 0, 1, 0, 1, 0, 1, 0});
  std::vector<bool> val({1, 1, 1, 1, 1, 1, 0, 1});

  cudf::test::fixed_width_column_wrapper<bool> input_column(input.begin(), input.end());

  auto sample = cudf::detail::make_counting_transform_iterator(0, [](auto i) { return i; });
  cudf::test::fixed_width_column_wrapper<cudf::size_type> expected(
    sample, sample + input.size(), input.begin());

  auto [null_mask, null_count] =
    cudf::bools_to_mask(input_column, cudf::test::get_default_stream());
  cudf::column got_column(expected);
  got_column.set_null_mask(std::move(*null_mask), null_count);

  CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, got_column.view());
}

TEST_F(TransformTest, MaskToBools)
{
  auto expected = cudf::test::fixed_width_column_wrapper<bool>({});
  auto out      = cudf::mask_to_bools(nullptr, 0, 0, cudf::test::get_default_stream());

  CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, out->view());
}

TEST_F(TransformTest, Encode)
{
  cudf::test::fixed_width_column_wrapper<cudf::size_type> input{{1, 2, 3, 2, 3, 2, 1}};
  cudf::test::fixed_width_column_wrapper<cudf::size_type> expect{{0, 1, 2, 1, 2, 1, 0}};
  cudf::test::fixed_width_column_wrapper<cudf::size_type> expect_keys{{1, 2, 3}};
  auto const result = cudf::encode(cudf::table_view({input}), cudf::test::get_default_stream());

  CUDF_TEST_EXPECT_COLUMNS_EQUAL(result.first->view().column(0), expect_keys);
  CUDF_TEST_EXPECT_COLUMNS_EQUAL(result.second->view(), expect);
}

TEST_F(TransformTest, OneHotEncode)
{
  auto input    = cudf::test::fixed_width_column_wrapper<cudf::size_type>{8, 8, 8, 9, 9};
  auto category = cudf::test::fixed_width_column_wrapper<cudf::size_type>{8, 9};

  auto col0 = cudf::test::fixed_width_column_wrapper<bool>{1, 1, 1, 0, 0};
  auto col1 = cudf::test::fixed_width_column_wrapper<bool>{0, 0, 0, 1, 1};

  auto expected = cudf::table_view{{col0, col1}};

  [[maybe_unused]] auto [res_ptr, got] =
    cudf::one_hot_encode(input, category, cudf::test::get_default_stream());

  CUDF_TEST_EXPECT_TABLES_EQUAL(expected, got);
}

TEST_F(TransformTest, NaNsToNulls)
{
  std::vector<cudf::size_type> input = {1, 2, 3, 4, 5};
  std::vector<bool> mask             = {true, true, true, true, false, false};

  auto input_column = cudf::test::fixed_width_column_wrapper<cudf::size_type>(
    input.begin(), input.end(), mask.begin());
  auto expected_column = [&]() {
    std::vector<cudf::size_type> expected(input);
    std::vector<bool> expected_mask;

    if (mask.size() > 0) {
      std::transform(
        input.begin(),
        input.end(),
        mask.begin(),
        std::back_inserter(expected_mask),
        [](cudf::size_type val, bool validity) { return validity and not std::isnan(val); });
    } else {
      std::transform(
        input.begin(), input.end(), std::back_inserter(expected_mask), [](cudf::size_type val) {
          return not std::isnan(val);
        });
    }

    return cudf::test::fixed_width_column_wrapper<cudf::size_type>(
             expected.begin(), expected.end(), expected_mask.begin())
      .release();
  }();

  auto [null_mask, null_count] =
    cudf::nans_to_nulls(input_column, cudf::test::get_default_stream());
  cudf::column got(input_column);
  got.set_null_mask(std::move(*null_mask), null_count);

  EXPECT_EQ(expected_column->null_count(), null_count);
  CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected_column->view(), got.view());
}

TEST_F(TransformTest, RowBitCount)
{
  std::vector<std::string> strings{"abc", "ï", "", "z", "bananas", "warp", "", "zing"};

  cudf::test::strings_column_wrapper col(strings.begin(), strings.end());

  cudf::table_view t({col});
  auto result = cudf::row_bit_count(t, cudf::test::get_default_stream());

  auto size_iter = cudf::detail::make_counting_transform_iterator(0, [&strings](int i) {
    return (static_cast<cudf::size_type>(strings[i].size()) + sizeof(cudf::size_type)) * CHAR_BIT;
  });
  cudf::test::fixed_width_column_wrapper<cudf::size_type> expected(size_iter,
                                                                   size_iter + strings.size());

  CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, *result);
}

TEST_F(TransformTest, SegmentedRowBitCount)
{
  // clang-format off
  std::vector<std::string> const strings { "daïs", "def", "", "z", "bananas", "warp", "", "zing" };
  std::vector<bool>        const valids  {  1,      0,    0,  1,   0,          1,      1,  1 };
  // clang-format on
  cudf::test::strings_column_wrapper const col(strings.begin(), strings.end(), valids.begin());
  auto const input = cudf::table_view({col});

  auto constexpr segment_length = 2;
  auto const [expected, actual] = [&]() {
    auto const row_sizes    = cudf::row_bit_count(input, cudf::test::get_default_stream());
    auto const num_segments = cudf::util::div_rounding_up_safe(row_sizes->size(), segment_length);
    auto expected =
      cudf::make_fixed_width_column(cudf::data_type{cudf::type_id::INT32}, num_segments);

    thrust::transform(
      rmm::exec_policy(cudf::test::get_default_stream()),
      thrust::make_counting_iterator(0),
      thrust::make_counting_iterator(num_segments),
      expected->mutable_view().begin<cudf::size_type>(),
      cuda::proclaim_return_type<cudf::size_type>(
        [segment_length,
         num_segments,
         num_rows = row_sizes->size(),
         d_sizes  = row_sizes->view().begin<cudf::size_type>()] __device__(auto const segment_idx) {
          // Since the number of rows may not divisible by segment_length,
          // the last segment may be shorter than the others.
          auto const size_begin = d_sizes + segment_idx * segment_length;
          auto const size_end   = std::min(size_begin + segment_length, d_sizes + num_rows);
          return thrust::reduce(thrust::seq, size_begin, size_end);
        }));

    auto actual =
      cudf::segmented_row_bit_count(input, segment_length, cudf::test::get_default_stream());
    return {std::move(expected), std::move(actual)};
  }();
  CUDF_TEST_EXPECT_COLUMNS_EQUAL(*expected, *actual);
}
