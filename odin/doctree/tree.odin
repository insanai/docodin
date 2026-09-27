package doctree

// Tree construction and mutation, mirroring ``docutils.nodes.Element``.
//
// All link changes go through ``link_before`` and ``unlink``, which keep the
// parent/first/last/next/prev handles consistent and bump the parent's
// ``gen`` so that running ``Findall`` iterators notice the change.

// ``nodes.Text(data)``.
new_text :: proc(doc: ^Doc, data: string) -> Node {
	return alloc_node(doc, .Text, data)
}

// A new element (``nodes.<tag>(rawsource, text)``).  For ``TextElement``
// classes a non-empty ``text`` becomes a Text child; ``FixedTextElement``
// classes get ``xml:space="preserve"``.  Use ``new_text`` for Text nodes,
// ``new_pending`` for ``pending`` and ``system_message`` for messages.
new_element :: proc(doc: ^Doc, t: Tag, rawsource := "", text := "") -> Node {
	assert(t != .Text, "doctree: use new_text for Text nodes")
	n := alloc_node(doc, t, rawsource)
	cats := TAG_CATEGORIES[t]
	if .TextElement in cats && len(text) > 0 {
		append_child(doc, n, new_text(doc, text))
	}
	if .FixedTextElement in cats do set_attr(doc, n, K_XML_SPACE, "preserve")
	return n
}

// A ``pending`` element (``nodes.pending(transform, details)``).
// ``transform`` is the transform's qualified class name and
// ``default_priority`` its ``default_priority`` (used by ``note_pending``).
new_pending :: proc(
	doc: ^Doc,
	transform: string,
	default_priority: int,
	details: []Detail = nil,
	rawsource := "",
) -> Node {
	n := alloc_node(doc, .pending, rawsource)
	p := Pending {
		transform        = clone(doc, transform),
		default_priority = default_priority,
		details          = make([dynamic]Detail, 0, len(details), doc.allocator),
	}
	for d in details do append(&p.details, Detail{clone(doc, d.key), clone_detail(doc, d.value)})
	doc.nodes[n].extra = u32(len(doc.pendings))
	append(&doc.pendings, p)
	return n
}

// The internal data of a ``pending`` element.
pending_of :: proc(doc: ^Doc, n: Node) -> ^Pending {
	assert(doc.nodes[n].tag == .pending)
	return &doc.pendings[doc.nodes[n].extra]
}

// Set a detail of a ``pending`` element (``pending.details[key] = value``).
set_detail :: proc(doc: ^Doc, n: Node, key: string, value: Detail_Value) {
	p := pending_of(doc, n)
	v := clone_detail(doc, value)
	for &d in p.details {
		if d.key == key {
			d.value = v
			return
		}
	}
	append(&p.details, Detail{clone(doc, key), v})
}

// A detail of a ``pending`` element.
get_detail :: proc(doc: ^Doc, n: Node, key: string) -> (Detail_Value, bool) {
	for d in pending_of(doc, n).details {
		if d.key == key do return d.value, true
	}
	return nil, false
}

@(private)
clone_detail :: proc(doc: ^Doc, v: Detail_Value) -> Detail_Value {
	#partial switch x in v {
	case string:
		return clone(doc, x)
	case []Node:
		out := make([]Node, len(x), doc.allocator)
		copy(out, x)
		return out
	case []string:
		out := make([]string, len(x), doc.allocator)
		for s, i in x do out[i] = clone(doc, s)
		return out
	}
	return v
}

// --- links -----------------------------------------------------------------------

// Is ``n`` currently in its parent's child list?
is_linked :: proc(doc: ^Doc, n: Node) -> bool {
	e := &doc.nodes[n]
	return e.prev != 0 || (e.parent != 0 && doc.nodes[e.parent].first == n)
}

// Take ``n`` out of its parent's child list; ``n.parent`` is kept.
@(private)
unlink :: proc(doc: ^Doc, n: Node) {
	if !is_linked(doc, n) do return
	e := &doc.nodes[n]
	p, prev, next := e.parent, e.prev, e.next
	if prev != 0 do doc.nodes[prev].next = next
	else do doc.nodes[p].first = next
	if next != 0 do doc.nodes[next].prev = prev
	else do doc.nodes[p].last = prev
	e.prev, e.next = 0, 0
	doc.nodes[p].gen += 1
}

// Link ``child`` into ``p`` before ``ref`` (at the end if ``ref`` is 0).
@(private)
link_before :: proc(doc: ^Doc, p, child, ref: Node) {
	assert(child != p, "doctree: a node cannot be its own child")
	unlink(doc, child)
	c := &doc.nodes[child]
	c.parent = p
	if ref == 0 {
		c.prev = doc.nodes[p].last
		if c.prev != 0 do doc.nodes[c.prev].next = child
		else do doc.nodes[p].first = child
		doc.nodes[p].last = child
	} else {
		c.prev = doc.nodes[ref].prev
		c.next = ref
		doc.nodes[ref].prev = child
		if c.prev != 0 do doc.nodes[c.prev].next = child
		else do doc.nodes[p].first = child
	}
	doc.nodes[p].gen += 1
}

// ``Node.setup_child``: set the parent and, inside a document, the
// document, ``source`` and ``line`` (from ``document.current_source`` and
// ``current_line``) where they are None.
setup_child :: proc(doc: ^Doc, p, child: Node) {
	doc.nodes[child].parent = p
	if !in_document(doc, p) do return
	c := &doc.nodes[child]
	c.flags += {.Has_Document}
	if .Has_Source not_in c.flags {
		if src, ok := doc.current_source.?; ok {
			c.source = intern(doc, src)
			c.flags += {.Has_Source}
		}
	}
	if .Has_Line not_in c.flags {
		if ln, ok := doc.current_line.?; ok {
			c.line = i32(ln)
			c.flags += {.Has_Line}
		}
	}
}

// --- children ------------------------------------------------------------------------

child_count :: proc(doc: ^Doc, p: Node) -> int {
	n := 0
	for c := doc.nodes[p].first; c != 0; c = doc.nodes[c].next do n += 1
	return n
}

// ``element[i]``; negative indices count from the end.  0 if out of range.
child_at :: proc(doc: ^Doc, p: Node, i: int) -> Node {
	if i < 0 {
		k := -1
		for c := doc.nodes[p].last; c != 0; c = doc.nodes[c].prev {
			if k == i do return c
			k -= 1
		}
		return 0
	}
	k := 0
	for c := doc.nodes[p].first; c != 0; c = doc.nodes[c].next {
		if k == i do return c
		k += 1
	}
	return 0
}

// A snapshot of the children (``element.children[:]``).
children :: proc(doc: ^Doc, p: Node, allocator := context.temp_allocator) -> []Node {
	out := make([dynamic]Node, 0, 8, allocator)
	for c := doc.nodes[p].first; c != 0; c = doc.nodes[c].next do append(&out, c)
	return out[:]
}

@(private = "file")
same :: proc(doc: ^Doc, a, b: Node) -> bool {
	if a == b do return true
	ea, eb := doc.nodes[a], doc.nodes[b]
	return ea.tag == .Text && eb.tag == .Text && ea.text == eb.text
}

// ``Element.index(item)``: position of the first child equal to ``item``
// (Text nodes compare by value, as ``str``), -1 if there is none.
index :: proc(doc: ^Doc, p, item: Node, start := 0) -> int {
	k := 0
	for c := doc.nodes[p].first; c != 0; c = doc.nodes[c].next {
		if k >= start && same(doc, c, item) do return k
		k += 1
	}
	return -1
}

// Position of ``item`` itself among the children of ``p``, -1 if absent.
index_identity :: proc(doc: ^Doc, p, item: Node) -> int {
	k := 0
	for c := doc.nodes[p].first; c != 0; c = doc.nodes[c].next {
		if c == item do return k
		k += 1
	}
	return -1
}

@(private = "file")
normalize_index :: proc(doc: ^Doc, p: Node, i: int) -> int {
	n := child_count(doc, p)
	j := i < 0 ? i + n : i
	return clamp(j, 0, n)
}

// ``Element.append``.
append_child :: proc(doc: ^Doc, p, child: Node) {
	unlink(doc, child)
	setup_child(doc, p, child)
	link_before(doc, p, child, 0)
}

// ``Element.extend``.
extend_children :: proc(doc: ^Doc, p: Node, items: []Node) {
	for c in items do append_child(doc, p, c)
}

// ``Element.insert(index, item)`` (``list.insert`` index semantics).
insert_child :: proc(doc: ^Doc, p: Node, i: int, item: Node) {
	ref := child_at(doc, p, normalize_index(doc, p, i))
	if ref == item do return
	unlink(doc, item)
	setup_child(doc, p, item)
	link_before(doc, p, item, ref)
}

// ``Element.insert(index, [items])``: ``element[index:index] = items``.
insert_children :: proc(doc: ^Doc, p: Node, i: int, items: []Node) {
	ref := child_at(doc, p, normalize_index(doc, p, i))
	for item in items {
		if item == ref do ref = doc.nodes[ref].next
		unlink(doc, item)
		setup_child(doc, p, item)
		link_before(doc, p, item, ref)
	}
}

// Insert ``item`` before the child ``ref``.
insert_before :: proc(doc: ^Doc, ref, item: Node) {
	p := doc.nodes[ref].parent
	assert(is_linked(doc, ref))
	if item == ref do return
	unlink(doc, item)
	setup_child(doc, p, item)
	link_before(doc, p, item, ref)
}

// ``Element.remove(item)``: remove the first child equal to ``item``.
// False if there is none (Python raises ``ValueError``).
remove_child :: proc(doc: ^Doc, p, item: Node) -> bool {
	for c := doc.nodes[p].first; c != 0; c = doc.nodes[c].next {
		if same(doc, c, item) {
			unlink(doc, c)
			return true
		}
	}
	return false
}

// ``Element.pop(i)``: remove and return the child at ``i`` (0 if none).
pop_child :: proc(doc: ^Doc, p: Node, i := -1) -> Node {
	c := child_at(doc, p, i)
	if c != 0 do unlink(doc, c)
	return c
}

// ``Element.clear()``.
clear_children :: proc(doc: ^Doc, p: Node) {
	for doc.nodes[p].first != 0 do unlink(doc, doc.nodes[p].first)
}

// ``Element.replace(old, new)``.  False if ``old`` is not a child.
replace :: proc(doc: ^Doc, p, old, new: Node) -> bool {
	i := index(doc, p, old)
	if i < 0 do return false
	target := child_at(doc, p, i)
	if target == new do return true
	unlink(doc, new)
	setup_child(doc, p, new)
	link_before(doc, p, new, target)
	unlink(doc, target)
	return true
}

// ``Element.replace(old, [new...])``: ``element[i:i+1] = news``.
replace_list :: proc(doc: ^Doc, p, old: Node, news: []Node) -> bool {
	i := index(doc, p, old)
	if i < 0 do return false
	target := child_at(doc, p, i)
	for n in news {
		if n == target do continue
		unlink(doc, n)
		setup_child(doc, p, n)
		link_before(doc, p, n, target)
	}
	if !contains_node(news, target) do unlink(doc, target)
	return true
}

@(private = "file")
contains_node :: proc(list: []Node, n: Node) -> bool {
	for x in list do if x == n do return true
	return false
}

// ``Element.replace_self(new)``: the basic attributes of ``n`` are added
// to ``new`` (if it is an element).
replace_self :: proc(doc: ^Doc, n, new: Node) -> bool {
	if doc.nodes[new].tag != .Text do update_basic_atts(doc, new, n)
	return replace(doc, doc.nodes[n].parent, n, new)
}

// ``Element.replace_self([new...])``: the basic attributes of ``n`` are
// added to the first node (if it is an element).
replace_self_list :: proc(doc: ^Doc, n: Node, news: []Node) -> bool {
	if len(news) > 0 && doc.nodes[news[0]].tag != .Text {
		update_basic_atts(doc, news[0], n)
	}
	return replace_list(doc, doc.nodes[n].parent, n, news)
}

// ``Element.first_child_matching_class``: index of the first child in
// ``[start, end)`` whose class is in ``tags``, -1 for None.
first_child_matching_class :: proc(
	doc: ^Doc,
	p: Node,
	tags: Tag_Set,
	start := 0,
	end := max(int),
) -> int {
	k := 0
	for c := doc.nodes[p].first; c != 0 && k < end; c = doc.nodes[c].next {
		if k >= start && doc.nodes[c].tag in tags do return k
		k += 1
	}
	return -1
}

// ``Element.first_child_not_matching_class``: index of the first child in
// ``[start, end)`` whose class is not in ``tags``, -1 for None.
first_child_not_matching_class :: proc(
	doc: ^Doc,
	p: Node,
	tags: Tag_Set,
	start := 0,
	end := max(int),
) -> int {
	k := 0
	for c := doc.nodes[p].first; c != 0 && k < end; c = doc.nodes[c].next {
		if k >= start && doc.nodes[c].tag not_in tags do return k
		k += 1
	}
	return -1
}

// ``Element.previous_sibling()``.
previous_sibling :: proc(doc: ^Doc, n: Node) -> Node {
	return doc.nodes[n].prev
}

// ``Element.section_hierarchy()``: the ``section`` ancestors of ``n`` (and
// ``n`` itself if it is one) that have a parent, outermost first.
section_hierarchy :: proc(doc: ^Doc, n: Node, allocator := context.temp_allocator) -> []Node {
	out := make([dynamic]Node, 0, 4, allocator)
	for m := n; doc.nodes[m].parent != 0; m = doc.nodes[m].parent {
		if doc.nodes[m].tag == .section do append(&out, m)
	}
	for i in 0 ..< len(out) / 2 do out[i], out[len(out) - 1 - i] = out[len(out) - 1 - i], out[i]
	return out[:]
}

// ``Element.get_language_code(fallback)``.
get_language_code :: proc(doc: ^Doc, n: Node, fallback := "") -> string {
	for m := n; m != 0; m = doc.nodes[m].parent {
		if doc.nodes[m].tag == .Text do return fallback
		for c in attr_list(doc, m, K_CLASSES) {
			s := str(doc, c)
			if len(s) >= 9 && s[:9] == "language-" do return s[9:]
		}
	}
	return fallback
}

// --- copies -----------------------------------------------------------------------------

// ``Node.copy()``: a copy without children.  Text copies have no source,
// line or document; element copies keep them and copy the list attributes.
copy_node :: proc(doc: ^Doc, n: Node) -> Node {
	return import_node(doc, doc, n)
}

// ``Node.deepcopy()``.
deepcopy :: proc(doc: ^Doc, n: Node) -> Node {
	return import_deep(doc, doc, n)
}

// ``copy_node`` from another document ``src`` into ``dst``.
import_node :: proc(dst, src: ^Doc, n: Node) -> Node {
	e := src.nodes[n]
	if e.tag == .Text do return new_text(dst, e.text)
	m := alloc_node(dst, e.tag, e.text)
	copy_attrs(dst, src, m, n)
	if .FixedTextElement in TAG_CATEGORIES[e.tag] do set_attr(dst, m, K_XML_SPACE, "preserve")
	d := &dst.nodes[m]
	d.flags = e.flags & {.Has_Document, .Has_Source, .Has_Line}
	d.line = e.line
	d.source = dst == src ? e.source : intern(dst, src.strings[e.source])
	if e.tag == .pending do import_pending(dst, src, m, n)
	return m
}

// ``deepcopy`` from another document ``src`` into ``dst``.
import_deep :: proc(dst, src: ^Doc, n: Node) -> Node {
	m := import_node(dst, src, n)
	for c := src.nodes[n].first; c != 0; c = src.nodes[c].next {
		append_child(dst, m, import_deep(dst, src, c))
	}
	return m
}

@(private = "file")
import_pending :: proc(dst, src: ^Doc, m, n: Node) {
	if dst == src {
		dst.nodes[m].extra = src.nodes[n].extra // shares ``details`` as docutils does
		return
	}
	p := src.pendings[src.nodes[n].extra]
	q := Pending {
		transform        = clone(dst, p.transform),
		default_priority = p.default_priority,
		details          = make([dynamic]Detail, 0, len(p.details), dst.allocator),
	}
	for d in p.details {
		v := d.value
		#partial switch x in d.value {
		case Node:
			v = import_deep(dst, src, x)
		case []Node:
			nodes := make([]Node, len(x), dst.allocator)
			for c, i in x do nodes[i] = import_deep(dst, src, c)
			v = nodes
		}
		append(&q.details, Detail{clone(dst, d.key), clone_detail(dst, v)})
	}
	dst.nodes[m].extra = u32(len(dst.pendings))
	append(&dst.pendings, q)
}
