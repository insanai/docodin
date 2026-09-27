# docodin

docodin is a drop-in replacement for [docutils](https://docutils.sourceforge.io/)
0.22, built on a reStructuredText engine written in [Odin](https://odin-lang.org/).
Sphinx, its extensions and every other docutils user run on it unchanged, with
identical output.

It has three parts:

- **A docutils implementation** (`python/docodin/shim/docutils`). The whole
  docutils package, written for docodin: nodes, parser, directives, roles,
  transforms, and every writer (HTML, LaTeX/XeTeX, manpage, ODT, XML, S5,
  PEP). It passes docutils' own test suite and Sphinx's test suite with the
  same results as docutils.
- **A native reST engine** (`odin/rst`). It parses the block and inline
  grammar exactly as docutils does, including every system message and line
  number, about 5× faster. The shim builds the Python document tree from its
  output.
- **Native tools** (`odin/check`, `cmd/`). `docodin-check` reports markup
  errors without Python: Elm-style reports with source excerpts and hints, or
  docutils' one-line format. A native document pipeline (document tree,
  transforms, HTML and LaTeX writers) is being built; see
  [docs/NATIVE_PIPELINE.md](docs/NATIVE_PIPELINE.md).

## Installation

```bash
uv pip install docodin          # or: pip install docodin
```

Wheels contain the native library for their platform. To build from source
you need the Odin compiler (`dev-2026-09` or newer) and a C toolchain (clang
on macOS, clang or cc on Linux):

```bash
uv build                        # sdist and platform wheel (hatchling)
scripts/build_odin.sh           # development: library, docodin-check, docodin
```

## Using docodin instead of docutils

docodin serves the `docutils` package itself. Programs keep importing
`docutils`, and there is no other API to learn.

| How | What happens |
|-----|--------------|
| `docodin-sphinx-build ARGS...` | `sphinx-build` running on docodin |
| `DOCODIN_DOCUTILS=1 any-command` | every Python process in the environment uses docodin (for example `sphinx-build`, `tox`, test runners) |
| docutils not installed | `import docutils` finds docodin automatically |
| `docodin.shim.install_shim(force=True)` | switch the current process, before docutils is imported |

The start-up hook behind `DOCODIN_DOCUTILS` (`docodin.pth`) costs about
0.1 ms and imports nothing unless docutils is requested.

Extensions that change the reST grammar still work exactly as with docutils.
That covers custom state classes, subclassed or monkeypatched parser states,
and patched `Inliner` dispatch. For those documents docodin parses with its
pure-Python state machine. `DOCODIN_NATIVE=0` forces the Python parser
everywhere, for debugging.

## Compatibility

- **docutils' test suite**: 465 passed, 17 skipped, 1862 subtests, identical to
  docutils. This holds natively and with `DOCODIN_NATIVE=0`.
- **Sphinx 9.1's test suite**: 2407 passed. The 7 failures are environment
  related and fail the same way with docutils.
- **Extensions and themes**: the test suites of myst-parser, sphinx-design,
  sphinx-tabs, sphinxcontrib-bibtex, sphinx-autodoc-typehints, sphinx-gallery,
  pydata-sphinx-theme, sphinx-book-theme, sphinxext-opengraph,
  sphinx-notfound-page, sphinx-rtd-theme and breathe give the same results as
  with docutils.
- **Documentation builds**: the furo, pydata, MyST and sphinx-design docs
  build to identical output with the html, latex, man and text builders, and
  CPython's documentation to identical HTML.
- **Differential testing**: generated and mutated documents are published by
  docutils and docodin with every writer under random settings. Outputs,
  warnings, and the source and line of every node must be identical
  (`tests/shim_differential.py`, `tests/fuzz_differential.py`).

## Performance

Sphinx 9.1, building CPython's documentation (599 pages, HTML, one process,
Linux x86-64):

| docutils | docodin | Speedup |
|----------|---------|---------|
| 64.8 s   | 49.0 s  | 1.32×   |

The reading phase (parsing and docutils transforms) drops from 35.7 s to
22.4 s. The rest is Sphinx's own processing and Python's garbage collector.
Peak memory is the same.

Standalone docutils work on the docutils documentation (60 files, 1.36 MB,
Apple M1):

| Task | docutils | docodin | Speedup |
|------|----------|---------|---------|
| parse → doctree | 1192 ms | 228 ms | 5.2× |
| publish HTML5 | 1794 ms | 802 ms | 2.2× |
| `docodin-check` on the docutils and Sphinx docs (2.75 MB) | 2.47 s | 49 ms (1 core), 14 ms (8 cores) | 50–175× |

## Native checker

```bash
docodin-check docs/*.rst                           # Elm-style reports
docodin-check --error-format=docutils docs/*.rst   # source:line: (LEVEL/n) text
docodin-check --report=info --exit-status=warning README.rst
```

```
-- UNCLOSED EMPHASIS ----------------------------------------- guide.rst:12:6

Inline emphasis start-string without end-string.

12| Some *emphasis without an end.
         ^
Hint: Close the emphasis with a matching `*`, or write `\*` for a literal
asterisk.
```

The checker reports what the parser detects, including in the reST content
of the standard directives. Directive execution, roles and reference
resolution need Python; use `docodin` or Sphinx for those.

## Layout

```
odin/rst/           reST parser (data-oriented parse tree)
odin/check/         checker core and Elm-style diagnostics
odin/doctree/       native docutils document tree, registry, reporter, JSON interchange
odin/lib/           C ABI library used by the Python package
cmd/                docodin-check and the docodin native CLI
python/docodin/     Python package: tree builder, shim, Sphinx integration
python/docodin/shim/docutils/   the docutils implementation
scripts/            build script, table and data generators
tests/              unit, parity, differential, conformance and benchmark tools
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design.

## Tests

```bash
odin test odin/tests && odin test odin/doctree/tests
uv run python -m pytest tests
uv run python tests/shim_differential.py --cases 2000
uv run python tests/fuzz_differential.py --cases 10000
uv run python tests/lint_differential.py
```

## License

MIT
