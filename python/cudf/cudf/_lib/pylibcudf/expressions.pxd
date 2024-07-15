# Copyright (c) 2024, NVIDIA CORPORATION.
from libcpp.memory cimport unique_ptr
from libcpp.string cimport string

from cudf._lib.pylibcudf.libcudf.expressions cimport (
    ast_operator,
    expression,
    table_reference,
)
from cudf._lib.pylibcudf.libcudf.scalar.scalar cimport scalar


cdef class Expression:
    cdef unique_ptr[expression] c_obj

cdef class Literal(Expression):
    cdef unique_ptr[scalar] c_scalar

cdef class ColumnReference(Expression):
    pass

cdef class Operation(Expression):
    # Hold on to the input expressions so
    # they don't get gc'ed
    cdef Expression right
    cdef Expression left

cdef class ColumnNameReference(Expression):
    pass
