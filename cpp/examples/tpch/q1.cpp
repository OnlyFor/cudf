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

#include <iostream>
#include <memory>
#include <vector>
#include <cudf/io/parquet.hpp>
#include <cudf/ast/expressions.hpp>
#include <cudf/column/column.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/detail/iterator.cuh>
#include <cudf/scalar/scalar.hpp>
#include <cudf/scalar/scalar_device_view.cuh>
#include <cudf/scalar/scalar_factories.hpp>
#include <cudf/table/table.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/transform.hpp>
#include <cudf/types.hpp>
#include <cudf/groupby.hpp>
#include <cudf/binaryop.hpp>
#include <cudf_test/debug_utilities.hpp>

/*
    select
        l_returnflag,
        l_linestatus,
        sum(l_quantity) as sum_qty,
        sum(l_extendedprice) as sum_base_price,
        sum(l_extendedprice * (1 - l_discount)) as sum_disc_price, // done
        sum(l_extendedprice * (1 - l_discount) * (1 + l_tax)) as sum_charge,
        avg(l_quantity) as avg_qty,
        avg(l_extendedprice) as avg_price,
        avg(l_discount) as avg_disc,
        count(*) as count_order
    from
        lineitem
    where
            l_shipdate <= date '1998-09-02'
    group by
        l_returnflag,
        l_linestatus
    order by
        l_returnflag,
        l_linestatus;

*/
void write_parquet(cudf::table_view input,
                   std::string filepath)
{
  auto sink_info      = cudf::io::sink_info(filepath);
  auto builder        = cudf::io::parquet_writer_options::builder(sink_info, input);
  auto options = builder.build();
  cudf::io::write_parquet(options);
}

std::unique_ptr<cudf::table> append_col_to_table(std::unique_ptr<cudf::table> table, std::unique_ptr<cudf::column> col) {
    std::vector<std::unique_ptr<cudf::column>> columns;
    for (size_t i = 0; i < table->num_columns(); i++) {
        columns.push_back(std::make_unique<cudf::column>(table->get_column(i)));
    }
    columns.push_back(std::move(col));
    return std::make_unique<cudf::table>(std::move(columns));
}

std::unique_ptr<cudf::table> read_filter_project(std::vector<std::string>& projection_cols) {
    std::string path = "/home/jayjeetc/tpch_sf1/lineitem/part-0.parquet";
    auto source = cudf::io::source_info(path);
    auto builder = cudf::io::parquet_reader_options_builder(source);

    // auto col_ref = cudf::ast::column_reference(5);

    // auto literal_value = cudf::timestamp_scalar<cudf::timestamp_s>(1719255747, true);
    // auto literal = cudf::ast::literal(literal_value);

    // auto filter_expr = cudf::ast::operation(
    //     cudf::ast::ast_operator::LESS, 
    //     col_ref,
    //     literal
    // );

    builder.columns(projection_cols);
    // builder.filter(filter_expr);

    auto options = builder.build();
    cudf::io::table_with_metadata result = cudf::io::read_parquet(options);
    write_parquet(result.tbl->view(), "file.parquet");
    return std::move(result.tbl);
}

std::unique_ptr<cudf::column> calc_disc_price(std::unique_ptr<cudf::table>& table) {
    auto one = cudf::fixed_point_scalar<numeric::decimal64>(1);
    auto disc = table->get_column(4).view();
    auto one_minus_disc = cudf::binary_operation(one, disc, cudf::binary_operator::SUB, disc.type());
    auto extended_price = table->get_column(3).view();
    auto disc_price = cudf::binary_operation(extended_price, one_minus_disc->view(), cudf::binary_operator::MUL, extended_price.type());
    return disc_price;
}

std::unique_ptr<cudf::column> calc_charge(std::unique_ptr<cudf::table>& table) {
    auto one = cudf::fixed_point_scalar<numeric::decimal64>(1);
    auto disc = table->get_column(4).view();
    auto one_minus_disc = cudf::binary_operation(one, disc, cudf::binary_operator::SUB, disc.type());
    auto extended_price = table->get_column(3).view();
    auto disc_price = cudf::binary_operation(extended_price, one_minus_disc->view(), cudf::binary_operator::MUL, extended_price.type());
    auto tax = table->get_column(7).view();
    auto one_plus_tax = cudf::binary_operation(one, tax, cudf::binary_operator::ADD, tax.type());
    auto charge = cudf::binary_operation(disc_price->view(), one_plus_tax->view(), cudf::binary_operator::MUL, disc_price->type());
    return charge;
}

std::vector<cudf::groupby::aggregation_request> make_single_aggregation_request(
    std::unique_ptr<cudf::groupby_aggregation>&& agg, cudf::column_view value) {
    std::vector<cudf::groupby::aggregation_request> requests;
    requests.emplace_back(cudf::groupby::aggregation_request());
    requests[0].aggregations.push_back(std::move(agg));
    requests[0].values = value;
    return requests;
}

std::unique_ptr<cudf::table> group_by(std::unique_ptr<cudf::table> &table, int32_t groupby_key_index, int32_t groupby_value_index) {
    auto tbl_view = table->view();
    auto keys = cudf::table_view{{tbl_view.column(0), tbl_view.column(1}};
    auto val  = tbl_view.column(groupby_value_index);
    cudf::groupby::groupby grpby_obj(keys);
    auto requests = make_single_aggregation_request(cudf::make_sum_aggregation<cudf::groupby_aggregation>(), val);
    auto agg_results = grpby_obj.aggregate(requests);
    
    auto result_key = std::move(agg_results.first);
    auto result_val = std::move(agg_results.second[0].results[0]);
    std::vector<cudf::column_view> columns{result_key->get_column(0), *result_val};
    return std::make_unique<cudf::table>(cudf::table_view(columns));    
}

int main() {
    // 1. Project 2. Filter 3. GroupBy 4. Aggregation
    std::vector<std::string> column_names = {
        "l_returnflag",
        "l_linestatus",
        "l_quantity",
        "l_extendedprice",
        "l_discount", 
        "l_shipdate",
        "l_orderkey",
        "l_tax"
    };

    std::unique_ptr<cudf::table> t1 = read_filter_project(column_names);
    std::unique_ptr<cudf::column> disc_price_col = calc_disc_price(t1);
    std::unique_ptr<cudf::column> charge_col = calc_charge(t1);
    auto t2 = append_col_to_table(std::move(t1), std::move(disc_price_col));
    auto t3 = append_col_to_table(std::move(t2), std::move(charge_col));

    std::cout << "Table after appending columns: " << std::endl;
    std::cout << t3->num_rows() << " " << t3->num_columns() << std::endl;

    return 0;
}
