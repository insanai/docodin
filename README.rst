=======
docodin
=======

docodin is a drop-in replacement for `docutils <https://docutils.sourceforge.io/>`__
0.22, built on a reStructuredText engine written in `Odin <https://odin-lang.org/>`__.
Sphinx, its extensions and every other docutils user run on it unchanged, with identical
output, faster.

- **A docutils implementation** (``python/docodin/shim/docutils``): the whole docutils
  package, written for docodin, with every writer.  It passes docutils' own test suite
  and Sphinx's test suite with the same results as docutils.
- **A native reStructuredText engine** (``odin/rst``): docutils' block and inline
  grammar, every system message and line number, about five times faster.
- **Native tools**: ``docodin`` publishes without Python, with docutils' output,
  messages and exit status; ``docodin-check`` explains markup errors in milliseconds;
  ``docodin-lsp`` gives editors docutils' diagnostics as you type.  Documents that need
  a Python library (Pygments, PIL, ...) go through docutils automatically.

The documentation is **The docodin Book** (``docs/book``), and the design decisions are
the **DocOdin Discussions** (``docs/dod``).  ``docs/README.rst`` explains how to build
them.

Installation
============

.. code-block:: console

   $ uv pip install docodin          # or: pip install docodin

Wheels contain the native library for their platform and need Python 3.12 or later.  To
build from source, and for the native commands, you need the Odin compiler
(``dev-2026-09`` or newer) and a C toolchain:

.. code-block:: console

   $ uv build                        # sdist and platform wheel (hatchling)
   $ scripts/build_odin.sh           # the library and bin/docodin, docodin-check, docodin-lsp

Using docodin instead of docutils
=================================

docodin serves the ``docutils`` package itself: programs keep importing ``docutils``.

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - How
     - What happens
   * - ``docodin-sphinx-build ARGS...``
     - ``sphinx-build`` running on docodin
   * - ``DOCODIN_DOCUTILS=1 any-command``
     - every Python process in the environment uses docodin (``sphinx-build``, ``tox``,
       test runners)
   * - docutils not installed
     - ``import docutils`` finds docodin automatically
   * - ``docodin.shim.install_shim(force=True)``
     - switch the current process, before docutils is imported

Extensions that change the reStructuredText grammar work exactly as with docutils:
docodin parses those documents with its pure-Python parser.  ``DOCODIN_GC=tuned`` makes
Sphinx builds about 20 % faster by tuning Python's garbage collector; it is opt-in
because projects with duplicate labels or ids can see different output, with docutils as
with docodin.

Performance
===========

Linux x86-64 with 32 cores, Python 3.13, docutils 0.22.4 and Sphinx 9.1:

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

Sphinx output is identical.  ``CHANGELOG.rst`` has the details.

Native tools
============

.. code-block:: console

   $ docodin doc.rst doc.html                   # as: python -m docutils doc.rst doc.html
   $ docodin --writer=latex --documentclass=book doc.rst doc.tex
   $ docodin pdf doc.rst                        # LaTeX writer and a TeX engine
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

The known differences are listed in the book's chapter "Known limits".

License
=======

MIT
