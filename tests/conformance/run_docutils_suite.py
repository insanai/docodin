"""Run the upstream docutils reST parser test suite against docodin.

Usage: python tests/conformance/run_docutils_suite.py <docutils-source-dir>
       [--native-only] [-v] [-k pattern]

The docutils source distribution (sdist) ships ``test/test_parsers`` with
input/expected pseudo-XML pairs.  This runner patches docutils so that every
``docutils.parsers.rst.Parser`` parses via docodin, runs the suite, and reports
a per-case pass rate.
"""

from __future__ import annotations

import argparse
import os
import signal
import sys
import unittest


class CaseResult(unittest.TestResult):
    def __init__(self, verbose: bool) -> None:
        super().__init__()
        self.verbose = verbose
        self.passed = 0
        self.failed: list[tuple[str, str]] = []

    def addSubTest(self, test, subtest, err):
        if err is None:
            self.passed += 1
        else:
            self.failed.append((str(subtest), self._exc_info_to_string(err, test)))

    def addSuccess(self, test):
        self.passed += 1

    def addFailure(self, test, err):
        self.failed.append((str(test), self._exc_info_to_string(err, test)))

    def addError(self, test, err):
        self.failed.append((str(test), self._exc_info_to_string(err, test)))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("docutils_dir")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("-k", "--pattern", default="test_*.py")
    ap.add_argument("--start", default="test/test_parsers/test_rst")
    ap.add_argument("--baseline", action="store_true", help="run with stock docutils")
    args = ap.parse_args()

    root = os.path.abspath(args.docutils_dir)
    os.chdir(root)
    sys.path.insert(0, os.path.join(root, "test"))
    sys.path.insert(0, root) if False else None

    if not args.baseline:
        import docodin
        from docutils.parsers import rst

        docodin.patch_docutils()
        patched = rst.Parser.parse

        def guarded(self, inputstring, document):
            def on_alarm(signum, frame):
                raise TimeoutError("docodin parse timed out")
            old = signal.signal(signal.SIGALRM, on_alarm)
            signal.alarm(5)
            try:
                return patched(self, inputstring, document)
            finally:
                signal.alarm(0)
                signal.signal(signal.SIGALRM, old)

        rst.Parser.parse = guarded

    suite = unittest.TestLoader().discover(args.start, pattern=args.pattern, top_level_dir=root)
    result = CaseResult(args.verbose)
    suite.run(result)
    total = result.passed + len(result.failed)
    if args.verbose:
        for name, tb in result.failed:
            print("=" * 70)
            print("FAIL:", name)
            print(tb[-4000:])
    else:
        for name, _ in result.failed:
            print("FAIL:", name)
    print(f"passed {result.passed}/{total} ({100.0 * result.passed / max(total, 1):.1f}%)")
    return 0 if not result.failed else 1


if __name__ == "__main__":
    sys.exit(main())
