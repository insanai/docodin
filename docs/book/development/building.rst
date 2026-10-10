.. _building:

====================
Building from source
====================

Requirements
============

- **Odin** ``dev-2026-09`` or newer, on the ``PATH`` as ``odin``.
- **A C toolchain**: ``clang`` on macOS, ``clang`` or ``cc`` on Linux.  It links the
  shared library.
- **uv** and **Python 3.12** or later.  docodin's development always runs Python through
  ``uv run``, in the project's environment.
- For the differential tests: a **docutils 0.22.4 source tree** (the sdist, for its test
  inputs and documentation) and **CPython 3.14**, which ``uv`` can provide.
- For PDF output: a TeX distribution (MacTeX or TeX Live) with ``pdflatex``, ``xelatex``
  or ``lualatex``.

The environment
===============

.. code-block:: console

   $ uv sync --extra test            # pytest, Sphinx, docutils
   $ uv sync --group docs            # Sphinx and furo, for the documentation

The ``test`` extra installs docutils as well: many tests compare docodin with the real
docutils, side by side.

Building the native code
========================

.. code-block:: console

   $ scripts/build_odin.sh           # optimised (-o:speed)
   $ scripts/build_odin.sh --debug   # debug information, no optimisation

The script builds, in order:

1. **The shared library** from ``odin/lib``.  The package is compiled to a single object
   (``-build-mode:obj -use-single-module``) and linked with the system toolchain, with
   ``docodin_init`` registered as the library initialiser so that the Odin runtime
   starts when the library is loaded.  (Linking directly with ``-build-mode:shared`` is
   broken on macOS in current Odin releases.)  On macOS the minimum OS version is
   ``MACOSX_DEPLOYMENT_TARGET`` (default 11.0).  The library is copied next to the old one
   in ``python/docodin`` and renamed into place, so running processes are not killed.
2. **The programs**: ``bin/docodin-check`` from ``cmd/docodin-check``, ``bin/docodin``
   from ``cmd/docodin`` and ``bin/docodin-lsp`` from ``cmd/docodin-lsp``.  Each is built
   in ``build/`` and moved into place, because a running program (an editor's language
   server) must not be overwritten in place.  On macOS they target the library's
   minimum OS version, since the wheel installs them too.

All builds use ``-vet -strict-style``.  ``bin/`` and ``build/`` are not versioned.

The Python package finds the library next to its own files, then in ``build/``; set
``DOCODIN_LIB_PATH`` to use another one.  An editable install (``uv sync``) uses the
library that the script put in ``python/docodin``: rebuild after changing Odin code.

Building the distribution
=========================

.. code-block:: console

   $ uv build                        # sdist and platform wheel (hatchling)

The hatch build hook (``hatch_build.py``) runs ``scripts/build_odin.sh`` for the wheel,
includes the library, installs the three programs as the wheel's scripts (hatchling's
``shared_scripts``, which installers put in the environment's ``bin`` or ``Scripts``
directory), and tags the wheel ``py3-none-<platform>``.  On macOS the platform is the
deployment target; on glibc Linux it is ``manylinux_<x>_<y>_<arch>``, after the newest
``GLIBC_x.y`` symbol version found in the library and the programs (at least 2.17), so the
tag states the glibc the binaries really need.  It stops when a program is missing.
``DOCODIN_SKIP_NATIVE_BUILD=1`` packages an engine that is already built.  The wheel's
only Python console script is ``docodin-sphinx-build``.

The sdist contains the Python package, the Odin sources, the commands, the scripts, the
tests, the documentation, ``hatch_build.py``, ``README.rst``, ``CHANGELOG.rst`` and the
license files.  A wheel built from it compiles the native code again, so building from
the sdist needs the Odin compiler too.

The version
-----------

The version is written in ``odin/version/version.odin`` (``VERSION``, imported by the
library, the programs and the book builder's pages), ``pyproject.toml``,
``python/docodin/__init__.py`` (``__version__``) and ``docs/book/conf.py`` and
``docs/dod/conf.py`` (``release``, and ``version``, its first two parts).
``tests/test_release.py`` fails when they disagree.

License files
-------------

``LICENSE`` is docodin's MIT license.  ``NOTICE.rst`` lists the third-party works docodin
contains or ports: docutils' data files and algorithms (smart quotes, the math
converters, the stylesheets), SmartyPants, and the Unicode Character Database behind the
generated tables.  ``LICENSES/`` holds their license texts.  ``pyproject.toml`` names
all three in ``license-files``, so the wheel carries them in ``dist-info/licenses``, and
in the sdist's ``include``.  Update ``NOTICE.rst`` when docodin embeds or ports another
third-party work.

Generated sources
=================

Tables that come from docutils or from Python's Unicode data are generated, never
written by hand.  Each generated file names its generator in its header.

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Script
     - Generates
   * - ``scripts/gen_shim_data.py``
     - the data modules of docodin's docutils package: languages, character classes,
       URI schemes, smart-quote and math tables, writer stylesheets and templates
   * - ``scripts/gen_unicode_tables.py``
     - the parser's Python-compatible character classes (``odin/rst``)
   * - ``scripts/gen_doctree_tables.py``
     - NFKD decomposition and ``str.lower`` tables for ``make_id`` (``odin/doctree``)
   * - ``scripts/gen_node_kinds.py``
     - the parse tree's node kinds
   * - ``scripts/gen_language_tables.py``
     - docutils' language modules for the transforms
   * - ``scripts/gen_rst_language_tables.py``
     - the localised directive and role names for the reader
   * - ``scripts/gen_math_tables.py``
     - the command tables of ``odin/math``
   * - ``scripts/gen_smartquotes_tables.py``
     - the quote tables of ``odin/text``
   * - ``scripts/gen_writer_tables.py``, ``scripts/gen_visitor_names.py``
     - the writers' tables and visitor names

The Unicode tables must all come from the same CPython version (3.14, Unicode 16): run
their generators with ``uv run --python 3.14``.

Repository layout
=================

.. code-block:: text

   odin/rst/           reST parser (data-oriented parse tree)
   odin/check/         checker core and Elm-style diagnostics
   odin/doctree/       native docutils document tree, registry, reporter, JSON interchange
   odin/reader/        native reader: docutils document trees, directives and roles
   odin/transforms/    native docutils transforms
   odin/writers/       native pseudo-XML, XML, HTML5 and LaTeX/XeLaTeX writers
   odin/math/          native math2html and latex2mathml (package texmath)
   odin/text/          native smart quotes
   odin/publish/       native publisher (settings, reader, transforms, writer)
   odin/lsp/           language server
   odin/lib/           C ABI library used by the Python package
   cmd/                docodin, docodin-check and docodin-lsp
   python/docodin/     Python package: tree builder, shim, Sphinx integration
   python/docodin/shim/docutils/   the docutils implementation
   scripts/            build script, table and data generators, doctree dumps
   tests/              unit, parity, differential, conformance and benchmark tools
   docs/book/          this book
   docs/dod/           the DocOdin Discussions
   docs/theme/         the documentation theme
