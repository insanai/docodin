==============================================================================
DOD 17: Incremental Reparsing for Large Files
==============================================================================

:Authors: Vikrant Rathore
:State: ideation
:Created: 2026-09-27
:Discussion:
:Labels: parser, editor, performance

.. contents:: Contents
   :local:
   :depth: 1

Summary
=======

A placeholder for ``rst.reparse(old, edit)``: reparsing only the part of a document that
an edit can affect, and reusing the rest of the old parse tree.  DOD 12 worked out the
strategy and decided not to build it until measurements show that it is needed.  This
record keeps the topic, its scope and the conditions for picking it up.

Background
==========

``docodin-lsp`` reparses the whole file on every change.  A full parse costs about 11 µs
per KB, so a 124 KB document is handled in about 6 ms from change to answer.  Only files
over about 1 MB exceed the 10 ms latency budget, and reStructuredText files of that size
are rare.  rust-analyzer and ruff reached the same conclusion for their languages.

Scope
=====

- The boundary rules of DOD 12: anchors at column 0 after a blank line, except after
  list-like constructs, simple tables and paragraphs that end in ``::``.
- A per-construct lookahead mark (the furthest line the state machine read), as the
  equivalent of tree-sitter's ``lookahead_bytes``.
- Convergence and splicing over the struct-of-arrays tree: relocated handles, shifted
  lines, rebased string views.
- Non-local state always recomputed: section levels, registries, anonymous references,
  footnote numbering.
- Changed ranges for semantic-token deltas.
- Verification by randomised edits on fuzz documents: ``reparse`` and a full parse must
  give the same tree hash and messages.

When to pick it up
==================

When the language server's measurements show real documents whose full reparse exceeds
the latency budget.  Until then, it stays in ``ideation``.

Compatibility and fidelity
==========================

The docutils path always parses fully; this would only serve the language server.

References
==========

- DOD 12 (the strategy, in the section on incremental reparsing), DOD 14.
