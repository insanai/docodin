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

// Reference flavours (``Node.num[0]`` of a ``Reference``).
Ref_Kind :: enum i32 {
	Simple, // name_ / name__
	Phrase, // `phrase`_ / `phrase <uri>`_ / `phrase <alias_>`_
	Uri,    // standalone URI or e-mail address
	Pep,    // PEP 8 / pep-0008.txt
	Rfc,    // RFC 2822
}

// ``Target.num[0]``: what the target points to.
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

Extra :: union {
	^Phrase_Info,
	^Directive_Info,
}

// Field usage per kind is documented next to the constructors in the parser
// and in serialize.odin; common conventions:
//   text: character data (Text, literal blocks, messages, labels)
//   raw:  docutils ``rawsource``
//   name: a secondary string (role, directive, bullet, delimiter, ...)
Node :: struct {
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
	first:    ^Node,
	last:     ^Node,
	next:     ^Node,
	parent:   ^Node,
	text:     string,
	raw:      string,
	name:     string,
	extra:    Extra,
}

new_node :: #force_inline proc(kind: Node_Kind, line: int, allocator: runtime.Allocator) -> ^Node {
	n := new(Node, allocator)
	n.kind = kind
	n.line = i32(line)
	return n
}

append_child :: #force_inline proc "contextless" (parent, child: ^Node) {
	if parent == nil || child == nil do return
	child.next = nil
	child.parent = parent
	if parent.last == nil {
		parent.first = child
	} else {
		parent.last.next = child
	}
	parent.last = child
}

// Append a (possibly empty) sibling chain.
append_chain :: proc "contextless" (parent: ^Node, chain: ^Node) {
	for c := chain; c != nil; {
		next := c.next
		append_child(parent, c)
		c = next
	}
}

child_count :: proc "contextless" (n: ^Node) -> int {
	count := 0
	for c := n.first; c != nil; c = c.next do count += 1
	return count
}

// Concatenated text content, like docutils ``astext()`` for inline trees
// (escape markers are removed by ``unescape``).
Node_List :: struct {
	first, last: ^Node,
}

list_append :: #force_inline proc "contextless" (l: ^Node_List, n: ^Node) {
	if n == nil do return
	n.next = nil
	if l.last == nil {
		l.first = n
	} else {
		l.last.next = n
	}
	l.last = n
}

list_extend :: proc "contextless" (l: ^Node_List, other: Node_List) {
	if other.first == nil do return
	if l.last == nil {
		l^ = other
	} else {
		l.last.next = other.first
		l.last = other.last
	}
}
