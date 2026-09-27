==============================================================================
DOD 12: Research for 0.2.0: Parser Speed, Positions and Editors
==============================================================================

:Authors: Vikrant Rathore
:State: committed
:Created: 2026-09-27
:Updated: 2026-09-27
:Discussion:
:Labels: parser, performance, editor

.. contents:: Contents
   :local:
   :depth: 2

Summary
=======

This record is the research behind docodin 0.2.0: what docodin should take from
tree-sitter, ruff, rust-analyzer and the fast Markdown parsers, measured against where
the native parser spends its time.  It was written as a design memo before the work
started, and it is kept here in full.  Its conclusions:

- The parser was already fast enough for an editor: the largest real document in
  docutils' documentation (``ref/rst/restructuredtext.rst``, 124 KB) parsed in 1.7 ms,
  and the 60 files of that documentation checked in 10 to 20 ms.  rust-analyzer, ruff
  and ty all reparse the whole file on every edit.  docodin should do the same first,
  and add incremental reuse only where measurements demand it.
- What editors lacked was not speed but **positions**.  The parse tree had a line per
  node, but no byte ranges, no end positions and no columns.  A lossless position layer
  is the prerequisite for semantic tokens, folding, go to definition, hover, code
  actions, and any later incremental reuse.
- Profiling showed that about 60 % of parse time was in the inliner, most of it in one
  waste: every word start ran the full ``simplename`` match and the standalone URI and
  e-mail match.  Two exact pre-filters and a SIMD line splitter, tried in a scratch copy,
  cut the parse of a 20.9 MB corpus from 386 ms to 225 ms (1.7 times; instructions from
  3.95 G to 2.47 G) with an identical parse tree.
- reStructuredText's block structure is anchored at column 0 and separated by blank
  lines, and the parser carries almost no state between top-level constructs.  That makes
  a tree-sitter-style "reparse until the state converges, then splice" strategy much
  simpler for reStructuredText than for Python, provided the constructs that continue
  across blank lines are handled.
- A native language server, ``docodin-lsp``, modelled on ruff's server, should be the
  main feature of 0.2.0.  It uses the Elm-style diagnostics that ``odin/check`` already
  has, and it gives editors docutils' exact structure where tree-sitter-rst is known to
  be wrong.

The constraint did not move: **the docutils path (the shim, ``docodin_parse`` and the
wire format it feeds, the native pipeline's outputs) stays byte for byte identical to
docutils 0.22.4.**  Every item is either invisible to that path, or an internal speed-up
proven identical by the differential suites plus a parse-tree hash comparison.

The *Outcome* section at the end says what was built.

Background: what others do
==========================

tree-sitter
-----------

- **Relative positions.**  Each subtree stores its padding and size as bytes, row and
  column, and absolute positions are summed while walking, so an edit touches only the
  nodes on its path.  Small leaves live inline in the 8-byte handle, and children sit
  directly before their parent's data
  (`subtree.h <https://github.com/tree-sitter/tree-sitter/blob/master/lib/src/subtree.h>`__).
- **Edits.**  ``ts_tree_edit`` marks the nodes on the path as changed.  A child counts as
  untouched only if its end plus its ``lookahead_bytes`` lies before the edit, where
  ``lookahead_bytes`` is how far the lexer peeked past the token.  A token whose scanner
  asked for its column is invalidated when the column shifts
  (`subtree.c <https://github.com/tree-sitter/tree-sitter/blob/master/lib/src/subtree.c>`__).
- **Reuse.**  ``ReusableNode`` walks the old tree in step with the parser.  A node is
  reused only if it starts at the current byte, is unchanged, is not an error and not
  *fragile* (built under a GLR conflict), the external scanner's state before it equals
  the current one byte for byte, its first leaf's lex mode matches, and the GLR stack
  has one version
  (`parser.c <https://github.com/tree-sitter/tree-sitter/blob/master/lib/src/parser.c>`__).
  The algorithm descends from Wagner and Graham, TOPLAS 1998
  (`paper <https://harmonia.cs.berkeley.edu/papers/twagner-parsing.pdf>`__).
  ``ts_tree_get_changed_ranges`` diffs the old and new trees for re-highlighting
  (`get_changed_ranges.c <https://github.com/tree-sitter/tree-sitter/blob/master/lib/src/get_changed_ranges.c>`__).
- **Error recovery** is cost-based: skipping a character costs 1, skipping a tree 100, a
  missing tree 110, recovery 500.  The parser tries, in order, inserting one missing
  token, popping back to an earlier state, and skipping into an error node, with at most
  6 stack versions
  (`error_costs.h <https://github.com/tree-sitter/tree-sitter/blob/master/lib/src/error_costs.h>`__).
- **External scanners** must serialise their entire state, at most 1024 bytes, after
  every external token; it is restored before the next scan
  (`documentation <https://github.com/tree-sitter/tree-sitter/blob/master/docs/src/creating-parsers/4-external-scanners.md>`__).
  tree-sitter-python's state is a stack of ``uint16`` indents, a stack of string
  delimiters and a flag.  It emits INDENT when a line is deeper than the top of the
  stack, one zero-width DEDENT per call while it is shallower, none inside brackets, and
  counts a tab as a flat 8
  (`scanner.c <https://github.com/tree-sitter/tree-sitter-python/blob/master/src/scanner.c>`__).
- **Queries.**  ``highlights.scm``, ``locals.scm`` and ``injections.scm`` are pattern
  files; the host evaluates predicates such as ``#match?`` and ``#any-of?``.  Injections
  re-parse embedded ranges as another language.  tree-sitter-highlight itself re-parses
  from scratch
  (`syntax highlighting <https://github.com/tree-sitter/tree-sitter/blob/master/docs/src/3-syntax-highlighting.md>`__,
  `highlight.rs <https://github.com/tree-sitter/tree-sitter/blob/master/crates/highlight/src/highlight.rs>`__).

tree-sitter-rst
---------------

`stsewd/tree-sitter-rst <https://github.com/stsewd/tree-sitter-rst>`__ is a hand-written
scanner of about 1600 lines behind a small grammar.  45 of its tokens are external, and
each inline construct (``*emphasis*`` from start to end) is one opaque token.  Where it
differs from docutils:

- **Sections are flat**: only titles, "to avoid guessing the level of subtitles".
  Underline length is not checked
  (`issue 43 <https://github.com/stsewd/tree-sitter-rst/issues/43>`__).
- **Not implemented**: tables, option lists, blank lines between list items
  (`issue 29 <https://github.com/stsewd/tree-sitter-rst/issues/29>`__) and nested line
  blocks.
- **Lists**: the enumerator sequence and style are not checked.
- **Directive content** is opaque.  Editors re-inject it as reStructuredText by
  directive name, which misses nested directives
  (`issue 51 <https://github.com/stsewd/tree-sitter-rst/issues/51>`__,
  `issue 52 <https://github.com/stsewd/tree-sitter-rst/issues/52>`__).
- **Blank lines are required** after every block: a missing one before a title swallows
  the title (`issue 47 <https://github.com/stsewd/tree-sitter-rst/issues/47>`__), and an
  incomplete definition list eats the rest of the file
  (`issue 48 <https://github.com/stsewd/tree-sitter-rst/issues/48>`__).
- **Incremental parsing**: the only serialised state is the indent stack, and
  serialisation was broken until
  `pull request 70 <https://github.com/stsewd/tree-sitter-rst/pull/70>`__ (June 2026),
  which explains issues 44 and 64.  Heavy multi-line peeking gives large
  ``lookahead_bytes``, so edits invalidate far.  Tabs count a flat 8 instead of tab
  stops.
- **Queries** are not shipped.  Neovim, Zed and Helix each carry their own.

Lesson: an approximate grammar can colour reStructuredText, but it cannot give an editor
docutils' structure.  That structure should come from the exact parser, over the
Language Server Protocol.

ruff's parser and ruff server
-----------------------------

- **Parser.**  A hand-written recursive descent parser replaced LALRPOP in ruff 0.4.0.
  It is more than twice as fast (``large/dataset.py``: 63.6 to 26.6 ms) and made linting
  and formatting 20 to 40 % faster
  (`announcement <https://astral.sh/blog/ruff-v0.4.0>`__,
  `pull request 10036 <https://github.com/astral-sh/ruff/pull/10036>`__).
- **Lexer.**  Lazy, and able to re-lex a token in a new context (28 % faster,
  `pull request 11457 <https://github.com/astral-sh/ruff/pull/11457>`__).
  ``checkpoint`` and ``rewind`` save the lexer state and error count for speculative
  parsing; an unclosed bracket is recovered by re-lexing the last newline as a logical
  one (`pull request 11845 <https://github.com/astral-sh/ruff/pull/11845>`__).
- **Tokens.**  ``Tokens`` is a lossless vector of ``Token{kind, range, flags}`` that keeps
  comments and non-logical newlines.  Comment ranges and the indentation style are
  derived from it.
- **Positions.**  Offsets are ``TextSize(u32)`` UTF-8 byte offsets, paired into
  ``TextRange``.  ``LineIndex`` keeps line starts, with an ASCII fast path, and
  binary-searches them to convert an offset to UTF-8, UTF-16 or UTF-32 columns, as LSP
  requires.
- **Errors never stop the parse.**  The result carries the syntax tree, the tokens and
  the errors.  A 32-bit recovery-context set decides whether an unexpected token ends the
  current list or is skipped with an error.  An error at the same offset as the previous
  one is dropped.
- **AST.**  Nodes are boxed.  A ``u32`` node index, assigned after parsing, lets ty keep
  references to nodes without holding whole ASTs, which had cost "multiple GB"
  (`issue 15621 <https://github.com/astral-sh/ruff/issues/15621>`__).  docodin's
  struct-of-arrays tree with ``u32`` handles already has this.
- **ruff server.**  A main loop fed by a bounded channel; notifications run
  synchronously, and diagnostics, hover and code actions on a thread pool over
  copy-on-write snapshots.  Synchronisation is incremental: each change is converted
  through ``LineIndex`` and applied with ``replace_range``, and the index is rebuilt.
  Diagnostics are pulled, or pushed for older clients.  **Every lint re-lexes and
  reparses the whole file.**  Quick fixes travel in the diagnostic's ``data``.
- **ty** puts its incrementality in salsa, but its parse query is not compared for
  equality: every edit reparses the file (`ty <https://astral.sh/blog/ty>`__).

Zed
---

Zed reparses with tree-sitter on every edit.  ``Buffer::reparse`` gives the parse 1 ms
synchronously, then finishes it in the background and parses again if the buffer changed
meanwhile.  Injection layers live in a copy-on-write sum tree, and old trees are shifted
with ``tree.edit`` so that stale highlights stay aligned until the new parse lands
(`syntax-aware editing <https://zed.dev/blog/syntax-aware-editing>`__).  Each language
feature (highlights, brackets, outline, indents, injections, text objects) is a query
file.  The language server is a separate process that the extension launches with
``language_server_command``.  The pattern is tree-sitter for instant, approximate local
structure, and the server for exact answers.

rust-analyzer and rowan
-----------------------

- **Parser.**  Hand-written recursive descent that emits start, finish, token and error
  events into a separate builder.  "Parsing never fails."
- **Green nodes** are immutable, store only widths, give children relative offsets, and
  are deduplicated, which saves 17 % of their memory.  **Red nodes** are created lazily
  with a parent pointer and an absolute offset.
- **Incremental reparsing** re-lexes a single token if it keeps its kind, else reparses
  the nearest balanced ``{}`` block, else the whole file.  The team's verdict is that
  "incremental reparsing doesn't actually matter much for IDE use-cases", and the block
  heuristic was never enabled.
- **salsa** memoises queries with their dependencies; *backdating* stops invalidation
  when a recomputed value is unchanged, and *durability* levels skip revalidating inputs
  that rarely change.  "Three architectures for a responsive IDE" names per-file
  map-reduce indexing as the simplest design that scales
  (`post <https://rust-analyzer.github.io/blog/2020/07/20/three-architectures-for-responsive-ide.html>`__).
  The resilient LL parsing tutorial adds two rules: every loop iteration consumes input,
  and recovery sets decide where an error ends
  (`tutorial <https://matklad.github.io/2023/05/21/resilient-ll-parsing-tutorial.html>`__).

Fast markup parsers and SIMD scanning
-------------------------------------

- **pulldown-cmark** parses in two passes.  The first builds the block structure as a
  vector tree with index links (slot 0 is a dummy and the index type is non-zero, the
  same layout as docodin's); paragraph content stays a chain of "maybe inline" items.
  The second resolves inlines lazily, one block at a time.  Every item carries start and
  end offsets.  CommonMark's ``openers_bottom`` rule keeps emphasis matching linear.
  Its SIMD scanner classifies 16 bytes at a time against the special-byte set with two
  nibble lookups (``pshufb``), walks the resulting bit mask with ``trailing_zeros``, and
  finds newlines with ``memchr2``.
- **md4c** uses push callbacks and no AST.  Per block it first collects "all potentially
  meaningful marks" into a compact buffer: 0.365 s against cmark's 0.706 s, with 41
  allocations against 3.9 million.  cmark checks linear time with pathological tests
  under a timeout.
- **djot** is designed for linear time "with no backtracking": references never depend
  on later definitions, and the syntax needs no Unicode classes.  reStructuredText has
  none of these properties, hence docodin's memo tables.
- **simdjson** classifies 64-byte blocks without branches: two nibble tables classify
  each byte, quoted ranges come from a carry-less multiply, and ``tzcnt`` and ``blsr``
  extract the indices (`Langdale and Lemire <https://arxiv.org/pdf/1902.08318>`__).
  UTF-8 can be validated in under one instruction per byte
  (`Keiser and Lemire <https://arxiv.org/abs/2010.03090>`__).
- **memchr** splats the needle, compares, extracts a mask and counts trailing zeros, 64
  bytes per iteration.  Its SWAR fallback is ``(x - 0x01...) & ~x & 0x80...``.
- **Odin's core:simd** covers all of this portably on NEON and SSE/AVX: ``#simd[N]T``
  vectors, ``lanes_eq``, ``lanes_lt``, ``lanes_ge``, ``select``, ``reduce_or``,
  ``reduce_min``, ``extract_msbs`` (a movemask), ``runtime_swizzle`` (``tbl`` or
  ``pshufb``, the nibble classifier) and ``count_trailing_zeros``.

reStructuredText editor tooling in 2026
---------------------------------------

- **esbonio** (v2.1.0) was the only reStructuredText language server with completion,
  hover, definition and symbols.  It is a pygls server whose features run in a "Sphinx
  agent" subprocess injected into the user's environment; its diagnostics are Sphinx's
  log warnings, collected after a build.  It has no semantic tokens, folding, references
  or rename.
- **Editors.**  VS Code: a TextMate grammar, esbonio, and rstcheck or doc8.  Zed:
  tree-sitter-rst and esbonio.  Neovim: nvim-treesitter (unstable tier, no folds) and
  esbonio.
- **Other tools.**  snooty-parser vendors docutils' parser and has a diagnostics-only
  server; rust-rst parses a subset with a PEG; rstcheck, restructuredtext-lint and doc8
  wrap docutils' messages; sphinx-lint is regex-based.
- **What nobody provided**: diagnostics as you type from the exact grammar without a
  Sphinx build, semantic tokens, folding, references and rename, hover for substitutions
  and footnotes, and completion of a document's own targets.  docodin had the grammar,
  the messages and the hints at about 1 ms per document; it lacked positions and a
  server.

Where the native parser spent its time
======================================

**Setup.**  Input: the 60 ``.rst`` files of docutils 0.22.4's ``docs/`` (1.39 MB),
concatenated and repeated 15 times: 20.9 MB and 630,975 lines.  Machine: Apple Silicon,
macOS 27.  Build: Odin dev-2026-09 with ``-o:speed``.  A harness calls ``rst.parse_text``
directly with a growing arena, best of 5.  Sampling at 1 ms on a ``-debug -o:speed``
build; about 3,080 samples fall in the parse.

.. list-table::
   :header-rows: 1
   :widths: 45 55

   * - Measure
     - Value
   * - ``parse_text``
     - 386 ms, 54 MB/s, 3.95 G instructions (189 per byte)
   * - of which ``split_lines``
     - 51 ms (408 MB/s)
   * - nodes
     - 815,866 (25.6 input bytes per node); ``size_of(Node_Data)`` = 96
   * - arena used
     - 242.6 MB (11.6 times the input); maximum RSS 158 MB
   * - ``docodin-check -j1``, whole run
     - 0.36 s, RSS 175 MB; UTF-8 validation 12 ms (1.7 GB/s)
   * - C ABI ``docodin_parse`` (parse and marshal)
     - 455 ms; wire 60.2 MB (2.9 times the input)
   * - ``marshal.loads`` of that wire
     - 164 ms
   * - wire tuple trees, 60 documents, Python heap
     - 9.1 MB, 6.5 times the input (docutils' own document trees: 62.3 MB, 44.8 times)
   * - largest real document (124 KB ``restructuredtext.rst``)
     - 1.7 ms parse

Self time by function, as a share of the parse samples:

.. list-table::
   :header-rows: 1
   :widths: 34 12 54

   * - Hotspot
     - Share
     - Cause
   * - ``parse_inline`` (with ``search_initial`` inlined)
     - 16.8 %
     - a byte-at-a-time scan; every word start is a candidate
   * - ``simplename_ends`` and its ``memmove``
     - 19.3 %
     - the ``name_`` reference alternative runs at every word start; ``Name_Ends`` is a
       520-byte struct returned by value and reversed
   * - ``uri_whole_at``, ``implicit_inline``, ``email_at``
     - 18.6 %
     - the standalone URI and e-mail search runs at every word start of every text run
   * - ``split_lines``, ``normalize_line``, ``rstrip``
     - 13.9 %
     - a scalar ``switch`` per byte, a second pass counting newlines, a third looking for
       tabs
   * - ``strings.join`` and ``memmove``
     - 4.0 %
     - ``join_lines`` copies paragraph lines that are contiguous in the source
   * - other copies in the inliner
     - about 5 %
     - ``Inliner`` and match structs passed by value, ``escape2null`` copies
   * - ``#soa`` node append
     - 2.4 %
     -
   * - block states
     - about 10 %
     - ``classify``, ``get_indented``, the body, explicit, list and table states

**Experiment** (a scratch copy, not committed).  Three exact changes:

1. ``search_uri`` returns at once when the run has neither ``:`` nor ``@``: an absolute
   URI needs ``:`` and an e-mail address needs ``@``.
2. ``match_reference`` scans the ASCII ``simplename`` chain first.  Without a ``_``
   directly after a word run there can be no reference, so it records ``name_fail``
   exactly as before and returns.  Non-ASCII input takes the old path.
3. ``split_lines``, ``estimate_line_count`` and ``normalize_line`` skip 16-byte blocks
   with ``core:simd`` (``lanes_eq`` on the lead bytes of line separators,
   ``reduce_min`` over ``select`` for the offset).

.. list-table::
   :header-rows: 1

   * - Variant
     - ``parse_text``
     - Throughput
     - Instructions
   * - 0.1.0
     - 386 ms
     - 54 MB/s
     - 3.95 G
   * - with the inliner pre-filters (1, 2)
     - 249 ms
     - 84 MB/s
     - not measured
   * - and SIMD line splitting (3)
     - 225 ms
     - 93 MB/s
     - 2.47 G

``split_lines`` alone went from 51 ms to 20 ms (1.05 GB/s).  An FNV hash over every
node's kind, line, current line, numbers, links, text, raw and name is identical in all
variants.  After the change, the profile was 37 % ``parse_inline`` self time (the
per-byte candidate loop), 6.7 % copies, 5.7 % ``implicit_inline``, 5.6 % ``split_lines``
and 4.6 % node append, so the next step was a pulldown-cmark-style candidate classifier
for the inliner.

How reStructuredText differs from Python and Markdown
=====================================================

- **Indentation is structural, not lexical.**  Python's INDENT and DEDENT are a token
  stream under a context-free grammar: a scanner with an indent stack suffices, and
  tree-sitter-python serialises just that stack.  In reStructuredText the meaning of an
  indented block depends on the line *before* it: a literal block after ``::``, a
  definition after a term line, an explicit markup body after ``..``, a field body after
  a field marker, a block quote (with an optional ``--`` attribution) after a blank
  line.  Blocks are cut out as line ranges (``get_indented``) and parsed recursively in
  nested state machines.  A scanner with an indent stack, which is tree-sitter-rst's
  whole state, cannot reproduce this; the tree-sitter-rst issues about lists, definition
  lists and literal blocks are this mismatch.
- **Tokens depend on block context.**  ``*`` at the start of a line is a bullet or
  emphasis.  ``1. Title`` followed by ``====`` is a title, not a list.  ``..`` is
  explicit markup or text.  A lossless token stream in ruff's sense is not meaningful
  before block parsing.  The lossless base layer for reStructuredText is the **line
  table**: offset, indentation, blank flag, tab flag.
- **Not context-free.**  Section levels come from the order in which title styles first
  appear; an enumerated list continues only while the ordinals are sequential and style
  and format match; anonymous references pair with anonymous targets in document order;
  auto-numbered footnotes and the ``make_id`` counters follow document order.
- **Inline markup is defined by regular expressions.**  Unlike CommonMark's delimiter
  stack, reStructuredText inline markup does not nest.  Recognition uses start-string
  prefix and end-string suffix character classes (Unicode punctuation categories), a
  greedy ``simplename`` with backtracking over its possible ends, and a leftmost match
  over many alternatives.  Linear time needs memo tables (``no_end``, ``name_fail``,
  ``role_fail``, ``email_fail``), not an openers stack.  What does carry over from
  Markdown is the **two-phase shape**, blocks first and then inlines per text block, and
  the SIMD candidate scan.
- **Positions need a mapping.**  docutils works on the output of ``string2lines``: tabs
  expanded to 8-column stops, vertical tabs and form feeds turned into spaces, trailing
  white space stripped, and Unicode line separators honoured.  Columns in expanded lines
  are not source columns.  Two facts help: ``split_lines`` already returns zero-copy
  slices of the input for lines without tabs (source offsets follow from the pointer),
  and ``escape2null`` preserves length (inline offsets map one to one onto the joined
  text block).

An incremental strategy for reStructuredText
============================================

Safe reparse boundaries
-----------------------

An **anchor** is a non-blank line at column 0 whose previous line is blank, or the first
line.  At an anchor between top-level constructs the root ``Body`` machine carries almost
no state: ``line_offset``, ``frozen_line`` (0 outside list-like constructs), ``cur_line``
(derived from the position) and ``inserted`` (include lines).  That is the equivalent of
tree-sitter's "external scanner state equal".  An anchor is a **boundary**, where the
previous construct cannot continue, unless:

- the previous top-level construct is **list-like**, because docutils looks past blank
  lines for its next item: bullet lists (same bullet), enumerated lists (next ordinal,
  same style and format), field and option lists, definition lists (a term at column 0
  after a blank line), and runs of explicit markup (consecutive footnotes, targets,
  directives, comments);
- the previous construct is a **simple table**, whose rows and borders may be separated
  by blank lines at column 0;
- the previous paragraph ends in ``::``, because the next column-0 block after the
  blank line may be a quoted literal block, or produce "Literal block expected; none
  found."

Local, with no special case: block quotes with attributions, indented literal blocks,
directive and field bodies (indented, so inside the window up to the next anchor),
section titles with or without overline, and transitions.

A construct also peeks ahead (``blank_finish``, title underlines, "Unexpected
indentation.").  The exact analogue of tree-sitter's ``lookahead_bytes`` is to record,
per top-level construct, the furthest line its state machine read.  A construct is
reusable only if that mark lies before the edit.

Non-local state: recompute, never patch
---------------------------------------

.. list-table::
   :header-rows: 1
   :widths: 30 36 34

   * - State
     - Where docodin keeps it
     - Strategy
   * - title style order, section levels, "Title level inconsistent"
     - the host (``builder.py``, ``odin/reader``, ``odin/check``); the parser emits flat
       section-title events
     - re-run the pass over titles after each parse
   * - enumerated list sequence
     - inside one list construct
     - covered by the list-like rule
   * - explicit and implicit targets, duplicates, id counters, message ids
     - the host's registry, in document order
     - rebuild per parse; linear and cheap
   * - anonymous references and targets
     - matched by order, document-wide
     - rebuild
   * - auto-numbered and symbol footnotes, citations, substitutions
     - the host and the transforms
     - rebuild
   * - ``include``
     - lines inserted into the state machine
     - the included file is an input dependency
   * - absolute ``line`` and ``cur_line``, directive offsets
     - the parse tree
     - shift by the change in lines on splice

Subtree reuse over the parse tree
---------------------------------

- **Contiguity.**  Nodes are appended in parse order, and nested parses and the inliner
  run inside their construct.  Each top-level construct is therefore a contiguous range
  of handles, plus ranges of ``phrases`` and ``directives``.  This is to be asserted in
  tests, not assumed.
- **Algorithm**, tree-sitter's reuse in reStructuredText's terms:

  1. Map the edit to lines, then walk back to the previous boundary whose construct's
     lookahead mark precedes the edit.  Take one more construct as margin: messages such
     as "Unexpected indentation." are created while parsing the next construct.
  2. Parse forward from there with ``input_offset`` set, so that lines come out absolute.
  3. After each completed top-level construct, check for convergence: if the current
     line equals an old boundary shifted by the change, lies past the edit, and the
     construct just finished is closed, stop.
  4. Splice: copy the old tail ranges with handles relocated, lines shifted, and string
     views rebased.

- **Alternative.**  A rowan-style "green block" layer with block-relative positions makes
  reuse zero-copy, but changes every consumer: the serialiser, ``builder.py``,
  ``odin/reader`` and ``odin/check``.  Absolute positions stay in the parse tree, and
  relocation belongs in the editor layer only.
- **When it pays.**  A full parse is about 11 µs per KB after the speed-ups (0.1.0: about
  19 µs).  Reuse matters only above about 1 MB per file, which is rare for
  reStructuredText.  That is the conclusion rust-analyzer and ruff reached too.

Proposal: the 0.2.0 work, ranked
================================

For every item, what must not change is the same: docutils' output, messages and line
numbers; node ``source`` and ``line``; the wire format that ``builder.py`` consumes
(unless a new flag asks for more); and the result of every differential suite.

.. list-table::
   :header-rows: 1
   :widths: 5 35 25 12 23

   * - #
     - Item
     - Benefit
     - Cost
     - Fidelity risk
   * - 1
     - inliner fast paths and SIMD scanning
     - 1.7 times measured, 2 to 2.5 times expected
     - small
     - low to medium, tested
   * - 2
     - lossless position layer
     - enables 3 and 5
     - medium
     - none (behind a flag)
   * - 3
     - ``docodin-lsp``
     - exact diagnostics and navigation in every editor
     - large
     - none (read-only)
   * - 4
     - lower peak memory
     - most of the 109 MB RSS gap (to confirm)
     - small to medium
     - none
   * - 5
     - incremental reparse API
     - only for files over about 1 MB
     - medium
     - none on the docutils path
   * - 6
     - line table first, ``dump --spans``, tree-sitter-rst as a consumer
     - tooling
     - small
     - none

1. Inliner fast paths and SIMD scanning
---------------------------------------

- **What.**  Land the three measured changes.  Replace ``search_initial``'s per-byte loop
  with a candidate scanner: a 16-byte ``core:simd`` classifier finds the next special
  byte, and the ``name_`` alternative is tried only at the start of a word chain that
  reaches a ``_``.  Add a whole-text pre-filter: text with no special byte and no ``:``
  or ``@`` becomes a single Text node.  Return ``Name_Ends`` through a pointer instead of
  by value.  In ``join_lines``, return the source slice when the lines are contiguous and
  separated by ``\n``.
- **Benefit.**  386 to 225 ms measured; the candidate scanner targets the remaining 37 %.
  The shim gains too: the native parse is about 85 % of ``docodin_parse``, and about 60 %
  of ``docodin_parse`` plus ``marshal.loads``.
- **Fidelity risk.**  When candidates are skipped, the leftmost-match semantics of
  docutils' ``initial`` pattern must still hold.  Risky cases are non-ASCII
  alphanumerics, ``\x00`` escapes and ``character_level_inline_markup``.
- **Verification.**  A parse-tree hash compared before and after on the corpus and the
  fuzz corpora; ``tests/fuzz_differential.py`` with a generator biased toward URIs,
  e-mail addresses, ``name_`` chains, non-ASCII words and escapes; docutils' suite
  natively and with ``DOCODIN_NATIVE=0``; a timed pathological suite in the style of
  cmark's (long ``a-b-c`` chains, 10\ :sup:`5` ``*``, 10\ :sup:`5` backquotes).

2. Lossless position layer
--------------------------

- **What.**  ``split_lines`` also produces a **line table**.  Under a new
  ``Parse_Flag.Spans``, an array parallel to the nodes holds source byte ranges: block
  nodes get the extent of their lines; inline nodes are mapped through their text
  block's line starts, which is exact because ``escape2null`` keeps lengths.  A
  ruff-style ``LineIndex`` converts offsets to UTF-8, UTF-16 or UTF-32 line and column
  pairs, with an ASCII fast path.
- **Cost.**  Medium.  The hard cases are nested parses, table cells, substitution
  definitions (dropped lines) and include insertion.
- **Fidelity risk.**  None with spans off.  Nothing on the docutils path reads the array.
- **Verification.**  The tree hash is equal with and without spans; fuzzed invariants:
  children lie inside their parents, siblings are ordered and disjoint, the source text
  of a span equals the text of escape-free Text nodes, and the first line of a span
  equals ``node.line`` wherever docutils sets one.

3. docodin-lsp, a native language server
----------------------------------------

- **Architecture**, modelled on ruff's server: JSON-RPC over standard input and output, a
  main loop that owns the session, incremental text synchronisation through the line
  index, a **full reparse** per change (1 to 2 ms), pull diagnostics with a push fallback.
- **Features.**  Diagnostics from the checker and the native reader's registry messages,
  with Elm titles and hints, and quick fixes carried in ``data``; document symbols;
  folding ranges; definition, references and rename for targets, footnotes, citations
  and substitutions; hover; semantic tokens; completion; later a cross-file index for
  ``:ref:`` and ``:doc:`` fed by a manifest that a docodin Sphinx extension writes, so
  the server never runs Python.
- **Cost.**  Large: three to five thousand lines of Odin.  Needs item 2.
- **Verification.**  Diagnostics equal ``docodin-check`` and docutils' messages;
  definitions checked against the ``refid`` of docutils' transformed tree; symbols
  compared with docutils' section tree; a latency budget of 10 ms from change to
  diagnostics on a 124 KB document.

4. Lower peak memory
--------------------

- **Facts.**  The arena used 11.6 times the input, and the node reserve (a tenth of the
  input length times 96 bytes) was 2.5 times what was used.  The wire (2.9 times the
  input) existed twice for a moment because ``ctypes.string_at`` copies it, and the tuple
  tree added 6.5 times the input before ``builder.py`` built nodes.  The per-thread bump
  arena kept a block of up to 64 MB.
- **Hypothesis, to confirm.**  The extra 109 MB of peak RSS at equal retained memory came
  from millions of short-lived tuples interleaved with long-lived nodes: pymalloc arenas
  that cannot be returned to the operating system.
- **What.**  Run ``marshal.loads`` on a view of the native buffer instead of a copy; size
  the node reserve by measurement; cap the retained block; stream the wire per top-level
  construct; shrink ``Node_Data``.

5. Incremental reparsing API
----------------------------

``rst.reparse(old, edit)`` implementing the boundary, lookahead and convergence rules
above, returning the changed ranges for semantic-token deltas; registries and section
levels always rebuilt.  Only for files over about 1 MB.  Verified by randomised edits on
fuzz documents: ``reparse`` and a full parse must give the same tree hash and messages.

6. Other adoptions
------------------

- **Line table first**: the reStructuredText analogue of ruff's lossless tokens.  A full
  token-stream redesign is not worth it; block states are only about 10 % of the time.
- **docodin dump --json --spans** to expose the parse tree with positions to other tools.
- **tree-sitter-rst as a consumer, not a model**: docodin can serve as a differential
  oracle for its sections, lists and tables.
- **Rejected**: parallel parsing of one document at anchors (files are already parsed in
  parallel), and a reference-counted green tree (the struct-of-arrays handle tree is
  already where ruff's node indices and pulldown-cmark's index trees converge).

Suggested order: item 1 first, with the tree hash as a permanent guard; then item 2;
then the memory quick wins, measured; then ``docodin-lsp`` (diagnostics, symbols,
folding and semantic tokens, then definition, hover and completion, then the Sphinx
manifest); item 5 only if measurements show files whose full reparse exceeds the latency
budget.

Alternatives
============

The rejected options are listed with each item: a tree-sitter grammar as the source of
structure, a token-stream redesign, a green tree, parallel parsing within a document,
and incremental parsing before it is needed.

Compatibility and fidelity
==========================

Every item keeps the docutils path identical; the parse-tree hash over every field of
every node makes the speed-ups provable, and the position layer is behind a flag.

Verification
============

Listed per item above.  The tree hash was run on the 20.9 MB corpus and on 30,000
generated documents under several settings.

Outcome
=======

docodin 0.2.0 delivered items 1 to 4 and part of item 6:

- **Item 1** landed with more than the experiment: SIMD line splitting, a candidate
  scanner that jumps between bytes that can start inline markup, URI and e-mail searches
  only before ``:`` and ``@``, reference matching without large struct copies, line joins
  as views of the input, and tab expansion over plain-ASCII runs.  The parser is **2.8
  times faster** (3.1 times fewer instructions on the 21 MB corpus); tab-indented
  documents are 2.7 to 5 times faster.  A quadratic case was removed on the way:
  positioning problematic inline markup rescanned the text for every error (a 600 KB
  line of ``|x``: from minutes to 27 ms).
- **Item 2** landed as ``Parse_Flag.Spans`` with the line table and ``rst.Line_Index``
  (DOD 13).  Spans cost about 10 % when on and nothing when off.
- **Item 3** landed as ``docodin-lsp`` (DOD 14): diagnostics, quick fixes, symbols,
  folding, semantic tokens, definition, references, hover and completion.  It parses each
  change once and answers in about 6 ms for a 124 KB document.  Rename and the
  cross-file index with a Sphinx manifest were not built; the server works on one file
  at a time.  Instead of a worker pool, one thread handles the messages in order, which
  the measured latency allows.
- **Item 4** landed as three of its steps (DOD 15): decoding without a copy (and item by
  item for large results), and a per-thread arena that maps its blocks from the
  operating system and keeps at most 4 MB between calls.  A Sphinx build of CPython's
  documentation now peaks below stock docutils: 883 MB against 895 MB.
- **Item 5** was not built; it is recorded as DOD 17 in the ``ideation`` state.
- **Item 6**: the line table landed; ``docodin dump --spans`` and the tree-sitter-rst
  oracle were not built.

References
==========

- ``CHANGELOG.rst`` (0.2.0), ``odin/rst/scan.odin``, ``odin/rst/source.odin``,
  ``odin/rst/spans.odin``, ``odin/rst/line_index.odin``, ``odin/lsp``.
- DOD 13, DOD 14, DOD 15, DOD 17.
