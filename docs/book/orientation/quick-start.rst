.. _quick-start:

===========
Quick start
===========

This chapter takes you from nothing to a Sphinx build on docodin, a checked file and a
document published without Python, in a few minutes.

Install
=======

.. code-block:: console

   $ uv pip install docodin          # or: pip install docodin

The wheel contains the native library for your platform and has no dependencies.  Check
that it loads:

.. code-block:: console

   $ python -c "import docodin; print(docodin.__version__, docodin.version())"
   0.2.0 0.2.0

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

Build the native tools
======================

The native commands are built from a source checkout.  You need the Odin compiler
(``dev-2026-09`` or newer) and a C toolchain:

.. code-block:: console

   $ git clone <docodin repository> docodin && cd docodin
   $ scripts/build_odin.sh
   $ ls bin
   docodin  docodin-check  docodin-lsp

Check a document
================

.. code-block:: console

   $ bin/docodin-check README.rst docs/**/*.rst

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

   $ bin/docodin guide.rst guide.html
   $ bin/docodin latex guide.rst guide.tex
   $ bin/docodin pdf guide.rst

``docodin`` takes docutils' command-line options and writes what ``python -m docutils``
writes.  :doc:`../guide/command-line` covers it in full.

Next steps
==========

- :doc:`../guide/editors` sets up ``docodin-lsp`` in Neovim, VS Code or Zed.
- :doc:`../reference/compatibility` shows how docodin is tested against docutils.
- :doc:`../internals/architecture` explains how the pieces fit together.
