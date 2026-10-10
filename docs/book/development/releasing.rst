.. _releasing:

=========
Releasing
=========

A release is the artifacts that users install: the sdist and the platform wheels.  The
release gate builds them from one revision, installs them outside the checkout, tests
what users run, and keeps the results.  DOD 19 records why.

The release gate
================

.. code-block:: console

   $ scripts/release_gate.sh                 # on a clean tree
   $ scripts/release_gate.sh --allow-dirty   # trying it out with local changes

The script stops at the first failure.  On a clean tree it runs these steps:

1. **The engine and the programs**: ``scripts/build_odin.sh``.
2. **The tests**: every Odin test group (``odin/tests`` and ``odin/*/tests``) with
   ``-vet -strict-style``, then ``uv run --extra test python -m pytest -q tests``.
3. **The sdist, and the wheel built from it**: ``uv build --sdist``, then the sdist is
   unpacked in a temporary directory and ``uv build --wheel`` runs there, as an installer
   building from source would, compiling the native code again.  The unpacked tree is
   deleted before the next step, so the installed programs cannot depend on it.  On
   Linux, ``uvx auditwheel show`` checks that the wheel's manylinux tag matches the glibc
   symbols the binaries use.
4. **The installed wheel**: a new environment outside the checkout gets the wheel and
   Sphinx.  The gate runs the three programs (``--version``), publishes a document that
   includes ``<isonum.txt>`` to HTML and LaTeX, checks it with ``docodin-check``, imports
   the library from Python, and builds a small Sphinx project with ``docodin sphinx`` and
   with ``docodin-sphinx-build``.
5. **The documentation**: the installed ``docodin`` builds ``docs/book`` and ``docs/dod``
   with ``-W``, with the PDF books when ``lualatex`` is on the ``PATH`` or in
   ``/Library/TeX/texbin``.  Without it the gate builds HTML only and prints ``PDF books:
   SKIPPED``.

With changes in the working tree, the gate refuses to start (status 2) unless
``--allow-dirty`` is given: a gate result names a revision, and it is only meaningful for
a committed one.

Requirements
------------

Those of :doc:`building`: Odin, a C toolchain, ``uv``, ``git``, and for the PDFs a TeX
distribution with ``lualatex`` and the fonts of :doc:`documentation`.  ``uv`` chooses the
Python, as for any ``uv`` command (in the checkout, the ``.python-version`` file names
3.12); ``UV_PYTHON`` selects another one, for example ``UV_PYTHON=3.13``.

Results
-------

Everything goes to ``build/release-gate/<revision>/``, where ``<revision>`` is the full
commit hash:

.. code-block:: text

   build/release-gate/<revision>/
     gate.log        the platform, the Odin and uv versions, and every step's output
     dist/           the sdist and the wheel that were tested
     docs/book/      the book built by the installed docodin (html/, latex/)
     docs/dod/       the design records, likewise

``gate.log`` ends with ``all gate steps passed`` when every step passed.  Keep the
directory with the release: the tested artifacts are the ones to publish.

On a remote Linux host
----------------------

Each platform needs its own run, because the wheel and the programs are built per
platform.  To gate a revision on a Linux machine over ``ssh``, check out the same commit
there, run the gate, and copy the results back:

.. code-block:: console

   $ REV=$(git rev-parse HEAD)
   $ git push build-host:docodin "$REV:refs/heads/release-gate"
   $ ssh build-host "cd docodin && git checkout -q --detach $REV &&
         UV_PYTHON=3.13 scripts/release_gate.sh"
   $ rsync -a "build-host:docodin/build/release-gate/$REV/" \
         "build/release-gate/linux-3.13/$REV/"

``build-host:docodin`` is a clone on the remote machine; any way of getting the same
commit there works, as long as its tree is clean.  The gate needs no display, and a
machine without TeX builds the HTML and says SKIPPED for the PDFs.  Run it once for each
Python to be verified, and copy the results after each run: the next run of the same
revision replaces them.

Verified platforms
------------------

.. list-table::
   :header-rows: 1
   :widths: 30 30 40

   * - Platform
     - Python
     - Gate result for 1.0.0b1
   * - macOS arm64
     - CPython 3.12
     - passed, with the PDF books
   * - Linux x86-64, glibc (``manylinux_2_34_x86_64``)
     - CPython 3.12
     - passed (276 Python tests passed, 8 skipped); PDFs skipped, no TeX engine
   * - Windows, other architectures, musl
     - not run
     - not verified

What the gate does not cover
----------------------------

The differential suites (:doc:`differential-testing`), the test suites of docutils,
Sphinx and the extensions (:doc:`testing`) and the benchmarks need other checkouts and
take longer; run them before a release as the :doc:`../appendices/maintenance-checklist`
says.  Uploading the artifacts is not part of the gate.

Making a release
================

1. Follow the :doc:`../appendices/maintenance-checklist`: the changelog, the numbers, the
   version, the design records and the documentation.
2. Commit, then run the release gate on every platform to be released, on the same
   revision.
3. Publish the sdist and the wheels from ``build/release-gate/<revision>/dist``, and tag
   the revision (``v1.0.0b1``).

The license files
=================

``LICENSE``, ``NOTICE.rst`` and ``LICENSES/`` must ship in every artifact
(:doc:`building`).  ``tests/test_release.py`` checks that the files named in
``license-files`` exist; the gate's ``dist/`` holds the artifacts to inspect.
