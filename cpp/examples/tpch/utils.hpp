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
#include <chrono>
#include <ctime>

#include <cudf/table/table.hpp>
#include <cudf/io/parquet.hpp>
#include <cudf/join.hpp>
#include <cudf/copying.hpp>
#include <cudf/groupby.hpp>
#include <cudf/binaryop.hpp>
#include <cudf/sorting.hpp>
#include <cudf/transform.hpp>
#include <cudf/reduction.hpp>
#include <cudf/unary.hpp>
#include <cudf/stream_compaction.hpp>
#include <cudf/reduction.hpp>
#include <cudf/column/column_factories.hpp>
#include <rmm/cuda_stream.hpp>
#include <rmm/cuda_stream_view.hpp>
#include <rmm/device_buffer.hpp>
#include <rmm/device_uvector.hpp>


std::unique_ptr<cudf::table> join_and_gather(
    cudf::table_view left_input,
    cudf::table_view right_input,
    std::vector<cudf::size_type> left_on,
    std::vector<cudf::size_type> right_on,
    cudf::null_equality compare_nulls,
    rmm::device_async_resource_ref mr = rmm::mr::get_current_device_resource()) {

    auto oob_policy = cudf::out_of_bounds_policy::DONT_CHECK;
    auto left_selected  = left_input.select(left_on);
    auto right_selected = right_input.select(right_on);
    auto const [left_join_indices, right_join_indices] = 
        cudf::inner_join(left_selected, right_selected, compare_nulls, mr);

    auto left_indices_span  = cudf::device_span<cudf::size_type const>{*left_join_indices};
    auto right_indices_span = cudf::device_span<cudf::size_type const>{*right_join_indices};

    auto left_indices_col  = cudf::column_view{left_indices_span};
    auto right_indices_col = cudf::column_view{right_indices_span};

    auto left_result  = cudf::gather(left_input, left_indices_col, oob_policy);
    auto right_result = cudf::gather(right_input, right_indices_col, oob_policy);

    auto joined_cols = left_result->release();
    auto right_cols  = right_result->release();
    joined_cols.insert(joined_cols.end(),
                        std::make_move_iterator(right_cols.begin()),
                        std::make_move_iterator(right_cols.end()));
    return std::make_unique<cudf::table>(std::move(joined_cols));
}

template <typename T>
std::vector<T> concat(const std::vector<T>& lhs, const std::vector<T>& rhs) {
    std::vector<T> result;
    result.reserve(lhs.size() + rhs.size());
    std::copy(lhs.begin(), lhs.end(), std::back_inserter(result));
    std::copy(rhs.begin(), rhs.end(), std::back_inserter(result));
    return result;
}

class table_with_cols {
    public:
        table_with_cols(
            std::unique_ptr<cudf::table> tbl, std::vector<std::string> col_names) 
                : tbl(std::move(tbl)), col_names(col_names) {}
        cudf::table_view table() {
            return tbl->view();
        }
        cudf::column_view column(std::string col_name) {
            return tbl->view().column(col_id(col_name));
        }
        std::vector<std::string> columns() {
            return col_names;
        }
        cudf::size_type col_id(std::string col_name) {
            auto it = std::find(col_names.begin(), col_names.end(), col_name);
            if (it == col_names.end()) {
                throw std::runtime_error("Column not found");
            }
            return std::distance(col_names.begin(), it);
        }
        std::unique_ptr<table_with_cols> append(std::unique_ptr<cudf::column>& col, std::string col_name) {
            std::vector<std::unique_ptr<cudf::column>> updated_cols;
            std::vector<std::string> updated_col_names;
            for (size_t i = 0; i < tbl->num_columns(); i++) {
                updated_cols.push_back(std::make_unique<cudf::column>(tbl->get_column(i)));
                updated_col_names.push_back(col_names[i]);
            }
            updated_cols.push_back(std::move(col));
            updated_col_names.push_back(col_name);
            auto updated_table = std::make_unique<cudf::table>(std::move(updated_cols));
            return std::make_unique<table_with_cols>(std::move(updated_table), updated_col_names);
        }
        cudf::table_view select(std::vector<std::string> col_names) {
            std::vector<cudf::size_type> col_indices;
            for (auto &col_name : col_names) {
                col_indices.push_back(col_id(col_name));
            }
            return tbl->select(col_indices);
        }
        void to_parquet(std::string filepath) {
            auto sink_info = cudf::io::sink_info(filepath);
            cudf::io::table_metadata metadata;
            std::vector<cudf::io::column_name_info> col_name_infos;
            for (auto &col_name : col_names) {
                col_name_infos.push_back(cudf::io::column_name_info(col_name));
            }
            metadata.schema_info = col_name_infos;
            auto table_input_metadata = cudf::io::table_input_metadata{metadata};
            auto builder = cudf::io::parquet_writer_options::builder(sink_info, tbl->view());
            builder.metadata(table_input_metadata);
            auto options = builder.build();
            cudf::io::write_parquet(options);
        }
    private:
        std::unique_ptr<cudf::table> tbl;
        std::vector<std::string> col_names;
};

std::unique_ptr<table_with_cols> apply_inner_join(
  std::unique_ptr<table_with_cols>& left_input,
  std::unique_ptr<table_with_cols>& right_input,
  std::vector<std::string> left_on,
  std::vector<std::string> right_on,
  cudf::null_equality compare_nulls = cudf::null_equality::EQUAL) {
    std::vector<cudf::size_type> left_on_indices;
    std::vector<cudf::size_type> right_on_indices;
    for (auto &col_name : left_on) {
        left_on_indices.push_back(left_input->col_id(col_name));
    }
    for (auto &col_name : right_on) {
        right_on_indices.push_back(right_input->col_id(col_name));
    }
    auto table = join_and_gather(
        left_input->table(), right_input->table(), 
        left_on_indices, right_on_indices, compare_nulls
    );
    return std::make_unique<table_with_cols>(std::move(table), 
        concat(left_input->columns(), right_input->columns()));
}

std::unique_ptr<table_with_cols> read_parquet(
    std::string filename, std::vector<std::string> columns = {}, std::unique_ptr<cudf::ast::operation> predicate = nullptr) {
    auto source = cudf::io::source_info(filename);
    auto builder = cudf::io::parquet_reader_options_builder(source);    
    if (columns.size()) {
        builder.columns(columns);
    }
    if (predicate) {
        builder.filter(*predicate);
    }
    auto options = builder.build();
    auto table_with_metadata = cudf::io::read_parquet(options);
    auto schema_info = table_with_metadata.metadata.schema_info;
    std::vector<std::string> column_names;
    for (auto &col_info : schema_info) {
        column_names.push_back(col_info.name);
    }
    return std::make_unique<table_with_cols>(
        std::move(table_with_metadata.tbl), column_names);
}

std::unique_ptr<table_with_cols> apply_filter(
    std::unique_ptr<table_with_cols>& table, cudf::ast::operation& predicate) {
    auto boolean_mask = cudf::compute_column(table->table(), predicate);
    auto result_table = cudf::apply_boolean_mask(table->table(), boolean_mask->view());    
    return std::make_unique<table_with_cols>(std::move(result_table), table->columns());
}

std::unique_ptr<table_with_cols> apply_mask(
    std::unique_ptr<table_with_cols>& table, std::unique_ptr<cudf::column>& mask) {
    auto result_table = cudf::apply_boolean_mask(table->table(), mask->view());
    return std::make_unique<table_with_cols>(std::move(result_table), table->columns());
}

struct groupby_context {
    std::vector<std::string> keys;
    std::unordered_map<std::string, std::vector<std::pair<cudf::aggregation::Kind, std::string>>> values;
};

std::unique_ptr<table_with_cols> apply_groupby(
    std::unique_ptr<table_with_cols>& table, groupby_context ctx) {
    auto keys = table->select(ctx.keys);
    cudf::groupby::groupby groupby_obj(keys);
    std::vector<std::string> result_column_names;
    result_column_names.insert(
        result_column_names.end(), ctx.keys.begin(), ctx.keys.end());
    std::vector<cudf::groupby::aggregation_request> requests;
    for (auto& [value_col, aggregations] : ctx.values) {
        requests.emplace_back(cudf::groupby::aggregation_request());
        for (auto& agg : aggregations) {
            if (agg.first == cudf::aggregation::Kind::SUM) {
                requests.back().aggregations.push_back(cudf::make_sum_aggregation<cudf::groupby_aggregation>());
            } else if (agg.first == cudf::aggregation::Kind::MEAN) {
                requests.back().aggregations.push_back(cudf::make_mean_aggregation<cudf::groupby_aggregation>());
            } else if (agg.first == cudf::aggregation::Kind::COUNT_ALL) {
                requests.back().aggregations.push_back(cudf::make_count_aggregation<cudf::groupby_aggregation>());
            } else {
                throw std::runtime_error("Unsupported aggregation");
            }
            result_column_names.push_back(agg.second);
        }
        requests.back().values = table->column(value_col);
    }
    auto agg_results = groupby_obj.aggregate(requests);
    std::vector<std::unique_ptr<cudf::column>> result_columns;
    for (size_t i = 0; i < agg_results.first->num_columns(); i++) {
        auto col = std::make_unique<cudf::column>(agg_results.first->get_column(i));
        result_columns.push_back(std::move(col));
    }
    for (size_t i = 0; i < agg_results.second.size(); i++) {
        for (size_t j = 0; j < agg_results.second[i].results.size(); j++) {
            result_columns.push_back(std::move(agg_results.second[i].results[j]));
        }
    }
    auto result_table = std::make_unique<cudf::table>(std::move(result_columns));
    return std::make_unique<table_with_cols>(
        std::move(result_table), result_column_names);
}

std::tm make_tm(int year, int month, int day) {
    std::tm tm = {0};
    tm.tm_year = year - 1900;
    tm.tm_mon = month - 1;
    tm.tm_mday = day;
    return tm;
}

int32_t days_since_epoch(int year, int month, int day) {
    std::tm tm = make_tm(year, month, day);
    std::tm epoch = make_tm(1970, 1, 1);
    std::time_t time = std::mktime(&tm);
    std::time_t epoch_time = std::mktime(&epoch);
    double diff = std::difftime(time, epoch_time) / (60*60*24);
    return static_cast<int32_t>(diff);
}

std::unique_ptr<table_with_cols> apply_orderby(
    std::unique_ptr<table_with_cols>& table, 
    std::vector<std::string> sort_keys,
    std::vector<cudf::order> sort_key_orders) {
    std::vector<cudf::column_view> column_views;
    for (auto& key : sort_keys) {
        column_views.push_back(table->column(key));
    }
    auto result_table = cudf::sort_by_key(
        table->table(), 
        cudf::table_view{column_views},
        sort_key_orders
    );
    return std::make_unique<table_with_cols>(
        std::move(result_table), table->columns());
}

std::unique_ptr<table_with_cols> apply_reduction(
    cudf::column_view& column, cudf::aggregation::Kind agg_kind, std::string col_name) {
    auto agg = cudf::make_sum_aggregation<cudf::reduce_aggregation>();
    auto result = cudf::reduce(column, *agg, column.type());
    cudf::size_type len = 1;
    auto col = cudf::make_column_from_scalar(*result, len);
    std::vector<std::unique_ptr<cudf::column>> columns;
    columns.push_back(std::move(col));
    auto result_table = std::make_unique<cudf::table>(std::move(columns));
    std::vector<std::string> col_names = {col_name};
    return std::make_unique<table_with_cols>(
        std::move(result_table), col_names
    );
}
