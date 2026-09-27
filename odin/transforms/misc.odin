package transforms

import "core:fmt"
import "core:strings"

import dt "../doctree"

// ``docutils.transforms.misc``, ``components`` and ``writer_aux``.

// --- pending details ------------------------------------------------------------

detail_string :: proc(doc: ^dt.Doc, pending: dt.Node, key: string) -> (string, bool) {
	v, ok := dt.get_detail(doc, pending, key)
	s, is_str := v.(string)
	return s, ok && is_str
}

detail_strings :: proc(doc: ^dt.Doc, pending: dt.Node, key: string) -> []string {
	v, _ := dt.get_detail(doc, pending, key)
	#partial switch x in v {
	case []string:
		return x
	case string:
		out := make([]string, 1, context.temp_allocator)
		out[0] = x
		return out
	}
	return nil
}

detail_int :: proc(doc: ^dt.Doc, pending: dt.Node, key: string) -> (int, bool) {
	v, _ := dt.get_detail(doc, pending, key)
	i, ok := v.(int)
	return i, ok
}

// The nodes of a detail (a node or a list of nodes).
detail_nodes :: proc(doc: ^dt.Doc, pending: dt.Node, key: string) -> []dt.Node {
	v, _ := dt.get_detail(doc, pending, key)
	#partial switch x in v {
	case dt.Node:
		out := make([]dt.Node, 1, context.temp_allocator)
		out[0] = x
		return out
	case []dt.Node:
		return x
	}
	return nil
}

// --- ClassAttribute ---------------------------------------------------------------

// ``ClassAttribute``: the classes of the "class" directive go to the next
// element that is not invisible, else an error replaces the pending node.
class_attribute :: proc(r: ^Run, pending: dt.Node, _: []dt.Detail) {
	doc := r.doc
	classes := detail_strings(doc, pending, "class")
	it := dt.findall(
		doc,
		pending,
		include_self = false,
		descend = false,
		siblings = true,
		ascend = true,
	)
	for el in dt.next(&it) {
		if dt.is_a(doc, el, .Invisible) || dt.tag(doc, el) == .system_message do continue
		if dt.tag(doc, el) == .Text {
			fail(r, "TypeError: string indices must be integers, not 'str'")
			return
		}
		extend_classes(doc, el, classes)
		py_remove(r, pending)
		return
	}
	directive, _ := detail_string(doc, pending, "directive")
	raw := dt.text(doc, pending)
	block := dt.new_element(doc, .literal_block, raw, raw)
	text := fmt.tprintf(`No suitable element following "%s" directive`, directive)
	line, has_line := dt.line(doc, pending)
	msg := system_message_line(doc, .ERROR, text, {block}, line if has_line else nil)
	py_replace_self(r, pending, msg)
}

// --- Transitions -------------------------------------------------------------------

@(private = "file")
SECTIONING :: dt.Tag_Set{.document, .section}

// ``Transitions``: warn about misplaced transitions and move a transition
// at the end of a section after the section.
transitions :: proc(r: ^Run, _: dt.Node, _: []dt.Detail) {
	doc := r.doc
	it := dt.findall(doc, doc.root, dt.Tag_Set{.transition})
	for n in dt.next(&it) do visit_transition(doc, n)
}

@(private = "file")
transition_problem :: proc(doc: ^dt.Doc, n: dt.Node, index: int) -> string {
	prev := dt.prev_sibling(doc, n)
	switch {
	case !dt.is(doc, dt.parent(doc, n), SECTIONING):
		return "Transition must be child of <document> or <section>."
	case index == 0 || dt.is(doc, prev, {.title, .subtitle, .meta, .decoration}):
		return "Document or section may not begin with a transition."
	case dt.is(doc, prev, {.transition}):
		return "At least one body element must separate transitions; " +
			"adjacent transitions are not allowed."
	}
	return ""
}

@(private = "file")
visit_transition :: proc(doc: ^dt.Doc, n: dt.Node) {
	p := dt.parent(doc, n)
	index := dt.index_identity(doc, p, n)
	if msg := transition_problem(doc, n, index); msg != "" {
		warning := dt.warning(doc, msg, {base_node = n})
		// Is it valid to insert a body element here?
		set_child_at(doc, p, index, dt.new_element(doc, .paragraph))
		ok, _, _ := dt.validate(doc, p, recursive = false)
		set_child_at(doc, p, index, n)
		if ok {
			dt.insert_child(doc, p, index + 1, warning)
			index += 1
		}
	}
	if !dt.is(doc, p, SECTIONING) || index != length(doc, p) - 1 do return
	sibling := n
	for index == length(doc, dt.parent(doc, sibling)) - 1 {
		sibling = dt.parent(doc, sibling)
		if dt.parent(doc, sibling) == 0 {
			warning := dt.warning(doc, "Document may not end with a transition.", {base_node = n})
			dt.append_child(doc, dt.parent(doc, n), warning)
			return
		}
		index = dt.index_identity(doc, dt.parent(doc, sibling), sibling)
	}
	remove_identity(doc, dt.parent(doc, n), n)
	dt.insert_child(doc, dt.parent(doc, sibling), index + 1, n)
}

// --- CallBack -------------------------------------------------------------------

// ``CallBack``: call ``details['callback'](pending)`` and remove the pending
// element.  Callbacks are named: the native pipeline has only the PEP
// reader's.
call_back :: proc(r: ^Run, pending: dt.Node, _: []dt.Detail) {
	doc := r.doc
	name, _ := detail_string(doc, pending, "callback")
	switch name {
	case PEP_CLEANUP_CALLBACK:
		pep_cleanup_callback(r, pending)
	case:
		fail(r, "unknown callback %q", name)
		return
	}
	py_remove(r, pending)
}

// --- components.Filter ----------------------------------------------------------

// ``Filter``: keep the pending element's nodes if the component
// (``details['component']``) supports one of the formats of
// ``details['format']``, else drop them.
filter :: proc(r: ^Run, pending: dt.Node, _: []dt.Detail) {
	doc := r.doc
	component, _ := detail_string(doc, pending, "component")
	formats, _ := detail_string(doc, pending, "format")
	supported: []string
	switch component {
	case "reader":
		supported = READER_SUPPORTED[r.options.reader]
	case "parser":
		supported = PARSER_SUPPORTED
	case "writer":
		supported = WRITER_SUPPORTED[r.options.writer]
	case:
		key_error(r, component)
		return
	}
	for f in strings.split(formats, ",", context.temp_allocator) {
		for s in supported {
			if s != f do continue
			py_replace_self(r, pending, ..detail_nodes(doc, pending, "nodes"))
			return
		}
	}
	py_remove(r, pending)
}

// --- writer_aux.Admonitions ----------------------------------------------------------

@(private = "file")
ADMONITION_LABELS := #partial [dt.Tag]Label {
	.attention = .attention,
	.caution   = .caution,
	.danger    = .danger,
	.error     = .error,
	.hint      = .hint,
	.important = .important,
	.note      = .note,
	.tip       = .tip,
	.warning   = .warning,
}

// ``Admonitions``: specific admonitions become generic ones with a
// (localized) title; every admonition gets its class name as a class.
admonitions :: proc(r: ^Run, _: dt.Node, _: []dt.Detail) {
	visit_admonitions(r, r.doc.root)
}

// ``findall(nodes.Admonition)``: a replaced admonition's children are
// walked as its old child list (which docutils' generator still iterates).
@(private = "file")
visit_admonitions :: proc(r: ^Run, n: dt.Node) {
	doc := r.doc
	kids := dt.children(doc, n)
	if dt.is_a(doc, n, .Admonition) {
		dt.list_append(doc, n, dt.K_CLASSES, dt.tagname(doc, n))
		if dt.tag(doc, n) != .admonition do generic_admonition(r, n, kids)
	}
	for c in kids do visit_admonitions(r, c)
}

@(private = "file")
generic_admonition :: proc(r: ^Run, n: dt.Node, kids: []dt.Node) {
	doc := r.doc
	adm := dt.new_element(doc, .admonition, dt.text(doc, n))
	dt.extend_children(doc, adm, kids)
	for a in dt.attributes(doc, n) {
		v := a.value
		if l, is_list := v.(dt.List); is_list {
			items := dt.list_items(doc, l)
			copy := dt.new_list(doc)
			for x in items do append(&doc.lists[copy], x)
			v = copy
		}
		dt.set_attr(doc, adm, a.key, v)
	}
	label := language(r).labels[ADMONITION_LABELS[dt.tag(doc, n)]]
	dt.insert_child(doc, adm, 0, dt.new_element(doc, .title, "", label))
	dt.replace_self(doc, n, adm)
}
