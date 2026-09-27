==============================================================================
DOD 11: Code Rules
==============================================================================

:Authors: Vikrant Rathore
:State: committed
:Created: 2026-09-27
:Discussion:
:Labels: process

.. contents:: Contents
   :local:
   :depth: 1

Summary
=======

docodin keeps its code small-grained and uniform: no source file over 1408 lines, lines
of at most 99 characters (108 as a hard limit), short procedures with low complexity,
idiomatic Odin written with data-oriented design, idiomatic Python in the shim,
Elm-style diagnostics in docodin's own tools, and small commits with plain messages.
The rules apply to Odin, Python and scripts alike, and to generated code.

Background
==========

docodin reimplements a large code base: docutils' Python package, and its whole
publishing pipeline again in Odin.  docutils has modules of several thousand lines.  A
port that copied that shape would be hard to review and hard to compare with its origin.
The rules keep every file readable in one sitting and every procedure testable on its
own.

Proposal
========

Size and shape
--------------

- **Files:** at most 1408 lines.  Large modules are split by topic into private
  submodules (for example ``odin/writers/html_*.odin``, ``nodes/_base.py``); the public
  module re-exports what docutils exposes.
- **Lines:** 99 characters as the normal limit, 108 as the hard limit.  ruff enforces 108
  (``line-length = 108``); reviews hold the 99.
- **Procedures and functions:** short, with low cyclomatic complexity.  ruff enforces it
  for Python: ``max-complexity = 12`` (mccabe), ``max-branches = 14``,
  ``max-statements = 50`` and ``max-returns = 8``.  Odin code follows the same limits by
  review; long procedures are split into named steps.
- **Odin builds** use ``-vet -strict-style`` (``scripts/build_odin.sh``).

Style
-----

- **Odin:** data-oriented design (DOD 4): handles instead of pointers, struct-of-arrays
  storage for hot fields, arenas, interned strings, bounds checks on, ``@(rodata)`` tables
  and no shared mutable state.
- **Python:** idiomatic, typed, ``from __future__ import annotations``, and the public
  names, signatures and module paths of docutils where the shim implements docutils.
- **Generated code** says which script generated it and from what, and is never edited
  by hand: ``scripts/gen_*.py``.
- **Messages:** docodin's own tools report problems in the Elm style (DOD 5); the
  docutils path keeps docutils' exact texts.
- **Fix, do not defer.**  A problem found while working is fixed in the same piece of
  work, with a test, rather than left as a note.

Commits
-------

- One logical change per commit, small enough to review on its own.
- The message is a short, plain sentence that says what the commit changes ("Expand tabs
  in string2lines in one pass over plain-ASCII runs").  References to issues or pull
  requests only when needed.
- No trailers, no tool or assistant attributions, no company or product names in commit
  messages or metadata.
- Each commit builds and passes the tests it touches.

Alternatives
============

- **Mirror docutils' module sizes.**  Easier to diff against docutils at first, harder to
  work with later.  Splitting by topic, with re-exports, keeps both.
- **Enforce everything by tools.**  ruff covers Python; Odin has no equivalent linter for
  procedure size, so review covers it.

Compatibility and fidelity
==========================

The rules shape the code, not its behaviour.  Splitting a docutils module keeps its
public names and ``__module__`` paths (DOD 6).

Verification
============

- ``uv run ruff check`` with the configuration in ``pyproject.toml``.
- The largest files in the repository are below the limit (``wc -l``).

Outcome
=======

In force since the first commits of the docutils shim ("Enforce line length and
complexity limits with ruff").

References
==========

- ``pyproject.toml`` (``[tool.ruff]``), ``scripts/build_odin.sh``.
- The book's chapter on code rules.
