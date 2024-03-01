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
#include <cudf_test/cudf_gtest.hpp>
#include <cudf_test/io_metadata_utilities.hpp>
#include <cudf_test/iterator_utilities.hpp>
#include <cudf_test/table_utilities.hpp>
#include <cudf_test/type_lists.hpp>

#include <cudf/column/column.hpp>
#include <cudf/column/column_factories.hpp>
#include <cudf/concatenate.hpp>
#include <cudf/copying.hpp>
#include <cudf/detail/iterator.cuh>
#include <cudf/detail/structs/utilities.hpp>
#include <cudf/fixed_point/fixed_point.hpp>
#include <cudf/io/data_sink.hpp>
#include <cudf/io/datasource.hpp>
#include <cudf/io/orc.hpp>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/table/table.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/utilities/span.hpp>

#include <rmm/cuda_stream_view.hpp>

#include <thrust/iterator/counting_iterator.h>

#include <fstream>
#include <type_traits>

namespace {
// Global environment for temporary files
auto const temp_env = reinterpret_cast<cudf::test::TempDirTestEnvironment*>(
  ::testing::AddGlobalTestEnvironment(new cudf::test::TempDirTestEnvironment));

using int32s_col       = cudf::test::fixed_width_column_wrapper<int32_t>;
using int64s_col       = cudf::test::fixed_width_column_wrapper<int64_t>;
using strings_col      = cudf::test::strings_column_wrapper;
using structs_col      = cudf::test::structs_column_wrapper;
using int32s_lists_col = cudf::test::lists_column_wrapper<int32_t>;

auto write_file(std::vector<std::unique_ptr<cudf::column>>& input_columns,
                std::string const& filename,
                bool nullable,
                std::size_t stripe_size_bytes    = cudf::io::default_stripe_size_bytes,
                cudf::size_type stripe_size_rows = cudf::io::default_stripe_size_rows)
{
  if (nullable) {
    // Generate deterministic bitmask instead of random bitmask for easy computation of data size.
    auto const valid_iter = cudf::detail::make_counting_transform_iterator(
      0, [](cudf::size_type i) { return i % 4 != 3; });
    cudf::size_type offset{0};
    for (auto& col : input_columns) {
      auto const [null_mask, null_count] =
        cudf::test::detail::make_null_mask(valid_iter + offset, valid_iter + col->size() + offset);
      col = cudf::structs::detail::superimpose_nulls(
        static_cast<cudf::bitmask_type const*>(null_mask.data()),
        null_count,
        std::move(col),
        cudf::get_default_stream(),
        rmm::mr::get_current_device_resource());

      // Shift nulls of the next column by one position, to avoid having all nulls
      // in the same table rows.
      ++offset;
    }
  }

  auto input_table = std::make_unique<cudf::table>(std::move(input_columns));
  auto filepath =
    temp_env->get_temp_filepath(nullable ? filename + "_nullable.orc" : filename + ".orc");

  auto const write_opts =
    cudf::io::orc_writer_options::builder(cudf::io::sink_info{filepath}, *input_table)
      .stripe_size_bytes(stripe_size_bytes)
      .stripe_size_rows(stripe_size_rows)
      .build();
  cudf::io::write_orc(write_opts);

  return std::pair{std::move(input_table), std::move(filepath)};
}

// NOTE: By default, output_row_granularity=10'000 rows.
// This means if the input file has more than 10k rows then the output chunk will never
// have less than 10k rows.
auto chunked_read(std::string const& filepath,
                  std::size_t output_limit,
                  std::size_t input_limit                = 0,
                  cudf::size_type output_row_granularity = 10'000)
{
  auto const read_opts =
    cudf::io::orc_reader_options::builder(cudf::io::source_info{filepath}).build();
  auto reader =
    cudf::io::chunked_orc_reader(output_limit, input_limit, output_row_granularity, read_opts);

  auto num_chunks = 0;
  auto out_tables = std::vector<std::unique_ptr<cudf::table>>{};

  do {
    auto chunk = reader.read_chunk();
    // If the input file is empty, the first call to `read_chunk` will return an empty table.
    // Thus, we only check for non-empty output table from the second call.
    if (num_chunks > 0) {
      CUDF_EXPECTS(chunk.tbl->num_rows() != 0, "Number of rows in the new chunk is zero.");
    }
    ++num_chunks;
    out_tables.emplace_back(std::move(chunk.tbl));
  } while (reader.has_next());

  auto out_tviews = std::vector<cudf::table_view>{};
  for (auto const& tbl : out_tables) {
    out_tviews.emplace_back(tbl->view());
  }

  return std::pair(cudf::concatenate(out_tviews), num_chunks);
}

auto chunked_read(std::string const& filepath,
                  std::size_t output_limit,
                  cudf::size_type output_row_granularity)
{
  return chunked_read(filepath, output_limit, 0UL, output_row_granularity);
}

}  // namespace

struct OrcChunkedReaderTest : public cudf::test::BaseFixture {};

TEST_F(OrcChunkedReaderTest, TestChunkedReadNoData)
{
  std::vector<std::unique_ptr<cudf::column>> input_columns;
  input_columns.emplace_back(int32s_col{}.release());
  input_columns.emplace_back(int64s_col{}.release());

  auto const [expected, filepath] = write_file(input_columns, "chunked_read_empty", false);
  auto const [result, num_chunks] = chunked_read(filepath, 1'000);
  EXPECT_EQ(num_chunks, 1);
  EXPECT_EQ(result->num_rows(), 0);
  EXPECT_EQ(result->num_columns(), 2);
  CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
}

TEST_F(OrcChunkedReaderTest, TestChunkedReadSimpleData)
{
  auto constexpr num_rows = 40'000;

  auto const generate_input = [num_rows](bool nullable, std::size_t stripe_rows) {
    std::vector<std::unique_ptr<cudf::column>> input_columns;
    auto const value_iter = thrust::make_counting_iterator(0);
    input_columns.emplace_back(int32s_col(value_iter, value_iter + num_rows).release());
    input_columns.emplace_back(int64s_col(value_iter, value_iter + num_rows).release());

    return write_file(input_columns,
                      "chunked_read_simple",
                      nullable,
                      cudf::io::default_stripe_size_bytes,
                      stripe_rows);
  };

  {
    auto const [expected, filepath] = generate_input(false, 1'000);
    auto const [result, num_chunks] = chunked_read(filepath, 245'000);
    EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }
  {
    auto const [expected, filepath] = generate_input(false, cudf::io::default_stripe_size_rows);
    auto const [result, num_chunks] = chunked_read(filepath, 245'000);
    EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  {
    auto const [expected, filepath] = generate_input(true, 1'000);
    auto const [result, num_chunks] = chunked_read(filepath, 245'000);
    EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }
  {
    auto const [expected, filepath] = generate_input(true, cudf::io::default_stripe_size_rows);
    auto const [result, num_chunks] = chunked_read(filepath, 245'000);
    EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }
}

TEST_F(OrcChunkedReaderTest, TestChunkedReadBoundaryCases)
{
  // Tests some specific boundary conditions in the split calculations.

  auto constexpr num_rows = 40'000;

  auto const [expected, filepath] = [num_rows]() {
    std::vector<std::unique_ptr<cudf::column>> input_columns;
    auto const value_iter = thrust::make_counting_iterator(0);
    input_columns.emplace_back(int32s_col(value_iter, value_iter + num_rows).release());
    return write_file(input_columns, "chunked_read_simple_boundary", false /*nullable*/);
  }();

  // Test with zero limit: everything will be read in one chunk.
  {
    auto const [result, num_chunks] = chunked_read(filepath, 0UL);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a very small limit: 1 byte.
  {
    auto const [result, num_chunks] = chunked_read(filepath, 1UL);
    // Number of chunks is 4 because of using default `output_row_granularity = 10k`.
    EXPECT_EQ(num_chunks, 4);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a very small limit: 1 byte, and small value of `output_row_granularity`.
  {
    auto const [result, num_chunks] = chunked_read(filepath, 1UL, 1'000);
    EXPECT_EQ(num_chunks, 40);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a very small limit: 1 byte, and large value of `output_row_granularity`.
  {
    auto const [result, num_chunks] = chunked_read(filepath, 1UL, 30'000);
    EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }
  // Test with a very large limit
  {
    auto const [result, num_chunks] = chunked_read(filepath, 2L << 40);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }
  // Test with a limit slightly less than one granularity segment of data
  // (output_row_granularity = 10k rows = 40'000 bytes).
  {
    auto const [result, num_chunks] = chunked_read(filepath, 39'000UL);
    EXPECT_EQ(num_chunks, 4);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a limit exactly the size one granularity segment of data
  // (output_row_granularity = 10k rows = 40'000 bytes).
  {
    auto const [result, num_chunks] = chunked_read(filepath, 40'000UL);
    EXPECT_EQ(num_chunks, 4);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a limit slightly more than one granularity segment of data
  // (output_row_granularity = 10k rows = 40'000 bytes).
  {
    auto const [result, num_chunks] = chunked_read(filepath, 41'000UL);
    EXPECT_EQ(num_chunks, 4);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a limit slightly less than two granularity segments of data
  {
    auto const [result, num_chunks] = chunked_read(filepath, 79'000UL);
    EXPECT_EQ(num_chunks, 4);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a limit exactly the size of two granularity segments of data minus 1 byte.
  {
    auto const [result, num_chunks] = chunked_read(filepath, 79'999UL);
    EXPECT_EQ(num_chunks, 4);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a limit exactly the size of two granularity segments of data.
  {
    auto const [result, num_chunks] = chunked_read(filepath, 80'000UL);
    EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a limit slightly more the size two granularity segments of data.
  {
    auto const [result, num_chunks] = chunked_read(filepath, 81'000);
    EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a limit exactly the size of the input minus 1 byte.
  {
    auto const [result, num_chunks] = chunked_read(filepath, 159'999UL);
    EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a limit exactly the size of the input.
  {
    auto const [result, num_chunks] = chunked_read(filepath, 160'000UL);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }
}

TEST_F(OrcChunkedReaderTest, TestChunkedReadWithString)
{
  auto constexpr num_rows               = 60'000;
  auto constexpr output_row_granularity = 20'000;

  auto const generate_input = [num_rows](bool nullable) {
    std::vector<std::unique_ptr<cudf::column>> input_columns;
    auto const value_iter = thrust::make_counting_iterator(0);

    // ints                               Granularity Segment  total bytes   cumulative bytes
    // 20000 rows of 4 bytes each               = A0           80000         80000
    // 20000 rows of 4 bytes each               = A1           80000         160000
    // 20000 rows of 4 bytes each               = A2           80000         240000
    input_columns.emplace_back(int32s_col(value_iter, value_iter + num_rows).release());

    // strings                            Granularity Segment  total bytes   cumulative bytes
    // 20000 rows of 1 char each    (20000  + 80004) = B0      100004        100004
    // 20000 rows of 4 chars each   (80000  + 80004) = B1      160004        260008
    // 20000 rows of 16 chars each  (320000 + 80004) = B2      400004        660012
    auto const strings  = std::vector<std::string>{"a", "bbbb", "cccccccccccccccc"};
    auto const str_iter = cudf::detail::make_counting_transform_iterator(0, [&](int32_t i) {
      if (i < 20000) { return strings[0]; }
      if (i < 40000) { return strings[1]; }
      return strings[2];
    });
    input_columns.emplace_back(strings_col(str_iter, str_iter + num_rows).release());

    // Cumulative sizes:
    // A0 + B0 :  180004
    // A1 + B1 :  420008
    // A2 + B2 :  900012
    //                                    skip_rows / num_rows
    // byte_limit==500000  should give 2 chunks: {0, 40000}, {40000, 20000}
    // byte_limit==1000000 should give 1 chunks: {0, 60000},
    return write_file(input_columns, "chunked_read_with_strings", nullable);
  };

  auto const [expected_no_null, filepath_no_null]       = generate_input(false);
  auto const [expected_with_nulls, filepath_with_nulls] = generate_input(true);

  // Test with zero limit: everything will be read in one chunk.
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 0UL);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 0UL);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  // Test with a very small limit: 1 byte.
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 1UL, output_row_granularity);
    EXPECT_EQ(num_chunks, 3);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] =
      chunked_read(filepath_with_nulls, 1UL, output_row_granularity);
    EXPECT_EQ(num_chunks, 3);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  // Test with a very large limit.
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 2L << 40);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 2L << 40);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  // Other tests:

  {
    auto const [result, num_chunks] =
      chunked_read(filepath_no_null, 500'000UL, output_row_granularity);
    EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] =
      chunked_read(filepath_with_nulls, 500'000UL, output_row_granularity);
    EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 1'000'000UL);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 1'000'000UL);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }
}

TEST_F(OrcChunkedReaderTest, TestChunkedReadWithStructs)
{
  auto constexpr num_rows               = 100'000;
  auto constexpr output_row_granularity = 20'000;

  auto const generate_input = [num_rows](bool nullable) {
    std::vector<std::unique_ptr<cudf::column>> input_columns;
    auto const int_iter = thrust::make_counting_iterator(0);
    input_columns.emplace_back(int32s_col(int_iter, int_iter + num_rows).release());
    input_columns.emplace_back([=] {
      auto child1 = int32s_col(int_iter, int_iter + num_rows);
      auto child2 = int32s_col(int_iter + num_rows, int_iter + num_rows * 2);

      auto const str_iter = cudf::detail::make_counting_transform_iterator(
        0, [&](int32_t i) { return std::to_string(i); });
      auto child3 = strings_col{str_iter, str_iter + num_rows};

      return structs_col{{child1, child2, child3}}.release();
    }());

    return write_file(input_columns, "chunked_read_with_structs", nullable);
  };

  auto const [expected_no_null, filepath_no_null]       = generate_input(false);
  auto const [expected_with_nulls, filepath_with_nulls] = generate_input(true);

  // Test with zero limit: everything will be read in one chunk.
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 0UL);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 0UL);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  // Test with a very small limit: 1 byte.
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 1UL, output_row_granularity);
    EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] =
      chunked_read(filepath_with_nulls, 1UL, output_row_granularity);
    EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  // Test with a very large limit.
  {
    auto const [result, num_chunks] =
      chunked_read(filepath_no_null, 2L << 40, output_row_granularity);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] =
      chunked_read(filepath_with_nulls, 2L << 40, output_row_granularity);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  // Other tests:

  {
    auto const [result, num_chunks] =
      chunked_read(filepath_no_null, 500'000UL, output_row_granularity);
    EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] =
      chunked_read(filepath_with_nulls, 500'000UL, output_row_granularity);
    EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }
}

TEST_F(OrcChunkedReaderTest, TestChunkedReadWithListsNoNulls)
{
  auto constexpr num_rows               = 100'000;
  auto constexpr output_row_granularity = 20'000;

  auto const [expected, filepath] = [num_rows]() {
    std::vector<std::unique_ptr<cudf::column>> input_columns;
    // 20000 rows in 1 segment consist of:
    //
    // 20001 offsets :   80004  bytes
    // 30000 ints    :   120000 bytes
    // total         :   200004 bytes
    //
    // However, `segmented_row_bit_count` used in chunked reader returns 200000,
    // thus we consider as having only 200000 bytes in total.
    auto const template_lists = int32s_lists_col{
      int32s_lists_col{}, int32s_lists_col{0}, int32s_lists_col{1, 2}, int32s_lists_col{3, 4, 5}};

    auto const gather_iter =
      cudf::detail::make_counting_transform_iterator(0, [&](int32_t i) { return i % 4; });
    auto const gather_map = int32s_col(gather_iter, gather_iter + num_rows);
    input_columns.emplace_back(
      std::move(cudf::gather(cudf::table_view{{template_lists}}, gather_map)->release().front()));

    return write_file(input_columns, "chunked_read_with_lists_no_null", false /*nullable*/);
  }();

  // Test with zero limit: everything will be read in one chunk.
  {
    auto const [result, num_chunks] = chunked_read(filepath, 0UL);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a very small limit: 1 byte.
  {
    auto const [result, num_chunks] = chunked_read(filepath, 1UL, output_row_granularity);
    EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a very large limit.
  {
    auto const [result, num_chunks] = chunked_read(filepath, 2L << 40UL, output_row_granularity);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Chunk size slightly less than 1 row segment (forcing it to be at least 1 segment per read).
  {
    auto const [result, num_chunks] = chunked_read(filepath, 199'999UL, output_row_granularity);
    EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Chunk size exactly 1 row segment.
  {
    auto const [result, num_chunks] = chunked_read(filepath, 200'000UL, output_row_granularity);
    EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Chunk size == size of 2 segments. Totally have 3 chunks.
  {
    auto const [result, num_chunks] = chunked_read(filepath, 400'000UL, output_row_granularity);
    EXPECT_EQ(num_chunks, 3);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Chunk size == size of 2 segment minus one byte: each chunk will be just one segment.
  {
    auto const [result, num_chunks] = chunked_read(filepath, 399'999UL, output_row_granularity);
    EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }
}

TEST_F(OrcChunkedReaderTest, TestChunkedReadWithListsHavingNulls)
{
  auto constexpr num_rows               = 100'000;
  auto constexpr output_row_granularity = 20'000;

  auto const [expected, filepath] = [num_rows]() {
    std::vector<std::unique_ptr<cudf::column>> input_columns;
    // 20000 rows in 1 page consist of:
    //
    // 625 validity words :   2500 bytes   (a null every 4 rows: null at indices [3, 7, 11, ...])
    // 20001 offsets      :   80004  bytes
    // 15000 ints         :   60000 bytes
    // total              :   142504 bytes
    //
    // However, `segmented_row_bit_count` used in chunked reader returns 142500,
    // thus we consider as having only 142500 bytes in total.
    auto const template_lists =
      int32s_lists_col{// these will all be null
                       int32s_lists_col{},
                       int32s_lists_col{0},
                       int32s_lists_col{1, 2},
                       int32s_lists_col{3, 4, 5, 6, 7, 8, 9} /* this list will be nullified out */};
    auto const gather_iter =
      cudf::detail::make_counting_transform_iterator(0, [&](int32_t i) { return i % 4; });
    auto const gather_map = int32s_col(gather_iter, gather_iter + num_rows);
    input_columns.emplace_back(
      std::move(cudf::gather(cudf::table_view{{template_lists}}, gather_map)->release().front()));

    return write_file(input_columns, "chunked_read_with_lists_nulls", true /*nullable*/);
  }();

  // Test with zero limit: everything will be read in one chunk.
  {
    auto const [result, num_chunks] = chunked_read(filepath, 0UL);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a very small limit: 1 byte.
  {
    auto const [result, num_chunks] = chunked_read(filepath, 1UL, output_row_granularity);
    EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a very large limit.
  {
    auto const [result, num_chunks] = chunked_read(filepath, 2L << 40, output_row_granularity);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Chunk size slightly less than 1 row segment (forcing it to be at least 1 segment per read).
  {
    auto const [result, num_chunks] = chunked_read(filepath, 142'499UL, output_row_granularity);
    EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Chunk size exactly 1 row segment.
  {
    auto const [result, num_chunks] = chunked_read(filepath, 142'500UL, output_row_granularity);
    EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Chunk size == size of 2 segments. Totally have 3 chunks.
  {
    auto const [result, num_chunks] = chunked_read(filepath, 285'000UL, output_row_granularity);
    EXPECT_EQ(num_chunks, 3);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Chunk size == size of 2 segment minus one byte: each chunk will be just one segment.
  {
    auto const [result, num_chunks] = chunked_read(filepath, 284'999UL, output_row_granularity);
    EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }
}

TEST_F(OrcChunkedReaderTest, TestChunkedReadWithStructsOfLists)
{
  auto constexpr num_rows = 100'000;

  // Size of each segment (10k row by default) is from 537k to 560k bytes (no nulls)
  // and from 456k to 473k (with nulls).
  auto const generate_input = [num_rows](bool nullable) {
    std::vector<std::unique_ptr<cudf::column>> input_columns;
    auto const int_iter = thrust::make_counting_iterator(0);
    input_columns.emplace_back(int32s_col(int_iter, int_iter + num_rows).release());
    input_columns.emplace_back([=] {
      std::vector<std::unique_ptr<cudf::column>> child_columns;
      child_columns.emplace_back(int32s_col(int_iter, int_iter + num_rows).release());
      child_columns.emplace_back(
        int32s_col(int_iter + num_rows, int_iter + num_rows * 2).release());

      auto const str_iter = cudf::detail::make_counting_transform_iterator(0, [&](int32_t i) {
        return std::to_string(i) + "++++++++++++++++++++" + std::to_string(i);
      });
      child_columns.emplace_back(strings_col{str_iter, str_iter + num_rows}.release());

      auto const template_lists = int32s_lists_col{
        int32s_lists_col{}, int32s_lists_col{0}, int32s_lists_col{0, 1}, int32s_lists_col{0, 1, 2}};
      auto const gather_iter =
        cudf::detail::make_counting_transform_iterator(0, [&](int32_t i) { return i % 4; });
      auto const gather_map = int32s_col(gather_iter, gather_iter + num_rows);
      child_columns.emplace_back(
        std::move(cudf::gather(cudf::table_view{{template_lists}}, gather_map)->release().front()));

      return structs_col(std::move(child_columns)).release();
    }());

    return write_file(input_columns, "chunked_read_with_structs_of_lists", nullable);
  };

  auto const [expected_no_null, filepath_no_null]       = generate_input(false);
  auto const [expected_with_nulls, filepath_with_nulls] = generate_input(true);

  // Test with zero limit: everything will be read in one chunk.
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 0UL);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 0UL);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  // Test with a very small limit: 1 byte.
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 1UL);
    EXPECT_EQ(num_chunks, 10);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 1UL);
    EXPECT_EQ(num_chunks, 10);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  // Test with a very large limit.
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 2L << 40);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 2L << 40);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  // Other tests:

  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 1'000'000UL);
    EXPECT_EQ(num_chunks, 10);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 1'500'000UL);
    EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 2'000'000UL);
    EXPECT_EQ(num_chunks, 4);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 5'000'000UL);
    EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 1'000'000UL);
    EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 1'500'000UL);
    EXPECT_EQ(num_chunks, 4);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 2'000'000UL);
    EXPECT_EQ(num_chunks, 3);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 5'000'000UL);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }
}

TEST_F(OrcChunkedReaderTest, TestChunkedReadWithListsOfStructs)
{
  auto constexpr num_rows = 100'000;

  // Size of each segment (10k row by default) is from 450k to 530k bytes (no nulls)
  // and from 330k to 380k (with nulls).
  auto const generate_input = [num_rows](bool nullable) {
    std::vector<std::unique_ptr<cudf::column>> input_columns;
    auto const int_iter = thrust::make_counting_iterator(0);
    input_columns.emplace_back(int32s_col(int_iter, int_iter + num_rows).release());

    auto offsets = std::vector<cudf::size_type>{};
    offsets.reserve(num_rows * 2);
    cudf::size_type num_structs = 0;
    for (int i = 0; i < num_rows; ++i) {
      offsets.push_back(num_structs);
      auto const new_list_size = i % 4;
      num_structs += new_list_size;
    }
    offsets.push_back(num_structs);

    auto const make_structs_col = [=] {
      auto child1 = int32s_col(int_iter, int_iter + num_structs);
      auto child2 = int32s_col(int_iter + num_structs, int_iter + num_structs * 2);

      auto const str_iter = cudf::detail::make_counting_transform_iterator(
        0, [&](int32_t i) { return std::to_string(i) + std::to_string(i) + std::to_string(i); });
      auto child3 = strings_col{str_iter, str_iter + num_structs};

      return structs_col{{child1, child2, child3}}.release();
    };

    input_columns.emplace_back(
      cudf::make_lists_column(static_cast<cudf::size_type>(offsets.size() - 1),
                              int32s_col(offsets.begin(), offsets.end()).release(),
                              make_structs_col(),
                              0,
                              rmm::device_buffer{}));

    return write_file(input_columns, "chunked_read_with_lists_of_structs", nullable);
  };

  auto const [expected_no_null, filepath_no_null]       = generate_input(false);
  auto const [expected_with_nulls, filepath_with_nulls] = generate_input(true);

  // Test with zero limit: everything will be read in one chunk.
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 0UL);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 0UL);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  // Test with a very small limit: 1 byte.
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 1UL);
    EXPECT_EQ(num_chunks, 10);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 1UL);
    EXPECT_EQ(num_chunks, 10);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  // Test with a very large limit.
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 2L << 40);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 2L << 40);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  // Other tests.

  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 1'000'000UL);
    EXPECT_EQ(num_chunks, 7);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 1'500'000UL);
    EXPECT_EQ(num_chunks, 4);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 2'000'000UL);
    EXPECT_EQ(num_chunks, 3);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 5'000'000UL);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 1'000'000UL);
    EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 1'500'000UL);
    EXPECT_EQ(num_chunks, 3);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 2'000'000UL);
    EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 5'000'000UL);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }
}

TEST_F(OrcChunkedReaderTest, TestChunkedReadNullCount)
{
  auto constexpr num_rows = 100'000;

  auto const sequence = cudf::detail::make_counting_transform_iterator(0, [](auto i) { return 1; });
  auto const validity =
    cudf::detail::make_counting_transform_iterator(0, [](auto i) { return i % 4 != 3; });
  cudf::test::fixed_width_column_wrapper<int32_t> col{sequence, sequence + num_rows, validity};
  std::vector<std::unique_ptr<cudf::column>> cols;
  cols.push_back(col.release());
  auto const expected = std::make_unique<cudf::table>(std::move(cols));

  auto const filepath          = temp_env->get_temp_filepath("chunked_reader_null_count.orc");
  auto const stripe_limit_rows = num_rows / 5;
  auto const write_opts =
    cudf::io::orc_writer_options::builder(cudf::io::sink_info{filepath}, *expected)
      .stripe_size_rows(stripe_limit_rows)
      .build();
  cudf::io::write_orc(write_opts);

  auto const byte_limit = stripe_limit_rows * sizeof(int);
  auto const read_opts =
    cudf::io::orc_reader_options::builder(cudf::io::source_info{filepath}).build();
  auto reader =
    cudf::io::chunked_orc_reader(byte_limit, 0UL /*read_limit*/, stripe_limit_rows, read_opts);

  do {
    // Every fourth row is null.
    EXPECT_EQ(reader.read_chunk().tbl->get_column(0).null_count(), stripe_limit_rows / 4UL);
  } while (reader.has_next());
}

namespace {

std::size_t constexpr input_limit_expected_file_count = 3;

std::vector<std::string> input_limit_get_test_names(std::string const& base_filename)
{
  return {base_filename + "_a.orc", base_filename + "_b.orc", base_filename + "_c.orc"};
}

void input_limit_test_write_one(std::string const& filepath,
                                cudf::table_view const& input,
                                cudf::io::compression_type compression)
{
  auto const out_opts = cudf::io::orc_writer_options::builder(cudf::io::sink_info{filepath}, input)
                          .compression(compression)
                          .stripe_size_rows(10'000)  // intentionally write small stripes
                          .build();
  cudf::io::write_orc(out_opts);
}

void input_limit_test_write(std::vector<std::string> const& test_files,
                            cudf::table_view const& input)
{
  CUDF_EXPECTS(test_files.size() == input_limit_expected_file_count,
               "Unexpected count of test filenames.");

  // No compression
  input_limit_test_write_one(test_files[0], input, cudf::io::compression_type::NONE);

  // Compression with a codec that uses a lot of scratch space at decode time (2.5x the total
  // decompressed buffer size).
  input_limit_test_write_one(test_files[1], input, cudf::io::compression_type::ZSTD);

  // Compression with a codec that uses no scratch space at decode time.
  input_limit_test_write_one(test_files[2], input, cudf::io::compression_type::SNAPPY);
}

void input_limit_test_read(int test_location,
                           std::vector<std::string> const& test_files,
                           cudf::table_view const& input,
                           size_t output_limit,
                           size_t input_limit,
                           int const* expected_chunk_counts)
{
  CUDF_EXPECTS(test_files.size() == input_limit_expected_file_count,
               "Unexpected count of test filenames.");

  for (size_t idx = 0; idx < test_files.size(); idx++) {
    SCOPED_TRACE("Original line of failure: " + std::to_string(test_location) +
                 ", file idx: " + std::to_string(idx));
    auto const [result, num_chunks] = chunked_read(test_files[idx], output_limit, input_limit);
    EXPECT_EQ(expected_chunk_counts[idx], num_chunks);
    // TODO: equal
    CUDF_TEST_EXPECT_TABLES_EQUIVALENT(*result, input);
  }
}

}  // namespace

struct OrcChunkedReaderInputLimitTest : public cudf::test::BaseFixture {};

TEST_F(OrcChunkedReaderInputLimitTest, SingleFixedWidthColumn)
{
  auto constexpr num_rows = 1'000'000;
  auto const iter1        = thrust::make_constant_iterator(15);
  auto const col1         = cudf::test::fixed_width_column_wrapper<double>(iter1, iter1 + num_rows);
  auto const input        = cudf::table_view{{col1}};

  auto const filename   = std::string{"single_col_fixed_width"};
  auto const test_files = input_limit_get_test_names(temp_env->get_temp_filepath(filename));
  input_limit_test_write(test_files, input);

  // Some small limit.
  {
    int constexpr expected[] = {100, 100, 100};
    input_limit_test_read(__LINE__, test_files, input, 0UL, 1UL, expected);
  }

  if (0) {
    int constexpr expected[] = {15, 20, 9};
    input_limit_test_read(__LINE__, test_files, input, 0UL, 2 * 1024 * 1024UL, expected);
  }

  // Limit of 1 byte.
  if (0) {
    int constexpr expected[] = {1, 50, 50};
    input_limit_test_read(__LINE__, test_files, input, 0UL, 1UL, expected);
  }
}
