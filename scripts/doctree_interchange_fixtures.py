"""Generate the doctree interchange dumps that odin/doctree/tests checks.

Each input is published with docutils (see scripts/doctree_json.py) for one writer and
dumped at every stage (``parsed``, ``transformed``, ``output``) to
``<name>.<writer>.<stage>.json``.  The inputs are the docutils functional test inputs
(``test/functional/input/*.rst``) and documentation (``docs/**/*.rst``) of a docutils
source tree, and documents of the fuzz generator (tests/fuzz_differential.py).

By default a modest fixture set is written to odin/doctree/tests/fixtures/interchange:
the small documents (each with one writer, in rotation) and a few fuzz documents.  With
``--corpus DIR`` every document is dumped with every writer to DIR, for a local run of
the Odin test with ``DOCTREE_INTERCHANGE_DIR=DIR``.  The docutils installation directory
is written as ``<docutils>`` (``doctree_json.py --portable``), so the dumps do not depend
on the machine.

    PY="uv run --no-project --python 3.14 --with docutils==0.22.4 python"
    $PY scripts/doctree_interchange_fixtures.py --docutils-src ~/src/docutils-0.22.4
"""

from __future__ import annotations

import argparse
import os
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path[:0] = [str(ROOT / "scripts"), str(ROOT / "tests")]

import doctree_json  # noqa: E402
from fuzz_differential import gen_document, mutate  # noqa: E402

FIXTURES = ROOT / "odin" / "doctree" / "tests" / "fixtures" / "interchange"
WRITERS = ("pseudoxml", "html5", "latex")
FIXTURE_LIMIT = 60_000  # largest dump (bytes) of a document kept as a fixture
FIXTURE_BUDGET = 3_500_000  # bytes of fixtures from the docutils sources


def sources(src: Path) -> list[str]:
    """The corpus paths, relative to the docutils source tree (which is the working
    directory while publishing, so that includes resolve)."""
    functional = sorted(src.glob("test/functional/input/*.rst"))
    docs = sorted(src.glob("docs/**/*.rst"))
    return [str(p.relative_to(src)) for p in functional + docs]


def fuzz_documents(count: int, seed: int) -> list[tuple[str, str, dict]]:
    """``(name, text, settings overrides)`` of generated documents."""
    rng = random.Random(seed)
    out = []
    for i in range(count):
        text = gen_document(rng)
        if rng.random() < 0.3:
            text = mutate(rng, text)
        overrides = {"halt_level": 5, "report_level": rng.choice([1, 2, 2, 5])}
        out.append((f"fuzz-{i:03d}.rst", text, overrides))
    return out


def dump(text: str, path: str, writer: str, overrides: dict) -> dict[str, str] | None:
    """The dumps of all stages; without ``output`` if the writer fails (e.g. a
    limitation of the LaTeX writer), None if docutils fails before."""
    stages = doctree_json.STAGES
    try:
        data = doctree_json.publish_stages(text, path, writer, overrides)
    except Exception as e:  # noqa: BLE001 - reported
        print(f"{path} ({writer}): {type(e).__name__}: {e}", file=sys.stderr)
        stages = ("parsed", "transformed")
        try:
            data = doctree_json.publish_stages(text, path, writer, overrides, stages)
        except Exception:  # noqa: BLE001 - reported above
            return None
    return {stage: doctree_json.portable(doctree_json.dumps(data[stage])) for stage in stages}


def slug(path: str) -> str:
    return path.removesuffix(".rst").replace("/", "_")


def write(out: Path, name: str, writer: str, dumps: dict[str, str]) -> int:
    size = 0
    for stage, text in dumps.items():
        (out / f"{slug(name)}.{writer}.{stage}.json").write_text(text, encoding="utf-8")
        size += len(text.encode())
    return size


def generate(src: Path, out: Path, corpus: bool, fuzz: int, seed: int) -> None:
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("*.json"):
        old.unlink()
    files = total = budget = 0
    cwd = os.getcwd()
    os.chdir(src)
    try:
        for i, path in enumerate(sources(src)):
            text = Path(path).read_text(encoding="utf-8")
            for writer in WRITERS if corpus else (WRITERS[i % len(WRITERS)],):
                dumps = dump(text, path, writer, {})
                small = dumps and max(len(t) for t in dumps.values()) <= FIXTURE_LIMIT
                if dumps and (corpus or small and budget < FIXTURE_BUDGET):
                    size = write(out, path, writer, dumps)
                    budget += size
                    total += size
                    files += len(dumps)
    finally:
        os.chdir(cwd)
    for i, (name, text, overrides) in enumerate(fuzz_documents(fuzz, seed)):
        for writer in WRITERS if corpus else (WRITERS[i % len(WRITERS)],):
            dumps = dump(text, name, writer, overrides)
            if dumps:
                total += write(out, name, writer, dumps)
                files += len(dumps)
    print(f"{files} dumps, {total / 1e6:.1f} MB in {out}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--docutils-src", type=Path, required=True,
                    help="docutils 0.22.4 source tree (with test/functional and docs)")
    ap.add_argument("--corpus", type=Path,
                    help="dump every document with every writer to this directory")
    ap.add_argument("--fuzz", type=int, help="number of fuzz documents (default 30, corpus 300)")
    ap.add_argument("--seed", type=int, default=20260927)
    args = ap.parse_args(argv)
    fuzz = args.fuzz if args.fuzz is not None else (300 if args.corpus else 30)
    out = args.corpus or FIXTURES
    generate(args.docutils_src.resolve(), out, args.corpus is not None, fuzz, args.seed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
