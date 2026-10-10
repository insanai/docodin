.. _releasing:

=========
Releasing
=========

A release is the artifacts that users install: the sdist and the platform wheels.  The
release gate builds them from one revision, installs them outside the checkout, tests
what users run, and keeps the results.  DOD 19 records why.

The release gate
================

.. graphviz::
   :class: adaptive-diagram
   :align: center
   :caption: Publishing a reviewed GitHub draft triggers PyPI; qualified packages are not rebuilt.
   :alt: A verified main revision is tagged, gated on Linux and macOS, assembled with checksums, reviewed as a draft and published; PyPI uploads the same two wheels and source distribution.

   digraph release_flow {
   graph [bgcolor="white", pad="0.28", nodesep="0.4", ranksep="0.28", fontname="Helvetica", fontsize=17, fontcolor="#425574", color="#CBD5E1"];
   node [shape=box, style="rounded,filled", fontname="Helvetica", fontsize=16, margin="0.22,0.16", fillcolor="#EFF4FF", color="#B3C6F7", fontcolor="#18243D", penwidth=1.2];
   edge [fontname="Helvetica", fontsize=12, color="#526B97", fontcolor="#425574", arrowsize=0.75, penwidth=1.4];
   rankdir=TB;
   source [label="Working branch -> main\nReviewed source revision", fillcolor="#F4F6FA", color="#CDD5E2"];
   verify [label="Verify\nOdin + Python + CLI checks"];
   tag [label="Version tag\nv1.0.0b1", fillcolor="#DBE7FF", color="#7DA1ED"];
   linux [label="Linux gate\nsdist -> wheel -> fresh install\nHTML + all PDFs"];
   mac [label="macOS gate\nsdist -> wheel -> fresh install\nNative + Sphinx smoke"];
   assemble [label="Assemble exact tested artifacts\nVersion, revision, SHA256 checks"];
   draft [label="Draft GitHub prerelease\nReview assets and notes", fillcolor="#FFF3E6", color="#E3BB86"];
   published [label="Publish GitHub release\nNative archives + packages", fillcolor="#E5F5EE", color="#8DC9B0"];
   pypi [label="PyPI workflow\nVerify and upload the same\n2 wheels + sdist", fillcolor="#E5F5EE", color="#8DC9B0"];
   source -> verify -> tag;
   tag -> linux;
   tag -> mac;
   {rank=same; linux; mac;}
   linux -> assemble;
   mac -> assemble;
   assemble -> draft -> published -> pypi;
   }


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
   with ``-W``. With ``lualatex`` on the ``PATH`` or in ``/Library/TeX/texbin``, it
   also builds both PDF books and a standalone PDF for every DOD except the template.
   Without TeX the gate builds HTML only and prints ``PDF books: SKIPPED``. The Linux
   release job requires the complete PDF collection for validation. PDFs are published
   on the documentation website and are not copied into release assets.

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
     docs/pdf/       both books and the individual DOD PDFs

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
     - passed, including PDF content regressions and both PDF books
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

GitHub Actions builds and tests the release artifacts, then prepares a draft GitHub
release. Publishing that draft triggers a separate PyPI workflow, which uploads the
same qualified files without rebuilding them.

1. Follow the :doc:`../appendices/maintenance-checklist`: update the version, changelog,
   design records and documentation, including the README and pinned installation
   examples. Commit on the working branch, merge into ``main``
   and wait for Verify to pass.
2. For a rehearsal, dispatch the Release workflow on ``main``. It builds both supported
   platforms and uploads ``release-assets`` without creating a tag, a GitHub release
   or a PyPI upload.
3. Configure the repository's ``PYPI_API_TOKEN`` secret with a PyPI token scoped to
   docodin. The token belongs in GitHub Actions secrets, never in the checkout or docs.
4. Tag the verified commit and push the tag:

   .. code-block:: console

      $ git switch main
      $ git tag -a v1.0.0b1 -m "docodin 1.0.0b1"
      $ git push origin v1.0.0b1

5. Release runs Verify, then the full gate for Linux x86-64 and macOS arm64. Linux also
   runs the PDF regressions and compiles both books and each standalone DOD. The Odin compiler,
   Source fonts and action revisions are pinned; downloads are checked against SHA256.
6. The workflow checks metadata and versions, produces native archives from the tested
   wheels, and adds ``RELEASE.json`` and ``SHA256SUMS``. A tag creates a **draft** GitHub
   release; beta tags are marked as prereleases. Inspect its assets and notes, then
   publish it when the token is configured.
7. Publish to PyPI downloads the published assets, verifies hashes and the tag's commit,
   checks the wheel and source metadata, and uploads only the two wheels and sdist.
   Native archives remain GitHub release downloads. PDFs are hosted on GitHub Pages. A failed publishing
   run can be retried with the workflow's ``tag`` input after correcting the failure.

The repository workflows are ``ci.yml``, ``pages.yml``, ``release.yml`` and ``publish.yml``
under ``.github/workflows``. PyPI publishing happens only for a published release,
not a normal push to ``main``. The Website workflow deploys the docodin-built site to
GitHub Pages after main's Verify workflow succeeds. It builds light and dark HTML and
the light PDF collection, adding a book download on every manual page and an individual
PDF download on each DOD page.

The README is embedded in each distribution's package metadata. PyPI displays that
release's README; editing ``README.rst`` on GitHub later does not update an existing
PyPI version. Finish and render-check it before creating the tag. A later correction
requires a new package version. GitHub Pages follows verified ``main`` changes and
hosts the documentation PDFs. Release assets contain software packages and checksums.

The license files
=================

``LICENSE``, ``NOTICE.rst`` and ``LICENSES/`` must ship in every artifact
(:doc:`building`).  ``tests/test_release.py`` checks that the files named in
``license-files`` exist; the gate's ``dist/`` holds the artifacts to inspect.
