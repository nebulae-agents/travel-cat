#!/usr/bin/env python3
"""Run the complete runtime suite; annotate only validated pre-run test IDs.

Normal unittest diagnostics and exit status remain intact. GitHub annotations
never include exception text, tracebacks, subtest parameters or a post-run ID.
"""
import os
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
SAFE_ID = re.compile(r"[A-Za-z0-9_.]+", re.ASCII)
MAX_ANNOTATIONS = 10
UNKNOWN_FIXTURE_ID = "unittest.suite.unknown_fixture_failure"
_ERROR_HOLDER = unittest.suite._ErrorHolder


def discovered_ids(suite):
    """Bind the exact discovered objects to their safe IDs before any tests run."""
    ids = {}
    for test in suite:
        if isinstance(test, unittest.TestSuite):
            ids.update(discovered_ids(test))
        else:
            try:
                value = test.id()
            except Exception:
                continue  # Never replace ordinary runner diagnostics with metadata errors.
            if isinstance(value, str) and SAFE_ID.fullmatch(value):
                ids[id(test)] = (test, value)  # Retain exact objects after TestSuite discards them.
    return ids


def discovered_fixture_ids(ids):
    """Exact stdlib fixture descriptions derived only from discovered classes/modules."""
    fixtures = {}
    for test, _ in ids.values():
        cls = type(test)
        class_name = cls.__module__ + "." + cls.__qualname__
        for name, phases in ((class_name, ("setUpClass", "tearDownClass")),
                             (cls.__module__, ("setUpModule", "tearDownModule"))):
            if SAFE_ID.fullmatch(name):
                for phase in phases:
                    fixtures[phase + " (" + name + ")"] = name + "." + phase
    return fixtures


class FailureIDResult(unittest.TextTestResult):
    def __init__(self, *args, ids):
        super().__init__(*args)
        self.ids = ids
        self.fixture_ids = discovered_fixture_ids(ids)
        self.failed_ids = []

    def remember(self, test):
        entry = self.ids.get(id(test))
        value = entry[1] if entry is not None and entry[0] is test else None
        if type(test) is _ERROR_HOLDER:
            # Never publish the holder's dynamic description; match an exact
            # precomputed description or emit only the fixed unknown marker.
            description = test.description
            value = self.fixture_ids.get(description, UNKNOWN_FIXTURE_ID) if type(description) is str else UNKNOWN_FIXTURE_ID
        if value is not None and value not in self.failed_ids and len(self.failed_ids) < MAX_ANNOTATIONS:
            self.failed_ids.append(value)

    def addFailure(self, test, err):
        self.remember(test)
        super().addFailure(test, err)

    def addError(self, test, err):
        self.remember(test)
        super().addError(test, err)

    def addSubTest(self, test, subtest, err):
        if err is not None:
            self.remember(test)  # Parent object only; never stringify subtest parameters.
        super().addSubTest(test, subtest, err)

    def addUnexpectedSuccess(self, test):
        self.remember(test)
        super().addUnexpectedSuccess(test)


def run(suite=None, *, stream=None, annotation_stream=None, github_actions=None):
    if suite is None:
        suite = unittest.defaultTestLoader.discover(
            start_dir=str(ROOT / "Tests/AgentRuntimeTests"), pattern="test_*.py")
    ids = discovered_ids(suite)
    result = unittest.TextTestRunner(
        stream=stream, resultclass=lambda *args: FailureIDResult(*args, ids=ids)).run(suite)
    enabled = os.environ.get("GITHUB_ACTIONS") if github_actions is None else github_actions
    if enabled == "true":
        for value in result.failed_ids:
            print("::error title=Runtime contract failed " + value + "::Agent runtime contract did not pass.",
                  file=sys.stdout if annotation_stream is None else annotation_stream)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(run())
