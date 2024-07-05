# SPDX-FileCopyrightText: Copyright (c) 2024 NVIDIA CORPORATION & AFFILIATES.
# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import pytest

import polars as pl

from cudf_polars.testing.asserts import (
    assert_gpu_result_equal,
    assert_ir_translation_raises,
)


@pytest.fixture(
    params=[(None, None), ("row-index", 0), ("index", 10)],
    ids=["no-row-index", "zero-offset-row-index", "offset-row-index"],
)
def row_index(request):
    return request.param


@pytest.fixture(
    params=[
        (None, 0),
        pytest.param(
            (2, 1), marks=pytest.mark.xfail(reason="No handling of row limit in scan")
        ),
        pytest.param(
            (3, 0), marks=pytest.mark.xfail(reason="No handling of row limit in scan")
        ),
    ],
    ids=["all-rows", "n_rows-with-skip", "n_rows-no-skip"],
)
def n_rows_skip_rows(request):
    return request.param


@pytest.fixture(params=["csv", "parquet"])
def df(request, tmp_path, row_index, n_rows_skip_rows):
    df = pl.DataFrame(
        {
            "a": [1, 2, 3, None],
            "b": ["ẅ", "x", "y", "z"],
            "c": [None, None, 4, 5],
        }
    )
    name, offset = row_index
    n_rows, skip_rows = n_rows_skip_rows
    if request.param == "csv":
        df.write_csv(tmp_path / "file.csv")
        return pl.scan_csv(
            tmp_path / "file.csv",
            row_index_name=name,
            row_index_offset=offset,
            skip_rows_after_header=skip_rows,
            n_rows=n_rows,
        )
    else:
        df.write_parquet(tmp_path / "file.pq")
        # parquet doesn't have skip_rows argument
        return pl.scan_parquet(
            tmp_path / "file.pq",
            row_index_name=name,
            row_index_offset=offset,
            n_rows=n_rows,
        )


@pytest.fixture(params=[None, ["a"], ["b", "a"]], ids=["all", "subset", "reordered"])
def columns(request, row_index):
    name, _ = row_index
    if name is not None and request.param is not None:
        return [*request.param, name]
    return request.param


@pytest.fixture(
    params=[None, pl.col("c").is_not_null()], ids=["no-mask", "c-is-not-null"]
)
def mask(request):
    return request.param


def test_scan(df, columns, mask):
    q = df
    if mask is not None:
        q = q.filter(mask)
    if columns is not None:
        q = df.select(*columns)
    assert_gpu_result_equal(q)


def test_scan_unsupported_raises(tmp_path):
    df = pl.DataFrame({"a": [1, 2, 3]})

    df.write_ndjson(tmp_path / "df.json")
    q = pl.scan_ndjson(tmp_path / "df.json")
    assert_ir_translation_raises(q, NotImplementedError)


@pytest.mark.xfail(reason="https://github.com/pola-rs/polars/pull/17363")
def test_scan_row_index_projected_out(tmp_path):
    df = pl.DataFrame({"a": [1, 2, 3]})

    df.write_parquet(tmp_path / "df.pq")

    q = pl.scan_parquet(tmp_path / "df.pq").with_row_index().select(pl.col("a"))

    assert_gpu_result_equal(q)


def test_scan_csv_column_renames_projection_schema(tmp_path):
    with (tmp_path / "test.csv").open("w") as f:
        f.write("""foo,bar,baz\n1,2,\n3,4,5""")

    q = pl.scan_csv(
        tmp_path / "test.csv",
        with_column_names=lambda names: [f"{n}_suffix" for n in names],
        schema_overrides={
            "foo_suffix": pl.String(),
            "bar_suffix": pl.Int8(),
            "baz_suffix": pl.UInt16(),
        },
    )

    assert_gpu_result_equal(q)
