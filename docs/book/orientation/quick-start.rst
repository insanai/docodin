.. _quick-start:

===========
Quick start
===========

This chapter takes you from nothing to a Sphinx build on docodin, a checked file, a
document published without Python and a native book build, in a few minutes.

Install
=======

.. code-block:: console

   $ uv pip install docodin          # or: pip install docodin

The wheel has no dependencies.  It contains the native library for your platform and
installs the native programs ``docodin``, ``docodin-check`` and ``docodin-lsp`` next to
the environment's Python.  Check that both load:

.. code-block:: console

   $ python -c "import docodin; print(docodin.__version__, docodin.version())"
   1.0.0b1 1.0.0b1
   $ docodin --version
   docodin 1.0.0b1 (Docutils 0.22.4, native)

Build a Sphinx project on docodin
=================================

Replace ``sphinx-build`` with ``docodin-sphinx-build``.  It takes exactly the same
arguments:

.. code-block:: console

   $ docodin-sphinx-build -b html docs docs/_build/html

The output is the same as with docutils.  To see the difference in time, build once with
each and compare; for larger projects, also try the opt-in collector tuning:

.. code-block:: console

   $ DOCODIN_GC=tuned docodin-sphinx-build -b html docs docs/_build/html

:doc:`../guide/sphinx` explains the tuning and the other ways to run Sphinx on docodin.

Use docodin from Python
=======================

Programs that import ``docutils`` need no change.  To run one on docodin even where
docutils is installed, set ``DOCODIN_DOCUTILS=1``:

.. code-block:: console

   $ DOCODIN_DOCUTILS=1 python my_tool.py

Or call docodin directly:

.. code-block:: python

   import docodin

   html = docodin.publish_string("Hello, *world*!", writer="html5")
   body = docodin.render_html("Hello, *world*!", standalone=False)

``publish_string`` runs the docutils package with the native parser;
``render_html`` runs the native pipeline, and falls back to docutils when the document
needs a Python library.

Check a document
================

.. code-block:: console

   $ docodin-check README.rst docs/**/*.rst

Problems are explained with the source line and a hint:

.. code-block:: text

   -- TITLE UNDERLINE TOO SHORT --------------------------------------- guide.rst:5

   Title underline too short.

   4| Installation
   5| ======
      ^^^^^^
   Hint: Make the underline at least as long as the title text (12 characters).

   -- UNCLOSED EMPHASIS -------------------------------------------- guide.rst:7:11

   Inline emphasis start-string without end-string.

   7| Text with *emphasis.
                ^
   Hint: Close the emphasis with a matching `*`, or write `\*` for a literal
   asterisk.

   Found 2 warnings in 1 file.

Publish without Python
======================

.. code-block:: console

   $ docodin guide.rst guide.html
   $ docodin latex guide.rst guide.tex
   $ docodin pdf guide.rst                   # needs a TeX engine

``docodin`` takes docutils' command-line options and writes what ``python -m docutils``
writes.  :doc:`../guide/command-line` covers it in full.

Build a book without Python
===========================

.. code-block:: console

   $ docodin book build docs --html -o /tmp/site

``docodin book build`` reads the project's ``conf.py`` (without running it) and builds an
HTML site, and a PDF book when a TeX engine is installed.  It supports a documented
subset of Sphinx's configuration and markup, and no extensions
(:doc:`../development/documentation`, :doc:`../reference/limits`).

Build from source
=================

The programs can also be built from a source checkout, with the Odin compiler
(``dev-2026-09`` or newer) and a C toolchain:

.. code-block:: console

   $ git clone <docodin repository> docodin && cd docodin
   $ scripts/build_odin.sh
   $ ls bin
   docodin  docodin-check  docodin-lsp

Next steps
==========

- :doc:`../guide/editors` sets up ``docodin-lsp`` in Neovim, VS Code or Zed.
- :doc:`../reference/compatibility` shows how docodin is tested against docutils.
- :doc:`../internals/architecture` explains how the pieces fit together.
