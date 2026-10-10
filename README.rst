**************
|logo| docodin
**************

**A native reStructuredText toolchain, written in Odin.**

Publish documents, check markup, build HTML sites and PDF books, and work with an
editor language server. Supported native documents run without Python; the Python
package brings the same engine to docutils and Sphinx.

Quickstart_ · Features_ · Performance_ · Documentation_

`Website <https://insanai.github.io/docodin/>`__ ·
`Book <https://insanai.github.io/docodin/book/>`__ ·
`Release 1.0.0b1 <https://github.com/insanai/docodin/releases/tag/v1.0.0b1>`__

**Beta 1.0.0b1.** Native tooling is the main focus. Compatibility checks target
docutils 0.22.4; complete support for every Sphinx project and extension is outside
this beta's promise. Read the `known limits
<https://insanai.github.io/docodin/book/reference/limits.html>`__ before adoption.

Features
========

- **Native publishing:** HTML5, LaTeX, XeLaTeX, Docutils XML and pseudo-XML, with
  docutils-compatible messages and exit status.
- **Sites and books:** build the documented subset of Sphinx projects with docodin's
  own HTML theme, navigation, search and cross-document references; typeset PDF books
  with an external TeX engine.
- **Fast markup checks:** ``docodin-check`` explains errors with source excerpts and
  hints, or reports them in docutils' format.
- **Editor tools:** ``docodin-lsp`` provides diagnostics, definitions, references, hover,
  completion, symbols, folding and semantic tokens within a document.
- **Native image metadata:** read PNG, JPEG, GIF, BMP, TIFF and WebP dimensions without
  Pillow or decoding pixels. Unsupported cases keep the Python fallback.
- **Python integration:** use ``publish_native`` directly, replace docutils through the
  shim, or run Sphinx with docodin's parser.
- **MIT licensed:** the source, native tools and Python package are open for improvement.

Quickstart
==========

Install a published beta wheel into a Python 3.12+ environment:

.. code-block:: console

   $ uv pip install docodin==1.0.0b1    # or: pip install docodin==1.0.0b1

For standalone tools, download the Linux x86-64 or macOS arm64 native archive from
`release page <https://github.com/insanai/docodin/releases/tag/v1.0.0b1>`__.
The release contains native archives, Python wheels, the source distribution and checksums.

Write ``hello.rst``:

.. code-block:: rst

   Hello, docodin
   ==============

   A small document with **strong text**, *emphasis* and a list:

   - Publish it to HTML.
   - Check its markup.
   - Typeset it as a PDF.

.. code-block:: console

   $ docodin hello.rst hello.html
   $ docodin-check hello.rst
   $ docodin pdf --engine=lualatex hello.rst hello.pdf

PDF generation needs TeX Live or MacTeX. Engine names and full executable paths work;
LuaLaTeX and XeLaTeX use the Unicode-capable writer. The `PDF guide
<https://insanai.github.io/docodin/book/guide/command-line.html>`__ explains settings and dependencies.

Build an existing documentation project with the supported markup and configuration:

.. code-block:: console

   $ docodin book build docs --html -o build/manual
   $ docodin book build docs --pdf -o build/manual

The builder reads ``conf.py`` without executing Python. See `Maintaining the
documentation <https://insanai.github.io/docodin/book/development/documentation.html>`__ for the supported values.

Build and installation
======================

Wheels contain the native library, Python package, ``docodin``, ``docodin-check`` and
``docodin-lsp``. The native programs run outside the source checkout. The release gate
has verified macOS arm64 (macOS 11+) and Linux x86-64 under CPython 3.12. Linux wheels
need glibc 2.34+ (for example Ubuntu 22.04, Debian 12 or RHEL 9). Windows, musl Linux
and other architectures have not been verified for this beta.

Native archives contain the three programs and license notices; wheels also contain
the Python package and shared library. Both distributions come from the same tested
release. Check downloads against the release's ``SHA256SUMS``.

From source, install Odin ``dev-2026-10``, a C toolchain and uv:

.. code-block:: console

   $ scripts/build_odin.sh             # library and three programs in bin/
   $ uv sync --extra test
   $ uv run --extra test python -m pytest -q tests
   $ uv build                         # source distribution and platform wheel

The `build guide <https://insanai.github.io/docodin/book/development/building.html>`__ covers compiler setup. The
`release guide <https://insanai.github.io/docodin/book/development/releasing.html>`__ explains the artifact installation
checks. PDF content tests additionally use Poppler's ``pdftotext``.

Python and Sphinx
=================

Publish through the native pipeline from Python:

.. code-block:: python

   import docodin

   html = docodin.publish_native("Hello, **docodin**.\n", writer="html5")

Install Sphinx support and build through docodin's docutils package:

.. code-block:: console

   $ uv pip install 'docodin[sphinx]==1.0.0b1'
   $ docodin-sphinx-build -b html docs build/sphinx

``docodin sphinx ARGS...`` uses docodin's parser with Sphinx. Setting
``DOCODIN_DOCUTILS=1`` makes Python processes in that environment use docodin's docutils
package. Programs continue importing ``docutils``. See the `Sphinx guide
<https://insanai.github.io/docodin/book/guide/sphinx.html>`__ for activation, grammar extensions and optional collector
tuning, and the `Python guide <https://insanai.github.io/docodin/book/guide/python.html>`__ for the API.

When a native publication needs a Python library or unsupported feature, it runs
``python -m docodin``. Python is selected from ``DOCODIN_PYTHON``, the interpreter next
to the program, then ``python3`` on ``PATH``. This is how Pygments highlighting and
unsupported image metadata keep their Python implementations.

Performance
===========

Published measurements show the difference between a native documentation build and
replacing a parser inside Sphinx. Fresh serial HTML builds on an AMD Ryzen 9 5950X,
Linux x86-64, Sphinx 9.1 and docutils 0.22.4; median of three runs, startup included:

.. list-table::
   :header-rows: 1
   :widths: 46 24 30

   * - Project
     - Sphinx
     - Native book builder
   * - The docodin Book (40 pages)
     - 1.77 s
     - 0.064 s (27.8× faster)
   * - Generated manual (151 pages)
     - 7.09 s
     - 0.249 s (28.5× faster)

These projects use the shared markup subset; docodin renders its own theme. They do
not measure arbitrary Sphinx extensions or identical HTML.

An earlier docodin 0.2.0 benchmark of the CPython documentation (599 pages, Python 3.13,
``-j1``) took **65.6 s with docutils and 47.6 s with docodin**, a **1.38×** improvement
with identical HTML. Parser replacement leaves Sphinx's Python work in place, so the
native builder's gains should not be expected from that integration. See the
`performance chapter <https://insanai.github.io/docodin/book/internals/performance.html>`__ and `changelog
<https://github.com/insanai/docodin/blob/main/CHANGELOG.rst>`__ for measurement conditions and historical results.

Limits and compatibility
========================

The native book builder supports the documented configuration and markup subset. It
does not execute Sphinx extensions or reproduce Sphinx's themes. The language server
works within a single document and does not rename symbols across a project.

Differential tests compare output, warnings, settings and node positions with docutils
0.22.4. Upstream docutils, Sphinx and selected extension suites are also used to check
the Python integration. These checks establish measured compatibility, not a promise
of complete Sphinx parity. Unicode 16 tables can also differ from an older Python's
Unicode data. The `compatibility reference <https://insanai.github.io/docodin/book/reference/compatibility.html>`__
and `known limits <https://insanai.github.io/docodin/book/reference/limits.html>`__ describe the supported boundary.

Documentation
=============

Read the website in light or dark mode, or download print-friendly light PDFs: the
complete book, the collected design records and each individual DOD. Download links
appear on the documentation pages.
Inline Graphviz diagrams explain the architecture, document pipeline, ownership and
design-record lifecycle in both HTML and PDF.

The website follows verified changes on ``main`` and hosts all documentation PDFs.
GitHub release assets contain software packages and checksums.

- `The docodin Book <https://insanai.github.io/docodin/book/index.html>`__: installation, tools, editors, reference,
  internals and development.
- `DocOdin Discussions <https://insanai.github.io/docodin/dod/>`__: numbered design records and their states.
- `Download the book (PDF) <https://insanai.github.io/docodin/pdf/docodin-book.pdf>`__ or
  `all design records (PDF) <https://insanai.github.io/docodin/pdf/docodin-dod.pdf>`__.
- `Building the documentation <https://github.com/insanai/docodin/blob/main/docs/README.rst>`__: native and Sphinx build commands.
- `Editor setup <https://insanai.github.io/docodin/book/guide/editors.html>`__: Neovim, VS Code and Zed.

Contributing
============

docodin is authored by **Vikrant Rathore**, with **Ronak Rathore** providing algorithm
assistance and **Kanak Rathore** contributing logo design. See `AUTHORS.rst <https://github.com/insanai/docodin/blob/main/AUTHORS.rst>`__.

Bug reports, small improvements and compatibility examples are welcome in `GitHub
issues <https://github.com/insanai/docodin/issues>`__ and pull requests. Include a small
input, the command you ran, your platform, and the expected output.

Read the `code rules <https://insanai.github.io/docodin/book/development/code-rules.html>`__ and `testing guide
<https://insanai.github.io/docodin/book/development/testing.html>`__. Keep Odin bounds checks enabled, use explicit
ownership and build with ``-vet -strict-style``. Changes on the docutils path need
differential evidence; substantial design changes belong in a DOD.

License
=======

`MIT <https://github.com/insanai/docodin/blob/main/LICENSE>`__. `NOTICE.rst <https://github.com/insanai/docodin/blob/main/NOTICE.rst>`__ lists third-party works; ``LICENSES/``
contains their license texts. Source distributions and wheels include these notices.

.. |logo| image:: https://raw.githubusercontent.com/insanai/docodin/main/docs/book/_static/docodin_logo.png
   :alt:
   :width: 40px
   :height: 40px
   :align: middle
