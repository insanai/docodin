==============================================================================
DOD 19: Beta Release Scope and Distribution
==============================================================================

:Authors: Vikrant Rathore
:State: committed
:Created: 2026-10-10
:Discussion:
:Labels: release, compatibility

.. contents:: Contents
   :local:
   :depth: 1

Summary
=======

docodin 1.0.0b1, the first beta, is a native-first release with a stated support
contract: native publishing, checking, the language server's single-document features,
native HTML book builds from a documented subset, and LaTeX output with an external TeX
engine for PDFs.  The Python, docutils and Sphinx integrations are supported within
their measured bounds rather than promised as unchanged replacements.  The wheel ships
the native programs, which embed the docutils data they need and so run without the
source checkout.  The shared library returns arena blocks to a small process-wide cache,
so threads that exit keep no memory.  One version constant serves every component, and
a release gate script builds, installs and tests the artifacts outside the checkout.

Background
==========

An external release review of revision ``82fb438`` (10 October 2026) found the native
tooling close to a first beta and asked for six things before it:

1. **A stated contract.**  The README promised that every Sphinx and docutils user runs
   unchanged with identical output.  That was wider than the native-first scope and
   than what was measured: the test suites of docutils, Sphinx and a dozen extensions
   give docutils' results, but not every extension or project has been run.
2. **Invalid input in the book builder.**  ``odin/site/project.odin`` published the raw
   bytes of a source that was not UTF-8: ``docodin book build -W`` exited with status 0
   and wrote invalid HTML.
3. **Distribution.**  The wheel shipped the shared library and a Python console script
   named ``docodin``, but not the native programs, which had to be built from a checkout
   (DOD 10).  The native ``docodin`` named the checkout's docutils data directory by its
   absolute build path (``cmd/docodin/main.odin``): a copied program failed on ``..
   include:: <isonum.txt>`` once the checkout was gone.
4. **Thread-lifetime retention in the shared library.**  Each call worked in a
   thread-local bump arena (``odin/lib/export.odin``), and ``bump_reset`` kept one block
   of up to 4 MiB for the next call (DOD 15).  Nothing released that block when the
   thread exited.  A C host that ran one parse on each of 200 short-lived threads grew to
   202 MiB, about 1 MiB per retired thread; a Python ``ctypes`` host grew to 215 MiB.
   Hosts with a fixed thread pool were bounded, hosts that create threads were not.
5. **Release metadata.**  The artifacts reported 0.2.0, the version was written
   separately in nine places, and there was no license text in the repository or the
   wheel.
6. **A repeatable release gate**, which builds and installs the advertised artifacts and
   records the tested revision and results.  Two tests depended on the environment: the
   site search-index test freed its allocator before its clean-up ran, and a DOD test
   needed the runner's git identity.

The review's measurements also separated two products that the documentation had
mixed: the native book builder (27.8 and 28.5 times faster than Sphinx on HTML builds)
and Sphinx running in Python on docodin's docutils (1.38 times on CPython's
documentation).

Discussion
==========

The support contract
--------------------

The beta supports:

- native publishing to HTML5, LaTeX, XeLaTeX, Docutils XML and pseudo-XML, with
  docutils' output, messages and exit status, and documents that need a Python library
  handed to Python (DOD 9);
- the native checker, ``docodin-check``;
- ``docodin-lsp``'s documented features, one document at a time;
- native HTML book and site builds (``docodin book build``) from the ``conf.py`` values
  and the markup subset documented in the book (DOD 18);
- LaTeX and XeLaTeX output; PDFs need an external TeX engine;
- the Python, docutils and Sphinx integrations within their measured bounds: docutils'
  and Sphinx's test suites, and those of the listed extensions, give docutils' results.

Outside the contract, and stated as limits rather than as unfinished features: running
arbitrary ``conf.py`` code or Sphinx extensions in the native builder, reproducing
Sphinx's builders or its HTML, rename and cross-document resolution in the language
server, native manual-page, ODT, S5, PEP and HTML4 writers.  Full parity with every
Sphinx extension stays a goal.  The native engine uses Unicode 16 tables whatever the
host Python (DOD 3), so on a Python with older Unicode data a few results differ from
docutils on that Python; this is documented, not hidden.

The book's chapter "Known limits" holds the contract; the README summarises it.

The native programs in the wheel
--------------------------------

The wheel installs ``docodin``, ``docodin-check`` and ``docodin-lsp`` into the
environment's scripts directory (``hatch_build.py``, hatchling's ``shared_scripts``).
The Python console script ``docodin`` is removed: two programs of one name in one
environment were a trap, and the native ``docodin`` already runs ``python -m docodin``
for everything that needs Python, with the same arguments, streams and exit status.  It
finds that Python as ``$DOCODIN_PYTHON``, else the ``python3`` or ``python`` next to the
program (the environment the wheel installed it into), else ``python3`` on the ``PATH``.
``docodin sphinx ARGS`` is a native command that runs ``python -m docodin sphinx ARGS``.
``docodin-sphinx-build`` stays a Python console script.  ``scripts/build_odin.sh``
builds the programs for the library's minimum macOS version (11.0), so they match the
wheel's platform tag.

A Linux wheel is tagged ``manylinux_<x>_<y>_<arch>`` after the newest ``GLIBC_x.y``
symbol version that the shipped library and programs require, which ``hatch_build.py``
reads from the binaries (at least 2.17, the oldest manylinux baseline).  The tag then
states the glibc the binaries really need instead of the build host's platform.  The
1.0.0b1 build is ``manylinux_2_34_x86_64``: glibc 2.34 or later (Ubuntu 22.04, Debian 12,
RHEL 9 or newer).

Data embedded for relocation
----------------------------

The native programs embed docutils' standard include files
(``odin/reader/std_include.odin``, with ``#load_directory``), as they already embedded
the stylesheets, templates and ``docutils.sty``.  ``pb.tools_docutils_dir`` returns the
checkout's ``python/docodin/shim/docutils`` when it exists, so that paths in messages are
those of the Python package, and otherwise the placeholder directory ``<docutils>``,
whose files are read from the embedded copies.  A file on disk always wins.  Without the
checkout, ``--link-stylesheet`` links a stylesheet by its file name, as docutils keeps a
stylesheet path it cannot find.  The include files add 256 KB to each program.

Arena blocks in a shared cache
------------------------------

After the outermost call of a thread returns, ``bump_park`` resets the thread's arena
and moves its one kept block (at most ``BUMP_RETAIN_MAX``, 4 MiB) to a process-wide cache
of ``BUMP_CACHE_MAX`` (8) blocks, or unmaps it when the cache is full.  The next
outermost call on any thread takes a block back with ``bump_unpark``.  Between calls an
arena owns no memory, so a thread that exits owns nothing, and the whole process keeps at
most 32 MiB cached however many threads it creates.  Steady-state parsing still maps no
memory, and calls that re-enter through the include callback keep using the same arena.
The cache is guarded by an atomic mutex, taken twice per outermost call; parsing itself
stays lock-free.

One version
-----------

``odin/version/version.odin`` holds the version, which the library, the three programs
and the pages of the native book builder import.  ``pyproject.toml``,
``docodin.__version__`` and both documentation ``conf.py`` files write it too, and
``tests/test_release.py`` checks that all of them, the loaded library and the built
programs agree.  The beta is 1.0.0b1.

License files
-------------

``LICENSE`` (MIT), ``NOTICE.rst`` (the third-party works docodin contains or ports:
docutils' data files and algorithms, SmartyPants, the Unicode Character Database) and
``LICENSES/`` (their license texts) ship in the sdist and, through ``license-files``,
in the wheel's ``dist-info/licenses``.

The release gate
----------------

``scripts/release_gate.sh`` runs on a clean tree and records everything under
``build/release-gate/<revision>/``:

1. builds the engine and the programs;
2. runs every Odin test group with ``-vet -strict-style`` and the Python tests;
3. builds the sdist, unpacks it in a temporary directory, builds the wheel from it as an
   installer would, and deletes the unpacked tree; on Linux, ``uvx auditwheel show``
   checks the wheel's manylinux tag;
4. installs the wheel and Sphinx into a new environment outside the checkout, and runs
   the programs, a document with a standard include, the LaTeX writer, the checker, the
   library from Python, ``docodin sphinx`` and ``docodin-sphinx-build``;
5. builds ``docs/book`` and ``docs/dod`` with the installed ``docodin``, with PDFs when
   ``lualatex`` is installed, and says SKIPPED otherwise.

The two environment-dependent tests were made self-contained, and the non-UTF-8 book
source now stops the build with a SEVERE report and status 1.

Alternatives
============

- **Keep the drop-in promise.**  It would have made full Sphinx and extension parity a
  release gate, though the native tools are useful now and the integrations' bounds are
  measured.  Rejected for the beta; parity stays on the roadmap.
- **Narrow the beta to the native tools only.**  The Python integrations are tested
  against docutils' and Sphinx's suites and are what Sphinx users run; dropping them
  from the contract would hide supported, tested behaviour.
- **A source-only beta.**  Document that the native programs are built from a checkout.
  The review accepted this for a source-only release, but then the checker, the book
  builder and the language server need the Odin compiler, and the two ``docodin``
  commands stay confusing.  Rejected.
- **Build Linux wheels in a manylinux container** and repair them with ``auditwheel``.
  It would lower the glibc requirement, but needs the Odin compiler in an old
  distribution's image; reading the requirement from the binaries and checking it with
  ``auditwheel show`` gives a correct tag now, and a container build can come later.
- **Separate binary archives** beside the wheel.  Another artifact per platform to
  build, test and document; the wheel is already per platform, and installers put its
  scripts on the ``PATH``.
- **Keep the Python console script** under another name.  ``python -m docodin`` already
  provides it, and the native program delegates to it.
- **Install the data files beside the programs** and look them up at run time.  The
  scripts directory of a wheel holds programs, not data trees, and a lookup relative to
  the executable is fragile across installers.  Embedding costs 256 KB per program.
- **Thread-exit destructors** (``pthread_key_create``, fiber-local storage on Windows)
  to unmap a thread's block when it exits.  Platform-specific, run in an unspecified
  order with other destructors, and they leave a pool of idle threads holding one block
  each.  The shared cache bounds the total for any number of threads, on every platform.
- **An explicit clean-up call** for hosts.  Every host would have to call it on every
  thread before the thread exits, which a ``ctypes`` caller cannot arrange reliably.
- **Unmap the arena after every call.**  Bounded, but every call would map and fault in
  fresh memory, which DOD 15 removed from steady-state parsing.
- **Write the version in each component** and grep before a release, as before.  Nine
  places drift apart easily; the test makes a mismatch fail.
- **A CI workflow instead of a script.**  The repository has no CI; a script runs the
  same steps locally, on a remote Linux host, or from a future CI job.

Compatibility and fidelity
==========================

The docutils path is unchanged.  The native programs' output and messages are unchanged
with the checkout present; without it, message paths name the ``<docutils>`` directory
and linked stylesheets are named by their file names.  A book source that is not UTF-8
used to give a zero exit status and invalid pages; it now fails, which a project that
relied on that must fix.  Environments that used the Python console script ``docodin``
get the native program, which delegates to the same Python front end for what it does
not do natively; ``python -m docodin`` is unchanged.  The arena cache changes no result,
only when memory is returned.

Verification
============

- ``tests/test_native.py`` (``test_short_lived_threads_do_not_retain_arenas``): 200
  short-lived threads parse a document, and peak memory grows by less than 64 MiB.  The
  review's C reproducer, run against the 1.0.0b1 library, stays at 6.05 MiB after both
  100 and 200 retired threads on Linux x86-64 (104 and 202 MiB before), and at 5.1 MiB
  after 200 retired threads on macOS arm64 (5.05 MiB after 100 calls on one thread).
- ``tests/test_book.py``: a source that is not UTF-8 stops the build with status 1 and
  no output, and ``docodin dod new`` without an author stops with NO AUTHOR (status 2).
- ``odin/publish/tests``: a standard include and the stylesheets work from the embedded
  copies, and a linked stylesheet is named by its file name.
- ``tests/test_release.py``: the versions agree, each program reports it, the license
  files exist.
- The release gate passed on macOS arm64, with the PDF books, and on Linux x86-64
  (``manylinux_2_34_x86_64``, confirmed by ``auditwheel show``; 276 Python tests passed
  and 8 skipped; PDFs skipped, the host has no TeX engine), both under CPython 3.12.
  Windows, other architectures and musl-based Linux are not verified.

Outcome
=======

Released in docodin 1.0.0b1: "Return a thread's arena block to a shared cache after each
library call", "Stop a book build at a source that is not UTF-8", "Name the author of a
new DOD with --author when git has none", "Keep the build allocator scoped in the search
index test", "Embed the standard include files so the native tools run without the
checkout", "Link embedded stylesheets by name when they are not on disk", "Find the
Python of docodin's own environment and add docodin sphinx", "Build the native programs
for the library's minimum macOS version", "Install the native programs from the wheel",
"Detect patched states and DOCODIN_NATIVE=0 in docodin.Parser and the Sphinx extension",
"Freeze the collector right after Sphinx starts in docodin-sphinx-build", "Add the MIT
license, third-party notices and their license texts", "Share one version constant among
the native components", "Set the version to 1.0.0b1 and test that all components agree",
"Add a release gate script", "Install the test extra in the release gate", "Tag Linux
wheels manylinux by the glibc versions the binaries need" and "Audit the Linux wheel's
platform tag in the release gate".

This record replaces the console-script part of DOD 10; DOD 10's activation design
stands.

References
==========

- DOD 3 (fidelity and the Unicode tables), DOD 9 (Python libraries stay Python), DOD 10
  (packaging and activation), DOD 15 (lower peak memory), DOD 18 (the documentation
  system).
- ``odin/lib/bump.odin``, ``odin/lib/export.odin``, ``odin/site/project.odin``,
  ``odin/reader/std_include.odin``, ``odin/publish/settings.odin``,
  ``odin/version/version.odin``, ``cmd/docodin/python.odin``, ``hatch_build.py``,
  ``pyproject.toml``, ``scripts/build_odin.sh``, ``scripts/release_gate.sh``,
  ``tests/test_release.py``.
- The review: ``build/reviews/beta-2026-10-10/release-review.rst`` (not versioned).
- ``CHANGELOG.rst`` (1.0.0b1).
