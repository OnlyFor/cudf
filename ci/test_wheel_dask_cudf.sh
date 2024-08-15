#!/bin/bash
# Copyright (c) 2023-2024, NVIDIA CORPORATION.

set -eou pipefail

RAPIDS_PY_CUDA_SUFFIX="$(rapids-wheel-ctk-name-gen ${RAPIDS_CUDA_VERSION})"
RAPIDS_PY_WHEEL_NAME="dask_cudf_${RAPIDS_PY_CUDA_SUFFIX}" RAPIDS_PY_WHEEL_PURE="1" rapids-download-wheels-from-s3 ./dist

# Download the cudf built in the previous step
RAPIDS_PY_WHEEL_NAME="cudf_${RAPIDS_PY_CUDA_SUFFIX}" rapids-download-wheels-from-s3 ./local-cudf-dep
python -m pip install ./local-cudf-dep/cudf*.whl

rapids-logger "Install dask_cudf and test requirements"
PIP_PACKAGE=$(echo ./dist/dask_cudf*.whl | head -n1)
# Use `package[test]` to install latest test dependencies or explicitly install oldest.
if [[ $RAPIDS_DEPENDENCIES != "oldest" ]]; then
    python -m pip install -v ${PIP_PACKAGE}[test]
else
    rapids-dependency-file-generator \
        --output requirements \
        --file-key py_test_dask_cudf \
        --matrix "cuda=${RAPIDS_CUDA_VERSION%.*};arch=$(arch);py=${RAPIDS_PY_VERSION};dependencies=${RAPIDS_DEPENDENCIES}" \
      | tee oldest-dependencies.txt

    python -m pip install -v ${PIP_PACKAGE} -r oldest-dependencies.txt
fi

RESULTS_DIR=${RAPIDS_TESTS_DIR:-"$(mktemp -d)"}
RAPIDS_TESTS_DIR=${RAPIDS_TESTS_DIR:-"${RESULTS_DIR}/test-results"}/
mkdir -p "${RAPIDS_TESTS_DIR}"

# Run tests in dask_cudf/tests and dask_cudf/io/tests
rapids-logger "pytest dask_cudf (dask-expr)"
pushd python/dask_cudf/dask_cudf
DASK_DATAFRAME__QUERY_PLANNING=True python -m pytest \
  --junitxml="${RAPIDS_TESTS_DIR}/junit-dask-cudf.xml" \
  --numprocesses=8 \
  .
popd

# Run tests in dask_cudf/tests and dask_cudf/io/tests (legacy)
rapids-logger "pytest dask_cudf (legacy)"
pushd python/dask_cudf/dask_cudf
DASK_DATAFRAME__QUERY_PLANNING=False python -m pytest \
  --junitxml="${RAPIDS_TESTS_DIR}/junit-dask-cudf-legacy.xml" \
  --numprocesses=8 \
  .
popd
