.. _installation:

============================
Installation and activation
============================

Installing docodin
==================

For a published beta, install its matching wheel from PyPI:

.. code-block:: console

   $ uv pip install docodin==1.0.0b1  # or: pip install docodin==1.0.0b1

Check `GitHub Releases <https://github.com/insanai/docodin/releases>`__ for published
versions. If the beta has not been published yet, use :doc:`../development/building`.

docodin needs Python 3.12 or later and has no dependencies.  Its wheels are built per
platform, not per Python version: the native library is loaded with ``ctypes`` and
exchanges data in CPython's ``marshal`` format, so one wheel (tagged
``py3-none-<platform>``) serves every supported Python.  On Linux the platform is
``manylinux_<x>_<y>_<arch>``, from the newest glibc symbol version that the library and
the programs need: ``manylinux_2_34_x86_64`` for 1.0.0b1, so glibc 2.34 or later (Ubuntu
22.04, Debian 12, RHEL 9 or newer).  On macOS the wheel targets macOS 11.0 or later.

The extras add optional tools:

``docodin[sphinx]``
   Sphinx 8.0 or later.
``docodin[test]``
   pytest, Sphinx and docutils, for docodin's own tests.

Standalone native downloads
----------------------------

Each GitHub release includes native archives for Linux x86-64 and macOS arm64, together
with ``SHA256SUMS``. Extract the archive for your platform and run ``docodin --help``,
``docodin-check --help`` or ``docodin-lsp --help`` from it. The archive contains the three
programs and their license notices; the matching wheel also installs the Python package
and shared library. Use the wheel for Sphinx integration and Python-dependent fallback
features.

The published release includes PDF copies of this book and the design records, built
from the same source revision as its distributions. The website follows verified
``main`` changes; use the release PDFs for documentation matching an older installation.

What the wheel installs
-----------------------

``docodin``
   The Python package: the native library, the docutils implementation
   (``docodin.shim``), the tree builder and the Sphinx integration.
``docodin.pth`` and ``docodin_autoload.py``
   A start-up hook in ``site-packages``.  It serves ``docutils`` from docodin when
   ``DOCODIN_DOCUTILS=1`` is set, and otherwise only when no docutils is installed.
``docodin``, ``docodin-check``, ``docodin-lsp`` (programs)
   The native programs, installed into the environment's ``bin`` directory
   (``Scripts`` on Windows): the publisher and book builder (:doc:`command-line`), the
   checker (:doc:`checker`) and the language server (:doc:`editors`).  They run without
   Python and without docodin's source checkout: the docutils data they need
   (stylesheets, templates, ``docutils.sty`` and the standard include files) is embedded.
``docodin-sphinx-build`` (command)
   ``sphinx-build`` running on docodin (:doc:`sphinx`), a Python console script.
``LICENSE``, ``NOTICE.rst``, ``LICENSES/``
   docodin's MIT license, the third-party notices and their license texts, in the
   wheel's ``dist-info/licenses`` directory.

Until 0.2.0 the wheel installed a Python console script named ``docodin`` (docutils'
front end with docodin's parser) and the native programs had to be built from a source
checkout.  Since 1.0.0b1 ``docodin`` is the native program; the Python front end is
``python -m docodin``, which the native program runs for what needs Python.

Which Python the native programs use
------------------------------------

``docodin`` runs ``python -m docodin`` for documents that need a Python library, for
``--config``, ``--record-dependencies`` and the ``--dump-*`` options, and for ``docodin
sphinx``.  It uses the first of these that can import docodin:

1. ``$DOCODIN_PYTHON``;
2. ``python3``, then ``python``, in the directory of the ``docodin`` program, which is
   the environment the wheel installed it into;
3. ``python3`` on the ``PATH``.

A program installed by the wheel therefore finds the Python of its own environment
without any setting.  ``docodin-check`` and ``docodin-lsp`` never run Python.

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

The release gate (:doc:`../development/releasing`) has verified 1.0.0b1 on macOS arm64
(with the PDF books) and on Linux x86-64 with glibc 2.34 or later, under CPython 3.12.
Windows, other architectures and musl-based Linux are not verified; the build script
produces ``docodin.dll`` on Windows, but no one has run the tests there.  On macOS the
library and the programs target macOS 11.0 or later.  ``DOCODIN_LIB_PATH`` points the
package at a library in another place (:doc:`../reference/environment`).
