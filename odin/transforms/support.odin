package transforms

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

import dt "../doctree"

// Helpers shared by the transforms: Python list semantics of child lists,
// attribute truthiness, the problematic-reference pattern and ``str``
// methods.

// --- child lists -----------------------------------------------------------------

// ``element[:] = items``: the items become the children (each set up as a
// child); children not among them leave the list but keep their parent.
set_children :: proc(doc: ^dt.Doc, p: dt.Node, items: []dt.Node) {
	dt.clear_children(doc, p)
	for item in items do dt.append_child(doc, p, item)
}

// ``element[i] = item``.
set_child_at :: proc(doc: ^dt.Doc, p: dt.Node, i: int, item: dt.Node) {
	old := dt.child_at(doc, p, i)
	if old == item do return
	dt.insert_child(doc, p, i, item)
	dt.pop_child(doc, p, dt.index_identity(doc, p, old))
}

// ``node.replace_self(new)``, also when ``new`` is ``node`` (which docutils
// sets up as a child again).
replace_self :: proc(doc: ^dt.Doc, n, new: dt.Node) {
	if n == new {
		dt.setup_child(doc, dt.parent(doc, n), n)
		return
	}
	dt.replace_self(doc, n, new)
}

// ``node.replace_self(new)`` (a list of nodes) of a node that may have left
// the tree: the run fails as docutils does.
py_replace_self :: proc(r: ^Run, n: dt.Node, news: ..dt.Node) {
	doc := r.doc
	if len(news) == 0 || dt.tag(doc, news[0]) == .Text {
		// no element to take the basic attributes: docutils asserts there are none
		for att in ([]dt.Str{dt.K_IDS, dt.K_CLASSES, dt.K_NAMES, dt.K_DUPNAMES}) {
			items := dt.attr_list(doc, n, att)
			if len(items) == 0 do continue
			b := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&b, "AssertionError: Losing \"%s\" attribute: [", dt.str(doc, att))
			for s, i in items {
				if i > 0 do strings.write_string(&b, ", ")
				dt.write_py_repr(&b, dt.str(doc, s))
			}
			strings.write_byte(&b, ']')
			fail(r, "%s", strings.to_string(b))
			return
		}
	}
	if dt.parent(doc, n) == 0 {
		fail(r, "AttributeError: 'NoneType' object has no attribute 'replace'")
	} else if !dt.replace_self_list(doc, n, news) {
		fail(r, "ValueError: list.index(x): x not in list")
	}
}

// ``parent[-1] += item``: append to the last child, which is then set up
// as a child again (``parent[-1] = child``).
append_to_last :: proc(doc: ^dt.Doc, parent, item: dt.Node) {
	last := dt.last_child(doc, parent)
	dt.append_child(doc, last, item)
	dt.setup_child(doc, parent, last)
}

// Remove the child ``item`` itself (not the first child equal to it).
remove_identity :: proc(doc: ^dt.Doc, p, item: dt.Node) {
	if i := dt.index_identity(doc, p, item); i >= 0 do dt.pop_child(doc, p, i)
}

// ``node.parent.remove(node)``: the run fails (``ValueError``) if ``node``
// is not among its parent's children.
py_remove :: proc(r: ^Run, node: dt.Node) {
	doc := r.doc
	p := dt.parent(doc, node)
	if p == 0 {
		fail(r, "AttributeError: 'NoneType' object has no attribute 'remove'")
		return
	}
	i := dt.index_identity(doc, p, node)
	if i < 0 {
		fail(r, "ValueError: list.remove(x): x not in list")
		return
	}
	dt.pop_child(doc, p, i)
}

// ``len(element)``.
length :: proc(doc: ^dt.Doc, n: dt.Node) -> int {
	return dt.child_count(doc, n)
}

// A snapshot of the children of ``p`` from index ``start`` on
// (``element[start:]``).
children_from :: proc(doc: ^dt.Doc, p: dt.Node, start: int) -> []dt.Node {
	all := dt.children(doc, p)
	return all[min(start, len(all)):]
}

// --- attributes ------------------------------------------------------------------

// Python truthiness of ``node.get(key)``.
attr_truthy :: proc(doc: ^dt.Doc, n: dt.Node, key: dt.Attr_Key) -> bool {
	v, ok := dt.get_attr(doc, n, key)
	if !ok do return false
	switch x in v {
	case string:
		return x != ""
	case int:
		return x != 0
	case bool:
		return x
	case dt.List:
		return len(dt.list_items(doc, x)) > 0
	case dt.Attr_None:
		return false
	}
	return false
}

// The first item of a list attribute (``node[key][0]``).
first_item :: proc(doc: ^dt.Doc, n: dt.Node, key: dt.Attr_Key) -> (dt.Str, bool) {
	items := dt.attr_list(doc, n, key)
	if len(items) == 0 do return 0, false
	return items[0], true
}

// ``str(node[key])``.
attr_text :: proc(doc: ^dt.Doc, n: dt.Node, key: dt.Attr_Key) -> string {
	v, _ := dt.get_attr(doc, n, key)
	b := strings.builder_make(context.temp_allocator)
	dt.write_py_str(&b, doc, v)
	return strings.to_string(b)
}

// ``element['classes'] += values``.
extend_classes :: proc(doc: ^dt.Doc, n: dt.Node, values: []string) {
	for v in values do dt.list_append(doc, n, dt.K_CLASSES, v)
}

// --- node internals -------------------------------------------------------------

// ``Element.note_referenced_by(name, id)``: mark ``n`` referenced, and the
// targets expecting a reference by that name or id.
note_referenced_by :: proc(doc: ^dt.Doc, n: dt.Node, name: dt.Str = 0, id: dt.Str = 0) {
	dt.set_flag(doc, n, .Referenced)
	ni, ok := doc.internals[n]
	if !ok do return
	if name != 0 {
		if by := expect_get(ni.expect_referenced_by_name[:], name); by != 0 {
			dt.set_flag(doc, by, .Referenced)
		}
	}
	if id != 0 {
		if by := expect_get(ni.expect_referenced_by_id[:], id); by != 0 {
			dt.set_flag(doc, by, .Referenced)
		}
	}
}

expect_get :: proc(m: []dt.Name_Ref, key: dt.Str) -> dt.Node {
	for e in m do if e.name == key do return e.node
	return 0
}

// ``d[key] = node`` of an ``expect_referenced_by_*`` dict.
expect_set :: proc(m: ^[dynamic]dt.Name_Ref, key: dt.Str, node: dt.Node) {
	for &e in m {
		if e.name == key {
			e.node = node
			return
		}
	}
	append(m, dt.Name_Ref{key, node})
}

// The internals of ``n``, created (empty maps) if missing.
ensure_internals :: proc(doc: ^dt.Doc, n: dt.Node) -> dt.Node_Internals {
	if ni, ok := doc.internals[n]; ok do return ni
	ni := dt.Node_Internals {
		expect_referenced_by_id   = make([dynamic]dt.Name_Ref, doc.allocator),
		expect_referenced_by_name = make([dynamic]dt.Name_Ref, doc.allocator),
	}
	doc.internals[n] = ni
	return ni
}

// --- messages and problematic references --------------------------------------------

// ``nodes.problematic(ref.rawsource, ref.rawsource, refid=msgid)`` with
// its id registered and noted as a backref of ``msg``.
new_problematic :: proc(doc: ^dt.Doc, ref: dt.Node, msg: dt.Node, msgid: dt.Str) -> dt.Node {
	raw := dt.text(doc, ref)
	prb := dt.new_element(doc, .problematic, raw, raw)
	dt.set_attr(doc, prb, dt.K_REFID, dt.str(doc, msgid))
	prbid := dt.set_id(doc, prb)
	dt.add_backref(doc, msg, prbid)
	return prb
}

// Replace ``ref`` by a problematic element linked to ``msg`` (whose id is
// set here).
report_problematic :: proc(doc: ^dt.Doc, ref: dt.Node, msg: dt.Node) {
	msgid := dt.set_id(doc, msg)
	dt.replace_self(doc, ref, new_problematic(doc, ref, msg, msgid))
}

// ``reporter.system_message(level, text, *children, line=line)``: an explicit
// ``line=None`` stays None (a ``line`` attribute of None) unless the reporter
// finds the line of the current input.
system_message_line :: proc(
	doc: ^dt.Doc,
	level: dt.Level,
	text: string,
	children: []dt.Node,
	line: Maybe(int),
) -> dt.Node {
	if _, ok := line.?; ok {
		return dt.system_message(doc, level, text, {children = children, line = line})
	}
	r := &doc.reporter
	src: Maybe(string)
	ln: Maybe(int)
	if r.source_and_line != nil do src, ln = r.source_and_line(doc, r.source_line_data, nil)
	if _, known := ln.?; known {
		opts := dt.Message_Options {
			children = children,
			line     = ln,
			source   = src.? or_else r.source,
		}
		return dt.system_message(doc, level, text, opts)
	}
	// build the message as ``Reporter.system_message`` does, with ``line=None``
	msg := dt.new_element(doc, .system_message)
	dt.append_child(doc, msg, dt.new_element(doc, .paragraph, "", text))
	dt.extend_children(doc, msg, children)
	dt.set_attr(doc, msg, dt.K_LINE, dt.Attr_None{})
	dt.set_attr(doc, msg, dt.K_LEVEL, int(level))
	dt.set_attr(doc, msg, dt.K_TYPE, dt.LEVEL_NAMES[level])
	dt.set_attr(doc, msg, dt.K_SOURCE, src.? or_else r.source)
	dt.report(doc, level, msg)
	return msg
}

// --- str ----------------------------------------------------------------------------

// ``str.strip()`` / ``lstrip()`` / ``rstrip()``: Unicode whitespace.
py_strip :: proc(s: string) -> string {
	return py_rstrip(py_lstrip(s))
}

py_lstrip :: proc(s: string) -> string {
	for r, i in s {
		if !dt.py_isspace(r) do return s[i:]
	}
	return ""
}

py_rstrip :: proc(s: string) -> string {
	end := len(s)
	for end > 0 {
		r, w := utf8.decode_last_rune_in_string(s[:end])
		if !dt.py_isspace(r) do break
		end -= w
	}
	return s[:end]
}

// ``len(s)`` (code points).
py_len :: proc(s: string) -> int {
	return utf8.rune_count_in_string(s)
}
