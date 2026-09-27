"""Differential fuzzing: docodin vs docutils.

Generates random reStructuredText (grammar-based documents and byte-level
mutations of corpus files), parses each with both parsers and compares the
pseudo-XML (including all system messages) and the ``source``/``line`` of
every node.  Every mismatch, crash or
timeout is saved for inspection.

    python tests/fuzz_differential.py [--cases N] [--seed S] [--corpus DIR] [--out DIR]
"""

from __future__ import annotations

import argparse
import multiprocessing as mp
import os
import random
import sys
import traceback

PIECES = [
    "Title\n=====\n", "=====\nTitle\n=====\n", "Sub\n---\n", "----\n", "==\n", "Short\n--\n",
    "Para *em* **strong** ``lit`` `interp` :role:`x` `ref`_ ref_ anon__ [1]_ [#]_ [*]_ [CIT]_ |sub|\n",
    "Text with http://example.org/path?q=1#frag and mail@example.com.\n",
    "Escapes \\*not\\* \\\\ `a\\` b`_ *a*b *a *b* c* ***x*** ``a``b\n",
    "- item\n- item\n\n  nested para\n", "* a\n+ b\n", "1. one\n2. two\n", "a) x\nb) y\n", "(i) r\n(ii) s\n",
    "#. auto\n#. auto\n", "3. start\n4. next\n", "Term\n  Definition\n", "Term : classifier\n    Def\n",
    ":field: body\n:other: more\n  continued\n", "-a  option\n--long=VAL  desc\n/V  dos\n",
    "| line\n|   indented\n| back\n", ">>> print(1)\n1\n", "::\n\n  literal\n\n", "Para::\n\n  code\n",
    "Para::\n\n> quoted\n> more\n", "  block quote\n\n  -- Attribution\n",
    "+---+---+\n| a | b |\n+===+===+\n| c | d |\n+---+---+\n",
    "=====  =====\nA      B\n=====  =====\n1      2\n=====  =====\n",
    ".. note:: body\n", ".. _target: http://x\n", ".. _ref:\n", ".. __: http://anon\n", "__ http://anon2\n",
    ".. [1] footnote\n", ".. [#] auto\n", ".. [#named] auto named\n", ".. [*] sym\n", ".. [CIT] citation\n",
    ".. |sub| replace:: text\n", ".. |img| image:: a.png\n", ".. comment\n   more\n", "..\n",
    ".. image:: pic.png\n   :alt: x\n", ".. code:: python\n\n   x = 1\n", ".. topic:: T\n\n   body\n",
    ".. unknown:: arg\n", ".. contents::\n", ".. role:: custom\n", ".. default-role:: literal\n",
    "Title with ``code``\n~~~~~~~~~~~~~~~~~~~\n", "  indented\ntext\n", "\n", "\n\n", "   \n",
    "*unclosed emphasis\n", "`unclosed\n", "``unclosed literal\n", "|unclosed\n", "_`target\n",
    ":a:`b`:c:\n", "`x`__ `y <z_>`_ `<http://u>`_\n", "\tTab\tseparated\n", "Ünïcödé テキスト ✓\n",
    "ﾃｰﾌﾞﾙ\n====\n", "=====  ======\nダイ1  ダイ2\n=====  ======\n",
]


def gen_document(rng: random.Random) -> str:
    parts = []
    for _ in range(rng.randint(1, 12)):
        piece = rng.choice(PIECES)
        if rng.random() < 0.3:
            indent = " " * rng.choice([1, 2, 3, 4, 8])
            piece = "".join(indent + line if line.strip() else line for line in piece.splitlines(True))
        parts.append(piece)
        if rng.random() < 0.7:
            parts.append("\n")
    return "".join(parts)


def mutate(rng: random.Random, text: str) -> str:
    if not text:
        return text
    chars = list(text)
    alphabet = list(" \n\t*`_:|[]<>=-+#.\\()'\"") + ["\u00a0", "\u3000", "\u200b", "é", "テ"]
    for _ in range(rng.randint(1, 8)):
        op = rng.random()
        pos = rng.randrange(len(chars) + 1)
        if op < 0.4:
            chars.insert(pos, rng.choice(alphabet))
        elif op < 0.7 and chars:
            del chars[min(pos, len(chars) - 1)]
        elif chars:
            chars[min(pos, len(chars) - 1)] = rng.choice(alphabet)
    return "".join(chars)


def check(text: str) -> tuple[str, str] | None:
    import docodin
    import docutils.frontend
    import docutils.nodes
    import docutils.utils
    from docutils.parsers import rst

    def run(parser):
        settings = docutils.frontend.get_default_settings(rst.Parser)
        settings.warning_stream = ""
        settings.report_level = 5
        settings.halt_level = 5
        settings.file_insertion_enabled = False
        doc = docutils.utils.new_document("fuzz", settings)
        parser.parse(text, doc)
        # pseudo-XML plus the Python-level source/line of every node (used in
        # warnings by transforms and Sphinx, not shown in pseudo-XML)
        positions = [(n.tagname, n.source, n.line) for n in doc.findall(docutils.nodes.Element)]
        return doc.pformat(), positions

    try:
        expected = run(rst.Parser())
    except Exception:  # noqa: BLE001 - docutils itself crashes: not comparable
        return None
    try:
        got = run(docodin.Parser())
    except Exception:  # noqa: BLE001
        return "crash", traceback.format_exc()
    if got != expected:
        return "mismatch", ""
    return None


def worker(args):
    seed, corpus = args
    rng = random.Random(seed)
    if corpus and rng.random() < 0.5:
        text = mutate(rng, rng.choice(corpus))
    else:
        text = gen_document(rng)
        if rng.random() < 0.3:
            text = mutate(rng, text)
    result = check(text)
    return seed, text, result


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--corpus", default=None)
    ap.add_argument("--out", default="fuzz-failures")
    args = ap.parse_args()
    corpus: list[str] = []
    if args.corpus:
        for root, _, files in os.walk(args.corpus):
            for name in files:
                if name.endswith((".rst", ".txt")):
                    with open(os.path.join(root, name), encoding="utf-8", errors="replace") as f:
                        text = f.read()
                    # keep mutations small and fast: use slices of documents
                    for i in range(0, len(text), 2000):
                        corpus.append(text[i:i + 2000])
    os.makedirs(args.out, exist_ok=True)
    failures = 0
    ctx = mp.get_context("spawn")
    with ctx.Pool(max(os.cpu_count() or 2, 2)) as pool:
        jobs = [(args.seed * 1_000_003 + i, corpus) for i in range(args.cases)]
        for seed, text, result in pool.imap_unordered(worker, jobs, chunksize=16):
            if result is None:
                continue
            failures += 1
            kind, detail = result
            with open(os.path.join(args.out, f"{kind}-{seed}.rst"), "w", encoding="utf-8") as f:
                f.write(text)
            if detail:
                with open(os.path.join(args.out, f"{kind}-{seed}.txt"), "w", encoding="utf-8") as f:
                    f.write(detail)
    print(f"{args.cases - failures}/{args.cases} cases identical; {failures} failures saved to {args.out}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
