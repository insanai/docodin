package rst

import "base:runtime"

// Document tree produced by the reStructuredText parser.
//
// The parser output mirrors the docutils doctree *before* registration with
// the ``document`` (ids, names, reference bookkeeping) — that part is done by
// the host (python/docodin/builder.py).  Two node kinds are
// parse events rather than doctree elements:
//
// * ``Section_Title`` — a section header; the host decides the section level
//   and nesting (docutils ``RSTState.check_subsection``).  Children: a
//   ``Title`` followed by header warnings.
// * ``Directive``/``Interpreted`` — pending directive/role invocations.
//
// Node kinds and tag names are generated (node_kinds.odin).
//
// Storage is data-oriented: a ``Tree`` owns every node in one ``#soa``
// array and links them by ``Node`` handles (indices), so the tree is a few
// flat allocations, walks touch only the fields they read, and every access
// is bounds-checked through the tree.  Handles stay valid while the tree
// grows.  Slot 0 is reserved: the handle 0 (``NO_NODE``) means "no node".
// Growing moves the node storage, so a node-creating call is never the
// right-hand side of a field store (``t.nodes[a].x = f()`` may address the
// old storage): store its result in a local first.

// Reference flavours (``num[0]`` of a ``Reference``).
Ref_Kind :: enum i32 {
	Simple, // name_ / name__
	Phrase, // `phrase`_ / `phrase <uri>`_ / `phrase <alias_>`_
	Uri,    // standalone URI or e-mail address
	Pep,    // PEP 8 / pep-0008.txt
	Rfc,    // RFC 2822
}

// ``Target`` ``num[0]``: what the target points to.
Target_Type :: enum i32 {
	Refuri,  // external URI (possibly empty: internal target)
	Refname, // indirect target
}

// Embedded alias of a phrase reference (``Inliner.phrase_ref``).
Phrase_Info :: struct {
	alias_type: enum u8 {None, Name, Uri},
	alias:      string, // normalized-ready alias (URI or reference name)
	target_raw: string, // rawsource of the embedded target (match.group(1))
	rawtext:    string, // rawsource of the reference text
}

Directive_Info :: struct {
	lines:       []string, // indented block; lines[0] = text after "::"
	line_offset: int,      // absolute (0-based) offset of lines[0]
	end_offset:  int,      // absolute offset of the last line of the block
	blank_finish: bool,
}

// Handle of a node: its index in ``Tree.nodes``.
Node :: distinct u32

NO_NODE :: Node(0)

// Field usage per kind is documented next to the constructors in the parser
// and in serialize.odin; common conventions:
//   text: character data (Text, literal blocks, messages, labels)
//   raw:  docutils ``rawsource``
//   name: a secondary string (role, directive, bullet, delimiter, ...)
// Strings are views into the source or the parser's allocator.
Node_Data :: struct {
	kind:     Node_Kind,
	line:     i32, // absolute 1-based line number, 0 = unknown
	// docutils ``document.current_line`` when docutils attaches the node to
	// the tree (used where docutils sets no explicit line; see
	// ``Parser.cur_line``).  Recorded where the host needs it: system
	// messages, comments, tables, option list items, line blocks, block
	// quotes, targets, footnotes and citations (registry messages), and the
	// inline-bearing nodes (inline markup messages are attached at that line).
	cur_line: i32,
	num:      [2]i32,
	parent:   Node,
	first:    Node,
	last:     Node,
	next:     Node,
	text:     string,
	raw:      string,
	name:     string,
	// Index into ``Tree.phrases`` (``Reference``) or ``Tree.directives``
	// (``Directive``); 0: none.
	extra:    u32,
}

// Source positions (``Parse_Flag.Spans``, off by default).  Every node of a
// ``parse_text`` parse gets a span: the half-open byte range ``[start, end)``
// of the source it was parsed from, in the text given to ``parse_text``
// (``node_span``; the line table is ``Tree.line_starts``).  The rules:
//
// * A span runs from the first byte of the construct (its marker, or its
//   text when it has none) to the end of its last non-blank line, trailing
//   whitespace and line break excluded.  Indentation before the first byte
//   is outside; the indentation of later lines is inside.
// * ``Document``: the whole text.  ``Section_Title``: from the overline (or
//   the title line) to the end of the underline; its ``Title``: the title
//   text.  ``Transition``: the marker.
// * Explicit markup (``Directive``, ``Comment``, ``Target``, ``Footnote``,
//   ``Citation``, ``Substitution_Definition``): from ``..`` (``__`` for an
//   anonymous target) through the whole indented block.  ``Label``:
//   ``[label]``.  A comment made of a malformed target or substitution
//   definition starts at its ``..``.
// * Lists: ``List_Item`` from its bullet or enumerator through its content;
//   ``Field`` from ``:name:``; ``Field_Name`` is ``:name:``; ``Field_Body``,
//   ``Definition`` and ``Description`` span their block (empty after the
//   marker when there is none).  ``Option_Group`` is the option marker,
//   ``Option`` one option, ``Option_String`` and ``Option_Argument`` their
//   text.  ``Term`` runs to the end of its text before the first
//   classifier, each ``Classifier`` over its text and the markup after it.
//   The lists themselves, ``Line_Block``, ``THead``, ``TBody`` and ``Row``
//   span their children.
// * ``Paragraph``, ``Literal_Block``, ``Doctest_Block``, ``Block_Quote``
//   (with its ``Attribution``, which starts at the dash), ``Line`` (from
//   ``|``): their lines.
// * Tables: ``Table`` and ``TGroup`` span the table's lines; a ``Colspec``
//   is empty at the table's start.  An ``Entry`` spans its cell's text,
//   from the first character of the cell's first non-blank line to the end
//   of its last one (empty at the cell's start when it has no text), so it
//   includes the text of the cells beside it; entries of a row, and rows
//   with cells spanning several rows, may overlap.  The nodes parsed from a
//   cell are located in the cell's lines.
// * Inline nodes span their markup, from the start-string to the end-string
//   (role prefix or suffix and ``_``/``__`` included); ``Text`` its
//   characters; a standalone URI, e-mail address, PEP or RFC reference the
//   matched text.
// * ``System_Message``: the text of the line it reports (``line``), or of
//   the current line when it reports none; its children share its span.
//   Messages report positions, so their spans need not lie inside their
//   parent's.
// * Nodes built from lines that ``include`` inserted get an empty span at
//   the end of the inserting directive.
//
// Apart from messages, a node's span lies inside its parent's, and the
// spans of siblings follow each other without overlapping (except table
// rows and entries, above).
Tree :: struct {
	nodes:       #soa[dynamic]Node_Data, // nodes[0] is the unused null slot
	phrases:     [dynamic]Phrase_Info,    // [0] unused
	directives:  [dynamic]Directive_Info, // [0] unused
	// The input of ``parse_text`` and its line table: the byte offset of the
	// start of each ``string2lines`` line, then ``len(text)``.
	text:        string,
	line_starts: []u32,
	// Source positions of the nodes (``Parse_Flag.Spans``), by handle; see
	// ``node_span``.
	spans:       [dynamic]Span,
}

// Allocate the tree's storage from ``allocator`` with room for about
// ``node_capacity`` nodes.  A no-op once the tree is initialised.
tree_init :: proc(t: ^Tree, allocator: runtime.Allocator, node_capacity := 64) {
	if len(t.nodes) > 0 do return
	// not zeroed: nodes are written whole, and untouched capacity stays cheap
	t.nodes.allocator = allocator
	non_zero_reserve_soa(&t.nodes, max(node_capacity, 2))
	non_zero_append(&t.nodes, Node_Data{}) // the null slot
	t.phrases = make([dynamic]Phrase_Info, 1, 4, allocator)
	t.directives = make([dynamic]Directive_Info, 1, 4, allocator)
}

// Number of nodes in the tree (the null slot excluded).
node_count :: #force_inline proc "contextless" (t: ^Tree) -> int {
	return max(len(t.nodes) - 1, 0)
}

// --- read API ----------------------------------------------------------------

node_kind :: #force_inline proc "contextless" (t: ^Tree, n: Node) -> Node_Kind {
	return t.nodes[n].kind
}

node_line :: #force_inline proc "contextless" (t: ^Tree, n: Node) -> int {
	return int(t.nodes[n].line)
}

node_cur_line :: #force_inline proc "contextless" (t: ^Tree, n: Node) -> int {
	return int(t.nodes[n].cur_line)
}

node_num :: #force_inline proc "contextless" (t: ^Tree, n: Node) -> [2]i32 {
	return t.nodes[n].num
}

node_text :: #force_inline proc "contextless" (t: ^Tree, n: Node) -> string {
	return t.nodes[n].text
}

node_raw :: #force_inline proc "contextless" (t: ^Tree, n: Node) -> string {
	return t.nodes[n].raw
}

node_name :: #force_inline proc "contextless" (t: ^Tree, n: Node) -> string {
	return t.nodes[n].name
}

first_child :: #force_inline proc "contextless" (t: ^Tree, n: Node) -> Node {
	return t.nodes[n].first
}

last_child :: #force_inline proc "contextless" (t: ^Tree, n: Node) -> Node {
	return t.nodes[n].last
}

next_sibling :: #force_inline proc "contextless" (t: ^Tree, n: Node) -> Node {
	return t.nodes[n].next
}

parent_of :: #force_inline proc "contextless" (t: ^Tree, n: Node) -> Node {
	return t.nodes[n].parent
}

// All fields of ``n`` (a copy).
node_data :: #force_inline proc "contextless" (t: ^Tree, n: Node) -> Node_Data {
	return t.nodes[n]
}

// The recorded block of a ``Directive`` (``ok`` is false for other nodes).
directive_info :: proc "contextless" (t: ^Tree, n: Node) -> (info: Directive_Info, ok: bool) {
	extra := t.nodes[n].extra
	if t.nodes[n].kind != .Directive || extra == 0 do return
	return t.directives[extra], true
}

// The embedded alias of a phrase ``Reference`` (``ok`` is false when there
// is none).
phrase_info :: proc "contextless" (t: ^Tree, n: Node) -> (info: Phrase_Info, ok: bool) {
	extra := t.nodes[n].extra
	if t.nodes[n].kind != .Reference || extra == 0 do return
	return t.phrases[extra], true
}

// Iterator over a sibling chain:
//
//	it := children(t, n)
//	for c in iterate(&it) { ... }
//
// The next sibling is read before ``c`` is yielded, so the loop body may
// move ``c`` to another parent.
Node_Iterator :: struct {
	t:    ^Tree,
	next: Node,
}

children :: #force_inline proc "contextless" (t: ^Tree, n: Node) -> Node_Iterator {
	return {t, t.nodes[n].first}
}

// The chain starting at ``first`` (e.g. a ``Node_List``).
chain :: #force_inline proc "contextless" (t: ^Tree, first: Node) -> Node_Iterator {
	return {t, first}
}

// The children of ``parent`` after ``before`` (its last child before they
// were appended; NO_NODE: all of them).
children_after :: #force_inline proc "contextless" (
	t: ^Tree,
	parent, before: Node,
) -> Node_Iterator {
	return {t, t.nodes[before].next if before != NO_NODE else t.nodes[parent].first}
}

iterate :: #force_inline proc "contextless" (it: ^Node_Iterator) -> (n: Node, ok: bool) {
	n = it.next
	if n == NO_NODE do return
	it.next = it.t.nodes[n].next
	return n, true
}

child_count :: proc "contextless" (t: ^Tree, n: Node) -> int {
	count := 0
	for c := t.nodes[n].first; c != NO_NODE; c = t.nodes[c].next do count += 1
	return count
}

// --- construction ------------------------------------------------------------------

new_node :: #force_inline proc(t: ^Tree, kind: Node_Kind, line: int) -> Node {
	if len(t.nodes) == 0 do non_zero_append(&t.nodes, Node_Data{}) // the null slot
	non_zero_append(&t.nodes, Node_Data{kind = kind, line = i32(line)})
	return Node(len(t.nodes) - 1)
}

// Record ``info`` for the ``Directive`` ``n``.
set_directive_info :: proc(t: ^Tree, n: Node, info: Directive_Info) {
	if len(t.directives) == 0 do append(&t.directives, Directive_Info{})
	append(&t.directives, info)
	t.nodes[n].extra = u32(len(t.directives) - 1)
}

// Record ``info`` for the phrase ``Reference`` ``n``.
set_phrase_info :: proc(t: ^Tree, n: Node, info: Phrase_Info) {
	if len(t.phrases) == 0 do append(&t.phrases, Phrase_Info{})
	append(&t.phrases, info)
	t.nodes[n].extra = u32(len(t.phrases) - 1)
}

append_child :: #force_inline proc "contextless" (t: ^Tree, parent, child: Node) {
	if parent == NO_NODE || child == NO_NODE do return
	t.nodes[child].next = NO_NODE
	t.nodes[child].parent = parent
	last := t.nodes[parent].last
	if last == NO_NODE {
		t.nodes[parent].first = child
	} else {
		t.nodes[last].next = child
	}
	t.nodes[parent].last = child
}

// Append a (possibly empty) sibling chain.
append_chain :: proc "contextless" (t: ^Tree, parent: Node, first: Node) {
	for c := first; c != NO_NODE; {
		next := t.nodes[c].next
		append_child(t, parent, c)
		c = next
	}
}

// Replace the children of ``parent`` by the chain ``l`` (whose nodes keep
// their parent links).
set_children :: #force_inline proc "contextless" (t: ^Tree, parent: Node, l: Node_List) {
	t.nodes[parent].first = l.first
	t.nodes[parent].last = l.last
}

// A detached sibling chain, built before its parent is known.
Node_List :: struct {
	first, last: Node,
}

list_append :: #force_inline proc "contextless" (t: ^Tree, l: ^Node_List, n: Node) {
	if n == NO_NODE do return
	t.nodes[n].next = NO_NODE
	if l.last == NO_NODE {
		l.first = n
	} else {
		t.nodes[l.last].next = n
	}
	l.last = n
}

list_extend :: proc "contextless" (t: ^Tree, l: ^Node_List, other: Node_List) {
	if other.first == NO_NODE do return
	if l.last == NO_NODE {
		l^ = other
	} else {
		t.nodes[l.last].next = other.first
		l.last = other.last
	}
}

// Record ``cur_line`` on every node of the chain starting at ``first``.
set_chain_cur_line :: proc "contextless" (t: ^Tree, first: Node, cur_line: int) {
	for n := first; n != NO_NODE; n = t.nodes[n].next do t.nodes[n].cur_line = i32(cur_line)
}
