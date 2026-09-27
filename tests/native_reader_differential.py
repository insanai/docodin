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
    sys.path.insert(0, str(ROOT / "tests"))
    from fuzz_differential import gen_directive_document

    return [(f"directives-{i}", gen_directive_document(random.Random(seed * 7_000_003 + i)))
            for i in range(count)]


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
