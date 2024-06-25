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
#include <cudf/filling.hpp>
#include <cudf/scalar/scalar.hpp>
#include <cudf/table/table.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/transform.hpp>
#include <cudf/types.hpp>
#include <cudf/groupby.hpp>
#include <cudf/binaryop.hpp>
#include <cudf/sorting.hpp>

/*
    select
        l_returnflag,
        l_linestatus,
        sum(l_quantity) as sum_qty,
        sum(l_extendedprice) as sum_base_price,
        sum(l_extendedprice * (1 - l_discount)) as sum_disc_price,
        sum(l_extendedprice * (1 - l_discount) * (1 + l_tax)) as sum_charge,
        avg(l_quantity) as avg_qty,
        avg(l_extendedprice) as avg_price,
        avg(l_discount) as avg_disc,
        count(*) as count_order
    from
        '~/tpch_sf1/lineitem/part-0.parquet'
    where
            l_shipdate <= date '1998-09-02'
    group by
        l_returnflag,
        l_linestatus
    order by
        l_returnflag,
        l_linestatus;
*/

void write_parquet(cudf::table_view input, std::string filepath) {
    auto sink_info = cudf::io::sink_info(filepath);
    auto builder = cudf::io::parquet_writer_options::builder(sink_info, input);
    auto options = builder.build();
    cudf::io::write_parquet(options);
}

std::unique_ptr<cudf::table> append_col_to_table(
    std::unique_ptr<cudf::table> table, std::unique_ptr<cudf::column> col) {
    std::vector<std::unique_ptr<cudf::column>> columns;
    for (size_t i = 0; i < table->num_columns(); i++) {
        columns.push_back(std::make_unique<cudf::column>(table->get_column(i)));
    }
    columns.push_back(std::move(col));
    return std::make_unique<cudf::table>(std::move(columns));
}

std::unique_ptr<cudf::table> scan_filter_project() {
    std::string lineitem = "/home/jayjeetc/tpch_sf1/lineitem/part-0.parquet";
    auto source = cudf::io::source_info(lineitem);
    auto builder = cudf::io::parquet_reader_options_builder(source);

    std::vector<std::string> projection_cols = {
        "l_returnflag",
        "l_linestatus",
        "l_quantity",
        "l_extendedprice",
        "l_discount", 
        "l_shipdate",
        "l_orderkey",
        "l_tax"
    };

    auto l_shipdate = cudf::ast::column_reference(5);
    auto date_scalar = cudf::timestamp_scalar<cudf::timestamp_D>(10471, true);
    auto date = cudf::ast::literal(date_scalar);
    auto filter_expr = cudf::ast::operation(
        cudf::ast::ast_operator::LESS_EQUAL,
        l_shipdate,
        date
    );

    builder.columns(projection_cols);
    builder.filter(filter_expr);

    auto options = builder.build();
    auto result = cudf::io::read_parquet(options);
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

std::unique_ptr<cudf::table> calc_group_by(std::unique_ptr<cudf::table>& table) {
    auto tbl_view = table->view();
    auto keys = cudf::table_view{{tbl_view.column(0), tbl_view.column(1)}};

    auto l_quantity = tbl_view.column(2);
    auto l_extendedprice = tbl_view.column(3);
    auto l_discount = tbl_view.column(4);
    auto l_discprice = tbl_view.column(8);
    auto l_charge = tbl_view.column(9);

    cudf::groupby::groupby groupby_obj(keys);
    std::vector<cudf::groupby::aggregation_request> requests;

    requests.emplace_back(cudf::groupby::aggregation_request());
    requests[0].aggregations.push_back(cudf::make_sum_aggregation<cudf::groupby_aggregation>());
    requests[0].aggregations.push_back(cudf::make_mean_aggregation<cudf::groupby_aggregation>());
    requests[0].values = l_quantity;

    requests.emplace_back(cudf::groupby::aggregation_request());
    requests[1].aggregations.push_back(cudf::make_sum_aggregation<cudf::groupby_aggregation>());
    requests[1].aggregations.push_back(cudf::make_mean_aggregation<cudf::groupby_aggregation>());
    requests[1].values = l_extendedprice;

    requests.emplace_back(cudf::groupby::aggregation_request());
    requests[2].aggregations.push_back(cudf::make_mean_aggregation<cudf::groupby_aggregation>());
    requests[2].values = l_discount;

    requests.emplace_back(cudf::groupby::aggregation_request());
    requests[3].aggregations.push_back(cudf::make_sum_aggregation<cudf::groupby_aggregation>());
    requests[3].values = l_discprice;

    requests.emplace_back(cudf::groupby::aggregation_request());
    requests[4].aggregations.push_back(cudf::make_sum_aggregation<cudf::groupby_aggregation>());
    requests[4].values = l_charge;

    requests.emplace_back(cudf::groupby::aggregation_request());
    requests[5].aggregations.push_back(cudf::make_count_aggregation<cudf::groupby_aggregation>());
    requests[5].values = l_charge;

    auto agg_results = groupby_obj.aggregate(requests);
    auto result_key = std::move(agg_results.first);
    std::vector<cudf::column_view> columns{
        result_key->get_column(0), 
        result_key->get_column(1),
        *agg_results.second[0].results[0],
        *agg_results.second[0].results[1],
        *agg_results.second[1].results[0],
        *agg_results.second[1].results[1],
        *agg_results.second[2].results[0],
        *agg_results.second[3].results[0],
        *agg_results.second[4].results[0],
        *agg_results.second[5].results[0]
    };
    return std::make_unique<cudf::table>(cudf::table_view(columns));
}

std::unique_ptr<cudf::table> sort(
    std::unique_ptr<cudf::table>& table) {
    auto tbl_view = table->view();
    return cudf::sort_by_key(
        tbl_view, 
        cudf::table_view{{tbl_view.column(0), tbl_view.column(1)}}
    );
}

int main() {
    std::unique_ptr<cudf::table> t1 = scan_filter_project();
    std::unique_ptr<cudf::column> disc_price_col = calc_disc_price(t1);
    std::unique_ptr<cudf::column> charge_col = calc_charge(t1);
    auto t2 = append_col_to_table(std::move(t1), std::move(disc_price_col));
    auto t3 = append_col_to_table(std::move(t2), std::move(charge_col));
    auto t4 = calc_group_by(t3);
    auto t5 = sort(t4);
    write_parquet(t5->view(), "q1.parquet");
    return 0;
}
