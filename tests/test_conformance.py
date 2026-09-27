"""Upstream docutils parser test suite and differential fuzzing.

The upstream suite needs a docutils source tree (the sdist ships the tests):
set ``DOCUTILS_SRC=/path/to/docutils-X.Y`` to run it.
"""

from __future__ import annotations

import os
import random
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).parent


@pytest.mark.skipif("DOCUTILS_SRC" not in os.environ, reason="set DOCUTILS_SRC to a docutils sdist")
def test_upstream_parser_suite():
    result = subprocess.run(
        [sys.executable, str(HERE / "conformance" / "run_docutils_suite.py"), os.environ["DOCUTILS_SRC"]],
        capture_output=True, text=True, timeout=1200)
    assert result.returncode == 0, result.stdout[-4000:]


def test_differential_fuzz_quick():
    sys.path.insert(0, str(HERE))
    try:
        import fuzz_differential as fuzz
    finally:
        sys.path.pop(0)
    rng = random.Random(20260927)
    failures = []
    for _ in range(300):
        text = fuzz.gen_document(rng)
        if rng.random() < 0.3:
            text = fuzz.mutate(rng, text)
        result = fuzz.check(text)
        if result is not None:
            failures.append((result[0], text))
    assert not failures, failures[:3]
