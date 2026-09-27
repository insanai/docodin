package doctree

import "core:slice"
import "core:strings"

// Text and pseudo-XML renderings: ``Node.astext()``, ``Element.starttag()``
// and ``Node.pformat()``.

// ``Node.astext()``.
astext :: proc(doc: ^Doc, n: Node, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	write_astext(&b, doc, n)
	return strings.to_string(b)
}

write_astext :: proc(b: ^strings.Builder, doc: ^Doc, n: Node) {
	e := doc.nodes[n]
	#partial switch e.tag {
	case .Text:
		strings.write_string(b, unescape(e.text))
		return
	case .image:
		// ``image.astext``: the ``alt`` attribute.
		if v, ok := get_attr(doc, n, K_ALT); ok do write_py_str(b, doc, v)
		return
	case .option_argument:
		// ``option_argument.astext``: delimiter + text.
		if v, ok := get_attr(doc, n, K_DELIMITER); ok {
			write_py_str(b, doc, v)
		} else {
			strings.write_byte(b, ' ')
		}
	case .system_message:
		write_message_head(b, doc, n)
	}
	sep := TAG_TEXT_SEPARATOR[e.tag]
	for c := e.first; c != 0; c = doc.nodes[c].next {
		if c != e.first do strings.write_string(b, sep)
		write_astext(b, doc, c)
	}
}

// ``'%s:%s: (%s/%s) ' % (source, line, type, level)`` of ``system_message.astext``.
@(private = "file")
write_message_head :: proc(b: ^strings.Builder, doc: ^Doc, n: Node) {
	keys := [?]Str{K_SOURCE, K_LINE, K_TYPE, K_LEVEL}
	seps := [?]string{":", ": (", "/", ") "}
	for k, i in keys {
		if v, ok := get_attr(doc, n, k); ok do write_py_str(b, doc, v)
		strings.write_string(b, seps[i])
	}
}

// ``Element.starttag()`` (with ``pseudo_quoteattr``).
starttag :: proc(doc: ^Doc, n: Node, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	write_starttag(&b, doc, n)
	return strings.to_string(b)
}

write_starttag :: proc(b: ^strings.Builder, doc: ^Doc, n: Node) {
	strings.write_byte(b, '<')
	strings.write_string(b, TAG_NAMES[doc.nodes[n].tag])
	for a in attlist(doc, n) {
		strings.write_byte(b, ' ')
		strings.write_string(b, a.key)
		strings.write_string(b, "=\"")
		write_attr_value(b, doc, a.value)
		strings.write_byte(b, '"')
	}
	strings.write_byte(b, '>')
}

// An attribute value as ``starttag`` formats it.
write_attr_value :: proc(b: ^strings.Builder, doc: ^Doc, value: Attr_Value) {
	switch v in value {
	case Attr_None:
		strings.write_string(b, "True")
	case bool:
		strings.write_byte(b, '1' if v else '0')
	case List:
		for s, i in doc.lists[v] {
			if i > 0 do strings.write_byte(b, ' ')
			strings.write_string(b, serial_escape(str(doc, s)))
		}
	case string:
		strings.write_string(b, v)
	case int:
		write_int(b, v)
	case:
		strings.write_string(b, "True")
	}
}

// ``Node.pformat(indent, level)``: the indented pseudo-XML of ``n``.
pformat :: proc(
	doc: ^Doc,
	n: Node,
	indent := "    ",
	level := 0,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	write_pformat(&b, doc, n, indent, level)
	return strings.to_string(b)
}

@(private = "file")
write_indent :: proc(b: ^strings.Builder, indent: string, level: int) {
	for _ in 0 ..< level do strings.write_string(b, indent)
}

write_pformat :: proc(b: ^strings.Builder, doc: ^Doc, n: Node, indent: string, level: int) {
	e := doc.nodes[n]
	if e.tag == .Text {
		write_text_pformat(b, doc, n, indent, level)
		return
	}
	write_indent(b, indent, level)
	write_starttag(b, doc, n)
	strings.write_byte(b, '\n')
	for c := e.first; c != 0; c = doc.nodes[c].next {
		write_pformat(b, doc, c, indent, level + 1)
	}
	if e.tag == .pending do write_pending_internals(b, doc, n, indent, level)
}

// ``Text.pformat``: the unescaped lines, or with the ``detailed`` setting
// a ``<#text>`` tag and the ``repr`` of each raw line.
@(private = "file")
write_text_pformat :: proc(b: ^strings.Builder, doc: ^Doc, n: Node, indent: string, level: int) {
	if doc.settings.detailed && in_document(doc, n) {
		write_indent(b, indent, level)
		strings.write_string(b, "<#text>")
		for l in py_splitlines(doc.nodes[n].text, true) {
			strings.write_byte(b, '\n')
			write_indent(b, indent, level + 1)
			write_py_repr(b, l)
		}
		strings.write_byte(b, '\n')
		return
	}
	for l in py_splitlines(astext(doc, n)) {
		write_indent(b, indent, level)
		strings.write_string(b, l)
		strings.write_byte(b, '\n')
	}
}

// The ``.. internal attributes:`` block of ``pending.pformat``.
@(private = "file")
write_pending_internals :: proc(
	b: ^strings.Builder,
	doc: ^Doc,
	n: Node,
	indent: string,
	level: int,
) {
	p := pending_of(doc, n)
	lines := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&lines, ".. internal attributes:")
	append(&lines, strings.concatenate({"     .transform: ", p.transform}, context.temp_allocator))
	append(&lines, "     .details:")
	details := slice.clone(p.details[:], context.temp_allocator)
	slice.sort_by(details, proc(a, b: Detail) -> bool {return a.key < b.key})
	for d in details do append_detail_lines(&lines, doc, d)
	for l in lines {
		strings.write_string(b, "    ")
		write_indent(b, indent, level)
		strings.write_string(b, l)
		strings.write_byte(b, '\n')
	}
}

@(private = "file")
append_detail_lines :: proc(lines: ^[dynamic]string, doc: ^Doc, d: Detail) {
	ta := context.temp_allocator
	nodes: []Node
	#partial switch v in d.value {
	case Node:
		nodes = {v}
	case []Node:
		nodes = v
	}
	if len(nodes) > 0 {
		append(lines, strings.concatenate({"       ", d.key, ":"}, ta))
		for v in nodes {
			for l in py_splitlines(pformat(doc, v, allocator = ta)) {
				append(lines, strings.concatenate({"         ", l}, ta))
			}
		}
		return
	}
	b := strings.builder_make(ta)
	strings.write_string(&b, "       ")
	strings.write_string(&b, d.key)
	strings.write_string(&b, ": ")
	write_detail_repr(&b, d.value)
	append(lines, strings.to_string(b))
}
