"""Differential test of the native checker (``bin/docodin-check``) against docutils.

Parses generated documents with docutils (parser only, no transforms) and
compares the reported parser messages with ``bin/docodin-check --error-format=docutils --report=warning``.
Messages produced by directives, roles and the document's name registry are
not the checker's (see odin/check/check.odin) and are ignored.

    python tests/lint_differential.py [--cases N] [--seed S] [--corpus DIR ...]
"""

from __future__ import annotations

import argparse
import io
import os
import random
import re
import subprocess
import sys
import tempfile

import docutils.frontend
import docutils.parsers.rst
import docutils.utils

sys.path.insert(0, os.path.dirname(__file__))
from fuzz_differential import gen_document, mutate

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(ROOT, "bin", "docodin-check")

# messages created outside the parser proper
HOST_MESSAGE = re.compile(
    r'directive|Unknown interpreted text role|interpreted text role|Duplicate (explicit|implicit)'
    r'|Duplicate substitution|Substitution definition|Unknown target name'
    r'|not supported in a substitution definition|Problematic content in substitution definition'
    r'|No role entry|No directive entry|Trying ".*" as canonical|Problems with ".*"'
    r'|Cannot analyze code|(PEP|RFC) number must be')

MESSAGE_START = re.compile(r"^(?:<[^>]*>|[^:\n]*):(\d*): \((DEBUG|INFO|WARNING|ERROR|SEVERE)/(\d)\) ",
                           re.MULTILINE)


def split_messages(text: str) -> list[str]:
    starts = [m.start() for m in MESSAGE_START.finditer(text)]
    return [text[a:b].rstrip("\n") for a, b in zip(starts, [*starts[1:], len(text)], strict=False)]


def docutils_messages(text: str, path: str) -> list[str]:
    stream = io.StringIO()
    settings = docutils.frontend.get_default_settings(docutils.parsers.rst.Parser)
    settings.warning_stream = stream
    settings.report_level = 2
    settings.halt_level = 5
    document = docutils.utils.new_document(path, settings)
    docutils.parsers.rst.Parser().parse(text, document)
    return [m for m in split_messages(stream.getvalue()) if not HOST_MESSAGE.search(m)]


def native_messages(path: str) -> list[str]:
    proc = subprocess.run([BINARY, "--error-format=docutils", "--report=warning",
                           "--exit-status=none", path], capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"exit status {proc.returncode}: {proc.stderr}")
    return split_messages(proc.stderr)


def compare(text: str, path: str) -> tuple[list[str], list[str]]:
    cwd = os.getcwd()
    os.chdir(os.path.dirname(path))  # relative includes
    try:
        expected = sorted(docutils_messages(text, path))
    finally:
        os.chdir(cwd)
    got = sorted(m for m in native_messages(path) if not HOST_MESSAGE.search(m))
    return expected, got


def check_corpus(dirs: list[str]) -> int:
    files = sorted(os.path.join(root, name) for d in dirs for root, _, names in os.walk(d)
                   for name in names if name.endswith((".rst", ".txt")))
    failures = compared = 0
    for path in files:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        expected, got = compare(text, path)
        compared += len(expected)
        if expected != got:
            failures += 1
            print(f"--- {path}\nexpected: {expected}\ngot:      {got}\n")
    print(f"{len(files) - failures}/{len(files)} files identical ({compared} messages)")
    return 1 if failures else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", type=int, default=500)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--corpus", nargs="*", default=[], help="compare the *.rst/*.txt files of DIR")
    args = ap.parse_args()
    if args.corpus:
        return check_corpus(args.corpus)
    rng = random.Random(args.seed)
    failures = 0
    compared = 0
    with tempfile.TemporaryDirectory() as tmp:
        for i in range(args.cases):
            text = gen_document(rng)
            if rng.random() < 0.3:
                text = mutate(rng, text)
            path = os.path.join(tmp, f"case{i}.rst")
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
            expected = sorted(docutils_messages(text, path))
            got = sorted(m for m in native_messages(path) if not HOST_MESSAGE.search(m))
            compared += len(expected)
            if expected != got:
                failures += 1
                if failures <= 5:
                    print(f"--- case {i}\n{text!r}\nexpected: {expected}\ngot:      {got}\n")
    print(f"{args.cases - failures}/{args.cases} identical ({compared} messages)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
