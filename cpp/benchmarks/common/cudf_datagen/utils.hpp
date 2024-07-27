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
#include <cudf_test/column_wrapper.hpp>

#include <cudf/binaryop.hpp>
#include <cudf/column/column.hpp>
#include <cudf/column/column_factories.hpp>
#include <cudf/concatenate.hpp>
#include <cudf/copying.hpp>
#include <cudf/datetime.hpp>
#include <cudf/detail/aggregation/aggregation.hpp>
#include <cudf/dictionary/dictionary_factories.hpp>
#include <cudf/filling.hpp>
#include <cudf/groupby.hpp>
#include <cudf/io/parquet.hpp>
#include <cudf/join.hpp>
#include <cudf/lists/combine.hpp>
#include <cudf/lists/filling.hpp>
#include <cudf/reduction.hpp>
#include <cudf/scalar/scalar.hpp>
#include <cudf/sorting.hpp>
#include <cudf/strings/combine.hpp>
#include <cudf/strings/convert/convert_datetime.hpp>
#include <cudf/strings/convert/convert_durations.hpp>
#include <cudf/strings/convert/convert_integers.hpp>
#include <cudf/strings/padding.hpp>
#include <cudf/strings/replace.hpp>
#include <cudf/table/table.hpp>
#include <cudf/transform.hpp>
#include <cudf/unary.hpp>

#include <rmm/cuda_device.hpp>
#include <rmm/exec_policy.hpp>
#include <rmm/mr/device/cuda_memory_resource.hpp>
#include <rmm/mr/device/device_memory_resource.hpp>
#include <rmm/mr/device/managed_memory_resource.hpp>
#include <rmm/mr/device/pool_memory_resource.hpp>

#include <cuda/functional>
#include <thrust/copy.h>
#include <thrust/device_vector.h>
#include <thrust/distance.h>
#include <thrust/equal.h>
#include <thrust/execution_policy.h>
#include <thrust/generate.h>
#include <thrust/host_vector.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/iterator/transform_iterator.h>
#include <thrust/logical.h>
#include <thrust/random.h>
#include <thrust/reduce.h>
#include <thrust/remove.h>
#include <thrust/scan.h>
#include <thrust/scatter.h>
#include <thrust/sequence.h>
#include <thrust/transform.h>

#include <ctime>
#include <memory>
#include <string>
#include <typeinfo>
#include <utility>
#include <vector>

void write_parquet(cudf::table_view tbl,
                   std::string const& path,
                   std::vector<std::string> const& col_names)
{
  std::cout << "Writing to " << path << "\n";
  auto const sink_info = cudf::io::sink_info(path);
  cudf::io::table_metadata metadata;
  std::vector<cudf::io::column_name_info> col_name_infos;
  for (auto& col_name : col_names) {
    col_name_infos.push_back(cudf::io::column_name_info(col_name));
  }
  metadata.schema_info            = col_name_infos;
  auto const table_input_metadata = cudf::io::table_input_metadata{metadata};
  auto builder                    = cudf::io::parquet_writer_options::builder(sink_info, tbl);
  builder.metadata(table_input_metadata);
  auto const options = builder.build();
  cudf::io::write_parquet(options);
}

std::unique_ptr<cudf::table> perform_left_join(cudf::table_view const& left_input,
                                               cudf::table_view const& right_input,
                                               std::vector<cudf::size_type> const& left_on,
                                               std::vector<cudf::size_type> const& right_on,
                                               cudf::null_equality compare_nulls)
{
  constexpr auto oob_policy                          = cudf::out_of_bounds_policy::NULLIFY;
  auto const left_selected                           = left_input.select(left_on);
  auto const right_selected                          = right_input.select(right_on);
  auto const [left_join_indices, right_join_indices] = cudf::left_join(
    left_selected, right_selected, compare_nulls, rmm::mr::get_current_device_resource());

  auto const left_indices_span  = cudf::device_span<cudf::size_type const>{*left_join_indices};
  auto const right_indices_span = cudf::device_span<cudf::size_type const>{*right_join_indices};

  auto const left_indices_col  = cudf::column_view{left_indices_span};
  auto const right_indices_col = cudf::column_view{right_indices_span};

  auto const left_result  = cudf::gather(left_input, left_indices_col, oob_policy);
  auto const right_result = cudf::gather(right_input, right_indices_col, oob_policy);

  auto joined_cols = left_result->release();
  auto right_cols  = right_result->release();
  joined_cols.insert(joined_cols.end(),
                     std::make_move_iterator(right_cols.begin()),
                     std::make_move_iterator(right_cols.end()));
  return std::make_unique<cudf::table>(std::move(joined_cols));
}

struct groupby_context_t {
  std::vector<int64_t> keys;
  std::unordered_map<std::string, std::vector<std::pair<cudf::aggregation::Kind, std::string>>>
    values;
};

/**
 * @brief Generate the `std::tm` structure from year, month, and day
 *
 * @param year The year
 * @param month The month
 * @param day The day
 */
std::tm make_tm(int year, int month, int day)
{
  std::tm tm{};
  tm.tm_year = year - 1900;
  tm.tm_mon  = month - 1;
  tm.tm_mday = day;
  return tm;
}

/**
 * @brief Calculate the number of days since the UNIX epoch
 *
 * @param year The year
 * @param month The month
 * @param day The day
 */
int32_t days_since_epoch(int year, int month, int day)
{
  std::tm tm             = make_tm(year, month, day);
  std::tm epoch          = make_tm(1970, 1, 1);
  std::time_t time       = std::mktime(&tm);
  std::time_t epoch_time = std::mktime(&epoch);
  double diff            = std::difftime(time, epoch_time) / (60 * 60 * 24);
  return static_cast<int32_t>(diff);
}

// Functor for generating random strings
struct gen_rand_str {
  char* chars;
  thrust::default_random_engine engine;
  thrust::uniform_int_distribution<unsigned char> char_dist;

  __host__ __device__ gen_rand_str(char* c) : chars(c), char_dist(32, 137) {}

  __host__ __device__ void operator()(thrust::tuple<cudf::size_type, cudf::size_type> str_begin_end)
  {
    auto begin = thrust::get<0>(str_begin_end);
    auto end   = thrust::get<1>(str_begin_end);
    engine.discard(begin);
    for (auto i = begin; i < end; ++i) {
      auto ch = char_dist(engine);
      if (i == end - 1 && ch >= '\x7F') ch = ' ';  // last element ASCII only.
      if (ch >= '\x7F')                            // x7F is at the top edge of ASCII
        chars[i++] = '\xC4';                       // these characters are assigned two bytes
      chars[i] = static_cast<char>(ch + (ch >= '\x7F'));
    }
  }
};

// Functor for generating random numbers
template <typename T>
struct gen_rand_num {
  T lower;
  T upper;

  __host__ __device__ gen_rand_num(T lower, T upper) : lower(lower), upper(upper) {}

  __host__ __device__ T operator()(const int64_t idx) const
  {
    if (cudf::is_integral<T>()) {
      thrust::default_random_engine engine;
      thrust::uniform_int_distribution<T> dist(lower, upper);
      engine.discard(idx);
      return dist(engine);
    } else {
      thrust::default_random_engine engine;
      thrust::uniform_real_distribution<T> dist(lower, upper);
      engine.discard(idx);
      return dist(engine);
    }
  }
};

/**
 * @brief Generate a column of random strings
 *
 * @param lower The lower bound of the length of the strings
 * @param upper The upper bound of the length of the strings
 * @param num_rows The number of rows in the column
 */
std::unique_ptr<cudf::column> gen_rand_str_col(int64_t lower,
                                               int64_t upper,
                                               cudf::size_type num_rows)
{
  rmm::device_uvector<cudf::size_type> offsets(num_rows + 1, cudf::get_default_stream());

  // The first element will always be 0 since it the offset of the first string.
  int64_t initial_offset{0};
  offsets.set_element(0, initial_offset, cudf::get_default_stream());

  // We generate the lengths of the strings randomly for each row and
  // store them from the second element of the offsets vector.
  thrust::transform(rmm::exec_policy(cudf::get_default_stream()),
                    thrust::make_counting_iterator(0),
                    thrust::make_counting_iterator(num_rows),
                    offsets.begin() + 1,
                    gen_rand_num<cudf::size_type>(lower, upper));

  // We then calculate the offsets by performing an inclusive scan on this
  // vector.
  thrust::inclusive_scan(
    rmm::exec_policy(cudf::get_default_stream()), offsets.begin(), offsets.end(), offsets.begin());

  // The last element is the total length of all the strings combined using
  // which we allocate the memory for the `chars` vector, that holds the
  // randomly generated characters for the strings.
  auto const total_length = *thrust::device_pointer_cast(offsets.end() - 1);
  rmm::device_uvector<char> chars(total_length, cudf::get_default_stream());

  // We generate the strings in parallel into the `chars` vector using the
  // offsets vector generated above.
  thrust::for_each_n(rmm::exec_policy(cudf::get_default_stream()),
                     thrust::make_zip_iterator(offsets.begin(), offsets.begin() + 1),
                     num_rows,
                     gen_rand_str(chars.data()));

  return cudf::make_strings_column(
    num_rows,
    std::make_unique<cudf::column>(std::move(offsets), rmm::device_buffer{}, 0),
    chars.release(),
    0,
    rmm::device_buffer{});
}

/**
 * @brief Generate a column of random numbers
 * @param lower The lower bound of the random numbers
 * @param upper The upper bound of the random numbers
 * @param count The number of rows in the column
 */
template <typename T>
std::unique_ptr<cudf::column> gen_rand_num_col(T lower,
                                               T upper,
                                               cudf::size_type count,
                                               rmm::cuda_stream_view stream,
                                               rmm::device_async_resource_ref mr)
{
  cudf::data_type type;
  if (cudf::is_integral<T>()) {
    if (typeid(lower) == typeid(int64_t)) {
      type = cudf::data_type{cudf::type_id::INT64};
    } else {
      type = cudf::data_type{cudf::type_id::INT32};
    }
  } else {
    type = cudf::data_type{cudf::type_id::FLOAT64};
  }
  auto col = cudf::make_numeric_column(type, count, cudf::mask_state::UNALLOCATED, stream, mr);
  thrust::transform(rmm::exec_policy(stream),
                    thrust::make_counting_iterator(0),
                    thrust::make_counting_iterator(count),
                    col->mutable_view().begin<T>(),
                    gen_rand_num<T>(lower, upper));
  return col;
}

/**
 * @brief Generate a primary key column
 *
 * @param start The starting value of the primary key
 * @param num_rows The number of rows in the column
 */
std::unique_ptr<cudf::column> gen_primary_key_col(int64_t start,
                                                  int64_t num_rows,
                                                  rmm::cuda_stream_view stream,
                                                  rmm::device_async_resource_ref mr)
{
  auto const init = cudf::numeric_scalar<int64_t>(start);
  auto const step = cudf::numeric_scalar<int64_t>(1);
  return cudf::sequence(num_rows, init, step, stream, mr);
}

/**
 * @brief Generate a column where all the rows have the same string value
 *
 * @param value The string value to fill the column with
 * @param num_rows The number of rows in the column
 */
std::unique_ptr<cudf::column> gen_rep_str_col(std::string value,
                                              int64_t num_rows,
                                              rmm::cuda_stream_view stream,
                                              rmm::device_async_resource_ref mr)
{
  auto const indices = rmm::device_uvector<cudf::string_view>(num_rows, stream);
  auto const empty_str_col =
    cudf::make_strings_column(indices, cudf::string_view(nullptr, 0), stream, mr);
  auto const scalar  = cudf::string_scalar(value);
  auto scalar_repeat = cudf::fill(empty_str_col->view(), 0, num_rows, scalar, stream, mr);
  return scalar_repeat;
}

/**
 * @brief Generate a column by randomly choosing from set of strings
 *
 * @param string_set The set of strings to choose from
 * @param num_rows The number of rows in the column
 */
std::unique_ptr<cudf::column> gen_rand_str_col_from_set(std::vector<std::string> string_set,
                                                        int64_t num_rows,
                                                        rmm::cuda_stream_view stream,
                                                        rmm::device_async_resource_ref mr)
{
  // Build a vocab table of random strings to choose from
  auto const keys = gen_primary_key_col(0, string_set.size(), stream, mr);
  auto const values =
    cudf::test::strings_column_wrapper(string_set.begin(), string_set.end()).release();
  auto const vocab_table = cudf::table_view({keys->view(), values->view()});

  // Build a single column table containing `num_rows` random numbers
  auto const rand_keys = gen_rand_num_col<int64_t>(0, string_set.size() - 1, num_rows, stream, mr);
  auto const rand_keys_table = cudf::table_view({rand_keys->view()});

  auto const joined_table =
    perform_left_join(rand_keys_table, vocab_table, {0}, {0}, cudf::null_equality::EQUAL);
  return std::make_unique<cudf::column>(joined_table->get_column(2));
}

/**
 * @brief Generate a phone number column according to TPC-H specification clause 4.2.2.9
 *
 * @param num_rows The number of rows in the column
 */
std::unique_ptr<cudf::column> gen_phone_col(int64_t num_rows,
                                            rmm::cuda_stream_view stream,
                                            rmm::device_async_resource_ref mr)
{
  auto const part_a =
    cudf::strings::from_integers(gen_rand_num_col<int64_t>(10, 34, num_rows, stream, mr)->view());
  auto const part_b =
    cudf::strings::from_integers(gen_rand_num_col<int64_t>(100, 999, num_rows, stream, mr)->view());
  auto const part_c =
    cudf::strings::from_integers(gen_rand_num_col<int64_t>(100, 999, num_rows, stream, mr)->view());
  auto const part_d = cudf::strings::from_integers(
    gen_rand_num_col<int64_t>(1000, 9999, num_rows, stream, mr)->view());
  auto const phone_parts_table =
    cudf::table_view({part_a->view(), part_b->view(), part_c->view(), part_d->view()});
  auto phone = cudf::strings::concatenate(phone_parts_table, cudf::string_scalar("-"), stream, mr);
  return phone;
}

std::unique_ptr<cudf::column> gen_rep_seq_col(int64_t limit, int64_t num_rows)
{
  auto pkey                    = gen_primary_key_col(0, num_rows);
  auto repeat_seq_zero_indexed = cudf::binary_operation(pkey->view(),
                                                        cudf::numeric_scalar<int64_t>(limit),
                                                        cudf::binary_operator::MOD,
                                                        cudf::data_type{cudf::type_id::INT64});
  return cudf::binary_operation(repeat_seq_zero_indexed->view(),
                                cudf::numeric_scalar<int64_t>(1),
                                cudf::binary_operator::ADD,
                                cudf::data_type{cudf::type_id::INT64});
}
