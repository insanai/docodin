"""Differential test of the native writers (odin/writers) against docutils.

Every input is published with docutils 0.22.4 for each writer and each settings variant and
dumped at stage ``output`` (scripts/doctree_json.py): the transformed document, docutils'
output and its ``publish_parts``.  The Odin runner (odin/writers/tests/differential) loads
each dump, writes it with the native writer and compares the output and every part.

The inputs are the docutils functional test inputs (with their test settings, also compared
with the expected files in ``test/functional/expected``), the documentation
``docs/**/*.rst`` and generated documents (tests/fuzz_differential.py plus writer-oriented
pieces).  Code blocks are compared with ``syntax_highlight: none`` (no Pygments).

    PY="uv run --no-project --python 3.14 --with docutils==0.22.4 python"
    $PY tests/native_writers_differential.py --docutils-src ~/src/docutils-0.22.4 \
        --work /tmp/writers --fuzz 2000

Documents with images scaled without both width and height need PIL to be written by
docutils; they are compared (docutils runs without PIL here, as the native writer) and
reported separately.
"""

from __future__ import annotations

import argparse
import copy
import multiprocessing as mp
import os
import random
import re
import runpy
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path[:0] = [str(ROOT / "scripts"), str(ROOT / "tests")]

import doctree_json  # noqa: E402
from docutils.writers import _html_base  # noqa: E402
from fuzz_differential import PIECES, mutate  # noqa: E402

# ``HTMLTranslator.starttag`` appends the classes of math nodes to the lists of the class
# attribute ``math_tags``: restored for each document, as in a new process.
MATH_TAGS = copy.deepcopy(_html_base.HTMLTranslator.math_tags)

WRITERS = ("pseudoxml", "xml", "html5", "latex", "xetex")
BASE = {"syntax_highlight": "none", "halt_level": 5}

# Settings variants per writer (applied on top of BASE).
VARIANTS: dict[str, list[dict]] = {
    "pseudoxml": [{}, {"detailed": True}],
    "xml": [{}, {"indents": True},
            {"newlines": True, "xml_declaration": False, "doctype_declaration": False,
             "output_encoding": "ascii"}],
    "html5": [
        {},
        {"embed_stylesheet": False, "stylesheet_path": "minimal.css,responsive.css"},
        {"initial_header_level": "1", "section_self_link": True, "toc_backlinks": "top",
         "table_style": "booktabs colwidths-grid", "footnote_references": "superscript"},
        {"compact_lists": False, "compact_field_lists": False, "cloak_email_addresses": True,
         "xml_declaration": True, "attribution": "parens", "footnote_backlinks": False,
         "image_loading": "lazy", "math_output": "MathJax"},
        {"math_output": "LaTeX", "initial_header_level": "4", "table_style": "colwidths-auto",
         "stylesheet": "a.css, b&c.css", "stylesheet_path": ""},
        {"math_output": "HTML math.css", "image_loading": "embed", "output_encoding": "ascii",
         "section_self_link": True, "initial_header_level": "6"},
        {"math_output": "HTML", "embed_images": True, "output_encoding": "latin-1",
         "table_style": "align-left,colwidths-auto", "stylesheet_path": "plain.css",
         "embed_stylesheet": False, "output_path": "out/doc.html"},
    ],
    "latex": [
        {"legacy_column_widths": True, "use_latex_citations": False},
        {},
        {"documentclass": "book", "use_part_section": True, "use_latex_docinfo": True,
         "use_latex_abstract": True, "use_latex_toc": False, "legacy_column_widths": False,
         "use_latex_citations": True, "footnote_references": "brackets"},
        {"legacy_class_functions": True, "table_style": ["booktabs"],
         "literal_block_env": "lstlisting", "compound_enumerators": True,
         "section_prefix_for_enumerators": True, "sectnum_xform": False},
        {"stylesheet": "docutils", "font_encoding": "OT1", "reference_label": "ref",
         "hyperlink_color": "false", "template": "titlepage.tex",
         "documentoptions": "a4paper,DIV=12", "language_code": "de",
         "table_style": ["borderless", "colwidths-auto"], "attribution": "none"},
    ],
    "xetex": [
        {"legacy_column_widths": True, "use_latex_citations": False},
        {"legacy_column_widths": False, "use_latex_citations": True, "language_code": "fr",
         "stylesheet": "docutils", "template": "titlingpage.tex", "documentclass": "memoir"},
    ],
}

# Settings of the docutils functional tests (test/functional/tests/_default.py and
# test_functional.py).
FUNCTIONAL_DEFAULTS = {"halt_level": 5, "input_encoding": "utf-8", "embed_stylesheet": False,
                       "syntax_highlight": "none"}
FUNCTIONAL_WRITERS = {"html5": "html5", "latex": "latex", "xetex": "xetex",
                      "pseudoxml": "pseudoxml", "docutils_xml": "xml"}

# Writer-oriented pieces for generated documents.
EXTRA_PIECES = [
    ":Author: A. Author\n:Date: 2026-09-27\n:Version: 1\n:Copyright: public\n:Status: draft\n",
    ":Authors: A; B\n:Address: 123 Street\n   City\n:Contact: a@example.org\n:Organization: O\n",
    ".. math::\n\n   a^2 + b^2 = c^2\n", "Inline :math:`x_1 + \\alpha` math.\n",
    ".. figure:: pic.png\n   :width: 50%\n   :align: right\n\n   Caption *text*\n\n   Legend\n",
    ".. image:: pic.png\n   :height: 3em\n   :width: 20px\n   :align: center\n",
    ".. table:: Title\n   :widths: 1 2\n\n   =====  =====\n   A      B\n   =====  =====\n"
    "   1      2\n   =====  =====\n",
    ".. list-table:: LT\n   :header-rows: 1\n   :stub-columns: 1\n\n   * - a\n     - b\n"
    "   * - c\n     - d\n",
    "+---+---+---+\n| a | b | c |\n+===+===+===+\n| multi | d |\n+---+---+---+\n"
    "| e | f | g |\n+---+   +---+\n| h |   | i |\n+---+---+---+\n",
    ".. sidebar:: Side\n   :subtitle: Sub\n\n   side body\n", ".. rubric:: Rubric\n",
    ".. admonition:: Custom\n\n   body\n", ".. warning:: careful\n", ".. epigraph::\n\n   text\n\n"
    "   -- Who\n", ".. container:: box\n\n   in box\n", ".. compound::\n\n   one\n\n   two\n",
    ".. line-block::\n\n   a\n     b\n", ".. parsed-literal::\n\n   *em* ``lit``\n",
    ".. raw:: html\n\n   <b>raw</b>\n", ".. raw:: latex\n\n   \\LaTeX\n",
    ".. class:: special\n\nClassy paragraph.\n", ".. sectnum::\n", ".. contents:: Local\n   :local:\n",
    ".. header:: Head text\n", ".. footer:: Foot text\n", ".. meta::\n   :keywords: a, b\n",
    ".. title:: Doc Title\n", ":abbr:`ABC (a b c)` :sub:`2` :sup:`3` :title-reference:`T`\n",
    ".. code:: python\n   :number-lines:\n\n   x = 1\n   y = 2\n", "Quotes \"a\" 'b' -- --- ...\n",
    ".. topic:: Abstract\n   :class: abstract\n\n   An abstract.\n", ".. highlights::\n\n   h\n",
    "Special chars: # $ % & ~ _ ^ \\\\ { } [ ] < > | \" @ ¶ © € ♥ ✓ — –\n",
    ".. raw:: html\n   :class: rawclass\n\n   <i>raw</i>\n", ".. container:: ins\n\n   inserted\n",
    ".. role:: kbd\n\nPress :kbd:`Ctrl-C` and :code:`x = 1`.\n",
    ".. role:: python(code)\n   :language: python\n\nCode :python:`print(1)`.\n",
    ".. class:: details open\n\nterm\n  details definition\n",
    ".. class:: field-indent-3em\n\n:a: b\n:long field name: c\n",
    ".. image:: movie.mp4\n   :class: controls\n", ".. image:: anim.swf\n   :alt: flash\n",
    ".. image:: pic.png\n   :scale: 50%\n", ".. image:: pic.png\n   :width: 40\n   :scale: 150\n",
    "An _`inline target` here and :ab:`abbr` :ac:`acro` :t:`title`.\n",
    ".. math::\n\n   \\frac{a\n", "Bad :math:`\\unknowncmd{x}` and :math:`a \\\\ b`.\n",
    ".. math::\n   :class: m\n   :name: eq1\n\n   a &= b \\\\\n   c &= d\n",
    "``--an-option`` and ``[+]?(\\d+)`` and ``a  b``\n", "mail: someone@example.org\n",
    ".. figure:: pic.png\n   :figwidth: 60%\n   :figclass: numbered\n\n   Cap\n",
    ":Dedication: For you.\n:Abstract: About.\n", ".. |date| date::\n\nToday |date|.\n",
]


def gen_writer_document(rng: random.Random) -> str:
    parts = []
    pieces = PIECES + EXTRA_PIECES * 2
    for _ in range(rng.randint(1, 14)):
        piece = rng.choice(pieces)
        if rng.random() < 0.15:
            indent = " " * rng.choice([2, 3, 4])
            piece = "".join(indent + line if line.strip() else line
                            for line in piece.splitlines(True))
        parts.append(piece)
        if rng.random() < 0.8:
            parts.append("\n")
    return "".join(parts)


# --- jobs --------------------------------------------------------------------------------

def functional_jobs(src: Path) -> list[dict]:
    """The functional tests of the supported writers, with their settings."""
    jobs = []
    test = src / "test"
    for config in sorted((test / "functional" / "tests").glob("*.py")):
        try:
            data = runpy.run_path(str(config))
        except Exception:  # noqa: BLE001 - e.g. tests that require PIL
            continue
        writer = FUNCTIONAL_WRITERS.get(data.get("writer", ""))
        if writer is None or data.get("parser", "rst") != "rst" or data.get("reader"):
            continue
        overrides = {**FUNCTIONAL_DEFAULTS, **data.get("settings_overrides", {})}
        overrides = {k: list(v) if isinstance(v, tuple) else v for k, v in overrides.items()}
        dest = data["test_destination"]
        overrides["output_path"] = f"functional/output/{dest}"
        source = f"functional/input/{data['test_source']}"
        jobs.append({"name": f"functional-{config.stem}", "path": source, "cwd": str(test),
                     "writer": writer, "overrides": overrides, "group": "functional-tests",
                     "expected": str(test / "functional" / "expected" / dest),
                     "variant": "functional"})
    return jobs


def corpus_jobs(src: Path, writers: tuple[str, ...]) -> list[dict]:
    """Functional inputs and docs/**/*.rst with every writer and variant."""
    jobs = []
    groups = [("functional", sorted((src / "test").glob("functional/input/*.rst")), src / "test"),
              ("docs", sorted(src.glob("docs/**/*.rst")), src)]
    for group, files, cwd in groups:
        for path in files:
            rel = str(path.relative_to(cwd))
            for writer in writers:
                for i, variant in enumerate(VARIANTS[writer]):
                    jobs.append({"name": f"{group}-{rel}", "path": rel, "cwd": str(cwd),
                                 "writer": writer, "overrides": {**BASE, **variant},
                                 "group": group, "variant": i})
    return jobs


def fuzz_jobs(count: int, seed: int, writers: tuple[str, ...], cwd: Path) -> list[dict]:
    rng = random.Random(seed)
    jobs = []
    for n in range(count):
        text = gen_writer_document(rng)
        if rng.random() < 0.2:
            text = mutate(rng, text)
        writer = writers[n % len(writers)]
        variants = VARIANTS[writer]
        i = rng.randrange(len(variants))
        overrides = {**BASE, **variants[i], "report_level": rng.choice([1, 2, 2, 4])}
        jobs.append({"name": f"fuzz-{n:05d}", "text": text, "path": f"fuzz-{n:05d}.rst",
                     "cwd": str(cwd), "writer": writer, "overrides": overrides,
                     "group": "fuzz", "variant": i})
    return jobs


# --- dumping -----------------------------------------------------------------------------

def slug(job: dict) -> str:
    name = re.sub(r"[^A-Za-z0-9_.-]+", "_", job["name"])
    return f"{name}.{job['writer']}.{job['variant']}.json"


def needs_pil(tree: dict) -> bool:
    """Is there an image with a scale but without both width and height?"""
    stack = [tree]
    while stack:
        node = stack.pop()
        atts = node.get("attributes", {})
        if node.get("tag") == "image" and "scale" in atts and not (
                "width" in atts and "height" in atts):
            return True
        stack.extend(node.get("children", []))
    return False


def dump_job(args: tuple[dict, str]) -> dict:
    job, out_dir = args
    os.chdir(job["cwd"])
    text = job.get("text")
    if text is None:
        text = Path(job["path"]).read_text(encoding="utf-8")
    result = {"job": job, "file": None, "reason": ""}
    _html_base.HTMLTranslator.math_tags = copy.deepcopy(MATH_TAGS)
    try:
        data = doctree_json.publish_stages(text, job["path"], job["writer"], job["overrides"],
                                           ("output",))
    except BaseException as e:  # noqa: BLE001 - docutils fails: nothing to compare
        result["reason"] = f"{type(e).__name__}: {e}"[:200]
        return result
    dump = data["output"]
    result["pil"] = needs_pil(dump["tree"])
    expected = job.get("expected")
    if expected:
        want = Path(expected).read_text(encoding="utf-8")
        result["functional_equal"] = want == dump["expected"]["output"]
    path = Path(out_dir) / slug(job)
    path.write_text(doctree_json.dumps(dump), encoding="utf-8")
    result["file"] = str(path)
    return result


def run_dumps(jobs: list[dict], out_dir: Path, processes: int) -> list[dict]:
    out_dir.mkdir(parents=True, exist_ok=True)
    with mp.Pool(processes) as pool:
        return list(pool.imap_unordered(dump_job, [(j, str(out_dir)) for j in jobs],
                                        chunksize=4))


# --- running and reporting ---------------------------------------------------------------

def build_runner(work: Path) -> Path:
    exe = work / "writers-differential"
    subprocess.run(["odin", "build", str(ROOT / "odin/writers/tests/differential"),
                    f"-out:{exe}", "-o:speed", "-vet", "-strict-style"], check=True)
    return exe


def run_runner(exe: Path, results: list[dict], work: Path) -> dict[str, str]:
    """The outcome line of each dump file."""
    listing = work / "dumps.lst"
    listing.write_text("".join(f"{r['file']}\t{r['job']['cwd']}\n" for r in results if r["file"]),
                       encoding="utf-8")
    save = work / "failed"
    save.mkdir(exist_ok=True)
    proc = subprocess.run([str(exe), "--save", str(save), str(listing)], capture_output=True,
                          text=True, errors="replace", check=False)
    if proc.returncode != 0:
        print(proc.stderr, file=sys.stderr)
    outcomes = {}
    for line in proc.stdout.splitlines():
        kind, _, rest = line.partition(" ")
        path = rest.split(" ", 1)[0]
        if kind in ("PASS", "FAIL", "SKIP", "ERROR"):
            outcomes.setdefault(path, line)
    return outcomes


def report(results: list[dict], outcomes: dict[str, str], work: Path) -> int:
    totals: dict[str, Counter] = defaultdict(Counter)
    failures = []
    reasons = Counter(f"{r['job']['writer']}: {r['reason'][:90]}" for r in results if not r["file"])
    for reason, count in reasons.most_common(12):
        print(f"docutils error ({count}x) {reason}")
    for r in results:
        key = f"{r['job']['writer']:9} {r['job']['group']:16} variant {r['job']['variant']}"
        if not r["file"]:
            totals[key]["docutils-error"] += 1
            continue
        line = outcomes.get(r["file"], "ERROR no outcome")
        kind = line.split(" ", 1)[0]
        totals[key]["total"] += 1
        totals[key]["identical"] += kind == "PASS"
        totals[key]["pil"] += bool(r.get("pil"))
        if kind != "PASS":
            failures.append(line)
        if "functional_equal" in r:
            status = "equal" if r["functional_equal"] else "DIFFERENT"
            print(f"functional {r['job']['name']}: docutils output {status} to the expected file;"
                  f" native: {kind}")
    print(f"\n{'writer':9} {'group':16} {'':9}  identical / total  (PIL, docutils errors)")
    by_writer: dict[str, Counter] = defaultdict(Counter)
    for key in sorted(totals):
        c = totals[key]
        by_writer[key.split()[0]].update(c)
        print(f"{key}  {c['identical']:5} / {c['total']:<5}  ({c['pil']}, {c['docutils-error']})")
    print()
    for writer, c in sorted(by_writer.items()):
        print(f"{writer:9} identical {c['identical']} / {c['total']}  (need PIL: {c['pil']})")
    (work / "failures.txt").write_text("\n".join(failures) + "\n", encoding="utf-8")
    print(f"\n{len(failures)} failures listed in {work / 'failures.txt'}")
    return 1 if failures else 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--docutils-src", type=Path, required=True,
                    help="docutils 0.22.4 source tree (with test/functional and docs)")
    ap.add_argument("--work", type=Path, default=Path("build/native-writers"))
    ap.add_argument("--groups", default="functional-tests,functional,docs,fuzz")
    ap.add_argument("--writers", default=",".join(WRITERS))
    ap.add_argument("--fuzz", type=int, default=1000)
    ap.add_argument("--seed", type=int, default=20260927)
    ap.add_argument("--jobs", type=int, default=os.cpu_count())
    ap.add_argument("--keep", action="store_true", help="keep the dumps of identical results")
    args = ap.parse_args(argv)
    src = args.docutils_src.resolve()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    groups = set(args.groups.split(","))
    writers = tuple(w for w in args.writers.split(",") if w)
    jobs = []
    if "functional-tests" in groups:
        jobs += [j for j in functional_jobs(src) if j["writer"] in writers]
    if "functional" in groups or "docs" in groups:
        jobs += [j for j in corpus_jobs(src, writers) if j["group"] in groups]
    if "fuzz" in groups:
        fuzz_dir = work / "fuzz-cwd"
        fuzz_dir.mkdir(exist_ok=True)
        jobs += fuzz_jobs(args.fuzz, args.seed, writers, fuzz_dir)
    exe = build_runner(work)
    print(f"{len(jobs)} jobs")
    results = run_dumps(jobs, work / "dumps", args.jobs)
    outcomes = run_runner(exe, results, work)
    status = report(results, outcomes, work)
    if not args.keep:
        for r in results:
            if r["file"] and outcomes.get(r["file"], "").startswith("PASS"):
                Path(r["file"]).unlink()
    return status


if __name__ == "__main__":
    sys.exit(main())
