.. _environment:

=====================
Environment variables
=====================

docodin reads these environment variables.  None is required.

Using docodin
=============

``DOCODIN_DOCUTILS``
   ``1``: every Python process that starts with this variable serves ``docutils`` from
   docodin (the start-up hook ``docodin.pth`` installs the shim).  Any other value, or
   none: docodin serves ``docutils`` only where no docutils is installed.

``DOCODIN_GC``
   ``tuned``: ``docodin-sphinx-build`` tunes Python's garbage collector for the build
   (raised thresholds, long-lived objects frozen after the extensions are loaded and after
   reading).  Any other value, or none: Python's default collector.  The ``docodin.sphinx``
   extension uses the configuration value ``docodin_gc_tuning`` instead.  See
   :doc:`../guide/sphinx`.

``DOCODIN_NATIVE``
   ``0``: the docutils package parses every document with its pure-Python parser instead
   of the native engine.  For debugging, and for comparing the two parsers.

``DOCODIN_PYTHON``
   The Python interpreter that the native ``docodin`` command runs (``python -m
   docodin``) for documents that need a Python library, and for ``--config``,
   ``--record-dependencies`` and the ``--dump-*`` options.  Without it, ``python3`` from
   the ``PATH`` is tried.  The interpreter must be able to import docodin.

``DOCODIN_LIB_PATH``
   The path of the native library (``libdocodin.dylib``, ``libdocodin.so`` or
   ``docodin.dll``) that the Python package loads.  Without it, the package loads the
   library next to its own files, or from the checkout's ``build`` directory.  A path that
   does not exist is an error.

``NO_COLOR``, ``TERM``
   With ``--color=auto``, ``docodin-check`` and ``docodin check`` do not colour their
   reports when ``NO_COLOR`` is set to a non-empty value or ``TERM`` is ``dumb``.

Building docodin
================

``DOCODIN_SKIP_NATIVE_BUILD``
   ``1``: the wheel build does not run ``scripts/build_odin.sh`` and packages the library
   that is already in ``python/docodin``.

``MACOSX_DEPLOYMENT_TARGET``
   The oldest macOS version the library is built for (default: ``11.0``), and the
   platform tag of the macOS wheel.

Testing docodin
===============

``DOCTREE_INTERCHANGE_DIR``
   A directory of doctree interchange dumps (made with
   ``scripts/doctree_interchange_fixtures.py --corpus``) that ``odin test
   odin/doctree/tests`` loads in addition to its fixtures
   (:doc:`../internals/interchange`).

``WRITERS_DUMP_DIR``
   A directory of ``output``-stage dumps that ``odin test odin/writers/tests`` compares
   with the native writers, in addition to its fixtures.

``DOCUTILS_SRC``
   A docutils 0.22.4 source distribution.  With it, ``tests/test_conformance.py`` runs
   docutils' parser test suite against docodin; without it, the test is skipped.

``DOCUTILS_SOURCE``
   The default of ``--docutils-src`` in ``tests/native_reader_differential.py``.
