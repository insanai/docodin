==============================================================================
DOD 13: Source Spans and the Line Index
==============================================================================

:Authors: Vikrant Rathore
:State: committed
:Created: 2026-09-27
:Discussion:
:Labels: parser, editor

.. contents:: Contents
   :local:
   :depth: 1

Summary
=======

Every parse records a line table, and on request (``Parse_Flag.Spans``) the half-open
byte range of the input that each node was parsed from.  A line index converts byte
offsets to and from the line and column positions of the Language Server Protocol,
counting columns in UTF-16, UTF-8 or UTF-32.  With the flag off the parser does no
position work beyond the line table, and with it on the tree, the messages and the wire
format are exactly the same.

Background
==========

docutils gives each node a line and nothing else: no columns, no end positions.  That is
enough for warnings, but an editor needs ranges to underline, fold, highlight and jump.
DOD 12 found that positions, not speed, were what editors lacked.  They are hard to get
right because docutils parses the output of ``string2lines`` (tabs expanded, trailing
white space removed, some characters replaced), not the source, and because nested
parses work on blocks cut out of that output.

Proposal
========

The data
--------

.. code-block:: text

   Span :: struct {start, end: u32} // [start, end) in Tree.text

   has_spans   :: proc(t: ^Tree) -> bool
   node_span   :: proc(t: ^Tree, n: Node) -> (start, end: int)  // 0, 0 without spans
   line_count  :: proc(t: ^Tree) -> int                          // string2lines lines
   line_span   :: proc(t: ^Tree, line: int) -> (start, end: int) // text of a 1-based line
   offset_line :: proc(t: ^Tree, offset: int) -> int             // 1-based line of an offset

``Tree.line_starts`` holds the byte offset of the start of each ``string2lines`` line,
followed by the length of the text.  With ``Parse_Flag.Spans`` (``Settings.spans``),
``Tree.spans`` holds a span per node handle.  The C ABI does not carry spans.

The rules
---------

- A span runs from the construct's first byte (its marker or its text) to the end of its
  last non-blank line, without trailing white space or the line break.  The indentation
  before the first byte is outside, that of later lines inside.
- A directive, comment, target, footnote, citation or substitution definition spans its
  whole block from ``..``.  A section spans its adornment lines, and its title the title
  text.  A list item starts at its bullet or enumerator, a field at ``:name:``; lists
  span their items.
- Inline nodes span their markup from the start-string to the end-string, roles and the
  trailing ``_`` included; a Text node spans its characters.
- In tables, an entry spans its cell's text from the first to the last non-blank line,
  and the nodes parsed from a cell are located in the cell.  Entries of one row, and rows
  with cells spanning several rows, may overlap.
- A system message spans the line it reports; it need not lie inside its parent.
- Otherwise spans nest: a child lies inside its parent, and siblings follow each other
  without overlapping.

How it works
------------

The lines of ``string2lines`` are views of the input, except those whose tabs were
expanded, and every block the state machines cut out is a view of those lines.  So a
string's input offset follows from its address.  The rewritten lines, and the table cell
lines (copies of a column range of the table's lines), are registered as pieces that map
back to the input; an offset inside a tab expansion maps to the end of the tab.  Inline
text joined from several lines is mapped through those lines (``escape2null`` keeps
offsets).  Nodes built from lines that ``include`` inserted are not in the input: they get
an empty span at the end of the inserting directive.  Recording is linear in the size of
the input ("Record source spans in linear time").

Editor positions
----------------

LSP counts lines at ``\n``, ``\r\n`` and ``\r`` (not at the other ``str.splitlines``
boundaries that ``string2lines`` honours), and columns in UTF-16 code units by default.
``Line_Index`` converts, like ruff's ``LineIndex``, with an ASCII fast path:

.. code-block:: text

   Position_Encoding :: enum u8 {UTF16, UTF8, UTF32}

   line_index_make    :: proc(text: string, encoding := .UTF16, allocator := ...) -> Line_Index
   line_index_destroy :: proc(idx: ^Line_Index, allocator := ...)
   line_col           :: proc(idx: ^Line_Index, offset: int) -> (line, col: int) // 0-based
   line_col_offset    :: proc(idx: ^Line_Index, line, col: int) -> int

``line_col`` clamps an offset past the end to the end of the text, and counts an offset
inside a UTF-8 sequence from the start of its character.  ``line_col_offset`` clamps a
column past the end of a line to the end of the line (before its break), a line past the
last one to the end of the text, and a column inside a surrogate pair to the start of the
character.

Alternatives
============

- **Relative positions** (tree-sitter, rowan).  They make incremental reuse cheap, but
  every consumer would have to sum offsets; absolute spans behind a flag cost nothing
  when off (DOD 12).
- **Columns in expanded lines.**  Wrong for any line with a tab, and editors want source
  positions.

Compatibility and fidelity
==========================

Spans are off on the docutils path.  With spans on, a hash over every field of every node
is identical to the hash with spans off and to that of the previous release.

Verification
============

- The tree hash, with spans on and off, on the 20.9 MB corpus (docutils'
  ``docs/**/*.rst`` repeated) and 30,000 generated documents, under several settings.
- The same documents are checked for the invariants: every span lies within the text and
  nests as above, Text and inline markup spans reproduce the node's text, and the first
  line of a block's span is its ``line`` (except where docutils' line is known to be
  off).
- ``odin test odin/tests`` (``spans_test.odin``), including tab-indented terms and table
  rows.

Outcome
=======

Released in docodin 0.2.0.  Spans cost about 10 % of parse time when on.  The language
server (DOD 14) turns them on for the tree it keeps.

References
==========

- ``odin/rst/spans.odin``, ``odin/rst/line_index.odin``, ``odin/rst/nodes.odin``.
- DOD 12, DOD 14.
