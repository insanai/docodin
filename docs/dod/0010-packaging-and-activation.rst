==============================================================================
DOD 10: Packaging and Activation
==============================================================================

:Authors: Vikrant Rathore
:State: committed
:Created: 2026-09-27
:Discussion:
:Labels: release, shim, compatibility

.. contents:: Contents
   :local:
   :depth: 1

Summary
=======

docodin is one Python distribution with no dependencies, built with hatchling into
platform wheels that carry the native library.  The library is loaded with ``ctypes``, so
a wheel depends on the platform but not on the Python version (``py3-none-<platform>``).
Users choose how much of their environment runs on docodin: one command
(``docodin-sphinx-build``), every process in an environment (``DOCODIN_DOCUTILS=1``,
through a start-up hook), automatically where docutils is not installed, or explicitly
from code.

Background
==========

docodin replaces a package that other packages import by name.  Two questions follow:
how the native code reaches users without a compiler, and how a user switches a program
that imports ``docutils`` to docodin without editing it.

Proposal
========

The distribution
----------------

- **Build backend: hatchling** with a custom build hook (``hatch_build.py``).  For a
  wheel, the hook runs ``scripts/build_odin.sh`` (it needs the Odin compiler and a C
  toolchain), includes the library that the script puts in ``python/docodin``, marks
  the wheel impure and tags it ``py3-none-<platform>``.  On macOS the platform tag is the
  deployment target the library is built for (``MACOSX_DEPLOYMENT_TARGET``, 11.0 by
  default).  ``DOCODIN_SKIP_NATIVE_BUILD=1`` packages a library that is already built.
  Editable installs never build; developers run the script themselves.
- **No CPython ABI.**  The library exports a C ABI, and results travel in CPython's
  ``marshal`` format, which ``marshal.loads`` decodes in C.  One wheel serves every
  supported Python version (3.12 and later).
- **No dependencies.**  ``dependencies = []``.  The extras ``sphinx`` and ``test`` add
  Sphinx and the test tools; the dependency group ``docs`` adds Sphinx and furo for the
  documentation.
- **Console scripts.**  ``docodin`` (the Python front end, ``python -m docodin``) and
  ``docodin-sphinx-build``.  The native tools (``bin/docodin``, ``bin/docodin-check``,
  ``bin/docodin-lsp``) are built from source by ``scripts/build_odin.sh``.
- **The library is replaced atomically.**  The build script copies the new library next
  to the old one and renames it into place, because overwriting a loaded (on macOS,
  code-signed) library in place makes the kernel kill the processes that use it.
- **Loading.**  ``docodin._native`` loads the library from the package directory, or
  from ``DOCODIN_LIB_PATH`` when that is set.

Activation
----------

.. list-table::
   :header-rows: 1
   :widths: 36 64

   * - How
     - What happens
   * - ``docodin-sphinx-build ARGS...``
     - ``sphinx-build`` with the shim installed first
   * - ``DOCODIN_DOCUTILS=1 any-command``
     - every Python process in the environment serves ``docutils`` from docodin
   * - docutils not installed
     - ``import docutils`` finds docodin's package through the fallback finder
   * - ``docodin.shim.install_shim(force=True)``
     - the current process, before docutils is imported
   * - ``extensions = ["docodin.sphinx"]``
     - Sphinx parses with docodin's parser, whichever docutils is loaded
   * - ``docodin.patch_docutils()``
     - an installed docutils parses with docodin's native engine

The start-up hook is ``docodin.pth``, which the wheel installs into ``site-packages``
with ``docodin_autoload.py``.  Python imports it when the interpreter starts.  It is a
top-level module, so importing it does not import the ``docodin`` package: with
``DOCODIN_DOCUTILS=1`` it installs the shim; otherwise it only appends a lazy finder that
imports docodin when something asks for ``docutils`` and nothing else provides it.  It
costs about 0.1 ms per interpreter start.

Alternatives
============

- **A CPython extension module.**  One wheel per Python version and platform, and
  nothing gained: the data crosses the boundary once, in ``marshal`` format.
- **Replace docutils on install** (declaring that docodin provides ``docutils``).
  Package managers do not support that cleanly, and users could not switch back per
  command.
- **Always serve docutils from docodin** when installed.  Too surprising for an
  environment that has both; activation is explicit, except where docutils is missing.

Compatibility and fidelity
==========================

Installing docodin changes nothing for a program that imports an installed docutils,
unless the user activates docodin.  Where docutils is missing, ``import docutils``
succeeds with docodin's package.

Verification
============

- ``uv build`` produces the sdist and a platform wheel; the wheel contains the library,
  the shim's data files, ``docodin.pth`` and ``docodin_autoload.py``.
- ``tests/test_shim.py`` covers the finder, ``install_shim``, ``enable`` and the
  start-up hook.

Outcome
=======

Implemented in docodin 0.1.0 ("Build platform wheels with hatchling, including the
shim's data files", "Add docodin-sphinx-build and an opt-in start-up hook that serves
docutils", "Install the native library atomically so running processes are not
killed").

References
==========

- ``pyproject.toml``, ``hatch_build.py``, ``scripts/build_odin.sh``,
  ``python/docodin.pth``, ``python/docodin_autoload.py``, ``python/docodin/_native.py``.
- DOD 6 (the import hook), DOD 16 (the collector tuning of ``docodin-sphinx-build``).
