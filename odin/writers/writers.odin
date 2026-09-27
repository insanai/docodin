package writers

import "base:runtime"
import "core:mem/virtual"
import "core:strings"

import dt "../doctree"

// Ports of the docutils 0.22 writers (``docutils.writers``): pseudo-XML,
// Docutils XML, HTML5 (``html5_polyglot``), LaTeX (``latex2e``) and XeLaTeX
// (``xetex``).  ``write`` translates a transformed document into the
// writer's output and its ``publish_parts`` parts, byte for byte as docutils
// does.
//
// Each translator walks the document with ``walkabout`` and dispatches on the
// node's tag through ``[doctree.Tag]`` tables of visit and depart procedures.
// Output goes to ``Out`` collectors: one buffer per document part, whose
// chunks stand for the items of docutils' part lists.

Writer_Name :: enum u8 {
	Pseudoxml,
	Xml,
	Html5,
	Latex,
	Xetex,
}

// A ``publish_parts`` part.
Part :: struct {
	name:  string,
	value: string,
}

// The parts of a writer's output, in docutils' insertion order.
Parts :: struct {
	items: []Part,
}

// The value of part ``name``.
part :: proc(parts: Parts, name: string) -> (string, bool) {
	for p in parts.items {
		if p.name == name do return p.value, true
	}
	return "", false
}

// The writer of a docutils writer name or alias (``get_writer_class``).
writer_by_name :: proc(name: string) -> (Writer_Name, bool) {
	switch strings.to_lower(name, context.temp_allocator) {
	case "pseudoxml", "pprint", "pformat":
		return .Pseudoxml, true
	case "xml", "docutils_xml":
		return .Xml, true
	case "html5", "html5_polyglot", "xhtml":
		return .Html5, true
	case "latex", "latex2e":
		return .Latex, true
	case "xetex", "xelatex", "luatex", "lualatex":
		return .Xetex, true
	}
	return .Pseudoxml, false
}

DOCUTILS_VERSION :: "0.22.4"

// Translate ``doc`` with ``writer``.  ``err`` is set where docutils raises
// (for example ``NotImplementedError`` of an unsupported construct); the
// document may be changed by the translator, as in docutils.  Output and
// parts are allocated with ``allocator``.
write :: proc(
	doc: ^dt.Doc,
	writer: Writer_Name,
	settings: Settings,
	allocator := context.allocator,
) -> (
	output: string,
	parts: Parts,
	err: string,
) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do panic("writers: cannot reserve arena")
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)
	context.allocator = scratch
	context.temp_allocator = scratch
	res: Result
	switch writer {
	case .Pseudoxml:
		res = write_pseudoxml(doc, settings, scratch)
	case .Xml:
		res = write_xml(doc, settings, scratch)
	case .Html5:
		res = write_html5(doc, settings, scratch)
	case .Latex, .Xetex:
		res = write_latex(doc, settings, writer == .Xetex, scratch)
	}
	if res.err == "" {
		s := settings
		res.output, res.err = encode_output(res.output, &s)
	}
	return clone_result(res, allocator)
}

// The output as ``Output.write`` encodes it with ``output_encoding`` and
// ``output_encoding_error_handler`` (and the caller decodes it again): for
// 8-bit codecs, characters out of range become character references with
// "xmlcharrefreplace" and fail with "strict".
encode_output :: proc(output: string, s: ^Settings) -> (string, string) {
	limit := codec_limit(s.output_encoding)
	switch limit {
	case 0:
		return output, strings.concatenate({"LookupError: unknown encoding: ", s.output_encoding})
	case max(rune):
		return output, ""
	}
	b: strings.Builder
	for r, i in output {
		if r <= limit {
			if strings.builder_len(b) > 0 do strings.write_rune(&b, r)
			continue
		}
		if s.output_encoding_error_handler != "xmlcharrefreplace" {
			return output, "UnicodeEncodeError: character maps to <undefined>"
		}
		if strings.builder_len(b) == 0 {
			b = strings.builder_make()
			strings.write_string(&b, output[:i])
		}
		strings.write_string(&b, "&#")
		strings.write_int(&b, int(r))
		strings.write_byte(&b, ';')
	}
	if strings.builder_len(b) == 0 do return output, ""
	return strings.to_string(b), ""
}

// The largest code point of a codec (``max(rune)`` for Unicode codecs, 0
// for an unsupported codec).
@(private = "file")
codec_limit :: proc(encoding: string) -> rune {
	name, _ := strings.replace_all(strings.to_lower(encoding), "_", "-")
	switch name {
	case "", "unicode", "utf-8", "utf8", "u8", "utf", "utf-8-sig":
		return max(rune)
	case "utf-16", "utf-32", "utf-16-le", "utf-16-be", "utf-32-le", "utf-32-be":
		return max(rune)
	case "ascii", "us-ascii", "646":
		return 0x7F
	case "latin-1", "latin1", "iso-8859-1", "iso8859-1", "l1", "8859", "cp819", "latin":
		return 0xFF
	}
	return 0
}

// A translator's result (in its scratch arena).
Result :: struct {
	output: string,
	parts:  [dynamic]Part,
	err:    string,
}

@(private = "file")
clone_result :: proc(res: Result, allocator: runtime.Allocator) -> (string, Parts, string) {
	items := make([]Part, len(res.parts), allocator)
	for p, i in res.parts {
		items[i] = Part{strings.clone(p.name, allocator), strings.clone(p.value, allocator)}
	}
	output := strings.clone(res.output, allocator)
	err := strings.clone(res.err, allocator) if res.err != "" else ""
	return output, Parts{items}, err
}

// ``Writer.assemble_parts``: whole, encoding, errors and version.
base_parts :: proc(res: ^Result, s: ^Settings, allocator: runtime.Allocator) {
	res.parts = make([dynamic]Part, 0, 32, allocator)
	append(&res.parts, Part{"whole", res.output})
	append(&res.parts, Part{"encoding", s.output_encoding})
	append(&res.parts, Part{"errors", s.output_encoding_error_handler})
	append(&res.parts, Part{"version", DOCUTILS_VERSION})
}

// --- walkabout ----------------------------------------------------------------------------

// What a visit procedure lets the walk do next (docutils' ``SkipNode``,
// ``SkipChildren`` and ``SkipDeparture`` exceptions).
Visit :: enum u8 {
	Continue,
	Skip_Node,
	Skip_Children,
	Skip_Departure,
}

// The dispatch tables of a translator of type ``T``.
Dispatch :: struct($T: typeid) {
	visit:  [dt.Tag]proc(t: ^T, n: dt.Node) -> Visit,
	depart: [dt.Tag]proc(t: ^T, n: dt.Node),
	// the docutils method names, for the debug messages
	names:  ^[dt.Tag][2]string,
}

// ``Node.walkabout(visitor)``.  A translator stops the walk by setting its
// ``err`` (docutils raises).
walkabout :: proc(t: ^$T, d: ^Dispatch(T), n: dt.Node) {
	if t.err != "" do return
	tag := dt.tag(t.doc, n)
	debug_dispatch(t.doc, d.names, tag, "visit")
	visit := d.visit[tag]
	if visit == nil {
		unimplemented_visit(t, n)
		return
	}
	res := visit(t, n)
	if t.err != "" || res == .Skip_Node do return
	if res != .Skip_Children {
		for c := dt.first_child(t.doc, n); c != 0; {
			nxt := dt.next_sibling(t.doc, c)
			walkabout(t, d, c)
			if t.err != "" do return
			c = nxt
		}
	}
	if res != .Skip_Departure {
		debug_dispatch(t.doc, d.names, tag, "departure")
		if depart := d.depart[tag]; depart != nil do depart(t, n)
	}
}

// With the ``debug`` setting: the messages of ``Node.walkabout`` and
// ``NodeVisitor.dispatch_visit`` / ``dispatch_departure``.
debug_dispatch :: proc(doc: ^dt.Doc, names: ^[dt.Tag][2]string, tag: dt.Tag, what: string) {
	if !doc.reporter.debug_flag || names == nil do return
	class := "Text" if tag == .Text else dt.TAG_NAMES[tag]
	method := names[tag][0] if what == "visit" else names[tag][1]
	dt.debug(doc, cat("docutils.nodes.Node.walkabout calling dispatch_", what, " for ", class))
	dt.debug(doc, cat("docutils.nodes.NodeVisitor.dispatch_", what, " calling ", method, " for ",
		class))
}

// ``NodeVisitor.unknown_visit`` / ``unimplemented_visit``.
unimplemented_visit :: proc(t: ^$T, n: dt.Node) {
	t.err = strings.concatenate(
		{"NotImplementedError: visiting unimplemented node type: ", dt.tagname(t.doc, n)},
		context.temp_allocator,
	)
}

// Visit procedures shared by the tables.
visit_pass :: proc(t: ^$T, n: dt.Node) -> Visit {
	return .Continue
}

visit_skip :: proc(t: ^$T, n: dt.Node) -> Visit {
	return .Skip_Node
}

// ``"".join(parts)`` in the temp allocator.
cat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts, context.temp_allocator)
}

// --- node helpers -------------------------------------------------------------------------

// ``key in node``.
has :: proc(doc: ^dt.Doc, n: dt.Node, key: string) -> bool {
	return dt.has_attr(doc, n, key)
}

// ``node.get(key, "")`` of a string attribute.
attr :: proc(doc: ^dt.Doc, n: dt.Node, key: string, default := "") -> string {
	return dt.get_string(doc, n, key, default)
}

// The items of a list attribute as strings.
list_strings :: proc(doc: ^dt.Doc, n: dt.Node, key: dt.Attr_Key) -> []string {
	items := dt.attr_list(doc, n, key)
	out := make([]string, len(items), context.temp_allocator)
	for s, i in items do out[i] = dt.str(doc, s)
	return out
}

has_class :: proc(doc: ^dt.Doc, n: dt.Node, class: string) -> bool {
	return n != 0 && dt.list_contains(doc, n, dt.K_CLASSES, class)
}

// ``isinstance(node.parent, tags)``.
parent_is :: proc(doc: ^dt.Doc, n: dt.Node, tags: dt.Tag_Set) -> bool {
	return dt.is(doc, dt.parent(doc, n), tags)
}

// ``isinstance(node.parent, nodes.TextElement)``.
in_text_element :: proc(doc: ^dt.Doc, n: dt.Node) -> bool {
	return dt.is_a(doc, dt.parent(doc, n), .TextElement)
}

// ``node.astext()`` (in the temp allocator).
astext :: proc(doc: ^dt.Doc, n: dt.Node) -> string {
	return dt.astext(doc, n, context.temp_allocator)
}

// The value of an attribute as ``str(value)``.
attr_text :: proc(doc: ^dt.Doc, v: dt.Attr_Value) -> string {
	b := strings.builder_make(context.temp_allocator)
	switch x in v {
	case string:
		return x
	case int:
		strings.write_int(&b, x)
	case bool:
		strings.write_string(&b, "True" if x else "False")
	case dt.List:
		for s, i in dt.list_items(doc, x) {
			if i > 0 do strings.write_byte(&b, ' ')
			strings.write_string(&b, dt.str(doc, s))
		}
	case dt.Attr_None:
		strings.write_string(&b, "None")
	}
	return strings.to_string(b)
}

// ``document.nameids[refname]``; false for a missing name or None.
nameid :: proc(doc: ^dt.Doc, refname: string) -> (string, bool) {
	key, found := dt.lookup(doc, refname)
	if !found do return "", false
	id, ok := dt.om_get(&doc.nameids, key)
	if !ok || id == 0 do return "", false
	return dt.str(doc, id), true
}

// ``bool(value)`` of an attribute value.
attr_truthy :: proc(doc: ^dt.Doc, v: dt.Attr_Value) -> bool {
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
