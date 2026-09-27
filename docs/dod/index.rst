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

.. rubric:: Ideation

* :doc:`0017-incremental-reparsing`

.. rubric:: Published

* :doc:`0018-documentation-system`

.. rubric:: Committed

* :doc:`0001-dod-process`
* :doc:`0002-compiler-architecture`
* :doc:`0003-exact-docutils-fidelity`
* :doc:`0004-data-oriented-storage`
* :doc:`0005-elm-style-diagnostics`
* :doc:`0006-docutils-shim`
* :doc:`0007-python-fallback-parser`
* :doc:`0008-native-pipeline`
* :doc:`0009-python-library-fallback`
* :doc:`0010-packaging-and-activation`
* :doc:`0011-code-rules`
* :doc:`0012-parser-research-0-2-0`
* :doc:`0013-source-spans`
* :doc:`0014-language-server`
* :doc:`0015-lower-peak-memory`
* :doc:`0016-garbage-collector-tuning`

.. dod-index-end
