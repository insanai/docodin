.. _maintenance-checklist:

=====================
Maintenance checklist
=====================

Use this checklist whenever a change reaches users or contributors, and before every
release.  The book is correct only if it is kept in step with the code.

For every change
================

Commands and options
   - A new or changed option of ``docodin``, ``docodin pdf``, ``docodin check``,
     ``docodin book``, ``docodin dod`` or ``docodin sphinx``: update
     :doc:`../reference/cli` (compare with ``bin/docodin --help`` and ``--help
     --writer=NAME`` for each writer) and the guide chapter that uses it.
   - A new or changed option of ``docodin-check`` or ``docodin-lsp``: update
     :doc:`../reference/cli` and :doc:`../guide/checker` or :doc:`../guide/editors`.

Settings and configuration
   - A new setting default in ``odin/publish/settings.odin``: update the table in
     :doc:`../reference/settings`.
   - A new ``conf.py`` value of the native builder, a new language server setting, or a
     new Sphinx configuration value: update :doc:`../reference/settings`.

Environment variables
   - A new ``DOCODIN_*`` variable, or a changed meaning: update
     :doc:`../reference/environment` (search the code with ``grep -rn DOCODIN_``).

Python API
   - A new or changed public function of ``docodin``, ``docodin.shim``,
     ``docodin.sphinx``, ``docodin.sphinx_build`` or ``docodin.conf``: update
     :doc:`../reference/python-api` and :doc:`../guide/python`.

Behaviour and fidelity
   - A new known difference from docutils, or one removed: update
     :doc:`../reference/limits` and :doc:`../reference/compatibility`.
   - A new Python need: update :doc:`../internals/python-needs`.
   - A new diagnostic title or hint in ``odin/check/hints.odin``: update the table in
     :doc:`../guide/checker`.

Internals
   - A change to a package's structure or data layout: update its chapter in Part IV and
     the package tables in :doc:`../internals/architecture` and
     :doc:`../development/building`.
   - A new test or differential script: update :doc:`../development/testing` or
     :doc:`../development/differential-testing`.

Distribution and licenses
   - A change to what the wheel or the sdist contains: update
     :doc:`../guide/installation` and :doc:`../development/building`.
   - Embedded or ported third-party code or data: update ``NOTICE.rst`` and add its
     license text to ``LICENSES/``.
   - A change to what the beta supports or to the verified platforms: update
     :doc:`../reference/limits` and ``README.rst``.

Design
   - A decision that needs a record: write a DOD (:doc:`../development/dod-process`).
   - A record that changes state: run ``docodin dod index`` and update the table in
     :doc:`../development/dod-process`.

Before a release
================

1. Run the unit tests, the Python tests and the differential suites
   (:doc:`../development/testing`, :doc:`../development/differential-testing`).
2. Measure the benchmarks on the reference machines and record the machine, Python,
   docutils and Sphinx versions with the numbers.
3. Write the release's section in ``CHANGELOG.rst``: what changed for users, the
   measurements, and anything that changed defaults.
4. Update the numbers wherever the book quotes them: :doc:`../internals/performance`,
   :doc:`../internals/memory`, :doc:`../guide/sphinx`,
   :doc:`../orientation/introduction`, and ``README.rst``.
5. Set the version everywhere it is written: ``odin/version/version.odin``,
   ``pyproject.toml``, ``python/docodin/__init__.py`` and both ``conf.py`` files
   (``version`` and ``release``); run ``uv lock`` so that ``uv.lock`` follows.
   ``tests/test_release.py`` fails while they disagree; ``git grep`` the old version to
   find it in prose.
6. Set implemented DODs to ``committed`` with their outcome, and run ``docodin dod
   index``.
7. Check and build the documentation:

   .. code-block:: console

      $ bin/docodin-check README.rst CHANGELOG.rst docs/README.rst docs/book/*.rst \
            docs/book/*/*.rst docs/dod/*.rst
      $ bin/docodin dod check
      $ bin/docodin book build docs/book
      $ bin/docodin book build docs/dod
      $ uv run --group docs sphinx-build -W --keep-going -b html docs/book /tmp/book
      $ uv run --group docs sphinx-build -W --keep-going -b html docs/dod /tmp/dod

8. Build the PDFs with Sphinx and ``latexmk -lualatex``, and look at the title page, the
   part pages and a few chapters.
9. Read the quick start from start to end, and run every command in it.
10. Commit, and run the release gate (``scripts/release_gate.sh``) on every platform to
    be released (:doc:`../development/releasing`).  Record the verified platforms in
    ``CHANGELOG.rst``, ``README.rst`` and :doc:`../reference/limits`.

Periodically
============

- Check that every chapter still matches the code it describes: file names, procedure
  names, options, defaults.
- Check that external links still work.
- Remove statements about the future that have become the past.
