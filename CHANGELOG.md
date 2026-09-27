# Changelog

## 0.2.0

Faster parsing, lower memory, and editor support, following the research in
[docs/design/0.2.0.md](docs/design/0.2.0.md). Output is unchanged: docutils'
and Sphinx's test suites, and all differential tests, give the same results
as with docutils.

### Performance

- **Parser, 2.8× faster** (3.1× fewer instructions on a 21 MB corpus):
  - SIMD line splitting;
  - a candidate scanner that jumps between bytes that can start inline markup;
  - URI and e-mail searches only before `:` and `@`;
  - reference matching without large struct copies;
  - line joins as views of the input;
  - tab expansion over plain-ASCII runs (tab-indented documents 2.7–5×
    faster).
- **A quadratic case removed.** Positioning problematic inline markup used to
  rescan the text for every error, for example on a long line of `|x`
  (600 KB: from minutes to 27 ms).
- **Lower peak memory.**
  - Parse results are decoded from the native buffer without a copy, and
    large results item by item.
  - The per-thread arena maps its blocks from the OS and keeps at most 4 MB
    between calls.
  - A Sphinx build of CPython's documentation now peaks below stock docutils:
    883 MB against 895 MB.
- **Faster Python tree code.** Visitor dispatch and `walkabout` no longer
  format debug messages that are not shown.
- **Opt-in collector tuning.** Garbage-collector tuning in
  `docodin-sphinx-build` and the `docodin.sphinx` extension is now opt-in
  (`DOCODIN_GC=tuned`, `docodin_gc_tuning = True`). It is about 20 % faster,
  but some projects' output depends on when Python collects garbage (CPython's
  documentation changes in four pages, with docutils as with docodin). In
  0.1.0 it was on by default.

| Workload (Linux x86-64, 32 cores, Python 3.13) | docutils | docodin 0.2.0 |
|---|---|---|
| Sphinx, CPython documentation (599 pages, `-j1`) | 65.6 s, 895 MB | 47.6 s (1.38×), 883 MB; identical HTML |
| The same with `DOCODIN_GC=tuned` | – | 38.4 s (1.71×), 1034 MB |
| Sphinx, CPython documentation, `-j auto` | 32.7 s wall, 99.7 s CPU | 29.1 s wall, 74.7 s CPU |
| Publish the docutils documentation to HTML5 (60 files, in process) | 2.21 s | 0.96 s (shim), 0.20 s (`publish_native`) |
| The same, one command per file | 7.37 s | 0.22 s (`docodin`) |
| Check the docutils and Sphinx documentation | 2.81 s | 0.03 s (`docodin-check -j1`) |

### Editor support

- **`docodin-lsp`**, a native language server for reStructuredText:
  - diagnostics identical to docutils' messages, with the Elm-style hints and
    quick fixes (title underlines, missing blank lines, unmatched inline
    markup, `::` without a literal block);
  - document symbols, folding ranges and semantic tokens;
  - go to definition and references for targets, sections, substitutions,
    footnotes and citations;
  - hover and completion (directives, options, roles, targets, substitutions).

  It parses each change once and answers in about 6 ms for a 124 KB document.
  Setup for Zed, VS Code and Neovim is in the README.
- **Source positions.** Every parse node can carry its byte span
  (`Parse_Flag.Spans`), with a line table and a UTF-16-aware line index for
  LSP positions. Spans cost about 10 % when on and nothing when off.
- **`publish.read_document`** runs the native reader and transforms and
  returns the document and its messages as records.

## 0.1.0

The first release: docodin replaces docutils 0.22.4, for Sphinx and every
other docutils user, with a native reStructuredText engine written in Odin.

### docutils replacement

- A complete implementation of the docutils package: nodes, frontend, io,
  readers, the reStructuredText parser, directives, roles, transforms,
  utilities, the math converters, and the writers (html4css1, html5,
  latex2e, xetex, manpage, odt, xml, pseudo-XML, s5, pep).
- A native parser for the block and inline grammar, with docutils' exact tree
  shapes, messages and node positions.
- A pure-Python fallback parser for documents whose grammar extensions
  change: custom or patched parser states, patched `Inliner` dispatch, or
  `DOCODIN_NATIVE=0`.
- Native smart quotes.
- Ways to use it: `docodin-sphinx-build`, the `DOCODIN_DOCUTILS=1` start-up
  hook, and an automatic fallback when docutils is not installed.
- docutils' test suite, Sphinx's test suite and the test suites of popular
  extensions and themes give the same results as with docutils.

### Native tools

- `docodin-check`: parallel markup checking with Elm-style reports (source
  excerpt, markers, hints) or docutils' message format.
- `docodin`: publishes documents without Python, with docutils' output,
  messages and exit status. The pipeline covers the reader, the transforms,
  and the pseudo-XML, XML, HTML5, LaTeX and XeLaTeX writers. `docodin pdf`
  runs the LaTeX writer and TeX.
- `docodin.publish_native` gives Python access to the native pipeline.
- Native publishing is complete: where docutils would use a Python library
  (Pygments, PIL, `urllib`, codecs, parser and writer modules, external
  MathML converters), the native pipeline reports it with the feature and
  its line. `publish_native`, `render_html` and `render_latex` then publish
  the document with docutils (`native_only=True` raises `NeedsPythonError`
  instead), and `docodin` runs `python -m docodin` with the same arguments,
  streams and exit status, or explains what needs Python when no Python with
  docodin is found. `--config` and the `--dump-*` options work the same way.
- `docodin-sphinx-build` and the `docodin.sphinx` extension tune Python's
  garbage collector: moderately raised thresholds, and the long-lived objects
  are frozen after the extensions are loaded and after reading. This saves
  about 18 % on the CPython documentation, for about 17 % more peak memory.
  (Opt-in since 0.2.0: see there.)

### Performance

Measured on Linux x86-64 with Python 3.13, docutils 0.22.4 and Sphinx 9.1:

| Workload | docutils | docodin |
|----------|----------|---------|
| Sphinx, CPython documentation (599 pages, `-j1`) | 64.3 s | 48.3 s (1.33×) |
| Sphinx, CPython documentation (`-j auto`, 32 cores) | 32.5 s, 99 s CPU | 29.1 s, 74 s CPU |
| Publish the docutils documentation to HTML5 (60 files, in process) | 1.98 s | 0.90 s (shim), 0.20 s (`publish_native`) |
| Same, one command per file | 7.48 s (`python -m docutils`) | 0.23 s (`docodin`) |
| Check the docutils and Sphinx documentation | 2.83 s (parser) | 0.05 s (`-j1`), 0.01 s (all cores) |

The HTML Sphinx builds were identical: 599 pages. In the single-process
Sphinx build, docodin's peak memory is higher (999 MB against 890 MB); the
memory held after reading is the same.
