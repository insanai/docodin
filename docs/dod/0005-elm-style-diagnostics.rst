==============================================================================
DOD 5: Elm-Style Diagnostics for docodin's Own Tools
==============================================================================

:Authors: Vikrant Rathore
:State: committed
:Created: 2026-09-27
:Discussion:
:Labels: tooling, editor, compatibility

.. contents:: Contents
   :local:
   :depth: 1

Summary
=======

docodin's own commands explain problems the way the Elm compiler does: a titled report
with the source excerpt, markers under the offending text, the message in plain words,
and a hint on how to fix it.  The docutils path is not affected: the shim, the native
pipeline and ``docodin-lsp`` keep docutils' exact message texts, and the tools offer
docutils' one-line format with ``--error-format=docutils``.

Background
==========

docutils reports problems as one line:

.. code-block:: text

   guide.rst:12: (WARNING/2) Inline emphasis start-string without end-string.

The line tells an expert what is wrong, but not where on the line, and not what to do.
Newcomers to reStructuredText meet the same handful of problems again and again: title
underlines that are too short, missing blank lines, unclosed inline markup, ``::``
without a literal block.  A checker that runs in milliseconds can afford to explain them.

Proposal
========

Report format
-------------

.. code-block:: text

   -- UNCLOSED EMPHASIS ----------------------------------------- guide.rst:12:6

   Inline emphasis start-string without end-string.

   12| Some *emphasis without an end.
            ^
   Hint: Close the emphasis with a matching `*`, or write `\*` for a literal
   asterisk.

- **The header** gives a title in capitals and the position (file, line and, where known,
  column), padded to 80 columns.
- **The message** is docutils' own text, unchanged, so that it can be searched for.
- **The excerpt** shows up to six source lines with line numbers, and markers under the
  offending text.  The parse tree records the position of problematic inline markup, so
  the marker points at the start-string, not just at the line.
- **The hint** says how to fix the problem.  Some hints depend on the message.
- **Colour** follows ``--color=auto|always|never``; ``auto`` colours only a terminal, and
  respects ``NO_COLOR`` and ``TERM=dumb``.

Where it is used
----------------

- ``docodin-check`` and ``docodin check``, for parser messages (``odin/check``: the checker
  core, the titles and hints in ``hints.odin``, the rendering in ``diagnostics.odin``).
- The ``docodin`` command's usage errors: an unknown option, an invalid value, a missing
  file each get a titled report with a hint, for example "INVALID SETTING" or
  "MISSING SOURCE".
- The ``docodin`` command's report when a document needs a Python library and no Python
  with docodin is available ("NEEDS PYTHON", DOD 9).
- ``docodin-lsp``: the diagnostic's ``code`` is the Elm title, the hint is part of the
  message, and mechanical hints come with a quick fix (DOD 14).

The titles
----------

The checker has a title and a hint for each parser message, among them: UNCLOSED
EMPHASIS, UNCLOSED STRONG EMPHASIS, UNCLOSED INLINE LITERAL, UNCLOSED INTERPRETED TEXT,
UNCLOSED INLINE TARGET, UNCLOSED SUBSTITUTION REFERENCE, TITLE UNDERLINE TOO SHORT,
TITLE OVERLINE TOO SHORT, TITLE OVERLINE MISMATCH, INCOMPLETE SECTION TITLE, MISSING
TITLE UNDERLINE, INCONSISTENT TITLE LEVEL, SECTION LEVEL SKIPPED, UNEXPECTED SECTION
TITLE, UNEXPECTED TRANSITION, INVALID TITLE OR TRANSITION, POSSIBLE TITLE, MISSING BLANK
LINE, UNEXPECTED INDENTATION, MISSING LITERAL BLOCK, INCONSISTENT QUOTED LITERAL BLOCK,
MALFORMED TABLE, MALFORMED HYPERLINK TARGET, MALFORMED SUBSTITUTION DEFINITION, EMPTY
FOOTNOTE, EMPTY CITATION, ENUMERATED LIST START, MULTIPLE ROLES, ROLE ON A REFERENCE,
INVALID OPTION, LINE TOO LONG and NESTING TOO DEEP.  Messages without a specific title
get their level (INFO, WARNING, ERROR, SEVERE).

Alternatives
============

- **docutils' format only.**  Precise but terse, and it gives no column.  It stays
  available for scripts and for comparison with docutils.
- **Rewrite docutils' message texts.**  Rejected: tools, tests and people search for
  those texts.  The hint is added; the message stays.

Compatibility and fidelity
==========================

The Elm format is a presentation of the same messages.  Everything on the docutils path
(the shim, the native publisher's warning stream, Sphinx) keeps docutils' one-line
format and texts.  ``tests/lint_differential.py`` compares the checker's messages in
docutils' format with docutils' parser messages.

Verification
============

- ``tests/test_checker.py`` for the report format, levels and exit status.
- ``tests/lint_differential.py`` against docutils on generated documents.

Outcome
=======

Implemented in docodin 0.1.0 ("Share the checker core in odin/check and report
Elm-style diagnostics"), and extended to the language server in 0.2.0.

References
==========

- ``odin/check``, ``cmd/docodin-check``, ``cmd/docodin/cli.odin``.
- The book's chapter on the checker and diagnostics.
