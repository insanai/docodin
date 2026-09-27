.. _testing:

=======
Testing
=======

docodin's tests answer one question in many ways: does docodin do exactly what docutils
does?  Unit tests check the pieces; differential tests compare whole runs with docutils
(:doc:`differential-testing`); the test suites of docutils, Sphinx and popular
extensions check the ecosystem.

Everyday commands
=================

.. code-block:: console

   $ scripts/build_odin.sh
   $ for t in odin/tests odin/{doctree,reader,transforms,writers,publish,lsp}/tests; do
   >     odin test $t
   > done
   $ uv run python -m pytest -q tests

Run both after every change.  ``odin test`` builds and runs the Odin unit tests of a
package; add ``-vet -strict-style`` to match the build flags.

The Odin tests
==============

.. list-table::
   :header-rows: 1
   :widths: 32 68

   * - Package
     - Tests
   * - ``odin/tests``
     - the parser (``rst_test.odin``) and source spans (``spans_test.odin``)
   * - ``odin/doctree/tests``
     - storage, registry, Unicode tables, and the interchange fixtures, which must load and
       dump back byte for byte
   * - ``odin/reader/tests``
     - the reader and the directives
   * - ``odin/transforms/tests``
     - transform units
   * - ``odin/writers/tests``
     - the writers against the ``output`` fixtures of the interchange
   * - ``odin/publish/tests``
     - ``publish`` and ``read_document``
   * - ``odin/lsp/tests``
     - the protocol and each feature of the language server

Some test directories also hold the Odin programs that the Python differential scripts
build and run (``differential``, ``harness``, ``odin/math/difftest``).

The Python tests
================

.. list-table::
   :header-rows: 1
   :widths: 32 68

   * - File
     - What it checks
   * - ``test_native.py``
     - the C ABI: parse results, the wire, line splitting, inline parsing
   * - ``test_parity.py``
     - host corner cases against docutils
   * - ``test_python_states.py``
     - custom, subclassed and patched parser states against docutils
   * - ``test_ecosystem.py``
     - Sphinx extension behaviour on the shim and on docutils, side by side
   * - ``test_shim.py``
     - the import hook, the start-up hook, all writers, ``docodin-sphinx-build``, the
       collector tuning, ``conf.py`` discovery
   * - ``test_docutils_api.py``
     - docutils' public API on docodin
   * - ``test_sphinx.py``
     - Sphinx builds with docodin
   * - ``test_publish_native.py``
     - ``publish_native``, ``render_html``, ``render_latex``, the fallback and
       ``native_only``
   * - ``test_native_cli.py``
     - the native ``docodin`` command against ``python -m docutils``
   * - ``test_checker.py``
     - ``docodin-check``: formats, levels, exit status
   * - ``test_lsp.py``
     - ``docodin-lsp`` against docutils' messages and resolved references
   * - ``test_conformance.py``
     - docutils' parser test suite (with ``DOCUTILS_SRC`` set to a docutils sdist)

The test suites of others
=========================

docodin's compatibility claims rest on running other projects' test suites on it:

- **docutils' test suite**: from a docutils 0.22.4 source tree, run its tests in an
  environment where docodin is installed and ``DOCODIN_DOCUTILS=1`` is set, so that
  ``import docutils`` is docodin's package; then again with ``DOCODIN_NATIVE=0``.  The
  expected result is docutils' own: 465 passed, 17 skipped, 1862 subtests.
- **Sphinx's test suite**, from a Sphinx 9.1 checkout, the same way; compare the lists of
  passed and failed tests with a run on docutils.
- **Extensions and themes**: the same procedure for each project's own test suite.

``tests/conformance/run_docutils_suite.py DOCUTILS_SRC`` runs docutils' parser test cases
(``test/test_parsers``, the input and expected pseudo-XML pairs) against docodin and
reports a pass rate per case; ``-k`` selects cases and ``-v`` shows failures.

Benchmarks
==========

``tests/benchmark.py`` compares docodin's parser with docutils' (see
:doc:`../internals/performance`).  Benchmarks are not tests: they do not fail, and their
numbers belong in the changelog with the machine and versions they were measured on.
