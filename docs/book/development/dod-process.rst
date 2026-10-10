.. _dod-process:

=====================================
Design records: DocOdin Discussions
=====================================

Decisions that shape docodin are written down as DocOdin Discussions (DODs): numbered
reStructuredText records in ``docs/dod``, each with a state.  DOD 1 defines the process
in full; this chapter is the working summary.

When to write one
=================

Write a DOD for a change that is hard to undo, visible to users, or needs a reason the
code cannot hold: a new native stage or command, anything that can change the docutils
path, a trade-off with measured costs, packaging and release decisions, and changes to
the project's rules.  Bug fixes, refactorings and tests do not need one.

States and labels
=================

.. list-table::
   :header-rows: 1
   :widths: 22 78

   * - State
     - Meaning
   * - ``prediscussion``
     - being written, on a branch
   * - ``ideation``
     - a placeholder for a topic nobody works on yet
   * - ``discussion``
     - open for review in a pull request
   * - ``published``
     - agreed and merged, not (fully) implemented
   * - ``committed``
     - implemented; the record explains how docodin works and why
   * - ``abandoned``
     - dropped, rejected or overtaken, with the reason

Labels: ``parser``, ``shim``, ``native``, ``performance``, ``tooling``, ``editor``,
``documentation``, ``process``, ``release``, ``compatibility``.

The format
==========

.. code-block:: rst

   ==============================================================================
   DOD 19: Title Words
   ==============================================================================

   :Authors: Name
   :State: prediscussion
   :Created: 2026-10-01
   :Discussion:
   :Labels: editor, performance

The sections follow: Summary, Background, Proposal (or Discussion), Alternatives,
Compatibility and fidelity, Verification, Decision (or Outcome), References.  Optional
fields: ``Updated``, ``Supersedes``, ``Superseded-By``.

The workflow
============

.. code-block:: console

   $ git switch -c dod/0019
   $ docodin dod new "Incremental checking in the language server" --labels editor
   $ $EDITOR docs/dod/0019-incremental-checking-in-the-language-server.rst
   $ docodin-check docs/dod/0019-*.rst && docodin dod check
   $ git push -u origin dod/0019            # reserves the number
   # open a pull request; set :State: discussion and :Discussion: to its link
   # when agreed: fill in Decision, set :State: published, then
   $ docodin dod index
   # when implemented: write the Outcome, set :State: committed, update the book
   # and the changelog, and run docodin dod index again

``docodin dod list --state committed`` and ``docodin dod list --label parser`` show the
records.  A ``published`` or ``committed`` record is never rewritten to describe a new
design: a new record supersedes it.

The records so far
==================

.. list-table::
   :header-rows: 1
   :widths: 10 62 28

   * - DOD
     - Title
     - State
   * - 1
     - DocOdin Discussions
     - committed
   * - 2
     - The docodin Compiler Architecture
     - committed
   * - 3
     - A Native Parser with Exact docutils Fidelity
     - committed
   * - 4
     - Data-Oriented Storage: Handles, Struct of Arrays and Arenas
     - committed
   * - 5
     - Elm-Style Diagnostics for docodin's Own Tools
     - committed
   * - 6
     - A Hand-Written docutils Package and Its Import Hook
     - committed
   * - 7
     - A Pure-Python Parser for Extensions That Change the Grammar
     - committed
   * - 8
     - The Native Pipeline: Reader, Transforms, Writers and Publisher
     - committed
   * - 9
     - Python Libraries Stay Python
     - committed
   * - 10
     - Packaging and Activation
     - committed
   * - 11
     - Code Rules
     - committed
   * - 12
     - Research for 0.2.0: Parser Speed, Positions and Editors
     - committed
   * - 13
     - Source Spans and the Line Index
     - committed
   * - 14
     - A Native Language Server, docodin-lsp
     - committed
   * - 15
     - Lower Peak Memory
     - committed
   * - 16
     - Garbage-Collector Tuning Is Opt-In
     - committed
   * - 17
     - Incremental Reparsing for Large Files
     - ideation
   * - 18
     - The Documentation System
     - committed
   * - 19
     - Beta Release Scope and Distribution
     - committed

``docs/dod/index.rst`` is the authoritative list; update this table when a record is
added or changes state.
