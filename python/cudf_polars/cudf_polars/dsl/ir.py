# SPDX-FileCopyrightText: Copyright (c) 2024 NVIDIA CORPORATION & AFFILIATES.
# SPDX-License-Identifier: Apache-2.0
# TODO: remove need for this
# ruff: noqa: D101
"""
DSL nodes for the LogicalPlan of polars.

An IR node is either a source, normal, or a sink. Respectively they
can be considered as functions:

- source: `IO () -> DataFrame`
- normal: `DataFrame -> DataFrame`
- sink: `DataFrame -> IO ()`
"""

from __future__ import annotations

from dataclasses import dataclass
from functools import cache
from typing import TYPE_CHECKING, Any, Callable

import pyarrow as pa
from typing_extensions import assert_never

import polars as pl

import cudf
import cudf._lib.pylibcudf as plc

import cudf_polars.dsl.expr as expr
from cudf_polars.containers import Column, DataFrame
from cudf_polars.utils import dtypes

if TYPE_CHECKING:
    from typing import Literal

    from cudf_polars.dsl.expr import Expr


__all__ = [
    "IR",
    "PythonScan",
    "Scan",
    "Cache",
    "DataFrameScan",
    "Select",
    "GroupBy",
    "Join",
    "HStack",
    "Distinct",
    "Sort",
    "Slice",
    "Filter",
    "Projection",
    "MapFunction",
    "Union",
    "HConcat",
    "ExtContext",
]


@dataclass(slots=True)
class IR:
    schema: dict

    def evaluate(self) -> DataFrame:
        """Evaluate and return a dataframe."""
        raise NotImplementedError


@dataclass(slots=True)
class PythonScan(IR):
    options: Any
    predicate: Expr | None


@dataclass(slots=True)
class Scan(IR):
    typ: Any
    paths: list[str]
    file_options: Any
    predicate: Expr | None

    def __post_init__(self):
        """Validate preconditions."""
        if self.file_options.n_rows is not None:
            raise NotImplementedError("row limit in scan")
        if self.typ not in ("csv", "parquet"):
            raise NotImplementedError(f"Unhandled scan type: {self.typ}")

    def evaluate(self) -> DataFrame:
        """Evaluate and return a dataframe."""
        options = self.file_options
        n_rows = options.n_rows
        with_columns = options.with_columns
        row_index = options.row_index
        assert n_rows is None
        if self.typ == "csv":
            df = DataFrame.from_cudf(
                cudf.concat(
                    [cudf.read_csv(p, usecols=with_columns) for p in self.paths]
                )
            )
        elif self.typ == "parquet":
            df = DataFrame.from_cudf(
                cudf.read_parquet(self.paths, columns=with_columns)
            )
        else:
            assert_never(self.typ)
        if row_index is not None:
            name, offset = row_index
            dtype = dtypes.from_polars(self.schema[name])
            step = plc.interop.from_arrow(pa.scalar(1), data_type=dtype)
            init = plc.interop.from_arrow(pa.scalar(offset), data_type=dtype)
            index = Column(
                plc.filling.sequence(df.num_rows(), init, step), name
            ).set_sorted(
                is_sorted=plc.types.Sorted.YES,
                order=plc.types.Order.ASCENDING,
                null_order=plc.types.null_order.AFTER,
            )
            df = df.with_columns(index)
        if self.predicate is None:
            return df
        else:
            mask = self.predicate.evaluate(df)
            return df.filter(mask)


@dataclass(slots=True)
class Cache(IR):
    key: int
    value: IR


@dataclass(slots=True)
class DataFrameScan(IR):
    df: Any
    projection: list[str]
    predicate: Expr | None

    def evaluate(self) -> DataFrame:
        """Evaluate and return a dataframe."""
        pdf = pl.DataFrame._from_pydf(self.df)
        if self.projection is not None:
            pdf = pdf.select(self.projection)
        # TODO: goes away when libcudf supports large strings
        table = pdf.to_arrow()
        schema = table.schema
        for i, field in enumerate(schema):
            if field.type == pa.large_string():
                # TODO: Nested types
                schema = schema.set(i, pa.field(field.name, pa.string()))
        table = table.cast(schema)
        df = DataFrame(
            [
                Column(col, name)
                for name, col in zip(
                    self.schema.keys(), plc.interop.from_arrow(table).columns()
                )
            ],
            [],
        )
        if self.predicate is not None:
            mask = self.predicate.evaluate(df)
            return df.filter(mask)
        else:
            return df


@dataclass(slots=True)
class Select(IR):
    df: IR
    cse: list[Expr]
    expr: list[Expr]

    def evaluate(self):
        """Evaluate and return a dataframe."""
        df = self.df.evaluate()
        for e in self.cse:
            df = df.with_columns(e.evaluate(df))
        return DataFrame([e.evaluate(df) for e in self.expr], [])


@dataclass(slots=True)
class GroupBy(IR):
    df: IR
    agg_requests: list[Expr]
    keys: list[Expr]
    options: Any

    @staticmethod
    def check_agg(agg: Expr) -> int:
        """
        Determine if we can handle an aggregation expression.

        Parameters
        ----------
        agg
            Expression to check

        Returns
        -------
        depth of nesting

        Raises
        ------
        NotImplementedError for unsupported expression nodes.
        """
        if isinstance(agg, expr.Agg):
            if agg.name == "implode":
                raise NotImplementedError("implode in groupby")
            return 1 + GroupBy.check_agg(agg.column)
        elif isinstance(agg, (expr.Len, expr.Column, expr.Literal)):
            return 0
        elif isinstance(agg, expr.BinOp):
            return max(GroupBy.check_agg(agg.left), GroupBy.check_agg(agg.right))
        elif isinstance(agg, expr.Cast):
            return GroupBy.check_agg(agg.column)
        else:
            raise NotImplementedError(f"No handler for {agg=}")

    def __post_init__(self):
        """Check whether all the aggregations are implemented."""
        if any(GroupBy.check_agg(a) > 1 for a in self.agg_requests):
            raise NotImplementedError("Nested aggregations in groupby")


@dataclass(slots=True)
class Join(IR):
    left: IR
    right: IR
    left_on: list[Expr]
    right_on: list[Expr]
    options: Any

    def __post_init__(self):
        """Raise for unsupported options."""
        if self.options[0] == "cross":
            raise NotImplementedError("cross join not implemented")

    @cache
    @staticmethod
    def _joiners(
        how: Literal["inner", "left", "outer", "leftsemi", "leftanti"],
    ) -> tuple[
        Callable, plc.copying.OutOfBoundsPolicy, plc.copying.OutOfBoundsPolicy | None
    ]:
        if how == "inner":
            return (
                plc.join.inner_join,
                plc.copying.OutOfBoundsPolicy.DONT_CHECK,
                plc.copying.OutOfBoundsPolicy.DONT_CHECK,
            )
        elif how == "left":
            return (
                plc.join.left_join,
                plc.copying.OutOfBoundsPolicy.DONT_CHECK,
                plc.copying.OutOfBoundsPolicy.NULLIFY,
            )
        elif how == "outer":
            return (
                plc.join.full_join,
                plc.copying.OutOfBoundsPolicy.NULLIFY,
                plc.copying.OutOfBoundsPolicy.NULLIFY,
            )
        elif how == "leftsemi":
            return (
                plc.join.left_semi_join,
                plc.copying.OutOfBoundsPolicy.DONT_CHECK,
                None,
            )
        elif how == "leftanti":
            return (
                plc.join.left_anti_join,
                plc.copying.OutOfBoundsPolicy.DONT_CHECK,
                None,
            )
        else:
            assert_never(how)

    def evaluate(self) -> DataFrame:
        """Evaluate and return a dataframe."""
        left = self.left.evaluate()
        right = self.right.evaluate()
        left_on = DataFrame([e.evaluate(left) for e in self.left_on], [])
        right_on = DataFrame([e.evaluate(right) for e in self.right_on], [])
        how, join_nulls, zlice, suffix, coalesce = self.options
        null_equality = (
            plc.types.NullEquality.EQUAL
            if join_nulls
            else plc.types.NullEquality.UNEQUAL
        )
        suffix = "_right" if suffix is None else suffix
        join_fn, left_policy, right_policy = Join._joiners(how)
        if right_policy is None:
            # Semi join
            lg = join_fn(left_on.table, right_on.table, null_equality)
            left = left.replace_columns(*left_on.columns)
            table = plc.copying.gather(left.table, lg, left_policy)
            result = DataFrame(
                [
                    Column(c, col.name)
                    for col, c in zip(left_on.columns, table.columns())
                ],
                [],
            )
        else:
            lg, rg = join_fn(left_on, right_on, null_equality)
            left = left.replace_columns(*left_on.columns)
            right = right.replace_columns(*right_on.columns)
            if coalesce and how != "outer":
                right = right.discard_columns(set(right_on.names))
            left = DataFrame(
                plc.copying.gather(left.table, lg, left_policy).columns(), []
            )
            right = DataFrame(
                plc.copying.gather(right.table, rg, right_policy).columns(), []
            )
            if coalesce and how == "outer":
                left.replace_columns(
                    *(
                        Column(
                            plc.replace.replace_nulls(left_col.obj, right_col.obj),
                            left_col.name,
                        )
                        for left_col, right_col in zip(
                            left.select_columns(set(left_on.names)),
                            right.select_columns(set(right_on.names)),
                        )
                    )
                )
                right.discard_columns(set(right_on.names))
            right = right.rename_columns(
                {name: f"{name}{suffix}" for name in right.names if name in left.names}
            )
            result = left.with_columns(*right.columns)
        if zlice is not None:
            raise NotImplementedError("slicing")
        else:
            return result


@dataclass(slots=True)
class HStack(IR):
    df: IR
    columns: list[Expr]


@dataclass(slots=True)
class Distinct(IR):
    df: IR
    options: Any


@dataclass(slots=True)
class Sort(IR):
    df: IR
    by: list[Expr]
    options: Any


@dataclass(slots=True)
class Slice(IR):
    df: IR
    offset: int
    length: int


@dataclass(slots=True)
class Filter(IR):
    df: IR
    mask: Expr


@dataclass(slots=True)
class Projection(IR):
    df: IR


@dataclass(slots=True)
class MapFunction(IR):
    df: IR
    name: str
    options: Any


@dataclass(slots=True)
class Union(IR):
    dfs: list[IR]


@dataclass(slots=True)
class HConcat(IR):
    dfs: list[IR]


@dataclass(slots=True)
class ExtContext(IR):
    df: IR
    extra: list[IR]
