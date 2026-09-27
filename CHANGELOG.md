# Changelog

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
  about 18 % on the CPython documentation, for about 4 % more peak memory.
  Set `DOCODIN_GC=default` or `docodin_gc_tuning = False` to turn it off.

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
