.. _checker:

=============================
The checker and diagnostics
=============================

``docodin-check`` finds reStructuredText markup errors at native speed, without Python.
It reports exactly the messages that docutils' parser reports, and explains each one
with the source line, a marker and a hint.  On the documentation of docutils and Sphinx
together it needs 0.03 s on one thread, where docutils' parser needs 2.81 s.

Running the checker
===================

.. code-block:: console

   $ docodin-check docs/*.rst                           # Elm-style reports
   $ docodin-check --error-format=docutils docs/*.rst   # source:line: (LEVEL/n) text
   $ docodin-check --report=info --exit-status=warning README.rst
   $ cat notes.rst | docodin-check                      # standard input
   $ docodin-check -j 4 $(git ls-files '*.rst')

``docodin-check [options] [FILE ...]`` checks the files in parallel, one worker thread
per CPU unless ``-j`` says otherwise, and reads standard input when no file (or ``-``) is
given.  Reports go to standard error, in the order of the files.  In the Elm format a
summary line follows, for example ``Found 2 warnings in 1 file.``

Exit status
-----------

- 0 when no message reached the ``--exit-status`` level (default: error);
- 1 when one did, or when a file could not be read;
- 2 for an unknown option or an invalid value.

So ``--exit-status=warning`` makes warnings fail a CI job, and the default lets them
pass while still reporting them.

The report format
=================

.. code-block:: text

   -- TITLE UNDERLINE TOO SHORT --------------------------------------- guide.rst:5

   Title underline too short.

   4| Installation
   5| ======
      ^^^^^^
   Hint: Make the underline at least as long as the title text (12 characters).

- The header has a title and the position.  Inline markup problems carry the column as
  well (``guide.rst:7:11``).
- The first paragraph is docutils' message, word for word, so it can be searched for.
- The excerpt shows the lines involved with their numbers, and markers under the
  offending text.
- The hint says how to fix the problem.

``--color=auto`` (the default) colours the reports when standard error is a terminal,
unless ``NO_COLOR`` is set or ``TERM`` is ``dumb``; ``--color=always`` and
``--color=never`` decide explicitly.

``--error-format=docutils`` writes docutils' own format instead, one message with its
literal block per entry, as docutils writes them to its warning stream:

.. code-block:: text

   guide.rst:5: (WARNING/2) Title underline too short.

   Installation
   ======

What the checker checks
=======================

The checker runs the native parser with docutils' default parser settings (and the
settings given as options, see :doc:`../reference/cli`) and reports its messages.  That
includes the reStructuredText content of the standard directives: the body of an
``admonition``, ``note``, ``topic``, ``sidebar``, a ``table`` title, and so on is parsed as
the directive would parse it.

It does not run directives, roles or transforms, which need the document registry or
Python.  So it does not report an unknown directive or role, a missing include file, an
unknown target name or a duplicate target.  For those, publish the document with the
native ``docodin`` command, which runs the whole pipeline, or use ``docodin-lsp``, whose
diagnostics include them (:doc:`editors`).

``docodin check FILE...`` is the same check inside the native ``docodin`` command, one
file after another, with the options ``--error-format``, ``--color``, ``--report`` and
``--exit-status``.

The diagnostics
===============

Every parser message has a title and, where one helps, a hint.

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Title
     - docutils' message, and what the hint suggests
   * - UNCLOSED EMPHASIS
     - "Inline emphasis start-string without end-string."  Close it with ``*``, or
       escape the asterisk.
   * - UNCLOSED STRONG EMPHASIS
     - "Inline strong start-string without end-string."  Close it with ``**``.
   * - UNCLOSED INLINE LITERAL
     - "Inline literal start-string without end-string."  Close it with a double
       backquote.
   * - UNCLOSED INTERPRETED TEXT
     - "Inline interpreted text or phrase reference start-string without end-string."
       Close it with a backquote; inline code takes double backquotes.
   * - UNCLOSED SUBSTITUTION REFERENCE
     - Close it with ``|``, or escape the bar.
   * - UNCLOSED INLINE TARGET
     - Close it with a backquote, as in ``_`target text```.
   * - MULTIPLE ROLES
     - "Multiple roles in interpreted text."  Give the text one role.
   * - ROLE ON A REFERENCE
     - "Mismatch: both interpreted text role ... and reference suffix."  Remove the role
       or the trailing ``_``.
   * - MISSING BLANK LINE
     - "... ends without a blank line; unexpected unindent.", "Line block ends without a
       blank line.", "Blank line required after table."  Add the blank line, or indent
       to continue.
   * - UNEXPECTED INDENTATION
     - "Unexpected indentation."  Remove the indentation, or add a blank line to make a
       block quote.
   * - MISSING LITERAL BLOCK
     - "Literal block expected; none found."  Add the literal block, or end the paragraph
       with a single ``:``.
   * - INCONSISTENT QUOTED LITERAL BLOCK
     - "Inconsistent literal block quoting."  Start every line with the same punctuation.
   * - TITLE UNDERLINE TOO SHORT
     - "Title underline too short."  The hint gives the title's width.
   * - TITLE OVERLINE TOO SHORT
     - "Title overline too short."
   * - TITLE OVERLINE MISMATCH
     - "Title overline & underline mismatch."  Use the same character and length.
   * - MISSING TITLE UNDERLINE
     - "Missing matching underline for section title overline."
   * - INCOMPLETE SECTION TITLE
     - "Incomplete section title."
   * - UNEXPECTED TRANSITION, UNEXPECTED SECTION TITLE
     - "Unexpected section title or transition." and "Unexpected section title."  Sections
       cannot be nested in lists, block quotes or directives.
   * - INVALID TITLE OR TRANSITION
     - "Invalid section title or transition marker."
   * - SECTION LEVEL SKIPPED
     - "Inconsistent title style: skip from level ... to ...."  Use an established level
       or the next new one.
   * - INCONSISTENT TITLE LEVEL
     - "Title level inconsistent:"  Use the style of an established level.
   * - POSSIBLE TITLE
     - "Possible title underline, too short for the title." and "Possible incomplete
       section title."
   * - POSSIBLE TITLE OR TRANSITION
     - "Unexpected possible title overline or transition."
   * - MALFORMED TABLE
     - "Malformed table."  Check the column boundaries and borders.
   * - ENUMERATED LIST START
     - "Enumerated list start value not ordinal-1."
   * - INVALID OPTION
     - "Invalid option list marker."
   * - MALFORMED HYPERLINK TARGET
     - "malformed hyperlink target."
   * - MALFORMED SUBSTITUTION DEFINITION
     - "malformed substitution definition."
   * - EMPTY FOOTNOTE, EMPTY CITATION
     - "Footnote content expected." and "Citation content expected."
   * - NESTING TOO DEEP
     - "Nesting too deep; content ignored."  docodin reports this where docutils would
       fail with a ``RecursionError``.
   * - LINE TOO LONG
     - "... exceeds the line-length-limit."  Shorten the line or raise
       ``--line-length-limit``.

Other messages are shown with their level as the title (INFO, WARNING, ERROR, SEVERE).

Using the checker in CI and hooks
=================================

A CI step that fails on warnings:

.. code-block:: console

   $ bin/docodin-check --exit-status=warning --color=never $(git ls-files '*.rst')

A local pre-commit hook:

.. code-block:: yaml

   repos:
     - repo: local
       hooks:
         - id: docodin-check
           name: docodin-check
           entry: bin/docodin-check --exit-status=warning
           language: system
           types: [rst]
