# docodin

docodin is a reStructuredText parser written in [Odin](https://odin-lang.org/).
It is a drop-in replacement for the docutils reST parser, for docutils itself,
Sphinx, and any Python tool built on docutils.

The native engine implements the whole reStructuredText grammar:
- the block state machine
- section titles, lists, tables, and explicit markup
- inline markup

It reproduces docutils 0.22 exactly, including line numbers and every
system message. The Python host then builds real `docutils.nodes` trees and
runs the docutils (or Sphinx) directives, roles, transforms, and writers.
Output is identical to docutils, and the parser is 5× faster.

The native checker `docodin-check` reports reST markup errors in docutils'
format without Python. It is about 50× faster than docutils single-threaded,
and faster still across cores.

## Performance

The benchmarks ran on an Apple M1 with docutils 0.22.4 and CPython 3.14.

**docutils documentation** (60 files, 1.36 MB), run with
`python tests/benchmark.py docutils-0.22.4/docs --repeat 3`:

| Task                                   | docutils  | docodin   | Speedup |
|----------------------------------------|-----------|-----------|---------|
| parse → doctree                        | 1192 ms   | 228 ms    | 5.2×    |
| publish pseudo-XML (parse + transforms + writer) | 1615 ms | 625 ms | 2.6× |
| publish HTML5                          | 1794 ms   | 802 ms    | 2.2×    |
| native parse only (no Python objects)  | —         | 32 ms     | 44 MB/s |

**Markup checking**, over the docutils and Sphinx documentation (214 files, 2.75 MB):

| Tool                     | Time    |
|--------------------------|---------|
| docutils parser          | 2.47 s  |
| `docodin-check -j1`      | 49 ms   |
| `docodin-check` (8 cores)| 14 ms   |

**Sphinx's own documentation** (pseudo-XML builder, 154 documents): 4.73 s,
against 6.54 s with the stock parser. The output is identical apart from
object addresses.

End-to-end speedups are smaller than parse speedups. Transforms and writers
are still docutils' Python code, and they cost the same in both cases.

## Compatibility

docodin is checked against docutils in these ways:

- **docutils' parser test suite** (`test/test_parsers/test_rst`): 913 of 913
  cases give identical pseudo-XML.
  ```
  python tests/conformance/run_docutils_suite.py path/to/docutils-0.22.4
  ```
- **The full docutils test suite, run under `docodin.patch_docutils()`**: the
  same results as stock docutils (465 tests, 1826 subtests).
- **The Sphinx test suite, with the extension enabled**: the same results as
  the stock parser (2407 passed; the 7 failures are environment-related and
  also fail without docodin).
- **Differential fuzzing** (`tests/fuzz_differential.py`): grammar-based
  documents and byte-level mutations of real documents. Each one is parsed
  by both implementations and compared: the pseudo-XML, including every
  system message, and the `source`/`line` of every node. `node.line` isn't
  shown in pseudo-XML, but transforms and Sphinx use it in their warnings.
  60,000 cases were identical.
- **The checker** (`tests/lint_differential.py`): its messages are compared
  with docutils' parser messages on generated documents and on the
  docutils/Sphinx documentation.

The native engine takes over only when the parser uses the standard docutils
grammar. If a program installs custom state classes, or an `Inliner` subclass
with extra inline patterns, docodin falls back to the pure-Python parser.

## Installation

Requirements:
- the Odin compiler (`dev-2026-09` or newer)
- a C toolchain (clang on macOS, cc on Linux)
- Python ≥ 3.12 and docutils 0.22

```bash
scripts/build_odin.sh     # builds python/docodin/libdocodin.* and bin/docodin-check
uv pip install -e .       # (the build hook also runs build_odin.sh)
```

## Usage

### Sphinx

```python
# conf.py
extensions = ["docodin.sphinx"]
```

### docutils API

```python
import docodin

html = docodin.publish_string(source, writer="html5")
parts = docodin.publish_parts(source, writer="html5")
doctree = docodin.publish_doctree(source)
document = docodin.parse(source)            # parse only, no transforms
```

`docodin.Parser` is a subclass of `docutils.parsers.rst.Parser`. You can use
it anywhere docutils accepts a parser:

```python
docutils.core.publish_string(source, parser=docodin.Parser(), writer="html5")
```

To make every docutils user in the process, including third-party code, parse
with docodin:

```python
docodin.patch_docutils()      # docodin.unpatch_docutils() restores docutils
```

### Command line

```bash
docodin --writer=html5 input.rst output.html     # any docutils front-end option
docodin rst2latex input.rst output.tex            # rst2* names select the writer
docutils --parser=docodin input.rst               # docutils' own front end
```

### Native checker

```bash
docodin-check docs/*.rst                    # report warnings and errors
docodin-check --report=info --exit-status=warning README.rst
```

Messages go to standard error in docutils' format,
`source:line: (LEVEL/n) text`. The exit status is 1 when a message at or
above `--exit-status` was reported (the default is `error`). See
`docodin-check --help` for all options.

The checker reports what the parser detects:
- inline markup errors
- malformed lists, tables, sections, and explicit markup
- inconsistent title levels

It also parses the reST inside the standard content directives (admonitions,
`topic`, `sidebar`, `container`, `table`, `figure`, `replace`, and others).

Some diagnostics come from the Python side of docutils, and the checker does
not report them:
- directive execution and unknown directives
- roles
- duplicate target names
- substitution definition validation
- reference resolution

Use `docodin` or Sphinx for those.

## Layout

```
odin/rst/            parser package: state machine, body/explicit/table/inline parsers
odin/lib/            shared library: C ABI, per-thread bump arena, marshal serializer
cmd/docodin-check/   native checker
odin/tests/          Odin unit tests
python/docodin/      docutils/Sphinx host: tree builder, Parser, Sphinx extension, CLI
scripts/             build script and table generators
tests/               unit, parity, conformance, fuzzing and benchmark tools
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design.

## Tests

```bash
odin test odin/tests                                        # Odin unit tests
pytest tests/                                               # unit and parity tests
DOCUTILS_SRC=path/to/docutils pytest tests/test_conformance.py
python tests/fuzz_differential.py --cases 10000
python tests/lint_differential.py --cases 5000
python tests/benchmark.py [CORPUS_DIR ...]
```

## License

MIT
