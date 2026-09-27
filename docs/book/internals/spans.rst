.. _spans:

=================================
Source spans and editor positions
=================================

docutils gives each node a line.  Editors need more: the exact range of the source that
a construct came from, and positions in the editor's coordinates.  docodin records both
without changing anything on the docutils path (DOD 13).

The line table
==============

Every parse records ``Tree.line_starts``: the byte offset of the start of each
``string2lines`` line of the input, followed by the length of the text.  It costs almost
nothing, because the line splitter finds the boundaries anyway.

.. code-block:: text

   line_count  :: proc(t: ^Tree) -> int                          // string2lines lines
   line_span   :: proc(t: ^Tree, line: int) -> (start, end: int) // text of a 1-based line
   offset_line :: proc(t: ^Tree, offset: int) -> int             // 1-based line of an offset
   split_lines_table :: proc(input: string, tab_width: int, allocator, table := true)
       -> (lines: []string, starts: []u32)

Spans
=====

With ``Parse_Flag.Spans`` (``Settings.spans``), the parser also records the **span** of
every node: the half-open byte range ``[start, end)`` of the input it was parsed from.

.. code-block:: text

   Span :: struct {start, end: u32}

   has_spans :: proc(t: ^Tree) -> bool
   node_span :: proc(t: ^Tree, n: Node) -> (start, end: int)  // 0, 0 without spans

The flag is off by default.  Without it the parser does no position work beyond the line
table; with it, the tree, the messages, ``line``, ``cur_line`` and the wire format are
exactly the same.  The C ABI does not carry spans.  Spans cost about 10 % of parse time.

The rules
---------

The rules are stated in full in ``odin/rst/nodes.odin``:

- A span runs from the construct's first byte (its marker, or its text) to the end of
  its last non-blank line, without trailing white space or the line break.  The
  indentation before the first byte is outside, that of later lines inside.
- A directive, comment, target, footnote, citation or substitution definition spans its
  whole block from ``..``.  A section title spans its adornment lines, its ``Title`` the
  title text.  A list item starts at its bullet or enumerator, a field at ``:name:``;
  lists span their items.
- Inline nodes span their markup from the start-string to the end-string, roles and the
  trailing ``_`` included; ``Text`` spans its characters.
- In tables, an ``Entry`` spans its cell's text from the first to the last non-blank
  line, and the nodes parsed from a cell are located in the cell.  Entries of one row, and
  rows with cells spanning several rows, may overlap.
- A ``System_Message`` spans the line it reports; it need not lie inside its parent.
- Otherwise spans nest: a child lies inside its parent, and siblings follow each other
  without overlapping.

How positions are recovered
---------------------------

The parser works on transformed lines, so positions have to be mapped back:

- The lines of ``string2lines`` are views of the input, except those whose tabs were
  expanded, and every block the state machines cut out is a view of those lines.  So a
  string's input offset follows from its address.
- The rewritten lines, and table cell lines (copies of a column range of the table's
  lines), are registered as **pieces** that map back to the input.  An offset inside a
  tab expansion maps to the end of the tab.
- Inline text joined from several lines is mapped through those lines; ``escape2null``
  keeps offsets.
- Nodes built from lines that ``include`` inserted are not in the input.  They get an
  empty span at the end of the inserting directive.

Recording is linear in the input.

Editor positions
================

The Language Server Protocol counts lines at ``\n``, ``\r\n`` and ``\r`` (not at the other
``str.splitlines()`` boundaries that ``string2lines`` honours) and columns in UTF-16 code
units by default.  ``rst.Line_Index`` converts between byte offsets and those positions,
like ruff's ``LineIndex``, with an ASCII fast path:

.. code-block:: text

   Position_Encoding :: enum u8 {UTF16, UTF8, UTF32}

   line_index_make    :: proc(text: string, encoding := .UTF16, allocator := ...) -> Line_Index
   line_index_destroy :: proc(idx: ^Line_Index, allocator := ...)
   line_col           :: proc(idx: ^Line_Index, offset: int) -> (line, col: int) // 0-based
   line_col_offset    :: proc(idx: ^Line_Index, line, col: int) -> int
   line_end           :: proc(idx: ^Line_Index, line: int) -> int

``line_col`` clamps an offset past the end to the end of the text, and counts an offset
inside a UTF-8 sequence from the start of its character.  ``line_col_offset`` clamps a
column past the end of a line to the end of the line (before its break), a line past the
last one to the end of the text, and a column inside a surrogate pair to the start of the
character.

Verification
============

- A hash over every field of every node (kind, lines, numbers, links, ``text``, ``raw``,
  ``name``, directive and phrase data) is equal with spans on and off, and equal to the
  hash of the previous release, on a 20.9 MB corpus (docutils' ``docs/**/*.rst``
  repeated) and 30,000 generated documents, under several settings.
- The same documents are checked for the invariants: every span lies within the text and
  nests as above, ``Text`` and inline markup spans reproduce the node's text, and the
  first line of a block's span is its ``line`` (except where docutils' line is known to
  be off).
- ``odin test odin/tests`` has the unit tests (``spans_test.odin``).
