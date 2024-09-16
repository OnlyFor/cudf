#!/bin/bash
# Copyright (c) 2022-2024, NVIDIA CORPORATION.

set -euo pipefail

rapids-configure-conda-channels

source rapids-configure-sccache

source rapids-date-string

export CMAKE_GENERATOR=Ninja

rapids-print-env

rapids-generate-version > ./VERSION

rapids-logger "Begin py build"

CPP_CHANNEL=$(rapids-download-conda-from-s3 cpp)
LIBRMM_CHANNEL=$(rapids-get-pr-conda-artifact rmm 1678 cpp)
RMM_CHANNEL=$(rapids-get-pr-conda-artifact rmm 1678 python)

# TODO: Remove `--no-test` flag once importing on a CPU
# node works correctly
# With boa installed conda build forwards to the boa builder

RAPIDS_PACKAGE_VERSION=$(head -1 ./VERSION) rapids-conda-retry mambabuild \
  --no-test \
  --channel "${CPP_CHANNEL}" \
  --channel "${LIBRMM_CHANNEL}" \
  --channel "${RMM_CHANNEL}" \
  conda/recipes/pylibcudf

RAPIDS_PACKAGE_VERSION=$(head -1 ./VERSION) rapids-conda-retry mambabuild \
  --no-test \
  --channel "${CPP_CHANNEL}" \
  --channel "${RAPIDS_CONDA_BLD_OUTPUT_DIR}" \
  --channel "${LIBRMM_CHANNEL}" \
  --channel "${RMM_CHANNEL}" \
  conda/recipes/cudf

RAPIDS_PACKAGE_VERSION=$(head -1 ./VERSION) rapids-conda-retry mambabuild \
  --no-test \
  --channel "${CPP_CHANNEL}" \
  --channel "${RAPIDS_CONDA_BLD_OUTPUT_DIR}" \
  --channel "${LIBRMM_CHANNEL}" \
  --channel "${RMM_CHANNEL}" \
  conda/recipes/dask-cudf

RAPIDS_PACKAGE_VERSION=$(head -1 ./VERSION) rapids-conda-retry mambabuild \
  --no-test \
  --channel "${CPP_CHANNEL}" \
  --channel "${RAPIDS_CONDA_BLD_OUTPUT_DIR}" \
  --channel "${LIBRMM_CHANNEL}" \
  --channel "${RMM_CHANNEL}" \
  conda/recipes/cudf_kafka

RAPIDS_PACKAGE_VERSION=$(head -1 ./VERSION) rapids-conda-retry mambabuild \
  --no-test \
  --channel "${CPP_CHANNEL}" \
  --channel "${RAPIDS_CONDA_BLD_OUTPUT_DIR}" \
  --channel "${LIBRMM_CHANNEL}" \
  --channel "${RMM_CHANNEL}" \
  conda/recipes/custreamz


rapids-upload-conda-to-s3 python
