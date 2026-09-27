.. _installation:

============================
Installation and activation
============================

Installing docodin
==================

.. code-block:: console

   $ uv pip install docodin          # or: pip install docodin

docodin needs Python 3.12 or later and has no dependencies.  Its wheels are built per
platform, not per Python version: the native library is loaded with ``ctypes`` and
exchanges data in CPython's ``marshal`` format, so one wheel (tagged
``py3-none-<platform>``) serves every supported Python.  On macOS the wheel targets macOS
11.0 or later.

The extras add optional tools:

``docodin[sphinx]``
   Sphinx 8.0 or later.
``docodin[test]``
   pytest, Sphinx and docutils, for docodin's own tests.

What the wheel installs
-----------------------

``docodin``
   The Python package: the native library, the docutils implementation
   (``docodin.shim``), the tree builder and the Sphinx integration.
``docodin.pth`` and ``docodin_autoload.py``
   A start-up hook in ``site-packages``.  It serves ``docutils`` from docodin when
   ``DOCODIN_DOCUTILS=1`` is set, and otherwise only when no docutils is installed.
``docodin`` (command)
   docutils' command-line front end with docodin's parser, the Python counterpart of
   the native ``docodin`` command (:doc:`command-line`).
``docodin-sphinx-build`` (command)
   ``sphinx-build`` running on docodin (:doc:`sphinx`).

The native commands ``docodin``, ``docodin-check`` and ``docodin-lsp`` are built from a
source checkout with ``scripts/build_odin.sh`` (:doc:`../development/building`).

Choosing what runs on docodin
=============================

Installing docodin changes nothing for programs that use an installed docutils.  You
decide how far docodin reaches:

.. list-table::
   :header-rows: 1
   :widths: 38 62

   * - How
     - What runs on docodin
   * - ``docodin-sphinx-build ARGS...``
     - that Sphinx build
   * - ``DOCODIN_DOCUTILS=1 any-command``
     - every Python process started with the variable, for example ``sphinx-build``,
       ``tox`` or a test runner, and the processes they start
   * - docutils not installed
     - every ``import docutils`` in the environment, automatically
   * - ``docodin.shim.install_shim(force=True)``
     - the current process; call it before anything imports docutils
   * - ``extensions = ["docodin.sphinx"]`` in ``conf.py``
     - Sphinx's reStructuredText parsing, on whichever docutils is loaded
   * - ``docodin.patch_docutils()``
     - the parsing of an installed docutils, in the current process

The first four serve docodin's complete docutils package.  The last two keep the
installed docutils and replace only its parser with docodin's native engine.

The start-up hook
-----------------

``docodin.pth`` runs ``import docodin_autoload`` whenever Python starts.  The module is
deliberately small and imports nothing heavy:

- with ``DOCODIN_DOCUTILS=1`` it calls ``docodin.shim.install_shim(force=True)``;
- otherwise it appends a lazy finder to ``sys.meta_path`` that is asked about
  ``docutils`` only after every other finder failed, and imports docodin only then.

It costs about 0.1 ms per interpreter start.

Checking which docutils is running
==================================

.. code-block:: python

   import docutils
   import docodin.shim

   print(docodin.shim.is_active())   # True: docutils is docodin's implementation
   print(docutils.__file__)          # .../docodin/shim/docutils/__init__.py

Switching back
==============

- Unset ``DOCODIN_DOCUTILS``, or run ``sphinx-build`` instead of
  ``docodin-sphinx-build``.
- In a process, ``docodin.shim.uninstall_shim()`` removes the hook and drops docodin's
  ``docutils`` modules (objects created from them keep their classes);
  ``docodin.unpatch_docutils()`` undoes ``patch_docutils``.
- ``pip uninstall docodin`` removes everything, including the start-up hook.

Platforms
=========

docodin is developed and tested on macOS (Apple Silicon) and Linux (x86-64).  The build
script produces ``libdocodin.dylib`` on macOS, ``libdocodin.so`` on Linux and
``docodin.dll`` elsewhere.  ``DOCODIN_LIB_PATH`` points the package at a library in
another place (:doc:`../reference/environment`).
