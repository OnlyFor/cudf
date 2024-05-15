# SPDX-FileCopyrightText: Copyright (c) 2024 NVIDIA CORPORATION & AFFILIATES.
# SPDX-License-Identifier: Apache-2.0
# TODO: remove need for this
# ruff: noqa: D101
"""
DSL nodes for the polars expression language.

An expression node is a function, `DataFrame -> Column` or `DataFrame -> Scalar`.

The evaluation context is provided by a LogicalPlan node, and can
affect the evaluation rule as well as providing the dataframe input.
In particular, the interpretation of the expression language in a
`GroupBy` node is groupwise, rather than whole frame.
"""

from __future__ import annotations

import enum
from dataclasses import dataclass
from enum import IntEnum
from functools import partial
from typing import TYPE_CHECKING, Any, ClassVar

import pyarrow as pa

from polars.polars import _expr_nodes as pl_expr

import cudf._lib.pylibcudf as plc

from cudf_polars.containers import Column, Scalar
from cudf_polars.utils import sorting

if TYPE_CHECKING:
    from typing import Callable

    from cudf_polars.containers import DataFrame

__all__ = [
    "Expr",
    "NamedExpr",
    "Literal",
    "Col",
    "BooleanFunction",
    "Sort",
    "SortBy",
    "Gather",
    "Filter",
    "Window",
    "Cast",
    "Agg",
    "BinOp",
]


class ExecutionContext(IntEnum):
    FRAME = enum.auto()
    GROUPBY = enum.auto()
    ROLLING = enum.auto()


@dataclass(slots=True)
class Expr:
    dtype: plc.DataType

    # TODO: return type is a lie for Literal
    def evaluate(
        self, df: DataFrame, *, context: ExecutionContext = ExecutionContext.FRAME
    ) -> Column:
        """Evaluate this expression given a dataframe for context."""
        raise NotImplementedError


@dataclass(slots=True)
class NamedExpr(Expr):
    name: str
    value: Expr

    def evaluate(
        self, df: DataFrame, *, context: ExecutionContext = ExecutionContext.FRAME
    ) -> Column:
        """Evaluate this expression given a dataframe for context."""
        return Column(self.value.evaluate(df, context=context).obj, self.name)


@dataclass(slots=True)
class Literal(Expr):
    value: Any

    def evaluate(
        self, df: DataFrame, *, context: ExecutionContext = ExecutionContext.FRAME
    ) -> Column:
        """Evaluate this expression given a dataframe for context."""
        obj = plc.interop.from_arrow(pa.scalar(self.value), data_type=self.dtype)
        return Scalar(obj)  # type: ignore


@dataclass(slots=True)
class Col(Expr):
    name: str

    def evaluate(
        self, df: DataFrame, *, context: ExecutionContext = ExecutionContext.FRAME
    ) -> Column:
        """Evaluate this expression given a dataframe for context."""
        return df._column_map[self.name]


@dataclass(slots=True)
class Len(Expr):
    def evaluate(
        self, df: DataFrame, *, context: ExecutionContext = ExecutionContext.FRAME
    ) -> Column:
        """Evaluate this expression given a dataframe for context."""
        # TODO: type is wrong
        return df.num_rows


@dataclass(slots=True)
class BooleanFunction(Expr):
    name: str
    options: Any
    arguments: list[Expr]


@dataclass(slots=True)
class Sort(Expr):
    column: Expr
    options: Any

    def evaluate(
        self, df: DataFrame, *, context: ExecutionContext = ExecutionContext.FRAME
    ) -> Column:
        """Evaluate this expression given a dataframe for context."""
        column = self.column.evaluate(df, context=context)
        (stable, nulls_last, descending) = self.options
        order, null_order = sorting.sort_order(
            [descending], nulls_last=nulls_last, num_keys=1
        )
        do_sort = plc.sorting.stable_sort if stable else plc.sorting.sort
        table = do_sort(plc.Table([column.obj]), order, null_order)
        return Column(table.columns()[0], column.name).set_sorted(
            is_sorted=plc.types.Sorted.YES, order=order[0], null_order=null_order[0]
        )


@dataclass(slots=True)
class SortBy(Expr):
    column: Expr
    by: list[Expr]
    options: Any

    def evaluate(
        self, df: DataFrame, *, context: ExecutionContext = ExecutionContext.FRAME
    ) -> Column:
        """Evaluate this expression given a dataframe for context."""
        column = self.column.evaluate(df, context=context)
        by = [b.evaluate(df, context=context) for b in self.by]
        (stable, nulls_last, descending) = self.options
        order, null_order = sorting.sort_order(
            descending, nulls_last=nulls_last, num_keys=len(self.by)
        )
        do_sort = plc.sorting.stable_sort_by_key if stable else plc.sorting.sort_by_key
        table = do_sort(
            plc.Table([column.obj]), plc.Table([c.obj for c in by]), order, null_order
        )
        return Column(table.columns()[0], column.name)


@dataclass(slots=True)
class Gather(Expr):
    values: Expr
    indices: Expr

    def evaluate(
        self, df: DataFrame, *, context: ExecutionContext = ExecutionContext.FRAME
    ) -> Column:
        """Evaluate this expression given a dataframe for context."""
        values = self.values.evaluate(df, context=context)
        indices = self.indices.evaluate(df, context=context)
        lo, hi = plc.reduce.minmax(indices.obj)
        lo = plc.interop.to_arrow(lo).as_py()
        hi = plc.interop.to_arrow(hi).as_py()
        n = df.num_rows
        if hi >= n or lo < -n:
            raise ValueError("gather indices are out of bounds")
        if indices.obj.null_count():
            bounds_policy = plc.copying.OutOfBoundsPolicy.NULLIFY
            obj = plc.replace.replace_nulls(
                indices.obj,
                plc.interop.from_arrow(pa.scalar(n), data_type=indices.obj.data_type()),
            )
        else:
            bounds_policy = plc.copying.OutOfBoundsPolicy.DONT_CHECK
            obj = indices.obj
        table = plc.copying.gather(plc.Table([values.obj]), obj, bounds_policy)
        return Column(table.columns()[0], values.name)


@dataclass(slots=True)
class Filter(Expr):
    values: Expr
    mask: Expr

    def evaluate(
        self, df: DataFrame, *, context: ExecutionContext = ExecutionContext.FRAME
    ) -> Column:
        """Evaluate this expression given a dataframe for context."""
        values = self.values.evaluate(df, context=context)
        mask = self.mask.evaluate(df, context=context)
        table = plc.stream_compaction.apply_boolean_mask(
            plc.Table([values.obj]), mask.obj
        )
        return Column(table.columns()[0], values.name).with_sorted(like=values)


@dataclass(slots=True)
class Window(Expr):
    agg: Expr
    by: None | list[Expr]
    options: Any


@dataclass(slots=True)
class Cast(Expr):
    dtype: plc.DataType
    column: Expr

    def evaluate(
        self, df: DataFrame, *, context: ExecutionContext = ExecutionContext.FRAME
    ) -> Column:
        """Evaluate this expression given a dataframe for context."""
        column = self.column.evaluate(df, context=context)
        return Column(plc.unary.cast(column.obj, self.dtype), column.name).with_sorted(
            like=column
        )


@dataclass(slots=True)
class Agg(Expr):
    column: Expr
    op: Callable[..., plc.Column]
    name: str

    _SUPPORTED: ClassVar[frozenset[str]] = frozenset(
        [
            "min",
            "max",
            "median",
            "nunique",
            "first",
            "last",
            "mean",
            "sum",
            "count",
            "std",
            "var",
            "agg_groups",
        ]
    )

    def __init__(
        self, dtype: plc.DataType, column: Expr, name: str, options: Any
    ) -> None:
        if name not in Agg._SUPPORTED:
            raise NotImplementedError(f"Unsupported aggregation {name}")
        self.dtype = dtype
        self.column = column
        self.name = name
        op = getattr(self, f"_{name}")
        if name in {"min", "max"}:
            op = partial(op, propagate_nans=options)
        elif name in {"std", "var"}:
            op = partial(op, ddof=options)
        self.op = op

    def _std(self, column: Column, *, ddof: int) -> Column:
        # TODO: handle nans
        return Column(
            plc.Column.from_scalar(
                plc.reduce.reduce(
                    column.obj, plc.aggregation.std(ddof=ddof), self.dtype
                ),
                1,
            ),
            column.name,
        )

    def _var(self, column: Column, *, ddof: int) -> Column:
        # TODO: handle nans
        return Column(
            plc.Column.from_scalar(
                plc.reduce.reduce(
                    column.obj, plc.aggregation.variance(ddof=ddof), self.dtype
                ),
                1,
            ),
            column.name,
        )

    def _sum(self, column: Column) -> Column:
        return Column(
            plc.Column.from_scalar(
                plc.reduce.reduce(column.obj, plc.aggregation.sum(), self.dtype), 1
            ),
            column.name,
        )

    def _count(self, column: Column) -> Column:
        return Column(
            plc.Column.from_scalar(
                plc.reduce.reduce(
                    column.obj,
                    plc.aggregation.count(plc.types.NullPolicy.EXCLUDE),
                    self.dtype,
                ),
                1,
            ),
            column.name,
        )

    def _min(self, column: Column, *, propagate_nans: bool) -> Column:
        if propagate_nans and column.nan_count > 0:
            return Column(
                plc.Column.from_scalar(
                    plc.interop.from_arrow(
                        pa.scalar(float("nan")), data_type=self.dtype
                    ),
                    1,
                ),
                column.name,
            )
        if column.nan_count > 0:
            column = column.mask_nans()
        return Column(
            plc.Column.from_scalar(
                plc.reduce.reduce(column.obj, plc.aggregation.min(), self.dtype), 1
            ),
            column.name,
        )

    def _max(self, column: Column, *, propagate_nans: bool) -> Column:
        if propagate_nans and column.nan_count > 0:
            return Column(
                plc.Column.from_scalar(
                    plc.interop.from_arrow(
                        pa.scalar(float("nan")), data_type=self.dtype
                    ),
                    1,
                ),
                column.name,
            )
        if column.nan_count > 0:
            column = column.mask_nans()
        return Column(
            plc.Column.from_scalar(
                plc.reduce.reduce(column.obj, plc.aggregation.max(), self.dtype), 1
            ),
            column.name,
        )

    def _median(self, column: Column) -> Column:
        return Column(
            plc.Column.from_scalar(
                plc.reduce.reduce(column.obj, plc.aggregation.median(), self.dtype),
                1,
            ),
            column.name,
        )

    def _first(self, column: Column) -> Column:
        return Column(plc.copying.slice(column.obj, [0, 1])[0], column.name)

    def _last(self, column: Column) -> Column:
        n = column.obj.size()
        return Column(plc.copying.slice(column.obj, [n - 1, n])[0], column.name)

    def _mean(self, column: Column) -> Column:
        return Column(
            plc.Column.from_scalar(
                plc.reduce.reduce(column.obj, plc.aggregation.mean(), self.dtype),
                1,
            ),
            column.name,
        )

    def _nunique(self, column: Column) -> Column:
        return Column(
            plc.Column.from_scalar(
                plc.reduce.reduce(
                    column.obj,
                    plc.aggregation.nunique(null_handling=plc.types.NullPolicy.INCLUDE),
                    self.dtype,
                ),
                1,
            ),
            column.name,
        )

    def evaluate(
        self, df, *, context: ExecutionContext = ExecutionContext.FRAME
    ) -> Column:
        """Evaluate this expression given a dataframe for context."""
        if context is not ExecutionContext.FRAME:
            raise NotImplementedError(f"Agg in context {context}")
        return self.op(self.column.evaluate(df, context=context))


@dataclass(slots=True)
class BinOp(Expr):
    left: Expr
    right: Expr
    op: plc.binaryop.BinaryOperator

    _MAPPING: ClassVar[dict[pl_expr.PyOperator, plc.binaryop.BinaryOperator]] = {
        pl_expr.PyOperator.Eq: plc.binaryop.BinaryOperator.EQUAL,
        pl_expr.PyOperator.EqValidity: plc.binaryop.BinaryOperator.NULL_EQUALS,
        pl_expr.PyOperator.NotEq: plc.binaryop.BinaryOperator.NOT_EQUAL,
        pl_expr.PyOperator.NotEqValidity: plc.binaryop.BinaryOperator.NULL_NOT_EQUALS,
        pl_expr.PyOperator.Lt: plc.binaryop.BinaryOperator.LESS,
        pl_expr.PyOperator.LtEq: plc.binaryop.BinaryOperator.LESS_EQUAL,
        pl_expr.PyOperator.Gt: plc.binaryop.BinaryOperator.GREATER,
        pl_expr.PyOperator.GtEq: plc.binaryop.BinaryOperator.GREATER_EQUAL,
        pl_expr.PyOperator.Plus: plc.binaryop.BinaryOperator.ADD,
        pl_expr.PyOperator.Minus: plc.binaryop.BinaryOperator.SUB,
        pl_expr.PyOperator.Multiply: plc.binaryop.BinaryOperator.MUL,
        pl_expr.PyOperator.Divide: plc.binaryop.BinaryOperator.DIV,
        pl_expr.PyOperator.TrueDivide: plc.binaryop.BinaryOperator.TRUE_DIV,
        pl_expr.PyOperator.FloorDivide: plc.binaryop.BinaryOperator.FLOOR_DIV,
        pl_expr.PyOperator.Modulus: plc.binaryop.BinaryOperator.PYMOD,
        pl_expr.PyOperator.And: plc.binaryop.BinaryOperator.BITWISE_AND,
        pl_expr.PyOperator.Or: plc.binaryop.BinaryOperator.BITWISE_OR,
        pl_expr.PyOperator.Xor: plc.binaryop.BinaryOperator.BITWISE_XOR,
        pl_expr.PyOperator.LogicalAnd: plc.binaryop.BinaryOperator.LOGICAL_AND,
        pl_expr.PyOperator.LogicalOr: plc.binaryop.BinaryOperator.LOGICAL_OR,
    }

    def evaluate(
        self, df: DataFrame, *, context: ExecutionContext = ExecutionContext.FRAME
    ) -> Column:
        """Evaluate this expression given a dataframe for context."""
        left = self.left.evaluate(df, context=context)
        right = self.right.evaluate(df, context=context)
        return Column(
            plc.binaryop.binary_operation(left.obj, right.obj, self.op, self.dtype),
            left.name,
        )
