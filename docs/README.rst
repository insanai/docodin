=========================
docodin's documentation
=========================

The documentation is reStructuredText only, in two projects:

``book/``
   *The docodin Book*: the manual, in five parts (Orientation, Using docodin, Reference,
   Internals, Development) and appendices.
``dod/``
   The *DocOdin Discussions*: docodin's numbered design records.  DOD 1 describes the
   process.
``theme/``
   The docodin theme, shared by both projects: the native builder embeds it, and the
   Sphinx builds use furo with ``theme/docodin.css``.

Both are Sphinx projects that docodin also builds natively.

Building natively
=================

Build the native tools first (``scripts/build_odin.sh``, see the book's chapter "Building
from source"), then:

.. code-block:: console

   $ bin/docodin book build docs/book           # HTML site and PDF book
   $ bin/docodin book build docs/dod
   $ bin/docodin book build docs/book --html -o /tmp/book-html
   $ bin/docodin book build docs/book --pdf --engine=xelatex

The PDF needs a TeX distribution (MacTeX or TeX Live) with ``lualatex`` or ``xelatex``.

Building with Sphinx
====================

The ``docs`` dependency group installs Sphinx and furo:

.. code-block:: console

   $ uv run --group docs sphinx-build -W --keep-going -b html docs/book docs/book/_build/html
   $ uv run --group docs sphinx-build -W --keep-going -b html docs/dod docs/dod/_build/html

For the PDFs, build LaTeX and run ``latexmk`` with LuaLaTeX:

.. code-block:: console

   $ uv run --group docs sphinx-build -W --keep-going -b latex docs/book docs/book/_build/latex
   $ (cd docs/book/_build/latex && latexmk -lualatex -interaction=nonstopmode docodin-book.tex)
   $ uv run --group docs sphinx-build -W --keep-going -b latex docs/dod docs/dod/_build/latex
   $ (cd docs/dod/_build/latex && latexmk -lualatex -interaction=nonstopmode docodin-dod.tex)

To build on docodin itself, replace ``sphinx-build`` with ``docodin-sphinx-build``.

Checking
========

.. code-block:: console

   $ bin/docodin-check README.rst CHANGELOG.rst docs/README.rst docs/book/*.rst \
         docs/book/*/*.rst docs/dod/*.rst
   $ bin/docodin dod check

Writing
=======

The book's chapter "Maintaining the documentation" (``book/development/documentation.rst``)
lists the markup both builders accept, the style of the book and the conventions of the
``conf.py`` files.  ``book/appendices/maintenance-checklist.rst`` says what to update when
the code changes.  New design records start with ``bin/docodin dod new "Title"``.
