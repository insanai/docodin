.. _sphinx:

==================
docodin and Sphinx
==================

Sphinx is built on docutils, and docodin was built to make Sphinx faster without
changing its output.  This chapter shows the ways to run Sphinx on docodin, the optional
collector tuning, and how to confirm that nothing changed.

Four ways to run Sphinx on docodin
==================================

``docodin-sphinx-build``
------------------------

.. code-block:: console

   $ docodin-sphinx-build -b html docs docs/_build/html
   $ docodin-sphinx-build -M latexpdf docs docs/_build

It takes exactly the arguments of ``sphinx-build``.  It installs docodin's docutils
package before Sphinx imports docutils, then runs Sphinx's own ``main``.  This is the
simplest way, and it is the one used for the measurements in this book.

``DOCODIN_DOCUTILS=1``
----------------------

.. code-block:: console

   $ DOCODIN_DOCUTILS=1 sphinx-build -b html docs docs/_build/html
   $ DOCODIN_DOCUTILS=1 make html
   $ DOCODIN_DOCUTILS=1 tox -e docs

The start-up hook serves docutils from docodin in every Python process that sees the
variable.  Use it when Sphinx is started by another tool (``make``, ``tox``, a CI
script, ``sphinx-autobuild``) that you do not want to change.

The ``docodin.sphinx`` extension
--------------------------------

.. code-block:: python

   # conf.py
   extensions = [
       "docodin.sphinx",
       # ... your other extensions
   ]

The extension replaces Sphinx's reStructuredText parser with one that parses through
docodin's native engine, on whichever docutils is loaded, including an installed
docutils.  It honours ``rst_prolog`` and ``rst_epilog``, and it hands a document back to
Sphinx's own parser when the parser's state classes or inliner are not the stock ones.
It is marked safe for parallel reading and writing.

``python -m docodin sphinx``
----------------------------

.. code-block:: console

   $ python -m docodin sphinx -b html docs docs/_build/html

The Python ``docodin`` command's ``sphinx`` subcommand patches the loaded docutils'
parser (``docodin.patch_docutils``) and runs ``sphinx-build`` with the remaining
arguments.

Which to use
------------

Prefer ``docodin-sphinx-build`` or ``DOCODIN_DOCUTILS=1``: they run all of docutils on
docodin, including the native smart quotes, and they give the
measured speed-ups.  Use the extension when a project must keep an installed docutils
but wants the faster parser.

Collector tuning
================

A Sphinx build keeps a large environment in memory, and Python's full garbage
collections scan it again and again.  docodin can tune the collector:

- the collection thresholds are raised moderately (``gc.set_threshold(50000, 20,
  100)``);
- after the extensions are loaded and after all documents are read, the live objects are
  collected once and frozen with ``gc.freeze()``, so later collections skip them.

Turn it on with the environment variable for ``docodin-sphinx-build``, or with a
configuration value for the extension:

.. code-block:: console

   $ DOCODIN_GC=tuned docodin-sphinx-build -b html docs docs/_build/html

.. code-block:: python

   # conf.py
   extensions = ["docodin.sphinx"]
   docodin_gc_tuning = True

On CPython's documentation it saves about 20 % of the build time (47.6 s to 38.4 s) for
about 17 % more peak memory (883 MB to 1034 MB).

.. warning::

   The tuning is opt-in because it can change the output of some projects, with docutils
   as with docodin.  With duplicate labels or repeated generated ids, "last one wins" in
   Sphinx's environment follows the lifetime of Python objects, and collecting at other
   moments can change which one is last.  CPython's documentation changes in four pages.
   Build your project with and without the tuning and compare the output before you
   rely on it (DOD 16).

Parallel builds
===============

docodin's native library keeps no shared mutable state, and each thread parses in its
own arena, so ``-j auto`` works as with docutils.  On CPython's documentation with 32
cores, the build takes 29.1 s instead of 32.7 s of wall time, and 74.7 s instead of
99.7 s of CPU time.

Confirming identical output
===========================

docodin's promise is identical output, and you can check it on your own project:

.. code-block:: console

   $ sphinx-build -b html docs /tmp/with-docutils
   $ docodin-sphinx-build -b html docs /tmp/with-docodin
   $ diff -r -x .buildinfo -x .doctrees /tmp/with-docutils /tmp/with-docodin

Leave out the files that record the build rather than the documents (``.buildinfo``
and the ``.doctrees`` directory).  Any other difference is a bug in docodin; please
report it with the smallest document that shows it.

To find out whether a difference comes from the native parser, build with
``DOCODIN_NATIVE=0``: docodin then parses every document with its pure-Python parser.

Extensions and themes
=====================

Extensions run on docodin as on docutils: they import ``docutils`` and get docodin's
package.  The test suites of myst-parser, sphinx-design, sphinx-tabs,
sphinxcontrib-bibtex, sphinx-autodoc-typehints, sphinx-gallery, pydata-sphinx-theme,
sphinx-book-theme, sphinxext-opengraph, sphinx-notfound-page, sphinx-rtd-theme and
breathe give the same results with docodin as with docutils.  Extensions that change the
reStructuredText grammar itself (custom parser states, patched ``Inliner`` dispatch) are
parsed with docodin's pure-Python parser, exactly as with docutils (DOD 7).
