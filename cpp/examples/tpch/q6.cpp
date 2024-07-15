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

#include "utils.hpp"

#include <cudf/ast/expressions.hpp>
#include <cudf/column/column.hpp>
#include <cudf/scalar/scalar.hpp>

/**
 * @file q6.cpp
 * @brief Implement query 6 of the TPC-H benchmark.
 *
 * create view lineitem as select * from '/tables/scale-1/lineitem.parquet';
 *
 * select
 *    sum(l_extendedprice * l_discount) as revenue
 * from
 *    lineitem
 * where
 *    l_shipdate >= date '1994-01-01'
 *    and l_shipdate < date '1995-01-01'
 *    and l_discount >= 0.05
 *    and l_discount <= 0.07
 *    and l_quantity < 24;
 */

/**
 * @brief Calculate the revenue column
 *
 * @param extendedprice The extended price column
 * @param discount The discount column
 * @param stream The CUDA stream used for device memory operations and kernel launches.
 * @param mr Device memory resource used to allocate the returned column's device memory.
 */
std::unique_ptr<cudf::column> calc_revenue(
  cudf::column_view const& extendedprice,
  cudf::column_view const& discount,
  rmm::cuda_stream_view stream      = cudf::get_default_stream(),
  rmm::device_async_resource_ref mr = rmm::mr::get_current_device_resource())
{
  auto revenue_type = cudf::data_type{cudf::type_id::FLOAT64};
  auto revenue      = cudf::binary_operation(
    extendedprice, discount, cudf::binary_operator::MUL, revenue_type, stream, mr);
  return revenue;
}

int main(int argc, char const** argv)
{
  auto args = parse_args(argc, argv);

  // Use a memory pool
  auto resource = create_memory_resource(args.memory_resource_type);
  rmm::mr::set_current_device_resource(resource.get());

  Timer timer;

  // Read out the `lineitem` table from parquet file
  std::vector<std::string> lineitem_cols = {
    "l_extendedprice", "l_discount", "l_shipdate", "l_quantity"};
  auto shipdate_ref = cudf::ast::column_reference(std::distance(
    lineitem_cols.begin(), std::find(lineitem_cols.begin(), lineitem_cols.end(), "l_shipdate")));
  auto shipdate_lower =
    cudf::timestamp_scalar<cudf::timestamp_D>(days_since_epoch(1994, 1, 1), true);
  auto shipdate_lower_literal = cudf::ast::literal(shipdate_lower);
  auto shipdate_upper =
    cudf::timestamp_scalar<cudf::timestamp_D>(days_since_epoch(1995, 1, 1), true);
  auto shipdate_upper_literal = cudf::ast::literal(shipdate_upper);
  auto shipdate_pred_a        = cudf::ast::operation(
    cudf::ast::ast_operator::GREATER_EQUAL, shipdate_ref, shipdate_lower_literal);
  auto shipdate_pred_b =
    cudf::ast::operation(cudf::ast::ast_operator::LESS, shipdate_ref, shipdate_upper_literal);
  auto lineitem_pred = std::make_unique<cudf::ast::operation>(
    cudf::ast::ast_operator::LOGICAL_AND, shipdate_pred_a, shipdate_pred_b);
  auto lineitem =
    read_parquet(args.dataset_dir + "/lineitem.parquet", lineitem_cols, std::move(lineitem_pred));

  // Cast the discount and quantity columns to float32 and append to lineitem table
  auto discout_float =
    cudf::cast(lineitem->column("l_discount"), cudf::data_type{cudf::type_id::FLOAT32});
  auto quantity_float =
    cudf::cast(lineitem->column("l_quantity"), cudf::data_type{cudf::type_id::FLOAT32});

  lineitem->append(discout_float, "l_discount_float");
  lineitem->append(quantity_float, "l_quantity_float");

  // Apply the filters
  auto discount_ref = cudf::ast::column_reference(lineitem->col_id("l_discount_float"));
  auto quantity_ref = cudf::ast::column_reference(lineitem->col_id("l_quantity_float"));

  auto discount_lower         = cudf::numeric_scalar<float_t>(0.05);
  auto discount_lower_literal = cudf::ast::literal(discount_lower);
  auto discount_upper         = cudf::numeric_scalar<float_t>(0.07);
  auto discount_upper_literal = cudf::ast::literal(discount_upper);
  auto quantity_upper         = cudf::numeric_scalar<float_t>(24);
  auto quantity_upper_literal = cudf::ast::literal(quantity_upper);

  auto discount_pred_a = cudf::ast::operation(
    cudf::ast::ast_operator::GREATER_EQUAL, discount_ref, discount_lower_literal);

  auto discount_pred_b =
    cudf::ast::operation(cudf::ast::ast_operator::LESS_EQUAL, discount_ref, discount_upper_literal);
  auto discount_pred =
    cudf::ast::operation(cudf::ast::ast_operator::LOGICAL_AND, discount_pred_a, discount_pred_b);
  auto quantity_pred =
    cudf::ast::operation(cudf::ast::ast_operator::LESS, quantity_ref, quantity_upper_literal);
  auto discount_quantity_pred =
    cudf::ast::operation(cudf::ast::ast_operator::LOGICAL_AND, discount_pred, quantity_pred);
  auto filtered_table = apply_filter(lineitem, discount_quantity_pred);

  // Calculate the `revenue` column
  auto revenue =
    calc_revenue(filtered_table->column("l_extendedprice"), filtered_table->column("l_discount"));

  // Sum the `revenue` column
  auto revenue_view = revenue->view();
  auto result_table = apply_reduction(revenue_view, cudf::aggregation::Kind::SUM, "revenue");

  timer.print_elapsed_millis();

  // Write query result to a parquet file
  result_table->to_parquet("q6.parquet");
  return 0;
}
