package doctree

import "base:runtime"

// Pre-order traversal: ``Node.findall``, ``traverse`` and ``next_node``.
//
// ``Findall`` reproduces the generator semantics of docutils, including
// its behaviour under mutation of the tree during iteration:
//
// * The children of a node are read when the iteration moves below it,
//   after the node itself was yielded (and possibly changed).
// * Children are walked by position, like Python's list iterator: after
//   the child at index i and its descendants, the child at index i + 1 of
//   the parent's *current* child list comes next.  So replacing the current
//   node with several nodes visits the added ones after the first, and a
//   removed node's children are still walked.
// * The following siblings (``siblings``/``ascend``) are a snapshot taken
//   when the iteration gets there (``node.parent[index+1:]``).
//
// Positions are revalidated with the parent's ``gen`` counter, so the walk
// costs O(1) per step while the tree is not changed.

// A condition (``condition`` of ``findall``): nil matches every node, a
// ``Tag_Set`` matches instances of those classes (``isinstance``), a
// ``Predicate`` calls a procedure.
Predicate :: struct {
	fn:   proc(doc: ^Doc, n: Node, data: rawptr) -> bool,
	data: rawptr,
}

Condition :: union {
	Tag_Set,
	Predicate,
}

@(private = "file")
Frame :: struct {
	parent: Node,
	index:  int,
	cur:    Node,
	gen:    u32,
}

@(private = "file")
Phase :: enum u8 {
	Start,
	Self_Done,
	Siblings,
	Done,
}

Findall :: struct {
	doc:          ^Doc,
	cond:         Condition,
	start:        Node,
	include_self: bool,
	descend:      bool,
	siblings:     bool,
	ascend:       bool,
	phase:        Phase,
	expand:       Node, // a yielded node whose children come next
	frames:       [dynamic]Frame,
	sibs:         [dynamic]Node,
	sib_pos:      int,
	anchor:       Node, // the node whose following siblings are visited
}

// ``Node.findall(condition, include_self, descend, siblings, ascend)``:
// an iterator for ``for n in doctree.next(&it)``.  ``ascend`` implies
// ``siblings``.
findall :: proc(
	doc: ^Doc,
	start: Node,
	cond: Condition = nil,
	include_self := true,
	descend := true,
	siblings := false,
	ascend := false,
	allocator := context.temp_allocator,
) -> Findall {
	return Findall {
		doc = doc,
		cond = cond,
		start = start,
		include_self = include_self,
		descend = descend,
		siblings = siblings || ascend,
		ascend = ascend,
		frames = make([dynamic]Frame, 0, 16, allocator),
		sibs = make([dynamic]Node, 0, 0, allocator),
	}
}

@(private = "file")
matches :: proc(it: ^Findall, n: Node) -> bool {
	switch c in it.cond {
	case Tag_Set:
		return it.doc.nodes[n].tag in c
	case Predicate:
		return c.fn(it.doc, n, c.data)
	}
	return true
}

@(private = "file")
push_frame :: proc(it: ^Findall, p: Node) {
	append(&it.frames, Frame{parent = p, index = -1, gen = it.doc.nodes[p].gen})
}

// The next child of a frame (``next(list_iterator)``), 0 when exhausted.
@(private = "file")
advance :: proc(doc: ^Doc, f: ^Frame) -> Node {
	gen := doc.nodes[f.parent].gen
	nxt: Node
	if gen != f.gen {
		nxt = child_at(doc, f.parent, f.index + 1)
	} else if f.cur == 0 {
		nxt = f.index < 0 ? doc.nodes[f.parent].first : 0
	} else {
		nxt = doc.nodes[f.cur].next
	}
	f.index += 1
	f.cur = nxt
	f.gen = gen
	return nxt
}

// Snapshot the siblings after ``it.anchor``; false if there are none to
// visit (no parent, or the anchor is no longer among its parent's children).
@(private = "file")
snapshot_siblings :: proc(it: ^Findall) -> bool {
	doc := it.doc
	p := doc.nodes[it.anchor].parent
	if p == 0 || index_identity(doc, p, it.anchor) < 0 do return false
	clear(&it.sibs)
	for s := doc.nodes[it.anchor].next; s != 0; s = doc.nodes[s].next do append(&it.sibs, s)
	it.sib_pos = 0
	return true
}

// Yield ``n`` (a root of a sub-walk) if it matches, else descend into it.
@(private = "file")
enter :: proc(it: ^Findall, n: Node, descend: bool) -> bool {
	if matches(it, n) {
		if descend do it.expand = n
		return true
	}
	if descend do push_frame(it, n)
	return false
}

@(private = "file")
step_phase :: proc(it: ^Findall) -> (n: Node, found: bool) {
	switch it.phase {
	case .Start:
		it.phase = .Self_Done
		if it.include_self && matches(it, it.start) {
			if it.descend do it.expand = it.start
			return it.start, true
		}
		if it.descend do push_frame(it, it.start)
	case .Self_Done:
		it.phase = .Done
		it.anchor = it.start
		if it.siblings && snapshot_siblings(it) do it.phase = .Siblings
	case .Siblings:
		return step_sibling(it)
	case .Done:
	}
	return 0, false
}

// The next following sibling (``for sibling in node.parent[index+1:]``),
// then, with ``ascend``, the siblings of the parent.
@(private = "file")
step_sibling :: proc(it: ^Findall) -> (Node, bool) {
	if it.sib_pos < len(it.sibs) {
		s := it.sibs[it.sib_pos]
		it.sib_pos += 1
		if enter(it, s, it.descend) do return s, true
	} else if !it.ascend {
		it.phase = .Done
	} else {
		it.anchor = it.doc.nodes[it.anchor].parent
		if !snapshot_siblings(it) do it.phase = .Done
	}
	return 0, false
}

// The next node of a ``Findall``; ``ok`` is false at the end.
next :: proc(it: ^Findall) -> (n: Node, ok: bool) {
	for {
		if it.expand != 0 {
			push_frame(it, it.expand)
			it.expand = 0
		}
		if len(it.frames) > 0 {
			c := advance(it.doc, &it.frames[len(it.frames) - 1])
			if c == 0 {
				pop(&it.frames)
			} else if enter(it, c, true) {
				return c, true
			}
			continue
		}
		if it.phase == .Done do return 0, false
		if n, ok = step_phase(it); ok do return
	}
}

// ``Node.traverse(...)``: all nodes of ``findall`` as a list.
traverse :: proc(
	doc: ^Doc,
	start: Node,
	cond: Condition = nil,
	include_self := true,
	descend := true,
	siblings := false,
	ascend := false,
	allocator := context.temp_allocator,
) -> []Node {
	out := make([dynamic]Node, 0, 16, allocator)
	it := findall(doc, start, cond, include_self, descend, siblings, ascend)
	for n in next(&it) do append(&out, n)
	return out[:]
}

// ``Node.next_node(...)``: the first node of ``findall`` (note that
// ``include_self`` defaults to false), 0 if there is none.
next_node :: proc(
	doc: ^Doc,
	start: Node,
	cond: Condition = nil,
	include_self := false,
	descend := true,
	siblings := false,
	ascend := false,
) -> Node {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	it := findall(doc, start, cond, include_self, descend, siblings, ascend)
	n, _ := next(&it)
	return n
}
