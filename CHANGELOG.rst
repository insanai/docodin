=========
Changelog
=========

1.0.0b1
=======

The first beta.  It states its own support contract instead of promising that every
docutils and Sphinx user runs unchanged: native publishing, the native checker, the
language server's documented single-document features, native HTML book and site builds
from the documented ``conf.py`` values and markup subset, and LaTeX and XeLaTeX output
with an external TeX engine for PDFs.  The Python, docutils and Sphinx integrations are
supported within their measured bounds; full parity with every extension is a goal, not
a promise.  The book's chapter "Known limits" and DOD 19 have the details.  This release
fixes the findings of an external release review of revision ``82fb438``.

Fixes
-----

- **PDF engine paths preserve Unicode.** Full paths to ``xelatex`` and ``lualatex``
  now select the Unicode-capable writer, just like bare engine names, on both native
  and Python-fallback publications.
- **Book chapter contents stay aligned.** An unnumbered opening chapter now advances
  minitoc's counter when its entry is added to the global contents. Each chapter's
  local contents lists its own sections instead of the preceding chapter's.
- **Book PDF subprocesses inherit TeX settings.** The book compiler keeps the caller's
  environment, including font and search paths, instead of overriding TeX log limits.
- **Documentation presentation.** The README has a shorter introduction, practical
  examples and explicit beta limits. A pencil-drawn Sphinx/Odin logo appears in the
  README and both documentation projects, including their native PDF introductions.
- **Native image dimensions.**  PNG, JPEG, GIF, BMP, TIFF and WebP headers supply HTML5
  image scaling and ``:figwidth: image`` without Pillow or pixel decoding.  The reader
  uses at most 64 KiB; other formats, longer or invalid headers and very large images
  retain the Pillow fallback.  Missing images, video images, non-file URIs and disabled
  file insertion now give Docutils-with-Pillow diagnostics directly.  The differential
  suite requires natively handled image cases to match rather than excluding every PIL
  case from its failure count.
- **Shared-library arenas no longer outlive their threads.**  After each outermost call,
  a thread's arena block goes to a process-wide cache of at most 8 blocks of at most
  4 MiB (``bump_park`` and ``bump_unpark`` in ``odin/lib/bump.odin``).  A thread that
  exits keeps nothing, so a host that creates and retires threads stays bounded.  Before,
  each retired thread kept its block: the review's C host grew about 1 MiB per thread
  (104 MiB after 100 threads, 202 MiB after 200).  With 1.0.0b1 it stays at 6.05 MiB
  after both 100 and 200 retired threads on Linux x86-64, and at 5.1 MiB on macOS arm64.
- **Book sources that are not UTF-8 stop the build.**  ``docodin book build`` reports a
  source that cannot be read (UNREADABLE SOURCE) or decoded as UTF-8 (SOURCE IS NOT
  UTF-8) as a SEVERE problem, writes no output and exits with status 1.  Before, it
  wrote invalid HTML and exited with status 0.
- **Collector tuning in docodin-sphinx-build.**  With ``DOCODIN_GC=tuned`` the collector
  is now frozen right after Sphinx starts.  It used to wait for ``builder-inited``,
  which Sphinx had already emitted, so the first freeze never happened.  The tuning's
  measurements in 0.1.0 and 0.2.0 were made without that freeze and have not been
  repeated.
- **Grammar changes on an installed docutils.**  ``docodin.Parser``,
  ``patch_docutils`` and the ``docodin.sphinx`` extension now detect patched stock
  parser states and ``DOCODIN_NATIVE=0`` on an installed docutils, as docodin's own
  docutils does, and parse those documents with docutils' Python parser.  The logic is
  shared in ``docodin._grammar``; on an installed docutils, the stock states are
  recorded when ``docodin.parser`` is imported.

Distribution
------------

- **GitHub project workflows.** Verification on Linux and macOS, a native GitHub Pages
  site, qualified wheels/source/native archives, draft tagged releases and a separate
  PyPI publishing workflow. Odin and PDF font downloads are checksum verified.
- **Public author credits.** Vikrant Rathore, with algorithm assistance from Ronak
  Rathore and logo design by Kanak Rathore. Documentation author fields contain names
  only; ``docodin dod new`` no longer copies Git email addresses into records.

- **The wheel installs the native programs** ``docodin``, ``docodin-check`` and
  ``docodin-lsp`` into the environment's ``bin`` (``Scripts``) directory.  The Python
  console script ``docodin`` is removed: the native ``docodin`` runs ``python -m
  docodin`` for what needs Python, with ``$DOCODIN_PYTHON``, else the ``python3`` or
  ``python`` next to the program, else ``python3`` on the ``PATH``.
  ``docodin-sphinx-build`` remains a Python console script.  On macOS the programs
  target macOS 11, like the library.  The native ``docodin`` hands ``--writer=NAME`` with
  a Python-only writer to Python too, and takes the first arguments of the Python front
  end: the ``rst2*`` names, among them ``rst2man``, ``rst2odt`` and ``rst2s5``.
- **manylinux wheels.**  ``hatch_build.py`` tags a Linux wheel
  ``manylinux_<x>_<y>_<arch>`` after the newest ``GLIBC_x.y`` symbol version that the
  shipped library and programs require.  The 1.0.0b1 build is
  ``manylinux_2_34_x86_64``: glibc 2.34 or later (Ubuntu 22.04, Debian 12, RHEL 9 or
  newer).  ``auditwheel show`` confirms the tag.
- **The native programs run without the source checkout.**  They embed docutils'
  standard include files (``<isonum.txt>`` and the others), as they already embedded the
  stylesheets and templates.  With the checkout present they use its docutils data
  directory, so paths in messages stay the same.  Without it, ``--link-stylesheet``
  links a stylesheet by its file name.
- **License files.**  ``LICENSE`` (MIT), ``NOTICE.rst`` and ``LICENSES/`` (docutils'
  terms, the 2-Clause BSD license, the SmartyPants license and the Unicode License v3)
  ship in the sdist and the wheel.
- **One version.**  The version is 1.0.0b1 in ``pyproject.toml``,
  ``docodin.__version__``, the documentation's ``conf.py`` files and one Odin constant
  (``odin/version``) shared by the library, the programs and the generated pages.
  ``tests/test_release.py`` checks that they agree.

Commands
--------

- ``docodin sphinx ARGS``: ``sphinx-build`` with docodin's parser, run as ``python -m
  docodin sphinx ARGS`` with the Python found as above.
- ``docodin dod new --author="Name <email>"`` names the author of a new record.
  Without it, and without git's ``user.name`` and ``user.email``, the command stops with
  NO AUTHOR instead of writing a record with no author.

Release process
---------------

- ``scripts/release_gate.sh`` builds the engine and programs, runs every Odin test group
  and the Python tests, builds the sdist and then a wheel from the unpacked sdist in a
  temporary directory that is deleted, checks a Linux wheel's tag with ``auditwheel
  show``, installs that wheel in a new environment outside the checkout, and smoke-tests
  the programs, the library and Sphinx.  It then builds
  ``docs/book`` and ``docs/dod`` with the installed ``docodin``, with PDFs when
  ``lualatex`` is installed (otherwise it says SKIPPED).  The log, the artifacts and the
  documentation go to ``build/release-gate/<revision>/``.
- Test fixes: the site search-index test no longer frees its allocator before its
  clean-up, and the DOD tests no longer depend on the runner's git identity.

Platforms
---------

The release gate has passed on macOS arm64, with the PDF books, and on Linux x86-64
(glibc, ``manylinux_2_34_x86_64``), where the host has no TeX engine and the PDFs were
skipped; both under CPython 3.12.  On Linux the Python tests gave 276 passed and 8
skipped.  Windows, other architectures and musl-based Linux are not verified.

Performance
-----------

The native book builder against Sphinx, as measured by the review: fresh HTML builds on
Linux x86-64 (AMD Ryzen 9 5950X, 32 logical CPUs), Sphinx 9.1 run serially, docutils
0.22.4, the median of three runs including start-up.

.. list-table::
   :header-rows: 1
   :widths: 44 24 32

   * - Project
     - Sphinx
     - ``docodin book build --html``
   * - The docodin Book (40 pages)
     - 1.771 s, 82.4 MiB
     - 0.064 s (27.8 times), 23.6 MiB
   * - A generated 151-page manual
     - 7.093 s, 186.8 MiB
     - 0.249 s (28.5 times), 107.5 MiB

These numbers are for the native builder, which writes its own theme and runs no Sphinx
extensions.  The Sphinx-on-docodin numbers of 0.2.0 measure a different path.

Verification
------------

The review, on Linux x86-64 under CPython 3.14: docutils' test suite gave 465 passed,
16 skipped and 1863 subtests on stock docutils, on docodin's docutils and with
``DOCODIN_NATIVE=0``; Sphinx's test suite gave 2380 passed, 28 skipped and the same 15
failing tests on stock docutils and on docodin.  Of 2940 native publishing differential
jobs, the 2893 outside the PIL category matched docutils; of the 47 that involve PIL, 41
matched and 6 differ in the image library's diagnostics, at the documented boundary
where the native tools hand documents to Python.

Documentation
-------------

- *The docodin Book* (``docs/book``), a manual in five parts with appendices, and the
  DocOdin Discussions (``docs/dod``), docodin's numbered design records.  Both are
  reStructuredText, built with Sphinx and with docodin, to HTML and PDF.
- The README and this changelog are reStructuredText.  The Markdown documents and the
  Typst specification were converted into the book and the design records, and removed.
- The README, the book and DOD 19 describe the beta's support contract, the native
  programs in the wheel and the release gate.

0.2.0
=====

Faster parsing, lower memory, and editor support, following the research recorded in
DOD 12 (``docs/dod/0012-parser-research-0-2-0.rst``).  Output is unchanged: docutils'
and Sphinx's test suites, and all differential tests, give the same results as with
docutils.

Performance
-----------

- **Parser, 2.8 times faster** (3.1 times fewer instructions on a 21 MB corpus):

  - SIMD line splitting;
  - a candidate scanner that jumps between bytes that can start inline markup;
  - URI and e-mail searches only before ``:`` and ``@``;
  - reference matching without large struct copies;
  - line joins as views of the input;
  - tab expansion over plain-ASCII runs (tab-indented documents 2.7 to 5 times
    faster).

- **A quadratic case removed.**  Positioning problematic inline markup used to rescan
  the text for every error, for example on a long line of ``|x`` (600 KB: from minutes
  to 27 ms).
- **Lower peak memory.**

  - Parse results are decoded from the native buffer without a copy, and large results
    item by item.
  - The per-thread arena maps its blocks from the OS and keeps at most 4 MB between
    calls.
  - A Sphinx build of CPython's documentation now peaks below stock docutils: 883 MB
    against 895 MB.

- **Faster Python tree code.**  Visitor dispatch and ``walkabout`` no longer format
  debug messages that are not shown.
- **Opt-in collector tuning.**  Garbage-collector tuning in ``docodin-sphinx-build`` and
  the ``docodin.sphinx`` extension is now opt-in (``DOCODIN_GC=tuned``,
  ``docodin_gc_tuning = True``).  It is about 20 % faster, but some projects' output
  depends on when Python collects garbage (CPython's documentation changes in four
  pages, with docutils as with docodin).  In 0.1.0 it was on by default.

.. list-table:: Linux x86-64, 32 cores, Python 3.13
   :header-rows: 1
   :widths: 44 24 32

   * - Workload
     - docutils
     - docodin 0.2.0
   * - Sphinx, CPython documentation (599 pages, ``-j1``)
     - 65.6 s, 895 MB
     - 47.6 s (1.38 times), 883 MB; identical HTML
   * - The same with ``DOCODIN_GC=tuned``
     - not applicable
     - 38.4 s (1.71 times), 1034 MB
   * - Sphinx, CPython documentation, ``-j auto``
     - 32.7 s wall, 99.7 s CPU
     - 29.1 s wall, 74.7 s CPU
   * - Publish the docutils documentation to HTML5 (60 files, in process)
     - 2.21 s
     - 0.96 s (shim), 0.20 s (``publish_native``)
   * - The same, one command per file
     - 7.37 s
     - 0.22 s (``docodin``)
   * - Check the docutils and Sphinx documentation
     - 2.81 s
     - 0.03 s (``docodin-check -j1``)

Editor support
--------------

- **docodin-lsp**, a native language server for reStructuredText:

  - diagnostics identical to docutils' messages, with the Elm-style hints and quick
    fixes (title underlines, missing blank lines, unmatched inline markup, ``::``
    without a literal block);
  - document symbols, folding ranges and semantic tokens;
  - go to definition and references for targets, sections, substitutions, footnotes
    and citations;
  - hover and completion (directives, options, roles, targets, substitutions).

  It parses each change once and answers in about 6 ms for a 124 KB document.  Setup
  for Zed, VS Code and Neovim is in The docodin Book, chapter "Editor support".

- **Source positions.**  Every parse node can carry its byte span (``Parse_Flag.Spans``),
  with a line table and a UTF-16-aware line index for LSP positions.  Spans cost about
  10 % when on and nothing when off.
- **publish.read_document** runs the native reader and transforms and returns the
  document and its messages as records.

0.1.0
=====

The first release: docodin replaces docutils 0.22.4, for Sphinx and every other docutils
user, with a native reStructuredText engine written in Odin.

docutils replacement
--------------------

- A complete implementation of the docutils package: nodes, frontend, io, readers, the
  reStructuredText parser, directives, roles, transforms, utilities, the math
  converters, and the writers (html4css1, html5, latex2e, xetex, manpage, odt, xml,
  pseudo-XML, s5, pep).
- A native parser for the block and inline grammar, with docutils' exact tree shapes,
  messages and node positions.
- A pure-Python fallback parser for documents whose grammar extensions change: custom or
  patched parser states, patched ``Inliner`` dispatch, or ``DOCODIN_NATIVE=0``.
- Native smart quotes.
- Ways to use it: ``docodin-sphinx-build``, the ``DOCODIN_DOCUTILS=1`` start-up hook, and
  an automatic fallback when docutils is not installed.
- docutils' test suite, Sphinx's test suite and the test suites of popular extensions and
  themes give the same results as with docutils.

Native tools
------------

- ``docodin-check``: parallel markup checking with Elm-style reports (source excerpt,
  markers, hints) or docutils' message format.
- ``docodin``: publishes documents without Python, with docutils' output, messages and
  exit status.  The pipeline covers the reader, the transforms, and the pseudo-XML, XML,
  HTML5, LaTeX and XeLaTeX writers.  ``docodin pdf`` runs the LaTeX writer and TeX.
- ``docodin.publish_native`` gives Python access to the native pipeline.
- Native publishing is complete: where docutils would use a Python library (Pygments,
  PIL, ``urllib``, codecs, parser and writer modules, external MathML converters), the
  native pipeline reports it with the feature and its line.  ``publish_native``,
  ``render_html`` and ``render_latex`` then publish the document with docutils
  (``native_only=True`` raises ``NeedsPythonError`` instead), and ``docodin`` runs
  ``python -m docodin`` with the same arguments, streams and exit status, or explains
  what needs Python when no Python with docodin is found.  ``--config`` and the
  ``--dump-*`` options work the same way.
- ``docodin-sphinx-build`` and the ``docodin.sphinx`` extension tune Python's garbage
  collector: moderately raised thresholds, and the long-lived objects are frozen after
  the extensions are loaded and after reading.  This saves about 18 % on the CPython
  documentation, for about 17 % more peak memory.  (Opt-in since 0.2.0: see there.)

Performance
-----------

.. list-table:: Linux x86-64, Python 3.13, docutils 0.22.4 and Sphinx 9.1
   :header-rows: 1
   :widths: 44 24 32

   * - Workload
     - docutils
     - docodin
   * - Sphinx, CPython documentation (599 pages, ``-j1``)
     - 64.3 s
     - 48.3 s (1.33 times)
   * - Sphinx, CPython documentation (``-j auto``, 32 cores)
     - 32.5 s, 99 s CPU
     - 29.1 s, 74 s CPU
   * - Publish the docutils documentation to HTML5 (60 files, in process)
     - 1.98 s
     - 0.90 s (shim), 0.20 s (``publish_native``)
   * - Same, one command per file
     - 7.48 s (``python -m docutils``)
     - 0.23 s (``docodin``)
   * - Check the docutils and Sphinx documentation
     - 2.83 s (parser)
     - 0.05 s (``-j1``), 0.01 s (all cores)

The HTML Sphinx builds were identical: 599 pages.  In the single-process Sphinx build,
docodin's peak memory is higher (999 MB against 890 MB); the memory held after reading
is the same.
