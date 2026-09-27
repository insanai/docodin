"""Differential testing of the docutils shim against real docutils, end to end.

Random documents (see ``fuzz_differential.py``) and corpus files are published
with every writer by two worker processes, one running real docutils and one
running the docodin shim, under randomly varied settings.  The outputs
(including warnings and exceptions) must be identical.

    uv run python tests/shim_differential.py [--cases N] [--seed S] [--jobs J]
        [--corpus DIR] [--out DIR] [--writers W,...]
"""

from __future__ import annotations

import argparse
import json
import os
import random
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

import fuzz_differential as fuzz  # noqa: E402

# "positions": source and line of every element after the transforms (Sphinx
# reports warnings with them; pseudo-XML does not show them).
WRITERS = ("positions", "pseudoxml", "xml", "html5", "html4", "latex", "xetex", "manpage", "odt")

SETTING_CHOICES = {
    "doctitle_xform": [True, False],
    "docinfo_xform": [True, False],
    "sectsubtitle_xform": [False, True],
    "smart_quotes": [False, True, "alt"],
    "footnote_references": ["brackets", "superscript"],
    "section_self_link": [False, True],
    "toc_backlinks": ["entry", "top", "none"],
    "language_code": ["en", "de", "fr", "ja"],
    "strip_comments": [False, True],
    "pep_references": [False, True],
    "rfc_references": [False, True],
    "report_level": [2, 1, 4],
    "math_output": ["HTML math.css", "MathML", "LaTeX", "MathJax"],
    "trim_footnote_reference_space": [False, True],
    "character_level_inline_markup": [False, True],
}

# Runs in the worker processes: reads JSON requests, writes JSON results.
WORKER = r'''
import io, json, sys, warnings, zipfile
warnings.simplefilter("ignore", FutureWarning)  # docutils announces 1.0 defaults
if sys.argv[1] == "shim":
    import docodin.shim
    docodin.shim.install_shim(force=True)
import docutils.core, docutils.nodes
assert (sys.argv[1] == "shim") == bool(getattr(docutils, "__docodin_shim__", False))

def publish(text, writer, settings):
    warnings = io.StringIO()
    overrides = {"_disable_config": True, "warning_stream": warnings, "halt_level": 5,
                 "embed_stylesheet": False, "stylesheet_path": "", "output_encoding": "unicode",
                 "input_encoding": "unicode", **settings}
    if writer == "odt":
        overrides.pop("output_encoding")
    try:
        if writer == "positions":
            doc = docutils.core.publish_doctree(text, source_path="doc.rst",
                                                settings_overrides=overrides)
            out = "\n".join("%s %s %s" % (n.tagname, n.source, n.line)
                            for n in doc.findall(docutils.nodes.Element))
        else:
            out = docutils.core.publish_string(text, source_path="doc.rst", writer_name=writer,
                                               settings_overrides=overrides)
    except BaseException as error:  # noqa: BLE001 - the exception is the result
        out = "EXCEPTION %s: %s" % (type(error).__name__, error)
    if isinstance(out, bytes):  # odt: compare the document parts
        with zipfile.ZipFile(io.BytesIO(out)) as z:
            out = z.read("content.xml").decode() + z.read("styles.xml").decode()
    return [out, warnings.getvalue()]

for line in sys.stdin:
    request = json.loads(line)
    result = {w: publish(request["text"], w, request["settings"]) for w in request["writers"]}
    sys.stdout.write(json.dumps(result) + "\n")
    sys.stdout.flush()
'''


class Worker:
    """A long-running publisher process (real docutils or the shim)."""

    def __init__(self, mode: str) -> None:
        env = {**os.environ, "PYTHONPATH": str(ROOT / "python")}
        self.proc = subprocess.Popen([sys.executable, "-c", WORKER, mode], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, text=True, env=env, cwd=str(ROOT))

    def publish(self, text: str, settings: dict, writers: tuple[str, ...]) -> dict:
        self.proc.stdin.write(json.dumps({"text": text, "settings": settings,
                                          "writers": writers}) + "\n")
        self.proc.stdin.flush()
        return json.loads(self.proc.stdout.readline())

    def close(self) -> None:
        self.proc.stdin.close()
        self.proc.wait()


def random_settings(rng: random.Random) -> dict:
    return {key: rng.choice(values) for key, values in SETTING_CHOICES.items()
            if rng.random() < 0.3}


def documents(rng: random.Random, corpus: list[str], cases: int):
    for _ in range(cases):
        roll = rng.random()
        if corpus and roll < 0.15:
            text = rng.choice(corpus)
        else:
            text = fuzz.gen_document(rng)
            if roll > 0.8:
                text = fuzz.mutate(rng, text)
        yield text, random_settings(rng)


def masked(output: str) -> str:
    """Drop lines naming the installation directory (stylesheet and theme paths)."""
    return "\n".join(line for line in output.splitlines()
                     if "site-packages" not in line and "/shim/docutils/" not in line)


def run_chunk(items: list[tuple[str, dict]], out_dir: Path, first: int,
              writers: tuple[str, ...] = WRITERS) -> int:
    real, shim = Worker("real"), Worker("shim")
    failures = 0
    try:
        for i, (text, settings) in enumerate(items, first):
            expected = real.publish(text, settings, writers)
            got = shim.publish(text, settings, writers)
            bad = [w for w in writers
                   if [masked(x) for x in expected[w]] != [masked(x) for x in got[w]]]
            if bad:
                failures += 1
                case = {"text": text, "settings": settings, "writers": bad,
                        "expected": {w: expected[w] for w in bad},
                        "got": {w: got[w] for w in bad}}
                (out_dir / f"case{i:05d}.json").write_text(json.dumps(case, indent=1))
    finally:
        real.close()
        shim.close()
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--cases", type=int, default=200)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    parser.add_argument("--corpus", default="")
    parser.add_argument("--out", default="shim-differential-failures")
    parser.add_argument("--writers", default=",".join(WRITERS))
    args = parser.parse_args()
    corpus = [p.read_text(encoding="utf-8", errors="replace")
              for p in Path(args.corpus).rglob("*.rst")] if args.corpus else []
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    items = list(documents(random.Random(args.seed), corpus, args.cases))
    size = max(1, -(-len(items) // args.jobs))
    chunks = [(items[i:i + size], i) for i in range(0, len(items), size)]
    with ThreadPoolExecutor(args.jobs) as pool:
        writers = tuple(args.writers.split(","))
        failures = sum(pool.map(lambda chunk: run_chunk(chunk[0], out_dir, chunk[1], writers),
                                chunks))
    print(f"{len(items) - failures}/{len(items)} identical (failures in {out_dir})")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
