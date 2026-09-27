"""Benchmark docodin against docutils.

Usage::

    python tests/benchmark.py [CORPUS_DIR ...] [--repeat N]

Without a directory a synthetic corpus is generated.  Each ``*.rst``/``*.txt``
file is parsed separately (as Sphinx/docutils do); reported times are the
best of ``--repeat`` runs over the whole corpus.
"""

from __future__ import annotations

import argparse
import gc
import os
import time
from collections.abc import Callable

import docodin
import docutils.core
import docutils.frontend
import docutils.parsers.rst
import docutils.utils
from docodin import _native


def synthetic_corpus(sections: int = 150) -> dict[str, str]:
    parts = ["Benchmark Document\n==================\n\n"]
    for i in range(1, sections + 1):
        title = f"Section {i}: Component analysis"
        parts.append(f"{title}\n{'-' * len(title)}\n\n")
        parts.append(
            f"Paragraph {i} with *emphasis*, **strong**, ``literal()``, a `link <https://example.org/{i}>`_,\n"
            f"a reference to `Section {i}: Component analysis`_ and :emphasis:`a role`.\n\n"
            "* item alpha\n* item beta\n\n  nested paragraph\n\n"
            "1. first\n2. second\n\n"
            f".. note::\n   Admonition for section {i}.\n\n"
            "::\n\n   def f(x):\n       return x * 2\n\n"
            f":Field: value {i}\n:Other: more\n\n"
            f"Term {i}\n    Definition of term {i}.\n\n"
            "=====  =====\nA      B\n=====  =====\n1      2\n=====  =====\n\n"
        )
    return {"synthetic.rst": "".join(parts)}


def load_corpus(dirs: list[str]) -> dict[str, str]:
    corpus: dict[str, str] = {}
    for d in dirs:
        for root, _, files in os.walk(d):
            for name in sorted(files):
                if name.endswith((".rst", ".txt")):
                    path = os.path.join(root, name)
                    with open(path, encoding="utf-8", errors="replace") as f:
                        corpus[path] = f.read()
    return corpus


def best_of(repeat: int, fn: Callable[[], None]) -> float:
    best = float("inf")
    for _ in range(repeat):
        gc.collect()
        t = time.perf_counter()
        fn()
        best = min(best, time.perf_counter() - t)
    return best


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("dirs", nargs="*")
    ap.add_argument("--repeat", type=int, default=3)
    args = ap.parse_args()
    corpus = load_corpus(args.dirs) if args.dirs else synthetic_corpus()
    size = sum(len(t.encode("utf-8")) for t in corpus.values())
    lines = sum(t.count("\n") + 1 for t in corpus.values())

    settings = docutils.frontend.get_default_settings(docutils.parsers.rst.Parser)
    settings.warning_stream = ""
    settings.report_level = 5
    settings.halt_level = 5
    overrides = {"warning_stream": "", "report_level": 5, "halt_level": 5,
                 "_disable_config": True}

    def parse_all(parser_factory):
        def run():
            parser = parser_factory()
            for path, text in corpus.items():
                doc = docutils.utils.new_document(path, settings.copy())
                parser.parse(text, doc)
        return run

    def native_only():
        lib = _native.native()
        for text in corpus.values():
            lib.parse(text)

    def publish(parser_factory, writer):
        def run():
            for path, text in corpus.items():
                docutils.core.publish_string(text, source_path=path, parser=parser_factory(),
                                             writer=writer, settings_overrides=overrides)
        return run

    rows = [
        ("native parse (Odin only)", best_of(args.repeat, native_only), None),
    ]
    stock_parse = best_of(args.repeat, parse_all(docutils.parsers.rst.Parser))
    odin_parse = best_of(args.repeat, parse_all(docodin.Parser))
    rows.append(("parse -> doctree: docutils", stock_parse, None))
    rows.append(("parse -> doctree: docodin", odin_parse, stock_parse / odin_parse))
    for writer in ("pseudoxml", "html5"):
        stock = best_of(args.repeat, publish(docutils.parsers.rst.Parser, writer))
        odin = best_of(args.repeat, publish(docodin.Parser, writer))
        rows.append((f"publish {writer}: docutils", stock, None))
        rows.append((f"publish {writer}: docodin", odin, stock / odin))

    print("=" * 66)
    print(f"Corpus: {len(corpus)} files, {size / 1024:.1f} KiB, {lines} lines")
    print("=" * 66)
    for name, secs, speedup in rows:
        extra = f"  ({speedup:.2f}x)" if speedup else ""
        print(f"{name:34s} {secs * 1000:9.1f} ms  {size / secs / 1e6:7.2f} MB/s{extra}")
    print("=" * 66)


if __name__ == "__main__":
    main()
