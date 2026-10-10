=======
docodin
=======

docodin is a reStructuredText toolchain built on an engine written in `Odin
<https://odin-lang.org/>`__.  It publishes, checks and builds documentation natively,
without Python, with the output and messages of `docutils
<https://docutils.sourceforge.io/>`__ 0.22.4.  It also contains a docutils package for
Python, so that Sphinx and other docutils users can parse with the native engine.

This is the first beta, 1.0.0b1.  The book's chapter "Known limits"
(``docs/book/reference/limits.rst``) states what it supports and where it stops.

- **A native reStructuredText engine** (``odin/rst``): docutils' block and inline
  grammar, every system message and line number, about five times faster than docutils'
  parser.
- **Native tools**: ``docodin`` publishes without Python, with docutils' output,
  messages and exit status, and builds HTML sites and PDF books; ``docodin-check``
  explains markup errors in milliseconds; ``docodin-lsp`` gives editors docutils'
  diagnostics as you type.  Documents that need a Python library (Pygments, PIL, ...)
  go through docutils automatically.
- **A docutils implementation** (``python/docodin/shim/docutils``): the whole docutils
  package, written for docodin, with every writer.  docutils' and Sphinx's test suites
  give the same results on it as on docutils.

The documentation is **The docodin Book** (``docs/book``), and the design decisions are
the **DocOdin Discussions** (``docs/dod``).  ``docs/README.rst`` explains how to build
them.

What the beta supports
======================

- **Native publishing**: reStructuredText to HTML5, LaTeX, XeLaTeX, Docutils XML and
  pseudo-XML with docutils' standard reader, transforms and writers, the same output,
  messages and exit status, and no Python unless a document needs a Python library.
- **The native checker**: ``docodin-check`` reports the parser's messages, explained or in
  docutils' format.
- **The language server**: ``docodin-lsp``'s documented features, one document at a time
  (diagnostics, definitions, references, hover, completion, symbols, folding, semantic
  tokens).
- **Native HTML book and site builds**: ``docodin book build`` builds a Sphinx project
  that keeps to the documented ``conf.py`` values and markup subset (the book's chapter
  "Maintaining the documentation").
- **LaTeX and XeLaTeX output**: ``docodin pdf`` and ``docodin book build`` write LaTeX
  and run an external TeX engine (``pdflatex``, ``xelatex`` or ``lualatex``) for PDFs.
- **Python, docutils and Sphinx integrations**, within their measured bounds: docutils'
  and Sphinx's test suites, and those of the extensions listed below, give the same
  results as with docutils.  Full parity with every extension and every Sphinx project
  is a goal, not a promise.

The native book builder reads ``conf.py`` rather than running it, and supports no
Sphinx extensions; it does not reproduce Sphinx's themes or HTML.  The language server
does not rename and does not resolve references across documents.

Installation
============

.. code-block:: console

   $ uv pip install docodin          # or: pip install docodin

The wheel needs Python 3.12 or later and contains, for its platform, the native library,
the Python package and the native programs ``docodin``, ``docodin-check`` and
``docodin-lsp``, which it installs into the environment's ``bin`` (``Scripts``)
directory next to ``docodin-sphinx-build``.  The programs run without the source
checkout.  When a document needs Python, ``docodin`` runs ``python -m docodin`` with
``$DOCODIN_PYTHON``, else the ``python3`` or ``python`` next to the program, else
``python3`` on the ``PATH``.

The release gate has verified 1.0.0b1 on macOS arm64 (macOS 11 or later) and on Linux
x86-64, under CPython 3.12.  The Linux wheel is tagged ``manylinux_2_34_x86_64``: it needs
glibc 2.34 or later (Ubuntu 22.04, Debian 12, RHEL 9 or newer).  Windows, other
architectures and musl-based Linux are not verified.

To build from source you need the Odin compiler (``dev-2026-09`` or newer) and a C
toolchain:

.. code-block:: console

   $ uv build                        # sdist and platform wheel (hatchling)
   $ scripts/build_odin.sh           # the library and bin/docodin, docodin-check, docodin-lsp

Native tools
============

.. code-block:: console

   $ docodin doc.rst doc.html                   # as: python -m docutils doc.rst doc.html
   $ docodin --writer=latex --documentclass=book doc.rst doc.tex
   $ docodin pdf doc.rst                        # LaTeX writer and a TeX engine
   $ docodin book build docs                    # a Sphinx project's site and PDF book
   $ docodin-check docs/*.rst                   # Elm-style reports
   $ docodin-check --error-format=docutils docs/*.rst

.. code-block:: text

   -- UNCLOSED EMPHASIS ----------------------------------------- guide.rst:12:6

   Inline emphasis start-string without end-string.

   12| Some *emphasis without an end.
            ^
   Hint: Close the emphasis with a matching `*`, or write `\*` for a literal
   asterisk.

From Python, ``docodin.publish_native(source, writer="html5")`` returns what
``publish_string`` returns, from the native pipeline.

Using docodin with docutils and Sphinx
======================================

docodin serves the ``docutils`` package itself: programs keep importing ``docutils``.

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - How
     - What happens
   * - ``docodin-sphinx-build ARGS...``
     - ``sphinx-build`` running on docodin's docutils
   * - ``docodin sphinx ARGS...``
     - ``sphinx-build`` with docodin's parser (``python -m docodin sphinx``)
   * - ``DOCODIN_DOCUTILS=1 any-command``
     - every Python process in the environment uses docodin (``sphinx-build``, ``tox``,
       test runners)
   * - docutils not installed
     - ``import docutils`` finds docodin automatically
   * - ``docodin.shim.install_shim(force=True)``
     - switch the current process, before docutils is imported

Extensions that change the reStructuredText grammar keep docutils' behaviour: docodin
parses those documents with its pure-Python parser.  ``DOCODIN_GC=tuned`` makes Sphinx
builds about 20 % faster by tuning Python's garbage collector; it is opt-in because
projects with duplicate labels or ids can see different output, with docutils as with
docodin.

Performance
===========

The native book builder against Sphinx, fresh HTML builds on Linux x86-64 (AMD Ryzen 9
5950X, 32 logical CPUs), Sphinx 9.1 run serially, docutils 0.22.4; the median of three
runs, start-up included:

.. list-table::
   :header-rows: 1
   :widths: 46 24 30

   * - Project
     - Sphinx
     - ``docodin book build --html``
   * - The docodin Book (40 pages)
     - 1.77 s, 82.4 MiB
     - 0.064 s (27.8 times), 23.6 MiB
   * - A generated 151-page manual
     - 7.09 s, 186.8 MiB
     - 0.249 s (28.5 times), 107.5 MiB

These builds use the features both understand (sections, inline markup, lists,
admonitions, a toctree, cross-document references); the builder writes its own theme,
not Sphinx's HTML.

Sphinx and docutils running on docodin, on Linux x86-64 with 32 cores, Python 3.13,
docutils 0.22.4 and Sphinx 9.1 (docodin 0.2.0):

.. list-table::
   :header-rows: 1
   :widths: 46 24 30

   * - Workload
     - docutils
     - docodin
   * - Sphinx, CPython documentation (599 pages, ``-j1``)
     - 65.6 s, 895 MB
     - 47.6 s (1.38 times), 883 MB
   * - The same with ``DOCODIN_GC=tuned``
     - not applicable
     - 38.4 s (1.71 times), 1034 MB
   * - Publish the docutils documentation to HTML5 (60 files, in process)
     - 2.21 s
     - 0.96 s (shim), 0.20 s (``publish_native``)
   * - The same, one command per file
     - 7.37 s (``python -m docutils``)
     - 0.22 s (``docodin``)
   * - Check the docutils and Sphinx documentation for markup errors
     - 2.81 s
     - 0.03 s (``docodin-check -j1``)

In these Sphinx builds the HTML output was identical to docutils'.  ``CHANGELOG.rst`` has
the details.

Editor support
==============

``docodin-lsp`` is a language server for reStructuredText: docutils' diagnostics as you
type, with hints and quick fixes; go to definition, references, hover and completion for
targets, sections, substitutions, footnotes and citations; document symbols, folding and
semantic tokens.  It runs no Python.  The book's chapter "Editor support"
(``docs/book/guide/editors.rst``) has the setup for Neovim, VS Code and Zed, and the
settings (``reportLevel``, ``debounce``, ``sphinx``, ``knownRoles``,
``knownDirectives``).

Compatibility
=============

- docutils' test suite: 465 passed, 17 skipped, 1862 subtests, identical to docutils,
  natively and with ``DOCODIN_NATIVE=0``.
- Sphinx 9.1's test suite: 2407 passed; the 7 failures are environment-related and fail
  the same way with docutils.
- The test suites of myst-parser, sphinx-design, sphinx-tabs, sphinxcontrib-bibtex,
  sphinx-autodoc-typehints, sphinx-gallery, pydata-sphinx-theme, sphinx-book-theme,
  sphinxext-opengraph, sphinx-notfound-page, sphinx-rtd-theme and breathe give the same
  results as with docutils.
- Differential tests publish generated documents with docutils and docodin, with every
  writer and random settings; outputs, warnings and node positions must be identical.

The native engine uses Unicode 16 character tables whatever the Python, so on a Python
with older Unicode data a few results can differ from docutils running on that Python.
The known differences and limits are listed in the book's chapter "Known limits".

License
=======

MIT (``LICENSE``).  ``NOTICE.rst`` lists the third-party works docodin contains or is
derived from (docutils, SmartyPants, the Unicode Character Database), and ``LICENSES/``
holds their license texts.  The sdist and the wheel include all three.
