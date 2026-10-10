==============================================================================
DocOdin Discussions
==============================================================================

The DocOdin Discussions (DODs) are docodin's design records.  Each one explains a
decision: the problem, the design, the alternatives, what it means for docutils fidelity,
and how it was verified.  A record has a state, from ``prediscussion`` to ``committed``,
so it is always clear which records describe docodin as it is and which are proposals.
DOD 1 describes the process.

.. rubric:: Quick start

1. Create a record: ``docodin dod new "Title" --labels parser,performance``.
2. Write it, and check it with ``docodin-check`` and ``docodin dod check``.
3. Open a pull request, set the state to ``discussion`` and link the pull request in
   ``:Discussion:``.
4. When it is merged or implemented, update the state and run ``docodin dod index``.

.. toctree::
   :maxdepth: 1
   :caption: All records
   :glob:

   [0-9]*

By state
========

.. dod-index-start

Committed
---------

- :doc:`DOD 1: DocOdin Discussions <0001-dod-process>`
- :doc:`DOD 2: The docodin Compiler Architecture <0002-compiler-architecture>`
- :doc:`DOD 3: A Native Parser with Exact docutils Fidelity <0003-exact-docutils-fidelity>`
- :doc:`DOD 4: Data-Oriented Storage: Handles, Struct of Arrays and Arenas <0004-data-oriented-storage>`
- :doc:`DOD 5: Elm-Style Diagnostics for docodin's Own Tools <0005-elm-style-diagnostics>`
- :doc:`DOD 6: A Hand-Written docutils Package and Its Import Hook <0006-docutils-shim>`
- :doc:`DOD 7: A Pure-Python Parser for Extensions That Change the Grammar <0007-python-fallback-parser>`
- :doc:`DOD 8: The Native Pipeline: Reader, Transforms, Writers and Publisher <0008-native-pipeline>`
- :doc:`DOD 9: Python Libraries Stay Python <0009-python-library-fallback>`
- :doc:`DOD 10: Packaging and Activation <0010-packaging-and-activation>`
- :doc:`DOD 11: Code Rules <0011-code-rules>`
- :doc:`DOD 12: Research for 0.2.0: Parser Speed, Positions and Editors <0012-parser-research-0-2-0>`
- :doc:`DOD 13: Source Spans and the Line Index <0013-source-spans>`
- :doc:`DOD 14: A Native Language Server, docodin-lsp <0014-language-server>`
- :doc:`DOD 15: Lower Peak Memory <0015-lower-peak-memory>`
- :doc:`DOD 16: Garbage-Collector Tuning Is Opt-In <0016-garbage-collector-tuning>`
- :doc:`DOD 18: The Documentation System <0018-documentation-system>`
- :doc:`DOD 19: Beta Release Scope and Distribution <0019-beta-release-scope-and-distribution>`

Ideation
--------

- :doc:`DOD 17: Incremental Reparsing for Large Files <0017-incremental-reparsing>`

.. dod-index-end
