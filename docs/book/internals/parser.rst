.. _parser:

==================
The native parser
==================

``odin/rst`` parses reStructuredText exactly as docutils 0.22.4's parser does: the same
tree, the same system messages in the same order, the same ``source`` and ``line`` on
every node (DOD 3).  This chapter describes how it is built, from the input lines to the
inline markup, and the places where exact fidelity takes care.

From text to lines
==================

docutils does not parse the source text; it parses the output of ``string2lines``: the
text split at every ``str.splitlines()`` boundary, tabs expanded to tab stops of
``tab_width`` columns (8 by default), vertical tabs and form feeds turned into spaces,
and trailing white space removed.  ``split_lines`` in ``source.odin`` produces the same
lines:

- Lines without tabs and other rewritten characters are **views of the input**; only
  lines that change are copied, from a pool.
- Line boundaries are found with **SIMD** scanning (``scan.odin``): 16-byte
  ``core:simd`` blocks are tested for the bytes that can start a boundary (``\n``,
  ``\r``, ``\x1c`` to ``\x1e``, and the lead bytes of U+0085, U+2028 and U+2029), and
  only blocks that contain one are examined byte by byte.  On a 21 MB corpus this runs
  at about 1 GB/s.
- **Tab expansion** runs in one pass over plain-ASCII runs; tab-indented documents are
  2.7 to 5 times faster than in 0.1.0.  The expansion is tested against Python's
  ``str.expandtabs`` semantics.
- Every parse also records the **line table**: the byte offset where each line starts in
  the input (:doc:`spans`).

``parse_text`` is the entry point; ``Parse_Flags`` select docutils' parser settings
(``Match_Titles``, ``Character_Level_Inline_Markup``, ``Pep_References``,
``Rfc_References``, ``Trim_Footnote_Reference_Space``, ``Rfc2822``), whether the input
is already a list of lines (``Raw_Lines``, for ``StringList`` input from Python), and
whether to record source spans (``Spans``).

The state machine
=================

``statemachine.odin`` follows docutils' ``StateMachine`` and ``StateMachineWS``.  The
input is a list of lines with an offset; states try their transitions against the
current line; indented blocks are cut out (``get_indented``, ``get_known_indented``,
``get_first_known_indented``) and parsed by **nested state machines**, exactly where
docutils nests them.  The states live in:

``body.odin``
   ``Body`` and its transitions: paragraphs, section titles and transitions, block
   quotes with attributions, literal blocks, doctest blocks, line blocks.
``lists.odin``
   bullet, enumerated, definition, field and option lists, with docutils' rules for
   continuing a list across blank lines (same bullet, next ordinal, same style and
   format).
``explicit.odin``
   explicit markup: footnotes, citations, hyperlink targets, substitution definitions,
   comments and directive blocks (the directive's name, arguments, options and content;
   the directive itself is run by the host).
``tables.odin``
   grid and simple tables, with docutils' table parsers and their messages.
``inline.odin``
   the inliner.

The parser keeps what docutils keeps: the outermost state machine's line for the
reporter (frozen inside list-like constructs), the cursor that ``next_line``,
``previous_line`` and ``goto_line`` move, and ``document.current_line``, recorded on the
nodes where docutils attaches them (``cur_line``).  Title styles are **not** resolved in
the parser: it emits flat section-title events, and the host (``builder.py``,
``odin/reader``, ``odin/check``) nests sections by the order in which styles first
appear, as docutils does.

``include`` is handled where docutils handles it.  When the parser meets an ``include``
directive, its include hook lets the host run the directive dry (resolve the path, read
and decode the file, apply the options); the parser inserts the lines after the directive
block, with docutils' padding lines, into the input of the state machine that runs the
directive (``insert_input``), and parses them there.

Inline markup
=============

reStructuredText's inline markup is defined by regular expressions in docutils: a
leftmost match over many alternatives, with start-string and end-string rules based on
Unicode punctuation categories, a greedy ``simplename`` with backtracking, and
standalone URIs and e-mail addresses.  The inliner reproduces those semantics with
hand-written matchers (``patterns.odin``) and three ideas:

**Candidates.**  Inline markup can only start at a few bytes: ``*``, `````, ``_``,
``|``, ``[`` and ``:``.  ``next_inline_special`` finds the next one with a 16-byte SIMD
classifier, so plain text is skipped a block at a time.  The ``name_`` reference
alternative is tried only at the start of a word chain that reaches a ``_``
(``chain_start``), and standalone URIs and e-mail addresses only before a ``:`` or an
``@`` (``next_uri_anchor``): an absolute URI needs a colon and an address an at sign.

**Memo tables.**  Some of docutils' patterns backtrack, which makes certain inputs
quadratic.  The inliner records where a search already failed (``no_end``,
``name_fail``, ``role_fail``, ``email_fail``) so the result is the same and the time is
linear.  In 0.2.0 one remaining quadratic case was removed: positioning problematic
inline markup rescanned the text for every error (a 600 KB line of ``|x`` took minutes;
it now takes 27 ms).

**Views.**  Paragraph text joined from several lines is a view of the input when the
lines are contiguous and separated by ``\n``; ``escape2null`` keeps offsets, so inline
positions map back to the source.

Character classes
=================

docutils' patterns use Python's Unicode data: ``\w``, the punctuation classes around
inline markup, ``str.isspace``, and ``unicodedata`` normalisation.  The tables in
``unicode_tables.odin`` (and ``odin/doctree/unicode_tables.odin``) are generated from
CPython 3.14, Unicode 16, by ``scripts/gen_unicode_tables.py`` and
``scripts/gen_doctree_tables.py``; each file records the version it was generated from.

Messages
========

System messages are parse nodes (``System_Message``) created with docutils' texts, at the
levels and in the order docutils creates them.  Some messages precede the construct they
belong to, for example "Unexpected indentation." after a paragraph, or the note about an
enumerated list's start value; the parser creates them first as well.  The position of
problematic inline markup is recorded, which gives the checker and the language server
their columns.

Limits
======

Recursion is bounded by ``MAX_NESTING`` (160 nested state machines).  Where docutils
would fail with ``RecursionError``, docodin reports "Nesting too deep; content ignored."
and continues.  Bounds checks stay on in release builds.

Speed
=====

On a 20.9 MB corpus (docutils' documentation repeated), the 0.2.0 parser is 2.8 times
faster than 0.1.0's and executes 3.1 times fewer instructions; 0.1.0 already parsed the
largest document of docutils' documentation (124 KB) in 1.7 ms.  :doc:`performance` has
the measurements, and DOD 12 the profile that led to the changes.
