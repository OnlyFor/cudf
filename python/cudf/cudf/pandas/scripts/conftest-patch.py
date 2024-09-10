# SPDX-FileCopyrightText: Copyright (c) 2023-2024, NVIDIA CORPORATION & AFFILIATES.
# All rights reserved.
# SPDX-License-Identifier: Apache-2.0

import contextlib
import json
import multiprocessing
import os
import sys
from functools import wraps

import pytest


def replace_kwargs(new_kwargs):
    def wrapper(func):
        @wraps(func)
        def wrapped(*args, **kwargs):
            kwargs.update(new_kwargs)
            return func(*args, **kwargs)

        return wrapped

    return wrapper


@contextlib.contextmanager
def null_assert_warnings(*args, **kwargs):
    try:
        yield []
    finally:
        pass


@pytest.fixture(scope="session", autouse=True)  # type: ignore
def patch_testing_functions():
    tm.assert_produces_warning = null_assert_warnings
    pytest.raises = replace_kwargs({"match": None})(pytest.raises)


# Dictionary to store function call counts
manager = multiprocessing.Manager()
function_call_counts = manager.dict()

# The specific function to track
FUNCTION_NAME = {"_slow_function_call", "_fast_function_call"}


def trace_calls(frame, event, arg):
    if event != "call":
        return
    code = frame.f_code
    func_name = code.co_name
    if func_name in FUNCTION_NAME:
        function_call_counts[func_name] = (
            function_call_counts.get(func_name, 0) + 1
        )


def pytest_sessionstart(session):
    # Set the profile function to trace calls
    sys.setprofile(trace_calls)


def pytest_sessionfinish(session, exitstatus):
    # Remove the profile function
    sys.setprofile(None)


@pytest.hookimpl(tryfirst=True)
def pytest_runtest_setup(item):
    # Check if this is the first test in the file
    if item.nodeid.split("::")[0] != getattr(
        pytest_runtest_setup, "current_file", None
    ):
        # If it's a new file, reset the function call counts
        global function_call_counts
        function_call_counts = manager.dict()
        pytest_runtest_setup.current_file = item.nodeid.split("::")[0]


@pytest.hookimpl(trylast=True)
def pytest_runtest_teardown(item, nextitem):
    # Check if this is the last test in the file
    if (
        nextitem is None
        or nextitem.nodeid.split("::")[0] != item.nodeid.split("::")[0]
    ):
        # Write the function call counts to a file
        worker_id = os.getenv("PYTEST_XDIST_WORKER", "master")
        output_file = f'function_call_counts_{os.path.basename(item.nodeid.split("::")[0])}_{worker_id}.json'
        with open(output_file, "w") as f:
            json.dump(function_call_counts, f, indent=4)
        print(f"Function call counts have been written to {output_file}")


@pytest.hookimpl(tryfirst=True)
def pytest_configure(config):
    if hasattr(config, "workerinput"):
        # Running in xdist worker
        global function_call_counts
        function_call_counts = manager.dict()


@pytest.hookimpl(trylast=True)
def pytest_unconfigure(config):
    if hasattr(config, "workerinput"):
        # Running in xdist worker
        worker_id = config.workerinput["workerid"]
        output_file = f"function_call_counts_worker_{worker_id}.json"
        with open(output_file, "w") as f:
            json.dump(function_call_counts, f, indent=4)
        print(f"Function call counts have been written to {output_file}")


sys.path.append(os.path.dirname(__file__))
