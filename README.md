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
- **Native tools** (`odin/check`, `odin/publish`, `cmd/`). `docodin-check`
  reports markup errors without Python: Elm-style reports with source excerpts
  and hints, or docutils' one-line format. `docodin` publishes documents
  without Python, with docutils' output, messages and exit status: the native
  document pipeline (reader, transforms, and the pseudo-XML, XML, HTML5, LaTeX
  and XeLaTeX writers); see [docs/NATIVE_PIPELINE.md](docs/NATIVE_PIPELINE.md).
  Documents that need a Python library (Pygments, PIL, ...) go through
  docutils automatically.

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

Linux x86-64 with 32 cores, Python 3.13, docutils 0.22.4 and Sphinx 9.1 (see
CHANGELOG.md):

| Workload | docutils | docodin |
|----------|----------|---------|
| Sphinx, CPython documentation (599 pages, `-j1`) | 64.3 s | 48.3 s (1.33×) |
| Sphinx, CPython documentation (`-j auto`) | 32.5 s wall, 99 s CPU | 29.1 s wall, 74 s CPU |
| Publish the docutils documentation to HTML5 (60 files, in process) | 1.98 s | 0.90 s (shim), 0.20 s (`publish_native`) |
| The same, one command per file | 7.48 s (`python -m docutils`) | 0.23 s (`docodin`) |
| Check the docutils and Sphinx documentation for markup errors | 2.83 s | 0.05 s (`docodin-check -j1`) |

In Sphinx builds the output is identical, and the remaining time is mostly
Sphinx's own processing. Peak memory of the single-process build is higher
(999 MB against 890 MB); the memory held after reading is the same.

## Native publishing

```bash
docodin doc.rst doc.html                     # as: python -m docutils doc.rst doc.html
docodin --writer=latex --documentclass=book doc.rst doc.tex
rst2xetex doc.rst doc.tex                    # rst2* names (links to docodin) pick the writer
docodin pdf doc.rst                          # LaTeX writer + pdflatex (or --engine=xelatex)
docodin --help --writer=latex                # the options of a writer
```

`docodin` takes docutils' front-end options (report, halt and exit-status
levels, title and docinfo switches, section numbering, backlinks, footnote
references, smart quotes, stripping, language, encodings, stylesheets, math
output, table styles, LaTeX document class and options, ...) and writes the
same output, messages and exit status as `python -m docutils`. It reads no
configuration files (`--config` runs it through Python, see below); `html` is
the html5 writer. Bad options get Elm-style reports with a hint.

From Python, `docodin.publish_native(source, writer="html5",
settings_overrides=...)` returns what `publish_string` returns (and
`publish_parts` with `parts=True`), raising docutils' exceptions.
`docodin.render_html` and `docodin.render_latex` return the whole document
or its body.

Some docutils features use Python libraries, which docodin does not
reimplement: Pygments (code with a language), PIL (image sizes for scaled
images and `:figwidth: image`), `urllib` (`:url:` options other than local
`file:` URLs), Python's codecs (encodings other than UTF-8, Latin-1 and
ASCII), parser and writer modules (`include` with `:parser:`, writers other
than the native ones) and external MathML converters. The native pipeline
detects where docutils would use one, and such documents are published by
docutils instead, so the result is always docutils' (with the libraries
that are installed):

- `publish_native`, `render_html` and `render_latex` use the importable
  docutils. Pass `native_only=True` to get a `docodin.NeedsPythonError`,
  listing each feature and its line, instead.
- `docodin` runs `python -m docodin` with the same arguments, standard
  streams and exit status. It uses `$DOCODIN_PYTHON`, else `python3`, if it
  imports docodin; `--config` and the `--dump-*` options go the same way.
  Without such a Python, it reports what needs Python and how to avoid it
  (for example `--syntax-highlight=none`) and exits with status 1:

```
-- NEEDS PYTHON ---------------------------------------------------- guide.rst:4

Highlighting "python" code needs Pygments.

docodin runs these with docutils' Python front end (`python -m docodin`), but
found no Python that imports docodin: it tries `$DOCODIN_PYTHON`, then
`python3`.

4| .. code:: python
   ^^^^^^^^^^^^^^^^
Hint: Install docodin's Python package (`pip install docodin`) or set
`DOCODIN_PYTHON` to a Python that has it, or write `--syntax-highlight=none` to
publish the code without highlighting.
```

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
odin/reader/        native reader: docutils document trees, directives and roles
odin/transforms/    native docutils transforms
odin/writers/       native pseudo-XML, XML, HTML5 and LaTeX/XeLaTeX writers
odin/math/          native math2html and latex2mathml (package texmath)
odin/text/          native smart quotes
odin/publish/       native publisher (settings, reader, transforms, writer)
odin/lib/           C ABI library used by the Python package
cmd/                docodin-check and the docodin native CLI
python/docodin/     Python package: tree builder, shim, Sphinx integration
python/docodin/shim/docutils/   the docutils implementation
scripts/            build script, table and data generators
tests/              unit, parity, differential, conformance and benchmark tools
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design.

## Known limits

- Two nested-include cases (in about 20,000 generated documents) differ in
  line numbers: an `include` two directive levels deep with more content
  after it in the outer directive.
- The native pipeline does not see directives, roles or transforms
  registered in Python; publish such documents with docutils (the shim).
- In `docodin` and `python -m docodin`, `html` is the html5 writer (in
  docutils it is html4css1).

Native publishing has no other limits: documents that need a Python
library are published by docutils (see [Native publishing](#native-publishing)).

## Tests

```bash
for t in odin/tests odin/{doctree,reader,transforms,writers,publish}/tests; do odin test $t; done
uv run python -m pytest tests
uv run python tests/shim_differential.py --cases 2000
uv run python tests/fuzz_differential.py --cases 10000
uv run python tests/lint_differential.py
uv run --no-project --python 3.14 --with docutils==0.22.4 python \
    tests/native_publish_differential.py --docutils-src ~/src/docutils-0.22.4 --fuzz 3000
```

## License

MIT
