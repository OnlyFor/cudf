# Copyright (c) 2020-2024, NVIDIA CORPORATION.

from numba.np import numpy_support

import cudf
from cudf._lib.types import SUPPORTED_NUMPY_TO_LIBCUDF_TYPES
from cudf.core._internals.expressions import parse_expression
from cudf.core.buffer import acquire_spill_lock, as_buffer
from cudf.utils import cudautils

from cython.operator cimport dereference
from libc.stdint cimport uintptr_t
from libcpp.memory cimport unique_ptr
from libcpp.pair cimport pair
from libcpp.string cimport string
from libcpp.utility cimport move

cimport pylibcudf.libcudf.transform as libcudf_transform
from pylibcudf cimport transform as plc_transform
from pylibcudf.expressions cimport Expression
from pylibcudf.libcudf.column.column cimport column
from pylibcudf.libcudf.column.column_view cimport column_view
from pylibcudf.libcudf.expressions cimport expression
from pylibcudf.libcudf.table.table cimport table
from pylibcudf.libcudf.table.table_view cimport table_view
from pylibcudf.libcudf.types cimport (
    bitmask_type,
    data_type,
    size_type,
    type_id,
)
from rmm._lib.device_buffer cimport DeviceBuffer, device_buffer

from cudf._lib.column cimport Column
from cudf._lib.types cimport underlying_type_t_type_id
from cudf._lib.utils cimport (
    columns_from_unique_ptr,
    data_from_table_view,
    table_view_from_columns,
)


@acquire_spill_lock()
def bools_to_mask(Column col):
    """
    Given an int8 (boolean) column, compress the data from booleans to bits and
    return a Buffer
    """
    mask, _ = plc_transform.bools_to_mask(
        input.to_pylibcudf(mode="read")
    )
    return as_buffer(mask)


@acquire_spill_lock()
def mask_to_bools(object mask_buffer, size_type begin_bit, size_type end_bit):
    """
    Given a mask buffer, returns a boolean column representng bit 0 -> False
    and 1 -> True within range of [begin_bit, end_bit),
    """
    if not isinstance(mask_buffer, cudf.core.buffer.Buffer):
        raise TypeError("mask_buffer is not an instance of "
                        "cudf.core.buffer.Buffer")
    plc_columns = plc_transform.mask_to_bools(
        mask_buffer.get_ptr(mode="read"), begin_bit, end_bit
    )
    return Column.from_pylibcudf(plc_column)


@acquire_spill_lock()
def nans_to_nulls(Column input):
    mask, _ = plc_transform.nans_to_nulls(
        input.to_pylibcudf(mode="read")
    )
    return as_buffer(mask)


@acquire_spill_lock()
def transform(Column input, op):
    nb_type = numpy_support.from_dtype(input.dtype)
    nb_signature = (nb_type,)
    compiled_op = cudautils.compile_udf(op, nb_signature)
    np_dtype = cudf.dtype(compiled_op[1])

    plc_column = plc_transform.transform(
        input.to_pylibcudf(mode="read"),
        compiled_op[0],
        plc.column._datatype_from_dtype_desc(np_dtype.str[1:]),
        True
    )
    return Column.from_pylibcudf(plc_column)


def table_encode(list source_columns):
    plc_table, plc_column = plc_transform.transform(
        plc.Table([col.to_pylibcudf(mode="read") for col in source_columns])
    )

    return (
        [Column.from_pylibcudf(col) for col in plc_table.columns()]
        Column.from_pylibcudf(plc_column)
    )


def one_hot_encode(Column input_column, Column categories):
    plc_table = plc_transform.one_hot_encode(
        input_column.to_pylibcudf(mode="read"),
        categories.to_pylibcudf(mode="read"),
    )
    result_columns = [
        Column.from_pylibcudf(col, data_ptr_exposed=True)
        for col in plc_table.columns()
    ]
    return dict(zip(pylist_categories, result_columns)), None


@acquire_spill_lock()
def compute_column(list columns, tuple column_names, expr: str):
    """Compute a new column by evaluating an expression on a set of columns.

    Parameters
    ----------
    columns : list
        The set of columns forming the table to evaluate the expression on.
    column_names : tuple[str]
        The names associated with each column. These names are necessary to map
        column names in the expression to indices in the provided list of
        columns, which are what will be used by libcudf to evaluate the
        expression on the table.
    expr : str
        The expression to evaluate.
    """
    visitor = parse_expression(expr, column_names)

    # At the end, all the stack contains is the expression to evaluate.
    cdef Expression cudf_expr = visitor.expression
    cdef table_view tbl = table_view_from_columns(columns)
    cdef unique_ptr[column] col
    with nogil:
        col = move(
            libcudf_transform.compute_column(
                tbl,
                <expression &> dereference(cudf_expr.c_obj.get())
            )
        )
    return Column.from_unique_ptr(move(col))
