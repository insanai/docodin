"""Differential fuzzing: docodin vs docutils.

Generates random reStructuredText (grammar-based documents and byte-level
mutations of corpus files), parses each with both parsers and compares the
pseudo-XML (including all system messages) and the ``source``/``line`` of
every node.  Every mismatch, crash or
timeout is saved for inspection.

    python tests/fuzz_differential.py [--cases N] [--seed S] [--corpus DIR] [--out DIR]
        [--directives | --inline]

``--directives`` generates documents of directives and roles instead (with
``include`` enabled) and also compares the warning stream of all messages.
``--inline`` generates paragraphs dense in the inliner's hard cases (standalone
URIs, e-mail addresses, ``name_`` reference chains, escapes, non-ASCII words)
under random inline settings.
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
    "- item\n- item\n\n  nested para\n", "* a\n+ b\n", "1. one\n2. two\n", "a) x\nb) y\n",
    "(i) r\n(ii) s\n",
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


# Pieces of directive documents (``--directives``): the standard directives
# and roles, with valid and invalid arguments, options and content, and
# ``include`` of the standard include files.
DIRECTIVE_PIECES = [
    ".. note:: Body text.\n", ".. warning::\n\n   Para one.\n\n   Para two.\n",
    ".. attention::\n", ".. caution:: x\n   :class: a b\n", ".. danger:: *emph* `ref`_\n",
    ".. error:: :name: target\n", ".. hint::\n   :class: Hint Class\n   :name: n1\n\n   Body\n",
    ".. important:: x\n\n   - item\n", ".. tip:: x\n   :bad: option\n",
    ".. admonition:: My *Title*\n\n   Body.\n", ".. admonition::\n\n   No title.\n",
    ".. admonition:: T\n   :class: special\n\n   Body.\n",
    ".. topic:: Topic Title\n\n   Topic body.\n", ".. topic:: T\n",
    ".. sidebar:: Side\n   :subtitle: Sub *title*\n\n   Side body.\n",
    ".. sidebar::\n   :subtitle: S\n\n   Body\n", ".. sidebar:: A\n\n   .. sidebar:: B\n\n      x\n",
    ".. topic:: Outer\n\n   .. topic:: Inner\n\n      x\n",
    ".. line-block::\n\n   First line\n     indented *more*\n\n   back\n",
    ".. parsed-literal::\n\n   code with *emphasis*\n   and `ref`_\n",
    ".. parsed-literal::\n", ".. code:: python\n   :number-lines:\n\n   x = 1\n   y = 2\n",
    ".. code::\n\n   plain\n", ".. code-block:: text\n   :number-lines: 9\n\n   a\n\n   b\n",
    ".. sourcecode:: c\n   :number-lines: x\n\n   int\n",
    ".. code:: c\n   :class: hl\n   :name: codename\n\n   int x;\n",
    ".. math::\n\n   a^2 + b^2\n\n   c^2\n", ".. math::\n   :name: eq\n\n   e = mc^2\n\n   f\n",
    ".. rubric:: A *rubric*\n", ".. rubric::\n", ".. rubric:: R\n   :class: x\n",
    ".. epigraph::\n\n   Quote text.\n\n   -- Author\n", ".. highlights::\n\n   One.\n\n   Two.\n",
    ".. pull-quote::\n\n   Pulled.\n\n   --- Somebody\n     continued\n",
    ".. compound::\n   :class: c\n\n   Para.\n\n   ::\n\n      lit\n", ".. container:: a b\n\n   Inside.\n",
    ".. container:: !!!\n\n   x\n", ".. container::\n",
    ".. class:: special\n", ".. class:: a b\n\n   Para one.\n\n   Para two.\n", ".. class::\n",
    ".. class:: ###\n", ".. rst-class:: x\n\n   y\n",
    ".. role:: custom\n", ".. role:: custom2(emphasis)\n", ".. role:: raw-html(raw)\n   :format: html\n",
    ".. role:: bad role\n", ".. role:: r(unknownbase)\n", ".. role:: c2(code)\n   :language: python\n",
    ".. role::\n", ".. role:: x(literal)\n   :class: k\n   :format: no\n",
    "Text :custom:`one` :custom2:`two` :raw-html:`<b>` :c2:`x=1` :x:`lit`\n",
    ".. default-role:: literal\n", ".. default-role::\n", ".. default-role:: nope\n",
    ".. default-role:: custom\n", "Default `role text` here.\n",
    "Roles :emphasis:`e` :strong:`s` :literal:`l` :sub:`2` :sup:`3` :t:`title` :ab:`abbr`\n",
    "Roles :pep:`8` :pep:`x` :rfc:`2822` :rfc:`2822#sec` :rfc:`0` :math:`a^2` :code:`c`\n",
    "Roles :raw:`raw` :index:`i` :unknown:`u` :acronym:`ac` :title-reference:`t`\n",
    "Roles :restructuredtext-unimplemented-role:`z` :Emphasis:`caps`\n",
    ".. raw:: html\n\n   <b>raw</b>\n", ".. raw:: html\n", ".. raw:: HTML  Latex\n   :class: r\n\n   x\n",
    ".. raw:: html\n   :file: nonexistent.html\n", ".. raw:: html\n   :file: a\n   :url: b\n",
    ".. |r| replace:: replacement *text*\n", ".. |r2| replace:: two\n\n   paragraphs\n",
    ".. |u| unicode:: U+2014 .. comment\n", ".. |u2| unicode:: 0x41 x42 &#x43; 68 abc\n   :trim:\n",
    ".. |u3| unicode:: 99999999999\n", ".. |u4| unicode:: 1114112\n", ".. replace:: outside\n",
    ".. unicode:: U+20\n", "Use |r| and |u| and |r2| and |missing|.\n",
    ".. title:: Document Title\n", ".. title::\n",
    ".. contents::\n", ".. contents:: Table\n   :depth: 2\n   :local:\n   :backlinks: top\n",
    ".. contents::\n   :depth: -1\n", ".. contents::\n   :backlinks: sideways\n",
    ".. contents::\n   :class: toc\n   :backlinks: none\n",
    ".. sectnum::\n", ".. sectnum::\n   :depth: 2\n   :start: 3\n   :prefix: A.\n   :suffix: )\n",
    ".. section-numbering::\n   :depth: x\n", ".. header:: Header *text*\n", ".. footer:: Footer\n",
    ".. header::\n", ".. target-notes::\n", ".. target-notes::\n   :class: tn\n",
    ".. restructuredtext-test-directive:: arg\n   :option: value\n\n   content\n",
    ".. restructuredtext-test-directive::\n", ".. include:: <isonum.txt>\n",
    ".. include:: <isolat1.txt>\n", ".. include:: nonexistent.rst\n",
    ".. include:: <isonum.txt>\n   :literal:\n",
    ".. include:: <isonum.txt>\n   :code: rst\n   :number-lines:\n",
    ".. include:: <isonum.txt>\n   :start-line: 3\n   :end-line: 8\n   :literal:\n   :number-lines: 3\n",
    ".. include:: <isonum.txt>\n   :start-after: frac12\n",
    ".. include:: <isonum.txt>\n   :start-after: copyright\n",
    ".. include:: <isonum.txt>\n   :end-before: nothing-like-this\n",
    "Text |copy| |reg| |trade|.\n", ".. note:: x\n   :class:\n",
    ".. note:: x\n   :class: a\n   :class: b\n",
    ".. note:: x\n   :name: a b\n", ".. note::\n   :name:\n",
    ".. topic:: T\n   :name: tn\n\n   Section\n   -------\n",
    ".. note::\n\n   Section\n   =======\n\n   x\n", ".. note:: x\n   :alt_: ref\n",
    ".. note:: x\n   :a\\:b: y\n", ".. note:: x\n   :class: a\n   not an option\n\n   body\n",
    ".. |img| note:: x\n", "Section\n=======\n", "Sub\n---\n", "Para with `link <http://x>`_.\n",
    ".. _tgt:\n", "- list\n\n  .. note:: in list\n", "| line\n|  block\n",
    "See PEP 8, PEP-0287 and RFC 2822 and pep-0008.txt.\n", "Refs [1]_ [#]_ and [*]_ here.\n",
    ".. [1] One.\n", ".. [#] Auto.\n", ".. [*] Symbol.\n", "Char*level*mark``up``x `r`_x\n",
    "Title\n=====\n\n.. _dup:\n\nTitle\n=====\n",
    ".. image:: a.png\n", ".. image:: a b.png\n   :alt: Alt *text*\n   :width: 50 %\n   :height: 2.5em\n",
    ".. image:: x.png\n   :align: middle\n", ".. image:: x.png\n   :scale: 50%\n   :target: http://x.org\n",
    ".. image:: x.png\n   :target: `ref`_\n   :name: img\n", ".. image:: x.png\n   :width: 3 furlongs\n",
    ".. image:: x.png\n   :loading: lazy\n   :class: c\n", ".. image::\n",
    ".. |img2| image:: i.png\n   :align: top\n",
    ".. |img3| image:: i.png\n   :align: left\n", "An |img2| inline.\n",
    ".. figure:: f.png\n   :figwidth: 50%\n   :figclass: fc\n   :align: center\n\n   Caption *here*.\n\n"
    "   Legend para.\n",
    ".. figure:: f.png\n   :figwidth: image\n   :figname: fig\n\n   ..\n\n   Legend only.\n",
    ".. figure:: f.png\n\n   - not a caption\n", ".. figure:: f.png\n   :align: top\n",
    ".. figure:: f.png\n\n   .. _ftarget:\n\n   Cap.\n",
    ".. table:: Title *t*\n   :widths: 1 2\n   :align: center\n\n"
    "   =====  =====\n   a      b\n   =====  =====\n",
    ".. table::\n   :widths: auto\n\n   +---+---+\n   | a | b |\n   +---+---+\n", ".. table::\n\n   para\n",
    ".. table::\n", ".. table::\n   :widths: 1 2 3\n\n   ===  ===\n   a    b\n   ===  ===\n",
    ".. csv-table:: CSV *title*\n   :header: \"A\", \"B\"\n   :widths: 30, 70\n\n"
    "   1, \"two, three\"\n   \"*4*\", 5\n",
    ".. csv-table::\n   :header-rows: 1\n   :stub-columns: 1\n\n   h1,h2\n   a,b\n\n   c\n",
    ".. csv-table::\n   :delim: ;\n   :quote: '\n   :keepspace:\n\n   a; 'b;c'\n",
    ".. csv-table::\n   :escape: \\\n\n   \"a\\\"b\", c\n", ".. csv-table::\n\n   \"unterminated\n",
    ".. csv-table::\n\n   \"a\"b, c\n", ".. csv-table::\n   :header-rows: 3\n\n   a\n",
    ".. csv-table::\n   :file: nonexistent.csv\n", ".. csv-table::\n   :delim: space\n\n   a b\n",
    ".. csv-table::\n", ".. csv-table::\n   :widths: 1\n\n   a, b\n",
    ".. list-table:: List *table*\n   :header-rows: 1\n   :widths: 1 1\n\n   * - H1\n     - H2\n"
    "   * - a\n     - b\n",
    ".. list-table::\n\n   * - a\n   * - b\n     - c\n", ".. list-table::\n\n   para\n",
    ".. list-table::\n\n   * not a list\n", ".. list-table::\n   :stub-columns: 2\n\n   * - a\n     - b\n",
    ".. list-table::\n",
    ".. meta::\n   :keywords: a, b\n   :description lang=en: Desc\n"
    "   :http-equiv=Content-Type: text/html\n",
    ".. meta::\n   :empty:\n", ".. meta::\n   :name bad\"att: x\n", ".. meta::\n\n   not a field\n",
    ".. meta::\n",
]


def gen_directive_document(rng: random.Random) -> str:
    parts = []
    for _ in range(rng.randint(1, 10)):
        piece = rng.choice(DIRECTIVE_PIECES)
        if rng.random() < 0.2:
            indent = " " * rng.choice([1, 2, 3, 4])
            piece = "".join(indent + ln if ln.strip() else ln for ln in piece.splitlines(True))
        parts.append(piece)
        if rng.random() < 0.8:
            parts.append("\n")
    return "".join(parts)


# Words of ``--inline`` documents: the candidates of the inliner's fast paths
# (URI and e-mail pre-filters, the ``name_`` chain scan, the candidate scanner).
INLINE_WORDS = [
    "http://example.org", "https://x.org/a/b?q=1&r=2#frag", "HTTP://UPPER.ORG/", "ftp://f.io/x.",
    "mailto:someone@example.com", "news:comp.lang", "urn:isbn:0451450523", "file:///tmp/x",
    "unknown-scheme:foo", "a:b", "x:y:z", "10:30", "http:", "http://", "http://x.org/(paren)",
    "<http://angle.org>", "http://x.org/path_", "http://x.org/a\\ b", "http://x.org/*star*",
    "user@example.com", "first.last@sub.example.co.uk", "a@b", "a@b.", "@at", "at@", "x\\@y.org",
    "trailing.dot.@x.org", "e@x.org.", "e@x.org>", "a+b@c-d.org", "'q'@x.io", "üser@x.org",
    "name_", "name__", "a-b.c+d:e_", "a_b_c_", "long-chain.with+many:seps_", "a-_", "a._", "a:_",
    "1_", "é_", "テキスト_", "naïve-word_", "a__b_", "_lead", "trail_.", "x_y", "ref_,", "ref_)",
    "(ref_)", "\\name_", "name\\_", "`phrase`_", "`anon`__", "`a <u_>`_", "`b <http://u>`_",
    ":role:`x`", "`x`:role:", "*em*", "**st**", "``lit``", "|sub|_", "[1]_", "[#a]_", "[CIT]_",
    "pep-0008.txt", "PEP 287", "RFC 2822", "RFC-822", "word", "Wörter", "日本語", "«q»_", "‘q’",
    "a*b", "*", "_", ":", "@", "`", "|", "[", "\\", "a\\:b", "x\u00a0y_", "\u3000w_",
]
INLINE_SEPARATORS = [" ", " ", " ", "  ", "\n", ", ", ". ", "(", ")", "-", "/", "'", '"', "", ":"]


def gen_inline_document(rng: random.Random) -> str:
    paragraphs = []
    for _ in range(rng.randint(1, 4)):
        words = []
        for _ in range(rng.randint(1, 24)):
            words.append(rng.choice(INLINE_WORDS))
            words.append(rng.choice(INLINE_SEPARATORS))
        text = "".join(words).strip() or "x"
        if rng.random() < 0.2:
            text = "- " + text.replace("\n", "\n  ")
        paragraphs.append(text + "\n")
    return "\n".join(paragraphs)


def gen_inline_settings(rng: random.Random) -> dict:
    return {
        "character_level_inline_markup": rng.random() < 0.25,
        "pep_references": rng.random() < 0.5,
        "rfc_references": rng.random() < 0.5,
        "trim_footnote_reference_space": rng.random() < 0.25,
    }


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


def check(
    text: str, directives: bool = False, overrides: dict | None = None
) -> tuple[str, str] | None:
    """Compare docodin with docutils on ``text``; ``directives``: with file
    insertion (``include``) and the warning stream of all messages;
    ``overrides``: further settings."""
    import io

    import docodin
    import docutils.frontend
    import docutils.nodes
    import docutils.utils
    from docutils.parsers import rst
    from docutils.parsers.rst import directives as directive_registry
    from docutils.parsers.rst import roles

    def run(parser):
        roles._roles.clear()  # docutils caches roles and directives per process
        directive_registry._directives.clear()
        settings = docutils.frontend.get_default_settings(rst.Parser)
        stream = io.StringIO()
        settings.warning_stream = stream
        settings.report_level = 1 if directives else 5
        settings.halt_level = 5
        settings.file_insertion_enabled = directives
        for key, value in (overrides or {}).items():
            setattr(settings, key, value)
        doc = docutils.utils.new_document("fuzz", settings)
        parser.parse(text, doc)
        # pseudo-XML plus the Python-level source/line of every node (used in
        # warnings by transforms and Sphinx, not shown in pseudo-XML)
        positions = [(n.tagname, n.source, n.line) for n in doc.findall(docutils.nodes.Element)]
        return doc.pformat(), positions, stream.getvalue()

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
    seed, corpus, mode = args
    rng = random.Random(seed)
    if mode == "inline":
        text = gen_inline_document(rng)
        if rng.random() < 0.2:
            text = mutate(rng, text)
        return seed, text, check(text, overrides=gen_inline_settings(rng))
    if mode == "directives":
        text = gen_directive_document(rng)
        return seed, text, check(text, directives=True)
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
    ap.add_argument("--directives", action="store_true",
                    help="generate directive documents (with include and the warning stream)")
    ap.add_argument("--inline", action="store_true",
                    help="generate paragraphs of URIs, e-mail addresses and name_ chains")
    args = ap.parse_args()
    mode = "directives" if args.directives else "inline" if args.inline else "blocks"
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
        jobs = [(args.seed * 1_000_003 + i, corpus, mode) for i in range(args.cases)]
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
