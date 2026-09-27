"""Differential test of the native reader (``odin/reader``) against docutils.

Parses documents with ``docutils.parsers.rst.Parser`` into
``docutils.utils.new_document`` (``publish_doctree`` without transforms) and
with the native reader (``reader.parse``, through the harness in
``odin/reader/tests/harness``), then compares byte for byte:

* the pseudo-XML (``document.pformat()``, all system messages included),
* the ``(tagname, source, line)`` of every element,
* the warning stream.

Documents are parsed twice: with ``report_level`` 5 (nothing reported) and
with ``report_level`` 1 (every message written to the warning stream, which
checks the order in which messages are created).  ``halt_level`` is 5 and
``syntax_highlight`` "none" (the native reader has no Pygments).

Inputs (categories):

* ``fuzz``: the generator of ``tests/fuzz_differential.py``,
* ``directives``: generated documents using the ported directives and roles
  (valid and invalid arguments, options and content; ``include`` of the
  standard include files),
* ``settings``: both generators with varied parser settings (PEP and RFC
  references, character-level inline markup, footnote reference space,
  ``raw_enabled``, id prefixes),
* ``functional``: ``docutils-0.22.4/test/functional/input/*.rst``,
* ``docs``: ``docutils-0.22.4/docs/**/*.rst``.

Documents that use directives not ported yet (images, figures, tables,
``meta``; the harness reports them) are counted separately.  For documents
with exotic characters, run the script with the interpreter whose Unicode
data the native tables use:
``uv run --no-project --python 3.14 --with docutils==0.22.4 python ...``.

    uv run python tests/native_reader_differential.py [--cases N] [--seed S]
        [--docutils DIR] [--only CATEGORY] [--out DIR] [--no-build]

``--docutils`` (or ``$DOCUTILS_SOURCE``) is an unpacked docutils 0.22.4
source distribution.
"""

from __future__ import annotations

import argparse
import io
import os
import random
import re
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HARNESS = ROOT / "build" / "reader-harness"
# The docutils 0.22.4 source tree (test/functional/input, docs).
DEFAULT_DOCUTILS = os.environ.get("DOCUTILS_SOURCE", "")
UNPORTED_MARK = "--unported--\n"  # the harness met a directive not ported yet
REPORT_LEVELS = (5, 1)

# Pieces of the ``directives`` category: the ported directives and roles,
# with valid and invalid arguments, options and content.
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
]

BATCH = 200


def build_harness() -> None:
    cmd = ["odin", "build", str(ROOT / "odin/reader/tests/harness"), "-vet", "-strict-style",
           "-o:speed", f"-out:{HARNESS}"]
    HARNESS.parent.mkdir(exist_ok=True)
    subprocess.run(cmd, check=True)


# Settings variants (``Setting_Flag`` of the harness): name -> (bit, value).
SETTING_FLAGS = {
    "pep_references": (0, True),
    "rfc_references": (1, True),
    "character_level_inline_markup": (2, True),
    "trim_footnote_reference_space": (3, True),
    "raw_enabled": (4, False),
    "id_prefix": (5, "p-"),
}


def setting_values(flags: int) -> dict:
    values = {}
    for name, (bit, value) in SETTING_FLAGS.items():
        if flags >> bit & 1:
            values[name] = value
            if name == "id_prefix":
                values["auto_id_prefix"] = "id"
    return values


def reference(text: str, source_path: str, report_level: int, file_insertion: bool,
              flags: int = 0) -> str:
    """docutils' result in the comparison format."""
    from docutils import frontend, nodes, utils
    from docutils.parsers.rst import Parser, directives, roles

    # the role and directive caches are per process in docutils
    roles._roles.clear()
    directives._directives.clear()
    settings = frontend.get_default_settings(Parser)
    settings.report_level = report_level
    settings.halt_level = 5
    stream = io.StringIO()
    settings.warning_stream = stream
    settings.syntax_highlight = "none"
    settings.file_insertion_enabled = file_insertion
    for name, value in setting_values(flags).items():
        setattr(settings, name, value)
    document = utils.new_document(source_path, settings)
    Parser().parse(text, document)
    lines = [document.pformat(), "--positions--\n"]
    for node in document.findall(nodes.Element):
        source = "None" if node.source is None else repr(node.source)
        lines.append(f"{node.tagname}\t{source}\t{node.line}\n")
    lines.append("--stream--\n")
    lines.append(stream.getvalue())
    return "".join(lines)


def native(cases: list[tuple[str, str, int, bool, int]], include_dir: str) -> list[str | None]:
    """The harness results (None: the harness crashed on the case)."""
    def pack(batch):
        out = bytearray()
        for text, source_path, level, insertion, flags in batch:
            for s in (source_path, text):
                data = s.encode("utf-8", "surrogatepass")
                out += struct.pack("<I", len(data)) + data
            out += bytes((level, 1 if insertion else 0, flags))
        return bytes(out)

    def run(batch):
        proc = subprocess.run([str(HARNESS), include_dir], input=pack(batch),
                              capture_output=True, timeout=600, check=False)
        if proc.returncode != 0:
            return None
        results, data, pos = [], proc.stdout, 0
        while pos < len(data):
            (n,) = struct.unpack_from("<I", data, pos)
            results.append(data[pos + 4:pos + 4 + n].decode("utf-8", "surrogatepass"))
            pos += 4 + n
        return results

    out: list[str | None] = []
    for start in range(0, len(cases), BATCH):
        batch = cases[start:start + BATCH]
        results = run(batch)
        if results is None:  # isolate the crashing cases
            results = []
            for case in batch:
                one = run([case])
                results.append(one[0] if one else None)
        out.extend(results)
    return out


def fuzz_cases(count: int, seed: int, corpus: list[str]) -> list[tuple[str, str]]:
    sys.path.insert(0, str(ROOT / "tests"))
    from fuzz_differential import gen_document, mutate

    cases = []
    for i in range(count):
        rng = random.Random(seed * 1_000_003 + i)
        if corpus and rng.random() < 0.5:
            text = mutate(rng, rng.choice(corpus))
        else:
            text = gen_document(rng)
            if rng.random() < 0.3:
                text = mutate(rng, text)
        cases.append((f"fuzz-{i}", text))
    return cases


def directive_cases(count: int, seed: int) -> list[tuple[str, str]]:
    cases = []
    for i in range(count):
        rng = random.Random(seed * 7_000_003 + i)
        parts = []
        for _ in range(rng.randint(1, 10)):
            piece = rng.choice(DIRECTIVE_PIECES)
            if rng.random() < 0.2:
                indent = " " * rng.choice([1, 2, 3, 4])
                piece = "".join(indent + ln if ln.strip() else ln
                                for ln in piece.splitlines(True))
            parts.append(piece)
            if rng.random() < 0.8:
                parts.append("\n")
        cases.append((f"directives-{i}", "".join(parts)))
    return cases


def file_cases(paths: list[Path]) -> list[tuple[str, str]]:
    cases = []
    for p in sorted(paths):
        try:
            cases.append((str(p), p.read_text(encoding="utf-8")))
        except UnicodeDecodeError:
            continue
    return cases


def compare(category: str, cases: list[tuple[str, str]], include_dir: str,
            out_dir: Path, file_insertion: bool, vary_settings: bool = False) -> dict[str, int]:
    runs = []
    expected = []
    for index, (name, text) in enumerate(cases):
        flags = random.Random(index).randrange(64) if vary_settings else 0
        for level in REPORT_LEVELS:
            try:
                want = reference(text, name, level, file_insertion, flags)
            except Exception:  # noqa: BLE001 - docutils itself fails: not comparable
                want = None
            runs.append((text, name, level, file_insertion, flags))
            expected.append(want)
    got = native(runs, include_dir)
    unported = set()
    for k, result in enumerate(got):
        if result is not None and result.startswith(UNPORTED_MARK):
            got[k] = result[len(UNPORTED_MARK):]
            unported.add(k // len(REPORT_LEVELS))
    stats = {"identical": 0, "differ": 0, "unported": 0, "crash": 0, "skipped": 0}
    for i, (name, text) in enumerate(cases):
        pair = range(i * len(REPORT_LEVELS), (i + 1) * len(REPORT_LEVELS))
        if any(expected[k] is None for k in pair):
            stats["skipped"] += 1
            continue
        if any(got[k] is None for k in pair):
            kind = "crash"
        elif all(got[k] == expected[k] for k in pair):
            stats["identical"] += 1
            continue
        else:
            kind = "unported" if i in unported else "differ"
        stats[kind] += 1
        save(out_dir, category, kind, name, text, [expected[k] for k in pair],
             [got[k] for k in pair])
    return stats


def save(out_dir: Path, category: str, kind: str, name: str, text: str,
         expected: list, got: list) -> None:
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", Path(name).name)
    base = out_dir / category / kind / safe
    base.parent.mkdir(parents=True, exist_ok=True)
    base.with_suffix(".rst").write_text(text, encoding="utf-8", errors="surrogatepass")
    for level, want, have in zip(REPORT_LEVELS, expected, got, strict=True):
        (base.parent / f"{base.name}.{level}.expected").write_text(
            want or "", encoding="utf-8", errors="surrogatepass")
        (base.parent / f"{base.name}.{level}.got").write_text(
            have if have is not None else "<crash>", encoding="utf-8", errors="surrogatepass")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--cases", type=int, default=3000)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--docutils", type=Path, default=DEFAULT_DOCUTILS or None,
                    help="docutils 0.22.4 source tree (default: $DOCUTILS_SOURCE)")
    ap.add_argument("--only", choices=("fuzz", "directives", "settings", "functional", "docs"))
    ap.add_argument("--out", type=Path, default=ROOT / "build" / "native-reader-failures")
    ap.add_argument("--no-build", action="store_true")
    args = ap.parse_args()
    if not args.no_build:
        build_harness()
    import docutils

    include_dir = str(Path(docutils.__file__).parent / "parsers" / "rst" / "include")
    source = args.docutils
    if source is None:
        print("no docutils source tree (--docutils or $DOCUTILS_SOURCE): "
              "skipping the functional and docs categories")
        source = Path("/nonexistent")
    functional = list((source / "test/functional/input").glob("*.rst"))
    docs = list((source / "docs").rglob("*.rst"))
    categories = {
        "functional": (file_cases(functional), True),
        "docs": (file_cases(docs), True),
    }
    if args.only in (None, "fuzz"):
        corpus = [text[i:i + 2000] for _, text in categories["docs"][0]
                  for i in range(0, len(text), 2000)]
        categories["fuzz"] = (fuzz_cases(args.cases, args.seed, corpus), False)
    if args.only in (None, "directives"):
        categories["directives"] = (directive_cases(args.cases, args.seed), True)
    if args.only in (None, "settings"):  # both generators, with varied settings
        mixed = fuzz_cases(args.cases // 2, args.seed + 1, [])
        mixed += directive_cases(args.cases // 2, args.seed + 1)
        categories["settings"] = (mixed, True)
    failed = 0
    for category, (cases, insertion) in categories.items():
        if (args.only and category != args.only) or not cases:
            continue
        stats = compare(category, cases, include_dir, args.out, insertion,
                        vary_settings=category == "settings")
        total = sum(stats.values()) - stats["skipped"]
        print(f"{category:11} identical {stats['identical']}/{total}"
              f"  differ {stats['differ']}  unported directives {stats['unported']}"
              f"  crash {stats['crash']}  (skipped: docutils fails {stats['skipped']})")
        failed += stats["differ"] + stats["crash"]
    print(f"failures saved to {args.out}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
