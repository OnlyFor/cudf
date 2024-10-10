# Copyright (c) 2024, NVIDIA CORPORATION.

import pyarrow as pa
import pylibcudf as plc
import pytest
from utils import assert_table_eq

mixed_pyarrow_tables = [
    pa.table([]),
    pa.table({"a": [1, 2, 3], "b": [4, 5, 6], "c": [7, 8, 9]}),
    pa.table({"a": [1, 2, 3]}),
    pa.table({"a": [1], "b": [2], "c": [3]}),
    pa.table({"a": ["a", "bb", "ccc"]}),
]


@pytest.mark.parametrize("arrow_tbl", mixed_pyarrow_tables)
def test_pack_and_unpack(arrow_tbl):
    plc_tbl = plc.interop.from_arrow(arrow_tbl)
    packed = plc.contiguous_split.pack(plc_tbl)

    res = plc.contiguous_split.unpack(packed)
    assert_table_eq(arrow_tbl, res)


@pytest.mark.parametrize("arrow_tbl", mixed_pyarrow_tables)
def test_pack_and_unpack_from_memoryviews(arrow_tbl):
    plc_tbl = plc.interop.from_arrow(arrow_tbl)
    packed = plc.contiguous_split.pack(plc_tbl)

    metadata, gpudata = packed.release()

    with pytest.raises(ValueError, match="Cannot release empty"):
        packed.release()

    del packed  # `metadata` and `gpudata` will survive

    res = plc.contiguous_split.unpack_from_memoryviews(metadata, gpudata)
    assert_table_eq(arrow_tbl, res)
