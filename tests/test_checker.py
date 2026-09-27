"""Tests of the native checker (``bin/docodin-check``) against docutils."""

from __future__ import annotations

import os
import random
import subprocess

import lint_differential as L
import pytest

pytestmark = pytest.mark.skipif(not os.path.exists(L.BINARY), reason="bin/docodin-check not built")

CASES = {
    "inline": "Para *emphasis and ``literal\n",
    "sections": "A\n===\n\nB\n---\n\nC\n===\n\nD\n~~~\n\nText\n\n===\nE\n===\n\nx\n",
    "lists": "- item\ntext\n\n1. one\n3. three\n",
    "tables": "+---+---+\n| a| b |\n+---+---+\n\ntext\n",
    "directive content": ".. note::\n\n   *unclosed\n\n.. topic:: *T\n\n   - x\n   y\n",
    "substitution": ".. |x| replace:: *y\n\n.. |z| image::\n",
    "line length": "x" * 20000 + "\n",
}


@pytest.mark.parametrize("name", sorted(CASES))
def test_case(tmp_path, name):
    path = tmp_path / "case.rst"
    path.write_text(CASES[name], encoding="utf-8")
    expected, got = L.compare(CASES[name], str(path))
    assert got == expected


def test_generated(tmp_path):
    rng = random.Random(3)
    for i in range(300):
        text = L.gen_document(rng)
        if rng.random() < 0.3:
            text = L.mutate(rng, text)
        path = tmp_path / f"case{i}.rst"
        path.write_text(text, encoding="utf-8")
        expected, got = L.compare(text, str(path))
        assert got == expected, text


def test_exit_status_and_levels(tmp_path):
    path = tmp_path / "bad.rst"
    path.write_text("Text *x\n\n.. [1] a\n.. [1] b\n", encoding="utf-8")

    def run(*args: str) -> subprocess.CompletedProcess:
        return subprocess.run([L.BINARY, *args, str(path)], capture_output=True, text=True,
                              check=False)

    assert run().returncode == 0  # warnings only (exit level: error)
    assert run("--exit-status=warning").returncode == 1
    assert run("--report=none").stderr == ""
    assert "(WARNING/2)" in run("--report=2", "--error-format=docutils").stderr


def test_elm_reports(tmp_path):
    path = tmp_path / "bad.rst"
    path.write_text("Title\n=====\n\nSome *emphasis.\n\n- item\ncontinued\n", encoding="utf-8")
    proc = subprocess.run([L.BINARY, "--color=never", str(path)], capture_output=True, text=True,
                          check=False)
    report = proc.stderr
    assert "-- UNCLOSED EMPHASIS " in report and "bad.rst:4:6\n" in report
    assert "4| Some *emphasis.\n        ^\n" in report
    assert "Hint: Close the emphasis with a matching `*`" in report
    assert "-- MISSING BLANK LINE " in report and "6| - item\n7| continued\n   ^^^^^^^^^\n" in report
    assert report.rstrip().endswith("Found 2 warnings in 1 file.")
    # report text is wrapped at 80 columns (headers carry the path as given)
    assert all(len(line) <= 80 for line in report.splitlines() if not line.startswith("-- "))
    colored = subprocess.run([L.BINARY, "--color=always", str(path)], capture_output=True,
                             text=True, check=False).stderr
    assert "\x1b[33m-- UNCLOSED EMPHASIS" in colored


def test_stdin_and_missing_file(tmp_path):
    proc = subprocess.run([L.BINARY, "--error-format=docutils", "-"], input="*x\n", capture_output=True,
                          text=True, check=False)
    assert proc.stderr.startswith("<stdin>:1: (WARNING/2) Inline emphasis")
    proc = subprocess.run([L.BINARY, str(tmp_path / "missing.rst")], capture_output=True, text=True,
                          check=False)
    assert proc.returncode == 1 and "cannot read" in proc.stderr
    assert subprocess.run([L.BINARY, "--bogus"], capture_output=True, check=False).returncode == 2
