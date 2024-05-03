# Copyright (c) 2024, NVIDIA CORPORATION.

import hashlib
import struct

import mmh3
import numpy as np
import pandas as pd
import pyarrow as pa
import pytest
import xxhash
from utils import assert_column_eq, assert_table_eq

import cudf._lib.pylibcudf as plc

SEED = 0
METHODS = ["md5", "sha1", "sha224", "sha256", "sha384", "sha512"]


@pytest.fixture
def pa_input_column(pa_type):
    if pa.types.is_integer(pa_type) or pa.types.is_floating(pa_type):
        return pa.array([1, 2, 3], type=pa_type)
    elif pa.types.is_string(pa_type):
        return pa.array(["a", "b", "c"], type=pa_type)
    elif pa.types.is_boolean(pa_type):
        return pa.array([True, True, False], type=pa_type)
    elif pa.types.is_list(pa_type):
        # TODO: Add heterogenous sizes
        return pa.array([[1], [2], [3]], type=pa_type)
    elif pa.types.is_struct(pa_type):
        return pa.array([{"v": 1}, {"v": 2}, {"v": 3}], type=pa_type)
    raise ValueError("Unsupported type")


@pytest.fixture()
def input_column(pa_input_column):
    return plc.interop.from_arrow(pa_input_column)


@pytest.fixture(scope="module")
def list_struct_table():
    data = pa.Table.from_pydict(
        {
            "list": [[1, 2, 3], [4, 5, 6], [7, 8, 9]],
            "struct": [{"a": 1, "b": 2}, {"a": 3, "b": 4}, {"a": 5, "b": 6}],
        }
    )
    return data


def python_hash_value(x, method):
    if isinstance(x, str):
        binary = str(x).encode()
    elif isinstance(x, float):
        binary = struct.pack("<d", x)
    elif isinstance(x, bool):
        binary = x.to_bytes(1, byteorder="little", signed=True)
    elif isinstance(x, int):
        binary = x.to_bytes(8, byteorder="little", signed=True)
    elif isinstance(x, np.ndarray):
        binary = x.tobytes()
    else:
        raise NotImplementedError
    if method == "murmurhash3_x86_32":
        # reimplement libcudf hash combine for a single colum
        seed = plc.hashing.LIBCUDF_DEFAULT_HASH_SEED
        hashval = mmh3.hash(binary, seed)
        return seed ^ (hashval + 0x9E3779B9 + (seed << 6) + (seed >> 2))
    elif method == "murmurhash3_x64_128":
        hasher = mmh3.mmh3_x64_128(seed=plc.hashing.LIBCUDF_DEFAULT_HASH_SEED)
        hasher.update(binary)
        # libcudf returns a tuple of two 64-bit integers
        return hasher.utupledigest()
    elif method == "xxhash_64":
        return xxhash.xxh64(
            binary, seed=plc.hashing.LIBCUDF_DEFAULT_HASH_SEED
        ).intdigest()
    else:
        return getattr(hashlib, method)(binary).hexdigest()


@pytest.mark.parametrize(
    "method", ["sha1", "sha224", "sha256", "sha384", "sha512"]
)
def test_hash_column_sha(pa_input_column, method):
    plc_tbl = plc.interop.from_arrow(
        pa.Table.from_arrays([pa_input_column], names=["data"])
    )
    plc_hasher = getattr(plc.hashing, method)

    if isinstance(pa_input_column.type, (pa.ListType, pa.StructType)):
        with pytest.raises(TypeError):
            plc_hasher(plc_tbl)
        return

    expect = pa.Array.from_pandas(
        pa_input_column.to_pandas().apply(python_hash_value, args=(method,))
    )
    got = plc_hasher(plc_tbl)
    assert_column_eq(got, expect)


def test_hash_column_md5(pa_input_column):
    plc_tbl = plc.interop.from_arrow(
        pa.Table.from_arrays([pa_input_column], names=["data"])
    )

    if isinstance(pa_input_column.type, pa.StructType):
        with pytest.raises(TypeError):
            plc.hashing.md5(plc_tbl)
        return

    expect = pa.Array.from_pandas(
        pa_input_column.to_pandas().apply(python_hash_value, args=("md5",))
    )
    got = plc.hashing.md5(plc_tbl)
    assert_column_eq(got, expect)


def test_hash_column_xxhash64(pa_input_column):
    plc_tbl = plc.interop.from_arrow(
        pa.Table.from_arrays([pa_input_column], names=["data"])
    )

    expect = pa.Array.from_pandas(
        pa_input_column.to_pandas().apply(
            python_hash_value, args=("xxhash_64",)
        )
    )
    got = plc.hashing.xxhash_64(plc_tbl, 0)
    assert_column_eq(got, expect)


@pytest.mark.parametrize(
    "method", ["sha1", "sha224", "sha256", "sha384", "sha512"]
)
@pytest.mark.parametrize("dtype", ["list", "struct"])
def test_sha_list_struct_err(list_struct_table, dtype, method):
    err_types = list_struct_table.select([dtype])
    plc_tbl = plc.interop.from_arrow(err_types)
    plc_hasher = getattr(plc.hashing, method)

    with pytest.raises(TypeError):
        plc_hasher(plc_tbl)


def test_murmurhash3_x86_32(pa_input_column):
    plc_tbl = plc.interop.from_arrow(
        pa.Table.from_arrays([pa_input_column], names=["data"])
    )
    got = plc.hashing.murmurhash3_x86_32(plc_tbl, 0)
    expect = pa.Array.from_pandas(
        pa_input_column.to_pandas().apply(
            python_hash_value, args=("murmurhash3_x86_32",)
        ),
        type=pa.uint32(),
    )
    assert_column_eq(got, expect)


def test_murmurhash3_x64_128(pa_input_column):
    plc_tbl = plc.interop.from_arrow(
        pa.Table.from_arrays([pa_input_column], names=["data"])
    )
    got = plc.hashing.murmurhash3_x64_128(plc_tbl, 0)
    tuples = pa_input_column.to_pandas().apply(
        python_hash_value, args=("murmurhash3_x64_128",)
    )
    expect = pa.Table.from_pandas(
        pd.DataFrame(
            {
                0: tuples.apply(lambda tup: np.uint64(tup[0])),
                1: tuples.apply(lambda tup: np.uint64(tup[1])),
            }
        )
    )

    assert_table_eq(got, expect)
