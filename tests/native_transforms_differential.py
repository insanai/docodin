"""Differential test of the native transforms (odin/transforms) against docutils.

Every case is a document published with docutils 0.22.4 as ``Publisher.publish`` does
(scripts/doctree_json.py), dumped at stage ``parsed`` and again after each transform that
``Transformer.apply_transforms`` applies, and after the whole run.  The Odin program
odin/transforms/tests/differential loads the ``parsed`` dump, applies the same queue one
transform at a time and requires ``doctree.dump_json`` to reproduce each dump byte for
byte: the tree with every node's source and line, the registry, the reporter's written
messages, the queue and the settings.  A mismatch is attributed to the first transform
after which the dumps differ; an exception of docutils must be an error of the native
run at the same transform.

Inputs: the docutils functional test inputs and documentation of a docutils source tree
(with each writer and a few settings variants), PEPs with the PEP reader, and generated
documents (tests/fuzz_differential.py plus transform-oriented pieces) with random
settings.

    PY="uv run --no-project --python 3.14 --with docutils==0.22.4 python"
    $PY tests/native_transforms_differential.py --docutils-src DIR --fuzz 2000 --jobs 8
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import signal
import subprocess
import sys
import traceback
import warnings
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path[:0] = [str(ROOT / "scripts"), str(ROOT / "tests")]

import doctree_json  # noqa: E402
from fuzz_differential import PIECES, mutate  # noqa: E402

WRITERS = ("pseudoxml", "html5", "latex")
SEP = "\x1e"  # separates the dumps of a case file
CHECK_TIMEOUT = 1200  # seconds for a share of the cases
CASE_TIMEOUT = 60  # seconds for one case
ODIN_PROGRAM = ROOT / "odin" / "transforms" / "tests" / "differential"

# Pieces that exercise the transforms (together with the parser pieces).
TRANSFORM_PIECES = [
    ":Author: A. Name\n:Version: $Revision: 1.2 $\n:Date: $Date: 2001-08-16 12:00:00 +0000 (Thu) $\n",
    ":Authors: Me; Myself, I\n:Organization: Org\n:Status: $RCSfile: file.txt,v $\n",
    ":Authors: - One\n          - Two\n:Copyright: Public\n:Dedication: For you.\n",
    ":Abstract: Short.\n:Abstract: Twice.\n:Contact: me@example.org\n:Address: 1 Street\n   Town\n",
    ":Author: E. Xampl\n:Date: 2024-01-01\n:Authors:\n:Custom Field: value\n",
    ":Authors: A. B; C. D\n\n  Two paragraphs\n:Revision: 3\n",
    ".. sectnum::\n", ".. sectnum::\n   :depth: 2\n   :prefix: P\n   :suffix: .\n   :start: 3\n",
    ".. contents::\n   :local:\n", ".. contents:: Table\n   :depth: 1\n   :backlinks: top\n",
    ".. contents::\n   :backlinks: none\n   :class: tight\n", ".. target-notes::\n",
    ".. target-notes::\n   :class: tn\n", ".. class:: special\n", ".. class:: a b\n\n",
    ".. note:: Note body.\n", ".. warning:: Warn.\n\n   .. tip:: Nested tip.\n",
    ".. admonition:: Generic\n\n   Body.\n", ".. danger:: x\n", ".. attention:: y\n",
    "----------\n", "\n----------\n\n", ".. |t| replace:: *text* with |u|\n",
    ".. |u| replace:: inner\n", ".. |c1| replace:: |c2|\n.. |c2| replace:: |c1|\n",
    ".. |lt| unicode:: U+2014\n   :ltrim:\n", ".. |rt| unicode:: U+2014\n   :trim:\n",
    "Use |t| and |lt| and |rt| and |c1| and |undefined| here.\n",
    "Anon `one`__ and `two`__.\n\n__ http://one\n__ two_\n",
    ".. _two: http://two\n.. _three: two_\n.. _four: three_\n", ".. _loop1: loop2_\n.. _loop2: loop1_\n",
    "Refs: two_ three_ four_ loop1_ missing_ `dup`_ `<bad>`_ `a <b`_\n",
    ".. _dup:\n\n.. _dup:\n\nPara after targets.\n", ".. _internal:\n\n.. _other:\n\nTarget para.\n",
    "Footnotes [#]_ [#label]_ [*]_ [*]_ [*]_ [2]_ [CIT2002]_\n\n.. [#] auto one\n.. [#label] labelled\n",
    ".. [*] symbol\n.. [2] numbered\n.. [CIT2002] cite\n", "[#]_ [#]_ [#]_ too many\n",
    '"Double" \'single\' -- en --- em ... ellipsis `back\'s` "quoted *inline* text"\n',
    ".. class:: language-de\n\n\"Deutsch\" 'zitat'\n", ".. class:: language-xx\n\n\"Unknown\" text\n",
    ".. role:: fr(literal)\n   :class: language-fr\n\n:fr:`\"x\"` and \"y\"\n",
    ".. header:: Head text\n", ".. footer:: Foot text\n", ".. meta::\n   :keywords: a, b\n",
    ".. title:: Explicit Title\n", ".. raw:: html\n\n   <b>raw</b>\n", ".. math:: x^2\n",
    "Section\n=======\n\nSubsection\n----------\n\nText.\n", "Only\n====\n\nLone\n----\n\nBody\n",
    ".. _ext: http://example.org\n\nSee ext_ and `anon <http://anon.org>`__.\n",
    ".. figure:: fig.png\n\n   .. _figtarget:\n\n   Caption text\n",
    ".. topic:: Topic\n\n   .. _topictarget:\n", ".. |img| image:: pic.png\n   :alt: alt text\n",
    "Title with |img| and [#]_\n=========================\n", ".. compound::\n\n   Para.\n",
]

# Settings the random cases vary: (name, candidate values).
VARIANTS = [
    ("doctitle_xform", [True, True, False]),
    ("docinfo_xform", [True, True, False]),
    ("sectsubtitle_xform", [False, True]),
    ("footnote_references", [None, "brackets", "superscript"]),
    ("trim_footnote_reference_space", [None, None, True, False]),
    ("strip_comments", [None, True]),
    ("strip_classes", [None, None, ["special"], ["a", "tight"]]),
    ("strip_elements_with_classes", [None, None, ["b"], ["special"]]),
    ("smart_quotes", [False, True, True, "alt"]),
    ("smartquotes_locales", [None, None, [("de", "«»‹›")], [("xx", "<>{}")]]),
    ("language_code", ["en", "en", "de", "fr", "en-GB", "de-CH", "xx", "ja", "zh-cn", "pt-br"]),
    ("report_level", [1, 2, 2, 3, 4, 5]),
    ("expose_internals", [None, None, ["line", "source"], ["rawsource", "resolved", "tagname"]]),
    ("toc_backlinks", ["entry", "top", False]),
    ("sectnum_xform", [True, True, False]),
    ("id_prefix", ["", "", "p-"]),
    ("auto_id_prefix", ["%", "%", "id"]),
    ("title", [None, None, "Given Title"]),
    ("validate", [False, False, True]),
    ("generator", [None, True]),
    ("source_link", [None, True]),
    ("datestamp", [None, None, "%Y-%m-%d"]),
    ("use_latex_toc", [None, False, True]),
]

# Settings of the functional and documentation inputs: defaults, then variants.
FIXED_VARIANTS = [
    {},
    {"report_level": 1, "smart_quotes": True, "sectsubtitle_xform": True},
    {"doctitle_xform": False, "docinfo_xform": False, "language_code": "de",
     "toc_backlinks": "top", "sectnum_xform": False, "expose_internals": ["line", "source"]},
]


# --- publishing ------------------------------------------------------------------------

def _clear_caches() -> None:
    """Forget what a previous document left in docutils' process-wide caches (a fresh
    process for each document, as the native pipeline is)."""
    from docutils import languages
    from docutils.parsers.rst import languages as rst_languages
    from docutils.utils import smartquotes

    languages.get_language.cache.clear()
    rst_languages.get_language.cache.clear()
    if not hasattr(smartquotes.smartchars, "_docodin_quotes"):
        smartquotes.smartchars._docodin_quotes = dict(smartquotes.smartchars.quotes)
    smartquotes.smartchars.quotes = dict(smartquotes.smartchars._docodin_quotes)


def _is_node_class(node) -> bool:
    """Node classes of the interchange, including the plain ``nodes.Element``
    containers of directives (``Tag.Element`` natively): a message or pending element
    whose stale parent is such a container is not loose."""
    from docutils import nodes

    return (isinstance(node, nodes.Text) or type(node) is nodes.Element
            or type(node).__name__ in nodes.node_class_names)


doctree_json.is_node_class = _is_node_class

_ORIGINAL_FIELDS = doctree_json.Dumper.element_fields
_ORIGINAL_DETACHED = doctree_json.Dumper.detached_records


def _element_fields(self, node, rec: dict) -> None:
    """Detached copies of substitution references keep their ``ref-origin`` (a node);
    the native transform holds it outside the attributes.  (In the tree it would be
    an unsupported attribute value.)"""
    origin = node.attributes.pop("ref-origin", None) if self._in_detached else None
    try:
        _ORIGINAL_FIELDS(self, node, rec)
    finally:
        if origin is not None:
            node.attributes["ref-origin"] = origin


def _detached_records(self) -> list:
    self._in_detached = True
    return _ORIGINAL_DETACHED(self)


doctree_json.Dumper._in_detached = False
doctree_json.Dumper.element_fields = _element_fields
doctree_json.Dumper.detached_records = _detached_records

PEP_CLEANUP_CALLBACK = "docutils.transforms.peps.TargetNotes.cleanup_callback"
_ORIGINAL_DETAILS = doctree_json.Dumper.details


def _details(self, details: dict) -> dict:
    """``pending.details`` with the PEP reader's cleanup callback (a bound method) as
    its name, which is how the native pipeline records it."""
    callback = details.get("callback")
    if getattr(callback, "__name__", None) == "cleanup_callback":
        details = {**details, "callback": PEP_CLEANUP_CALLBACK}
    return _ORIGINAL_DETAILS(self, details)


doctree_json.Dumper.details = _details


_BOUND_CALLBACK = re.compile(r"<bound method TargetNotes\.cleanup_callback of "
                             r"<docutils\.transforms\.peps\.TargetNotes object at 0x[0-9a-f]+>>")


def _dump(document, run_input) -> str:
    data = doctree_json.snapshot(document, "transformed", run_input)
    pformat = data["expected"]["pformat"]
    data["expected"]["pformat"] = _BOUND_CALLBACK.sub(repr(PEP_CLEANUP_CALLBACK), pformat)
    return doctree_json.portable(doctree_json.dumps(data))


def publish_steps(text: str, source_path: str, writer: str, reader: str,
                  overrides: dict) -> dict:
    """Run docutils and snapshot the document at ``parsed``, after each transform and
    at the end.  ``{"parsed", "steps": [(transform, dump)], "final", "error"}``."""
    from docutils import core
    from docutils import io as dio

    _clear_caches()
    doctree_json._WRITTEN.clear()
    settings_overrides = {"_disable_config": True, **overrides,
                          "warning_stream": doctree_json._Capture()}
    pub = core.Publisher(reader, "restructuredtext", writer,
                         source_class=dio.StringInput, destination_class=dio.StringOutput)
    pub.process_programmatic_settings(None, settings_overrides, None)
    pub.set_source(text, source_path)
    pub.set_destination(None, None)
    pub.set_io()
    run_input = {"source_path": source_path, "writer": writer, "overrides": overrides}
    if reader != "standalone":
        run_input["reader"] = reader
    document = pub.reader.read(pub.source, pub.parser, pub.settings)
    t = document.transformer
    t.populate_from_components((pub.source, pub.reader, pub.reader.parser, pub.writer,
                                pub.destination))
    out = {"parsed": doctree_json.portable(doctree_json.dumps(
        doctree_json.snapshot(document, "parsed", run_input))), "steps": [], "error": None}
    document.reporter.attach_observer(document.note_transform_message)
    while t.transforms:
        if not t.sorted:
            t.transforms.sort(reverse=True)
            t.sorted = True
        priority, cls, pending, kwargs = t.transforms.pop()
        name = f"{cls.__module__}.{cls.__name__}"
        try:
            cls(document, startnode=pending).apply(**kwargs)
        except CaseTimeout:
            raise
        except Exception as e:  # docutils aborts the run
            out["error"] = {"transform": name, "message": f"{type(e).__name__}: {e}"}
            return out
        out["steps"].append((name, _dump(document, run_input)))
    document.reporter.detach_observer(document.note_transform_message)
    out["final"] = _dump(document, run_input)
    return out


def write_case(path: Path, name: str, result: dict) -> None:
    meta = {"name": name, "steps": [s[0] for s in result["steps"]], "error": result["error"]}
    records = [json.dumps(meta, ensure_ascii=False) + "\n", result["parsed"]]
    records += [s[1] for s in result["steps"]]
    if result["error"] is None:
        records.append(result["final"])
    path.write_text(SEP.join(records), encoding="utf-8")


# --- cases -----------------------------------------------------------------------------

def gen_transform_document(rng: random.Random) -> str:
    parts = []
    for _ in range(rng.randint(2, 14)):
        piece = rng.choice(TRANSFORM_PIECES if rng.random() < 0.6 else PIECES)
        if rng.random() < 0.1:
            piece = "".join("   " + line if line.strip() else line
                            for line in piece.splitlines(True))
        parts.append(piece)
        parts.append("\n")
    return "".join(parts)


def random_settings(rng: random.Random, writer: str) -> dict:
    out = {"halt_level": 5}
    for name, values in VARIANTS:
        value = rng.choice(values)
        if value is None or (name == "use_latex_toc" and writer != "latex"):
            continue
        if name == "footnote_references" and writer == "pseudoxml":
            continue
        out[name] = value
    if rng.random() < 0.03:
        out["debug"] = True
    return out


def fuzz_cases(count: int, seed: int) -> list[tuple]:
    rng = random.Random(seed)
    cases = []
    for i in range(count):
        text = gen_transform_document(rng)
        if rng.random() < 0.15:
            text = mutate(rng, text)
        writer = rng.choice(WRITERS)
        cases.append((f"fuzz-{i:05d}", text, f"fuzz-{i:05d}.rst", writer, "standalone",
                      random_settings(rng, writer)))
    return cases


def corpus_cases(src: Path, variants: int) -> list[tuple]:
    cases = []
    functional = sorted(src.glob("test/functional/input/*.rst"))
    docs = sorted(src.glob("docs/**/*.rst"))
    for path in functional + docs:
        rel = str(path.relative_to(src))
        text = path.read_text(encoding="utf-8")
        slug = rel.replace("/", "_").removesuffix(".rst")
        for writer in WRITERS:
            for v, overrides in enumerate(FIXED_VARIANTS[:variants]):
                cases.append((f"{slug}.{writer}.v{v}", text, rel, writer, "standalone",
                              {"halt_level": 5, **overrides}))
    for path in sorted(src.glob("docs/peps/pep-*.rst")):
        rel = str(path.relative_to(src))
        cases.append((f"pep_{path.stem}", path.read_text(encoding="utf-8"), rel, "html5", "pep",
                      {"halt_level": 5}))
    return cases


class CaseTimeout(Exception):
    pass


def _alarm(signum, frame):
    raise CaseTimeout


def init_worker() -> None:
    """Workers: no statemachine debug output, a time limit per case."""
    sys.stderr = open(os.devnull, "w")  # noqa: SIM115
    signal.signal(signal.SIGALRM, _alarm)


def run_case(args) -> tuple[str, str]:
    name, text, source_path, writer, reader, overrides, out_dir, cwd = args
    os.chdir(cwd)
    signal.alarm(120)
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            result = publish_steps(text, source_path, writer, reader, overrides)
    except doctree_json.InterchangeError as e:
        return name, f"skip: {e}"
    except CaseTimeout:
        return name, "skip: timeout"
    except RecursionError:
        return name, "skip: RecursionError"
    except Exception as e:  # noqa: BLE001 - the parser or a snapshot failed
        return name, f"skip: {type(e).__name__}: {e}"
    finally:
        signal.alarm(0)
    if result["error"] is None and "final" not in result:
        return name, "skip: no result"
    write_case(Path(out_dir) / f"{name}.case", name, result)
    return name, "ok"


# --- checking --------------------------------------------------------------------------

def build_program(out: Path) -> Path:
    exe = out / "transforms-differential"
    subprocess.run(["odin", "build", str(ODIN_PROGRAM), "-vet", "-strict-style", "-o:speed",
                    f"-out:{exe}"], check=True)
    return exe


def check_cases(exe: Path, files: list[Path], jobs: int, cwd: Path) -> list[str]:
    """Run the Odin program on ``jobs`` shares of the case files.  A share that takes
    too long is checked again case by case, each with a time limit."""
    chunks = [files[i::jobs] for i in range(jobs)]
    procs = []
    for n, chunk in enumerate(c for c in chunks if c):
        list_file = chunk[0].parent / f".chunk-{n}.lst"
        list_file.write_text("\n".join(str(f) for f in chunk) + "\n", encoding="utf-8")
        procs.append((chunk, subprocess.Popen([str(exe), "--list", str(list_file)], cwd=cwd,
                                              stdout=subprocess.PIPE, text=True)))
    lines = []
    for chunk, p in procs:
        try:
            stdout, _ = p.communicate(timeout=CHECK_TIMEOUT)
            lines.extend(stdout.splitlines())
        except subprocess.TimeoutExpired:
            p.kill()
            p.communicate()
            lines.extend(check_one_by_one(exe, chunk, cwd))
    return lines


def check_one_by_one(exe: Path, files: list[Path], cwd: Path) -> list[str]:
    lines = []
    for f in files:
        try:
            out = subprocess.run([str(exe), str(f)], cwd=cwd, capture_output=True, text=True,
                                 timeout=CASE_TIMEOUT).stdout
            lines.extend(out.splitlines())
        except subprocess.TimeoutExpired:
            lines.append(f"FAIL {f.stem} native run exceeds {CASE_TIMEOUT} s")
    return lines


def summarize(lines: list[str]) -> int:
    stats: dict[str, Counter] = {}
    results = Counter()
    failures = []
    for line in lines:
        if line.startswith("STATS "):
            for transform, counts in json.loads(line[6:]).items():
                stats.setdefault(transform, Counter()).update(counts)
        elif line.startswith(("PASS ", "FAIL ")):
            results[line[:4]] += 1
            if line.startswith("FAIL"):
                failures.append(line)
    modules: dict[str, Counter] = {}
    for transform, counts in sorted(stats.items()):
        module = transform.split(".")[-2]
        modules.setdefault(module, Counter()).update(counts)
        print(f"  {transform:60} {counts['identical']:6} / {counts['total']:6}")
    print("per module:")
    for module, counts in sorted(modules.items()):
        print(f"  {module:20} {counts['identical']:7} / {counts['total']:7}")
    print(f"cases: {results['PASS']} identical, {results['FAIL']} different")
    for line in failures[:40]:
        print(" ", line)
    return 1 if failures else 0


def parse_args(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--docutils-src", type=Path, help="docutils source tree (corpus inputs)")
    ap.add_argument("--variants", type=int, default=len(FIXED_VARIANTS),
                    help="settings variants of each corpus input")
    ap.add_argument("--fuzz", type=int, default=500, help="number of generated documents")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--out", type=Path, default=Path("/tmp/native-transforms-diff"))
    ap.add_argument("--check-only", action="store_true", help="check existing case files")
    ap.add_argument("--only", help="only cases whose name contains this")
    ap.add_argument("--worker", help=argparse.SUPPRESS)  # "I/N": generate a share
    return ap.parse_args(argv)


def all_cases(args) -> list[tuple]:
    cases = fuzz_cases(args.fuzz, args.seed)
    if args.docutils_src:
        cases += corpus_cases(args.docutils_src.resolve(), args.variants)
    if args.only:
        cases = [c for c in cases if args.only in c[0]]
    return cases


def worker(args, cwd: Path) -> int:
    """Generate the cases ``I::N``; one ``status name`` line per case."""
    i, n = (int(x) for x in args.worker.split("/"))
    init_worker()
    for case in all_cases(args)[i::n]:
        print(f"start {case[0]}", flush=True)
        name, status = run_case((*case, str(args.out / "cases"), str(cwd)))
        print(f"done {name} {status}"[:300], flush=True)
    return 0


def generate(args, argv: list[str]) -> None:
    """Run ``--jobs`` worker processes; a worker that dies is reported with the case
    it was generating."""
    cases_dir = args.out / "cases"
    for old in cases_dir.glob("*.case"):
        old.unlink()
    logs = [args.out / f"worker-{i}.log" for i in range(args.jobs)]
    procs = []
    for i, log in enumerate(logs):
        with log.open("w") as f:
            procs.append(subprocess.Popen(
                [sys.executable, __file__, *argv, "--worker", f"{i}/{args.jobs}"], stdout=f))
    outcomes = Counter()
    for p, log in zip(procs, logs, strict=True):
        p.wait()
        current = None
        for line in log.read_text(encoding="utf-8").splitlines():
            kind, _, rest = line.partition(" ")
            if kind == "start":
                current = rest
                continue
            current = None
            name, _, status = rest.partition(" ")
            outcomes[status.split(":")[0]] += 1
            if status != "ok":
                print(f"{name}: {status}")
        if p.returncode != 0 or current:
            print(f"worker died (exit {p.returncode}) in {current}")
            outcomes["died"] += 1
    print(f"generated: {dict(outcomes)}")


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    args = parse_args(argv)
    (args.out / "cases").mkdir(parents=True, exist_ok=True)
    cwd = args.docutils_src.resolve() if args.docutils_src else Path.cwd()
    if args.worker:
        return worker(args, cwd)
    if not args.check_only:
        generate(args, argv)
    exe = build_program(args.out)
    files = sorted((args.out / "cases").glob("*.case"))
    if args.only:
        files = [f for f in files if args.only in f.name]
    try:
        lines = check_cases(exe, files, args.jobs, cwd)
    except Exception:  # noqa: BLE001
        traceback.print_exc()
        return 2
    return summarize(lines)


if __name__ == "__main__":
    sys.exit(main())
