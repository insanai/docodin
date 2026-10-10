"""End-to-end differential test of the native publisher (odin/publish) against docutils.

Each document is published by docutils 0.22.4 (``Publisher.publish`` as ``publish_string``
and ``publish_parts`` run it, with ``enable_exit_status`` and ``traceback`` off, as
``publish_cmdline`` runs) and by ``publish.publish`` (the reader, the transforms and the
writer in Odin) with the same settings.  Compared: the output, every part, the text written
to the warning stream, the failure report and the exit status.

The inputs are the docutils functional test inputs and ``docs/**/*.rst`` with every writer
and a few settings variants, and generated documents (tests/fuzz_differential.py and the
transform and writer pieces) under random settings, including halting and exit status levels.
Code is compared with ``syntax_highlight: none`` (no Pygments).  Documents whose images
docutils would measure with PIL are reported separately.  Where the native publisher reports
that docutils would use a Python library (the hosts publish such documents with docutils),
its output is still that of docutils without the library, as in this reference: it is
compared, and the documents are counted by feature.

    PY="uv run --no-project --python 3.14 --with docutils==0.22.4 python"
    $PY tests/native_publish_differential.py --docutils-src ~/src/docutils-0.22.4 --fuzz 3000
"""

from __future__ import annotations

import argparse
import copy
import io
import json
import multiprocessing as mp
import os
import random
import re
import signal
import subprocess
import sys
import warnings
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path[:0] = [str(ROOT / "scripts"), str(ROOT / "tests")]

import docutils  # noqa: E402
from docutils import core, frontend, nodes  # noqa: E402
from docutils import io as dio  # noqa: E402
from docutils.parsers.rst import directives as rst_directives  # noqa: E402
from docutils.parsers.rst import roles as rst_roles  # noqa: E402
from docutils.writers import _html_base  # noqa: E402
from fuzz_differential import gen_directive_document, gen_document, mutate  # noqa: E402
from native_transforms_differential import _clear_caches, gen_transform_document  # noqa: E402
from native_transforms_differential import random_settings as transform_settings  # noqa: E402
from native_writers_differential import VARIANTS, gen_writer_document  # noqa: E402

WRITERS = ("pseudoxml", "xml", "html5", "latex", "xetex")
BASE = {"syntax_highlight": "none"}
DOCUTILS_DIR = str(Path(docutils.__file__).resolve().parent)
MATH_TAGS = copy.deepcopy(_html_base.HTMLTranslator.math_tags)
PYTHON_VERSION = re.compile(r"Python version \([^)]*\)")
NATIVE_PYTHON_VERSION = "Python version (none: docodin native)"

# Settings of the corpus besides each writer's variants.
CORPUS_VARIANTS = [
    {},
    {"report_level": 1, "smart_quotes": True, "sectsubtitle_xform": True, "halt_level": 5},
    {"doctitle_xform": False, "docinfo_xform": False, "toc_backlinks": "top",
     "sectnum_xform": False, "exit_status_level": 2, "halt_level": 3},
]


# --- jobs -----------------------------------------------------------------------------------

def corpus_jobs(src: Path, writers: tuple[str, ...]) -> list[dict]:
    """Functional inputs and docs/**/*.rst with every writer and settings variant."""
    jobs = []
    groups = [("functional", sorted((src / "test").glob("functional/input/*.rst")), src / "test"),
              ("docs", sorted(src.glob("docs/**/*.rst")), src)]
    for group, files, cwd in groups:
        for path in files:
            rel = str(path.relative_to(cwd))
            for writer in writers:
                variants = CORPUS_VARIANTS + VARIANTS[writer][1:2]
                for i, variant in enumerate(variants):
                    jobs.append({"name": f"{group}:{rel}:{writer}:{i}", "path": rel,
                                 "source_path": rel, "cwd": str(cwd), "writer": writer,
                                 "overrides": {**BASE, **variant}, "group": group})
    return jobs


def random_overrides(rng: random.Random, writer: str) -> dict:
    """Transform settings, a writer variant, and random halt and exit status levels."""
    overrides = {**BASE, **transform_settings(rng, writer), **rng.choice(VARIANTS[writer])}
    overrides["halt_level"] = rng.choice([5, 5, 5, 4, 3, 2])
    if rng.random() < 0.3:
        overrides["exit_status_level"] = rng.choice([1, 2, 3, 4])
    if rng.random() < 0.1:  # command-line style values, converted by the validators
        overrides["report_level"] = rng.choice(["info", "warning", "3", "none"])
        overrides["tab_width"] = rng.choice(["4", "8"])
    return overrides


GENERATORS = (gen_document, gen_directive_document, gen_transform_document, gen_writer_document)


def fuzz_jobs(count: int, seed: int, writers: tuple[str, ...], cwd: Path) -> list[dict]:
    rng = random.Random(seed)
    jobs = []
    for n in range(count):
        text = GENERATORS[n % len(GENERATORS)](rng)
        if rng.random() < 0.15:
            text = mutate(rng, text)
        writer = rng.choice(writers)
        jobs.append({"name": f"fuzz:{n:05d}:{writer}", "text": text,
                     "source_path": f"fuzz-{n:05d}.rst", "cwd": str(cwd), "writer": writer,
                     "overrides": random_overrides(rng, writer), "group": "fuzz"})
    return jobs


# --- docutils -------------------------------------------------------------------------------

class CaseTimeout(Exception):
    pass


def _alarm(signum, frame):
    raise CaseTimeout


def init_worker() -> None:
    sys.stderr = open(os.devnull, "w")  # noqa: SIM115 - statemachine debug output
    signal.signal(signal.SIGALRM, _alarm)


def needs_pil(document) -> bool:
    """An image docutils measures with PIL: scaled without width and height, or a figure
    with ``:figwidth: image``."""
    if document is None:
        return False
    for node in document.findall(nodes.image):
        if "scale" in node and not ("width" in node and "height" in node):
            return True
    return any(fig.get("width") == "image" for fig in document.findall(nodes.figure))


# Settings the native publisher gets as command-line strings: docutils converts them with
# the option's validator (as for a command line or a configuration file).
VALIDATORS = {"report_level": frontend.validate_threshold,
              "tab_width": frontend.validate_nonnegative_int}


def validated(overrides: dict) -> dict:
    return {k: VALIDATORS[k](v) if isinstance(v, str) and k in VALIDATORS else v
            for k, v in overrides.items()}


def publish_reference(job: dict) -> dict:
    """What ``publish_cmdline`` would write and return, for a string source."""
    stream, report = io.StringIO(), io.StringIO()
    overrides = {"_disable_config": True, **validated(job["overrides"]),
                 "warning_stream": stream, "traceback": False}
    pub = core.Publisher("standalone", "restructuredtext", job["writer"],
                         source_class=dio.StringInput, destination_class=dio.StringOutput)
    pub._stderr = dio.ErrorOutput(report)
    pub.process_programmatic_settings(None, overrides, None)
    pub.set_source(job["text"], job["source_path"])
    pub.set_destination(None, None)
    status = 0
    try:
        pub.publish(enable_exit_status=True)
    except SystemExit as e:
        status = e.code if isinstance(e.code, int) else 1
    output = pub.destination.destination
    if isinstance(output, bytes):
        output = output.decode(pub.settings.output_encoding)
    parts = {k: v for k, v in (pub.writer.parts or {}).items() if isinstance(v, str)}
    return {"output": output or "", "parts": parts, "messages": stream.getvalue(),
            "report": report.getvalue(), "status": status, "pil": needs_pil(pub.document)}


def reference(job: dict) -> dict:
    os.chdir(job["cwd"])
    if "text" not in job:
        job["text"] = Path(job["path"]).read_text(encoding="utf-8")
    _clear_caches()  # a fresh process for each document, as the native publisher is
    rst_directives._directives.clear()
    rst_roles._roles.clear()
    _html_base.HTMLTranslator.math_tags = copy.deepcopy(MATH_TAGS)
    signal.alarm(60)
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            job["expected"] = publish_reference(job)
    except CaseTimeout:
        job["skip"] = "docutils timeout"
    except BaseException as e:  # noqa: BLE001 - docutils itself fails: nothing to compare
        job["skip"] = f"docutils: {type(e).__name__}: {e}"[:160]
    finally:
        signal.alarm(0)
    return job


# --- the native publisher -------------------------------------------------------------------

def build_runner(work: Path) -> Path:
    exe = work / "publish-differential"
    subprocess.run(["odin", "build", str(ROOT / "odin/publish/tests/differential"),
                    f"-out:{exe}", "-o:speed", "-vet", "-strict-style"], check=True)
    return exe


def run_native(exe: Path, cases: list[dict], path: Path) -> dict[str, dict]:
    """Native outcomes by case name; a crashing batch is retried case by case."""
    fields = ("name", "text", "source_path", "writer", "cwd", "overrides")
    path.write_text(json.dumps([{k: c[k] for k in fields} for c in cases]), encoding="utf-8")
    proc = subprocess.run([str(exe), "--docutils-dir", DOCUTILS_DIR, str(path)],
                          capture_output=True, check=False, timeout=3600)
    results = {}
    for line in proc.stdout.decode("utf-8", "replace").splitlines():
        try:
            out = json.loads(line)
        except json.JSONDecodeError:
            continue
        results[out["name"]] = out
    missing = [c for c in cases if c["name"] not in results]
    if proc.returncode != 0 and missing:
        if len(cases) == 1:
            err = proc.stderr.decode("utf-8", "replace").strip().splitlines()[-1:] or ["?"]
            return {cases[0]["name"]: {"crash": f"exit {proc.returncode}: {err[0][:200]}"}}
        for c in missing:
            results.update(run_native(exe, [c], path.with_suffix(".one.json")))
    return results


def run_all_native(exe: Path, cases: list[dict], work: Path, jobs: int) -> dict[str, dict]:
    batches = [cases[i:i + 40] for i in range(0, len(cases), 40)]
    results: dict[str, dict] = {}
    with ThreadPoolExecutor(jobs) as pool:
        futures = [pool.submit(run_native, exe, b, work / f"batch-{i}.json")
                   for i, b in enumerate(batches)]
        for f in futures:
            results.update(f.result())
    return results


# --- comparing ------------------------------------------------------------------------------

def difference(field: str, want: str, got: str) -> str:
    i = next((k for k, (a, b) in enumerate(zip(want, got, strict=False)) if a != b),
             min(len(want), len(got)))
    return f"{field}@{i}: {want[max(0, i - 30):i + 50]!r} | {got[max(0, i - 30):i + 50]!r}"


def compare(job: dict, native: dict) -> str:
    """"" if identical, else the first difference."""
    if "crash" in native:
        return f"native crash: {native['crash']}"
    want = job["expected"]
    if want["status"] != native["status"]:
        return f"status: docutils {want['status']}, native {native['status']}"
    report = PYTHON_VERSION.sub(NATIVE_PYTHON_VERSION, want["report"])
    for field, a, b in (("messages", want["messages"], native["messages"]),
                        ("report", report, native["report"])):
        if a != b:
            return difference(field, a, b)
    if want["report"]:
        return ""  # failed: no output to compare
    if want["output"] != native["output"]:
        return difference("output", want["output"], native["output"])
    parts = dict(native["parts"])
    for name, value in want["parts"].items():
        if parts.get(name) != value:
            return difference(f"part {name}", value, parts.get(name) or "")
    return ""


def report(jobs: list[dict], results: dict[str, dict], work: Path) -> int:
    totals: dict[tuple[str, str], Counter] = defaultdict(Counter)
    failures, kinds, needs = [], Counter(), Counter()
    for job in jobs:
        key = (job["writer"], job["group"])
        if "skip" in job:
            totals[key]["skipped"] += 1
            continue
        pil = job["expected"]["pil"]
        native = results.get(job["name"], {"crash": "no result"})
        needs.update({need.split(":", 1)[0] for need in native.get("needs", [])})
        diff = compare(job, native)
        totals[key]["total"] += 1
        totals[key]["pil" if pil else "identical"] += diff == ""
        totals[key]["pil-total"] += pil
        pil_fallback = any(need.split(":", 1)[0] == "pil" for need in native.get("needs", []))
        if diff and (not pil or not pil_fallback):
            failures.append(f"{job['name']}  {diff}")
            kinds[diff.split("@")[0].split(":")[0]] += 1
            save_failure(work, job, results.get(job["name"], {}))
    print(f"{'writer':9} {'group':10} identical / total  (PIL identical / PIL, skipped)")
    for (writer, group), c in sorted(totals.items()):
        plain = c["total"] - c["pil-total"]
        print(f"{writer:9} {group:10} {c['identical']:6} / {plain:<6}  "
              f"({c['pil']} / {c['pil-total']}, {c['skipped']})")
    for kind, n in kinds.most_common():
        print(f"  {n:5} differ first in {kind}")
    for feature, n in sorted(needs.items()):
        print(f"  {n:5} need Python ({feature})")
    (work / "failures.txt").write_text("\n".join(failures) + "\n", encoding="utf-8")
    print(f"{len(failures)} failures listed in {work / 'failures.txt'}")
    return 1 if failures else 0


def save_failure(work: Path, job: dict, native: dict) -> None:
    out = work / "failed"
    out.mkdir(exist_ok=True)
    name = re.sub(r"[^A-Za-z0-9_.-]+", "_", job["name"])
    data = {"job": {k: v for k, v in job.items() if k != "expected"},
            "docutils": job["expected"], "native": native}
    (out / f"{name}.json").write_text(json.dumps(data, indent=1, ensure_ascii=False),
                                      encoding="utf-8")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--docutils-src", type=Path, required=True,
                    help="docutils 0.22.4 source tree (with test/functional and docs)")
    ap.add_argument("--work", type=Path, default=Path("build/native-publish"))
    ap.add_argument("--groups", default="functional,docs,fuzz")
    ap.add_argument("--writers", default=",".join(WRITERS))
    ap.add_argument("--fuzz", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=20260927)
    ap.add_argument("--jobs", type=int, default=os.cpu_count())
    args = ap.parse_args(argv)
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    groups = set(args.groups.split(","))
    writers = tuple(w for w in args.writers.split(",") if w)
    jobs = [j for j in corpus_jobs(args.docutils_src.resolve(), writers) if j["group"] in groups]
    if "fuzz" in groups:
        fuzz_dir = work / "fuzz-cwd"
        fuzz_dir.mkdir(exist_ok=True)
        jobs += fuzz_jobs(args.fuzz, args.seed, writers, fuzz_dir)
    exe = build_runner(work)
    print(f"{len(jobs)} jobs")
    with mp.Pool(args.jobs, initializer=init_worker) as pool:
        jobs = list(pool.imap(reference, jobs, chunksize=4))
    results = run_all_native(exe, [j for j in jobs if "skip" not in j], work, args.jobs)
    return report(jobs, results, work)


if __name__ == "__main__":
    sys.exit(main())
