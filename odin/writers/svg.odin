package writers

import "core:strconv"
import "core:strings"

import dt "../doctree"

// Embedded SVG images of the HTML5 writer: ``merge_svg_attributes`` parses
// the SVG code as ``xml.etree.ElementTree.fromstring`` does, sets the image
// attributes on the root element and serializes the tree as
// ``ElementTree.tostring(svg, encoding="unicode")``.  Comments, processing
// instructions, the XML declaration and the document type are dropped.

SVG_NS :: "http://www.w3.org/2000/svg"
XLINK_NS :: "http://www.w3.org/1999/xlink"
XML_NS :: "http://www.w3.org/XML/1998/namespace"

// ``ElementTree._namespace_map`` after ``register_namespace`` of the SVG
// namespaces ("" for SVG, "xlink").
@(private = "file")
NAMESPACE_PREFIXES := [?][2]string {
	{XML_NS, "xml"},
	{"http://www.w3.org/1999/xhtml", "html"},
	{"http://www.w3.org/1999/02/22-rdf-syntax-ns#", "rdf"},
	{"http://schemas.xmlsoap.org/wsdl/", "wsdl"},
	{"http://www.w3.org/2001/XMLSchema", "xs"},
	{"http://www.w3.org/2001/XMLSchema-instance", "xsi"},
	{"http://purl.org/dc/elements/1.1/", "dc"},
	{SVG_NS, ""},
	{XLINK_NS, "xlink"},
}

@(private = "file")
Xml_Attr :: struct {
	key:   string, // "{uri}local" or "local"
	value: string,
}

@(private = "file")
Xml_Elem :: struct {
	tag:      string, // "{uri}local" or "local"
	attrs:    [dynamic]Xml_Attr,
	text:     strings.Builder,
	tail:     strings.Builder,
	children: [dynamic]int,
}

@(private = "file")
Xml_Tree :: struct {
	elems: [dynamic]Xml_Elem,
}

@(private = "file")
Xml_Parser :: struct {
	src:    string,
	pos:    int,
	tree:   ^Xml_Tree,
	scopes: [dynamic]map[string]string, // prefix to namespace URI
	err:    string,
}

// ``merge_svg_attributes`` (``prepare_svg``): the SVG element with the
// attributes of the image; on a parse error the code as is and an error.
prepare_svg :: proc(t: ^Html, code: string, n: dt.Node, atts: []Att, classes: []string) -> string {
	tree: Xml_Tree
	root, err := parse_xml(&tree, code)
	if err != "" {
		uri := attr(t.doc, n, "uri")
		msg := cat("Cannot parse SVG image \"", uri, "\":\n  ", err)
		append(&t.messages, dt.error(t.doc, msg, {base_node = n}))
		return code
	}
	merge_svg(t, &tree, root, n, atts, classes)
	b := strings.builder_make(context.temp_allocator)
	serialize_svg(&b, &tree, root)
	return strings.to_string(b)
}

@(private = "file")
elem_get :: proc(e: ^Xml_Elem, key: string) -> (string, bool) {
	for a in e.attrs do if a.key == key do return a.value, true
	return "", false
}

@(private = "file")
elem_set :: proc(e: ^Xml_Elem, key, value: string) {
	for &a in e.attrs {
		if a.key == key {
			a.value = value
			return
		}
	}
	append(&e.attrs, Xml_Attr{key, value})
}

@(private = "file")
merge_svg :: proc(
	t: ^Html,
	tree: ^Xml_Tree,
	root: int,
	n: dt.Node,
	atts: []Att,
	classes: []string,
) {
	svg := &tree.elems[root]
	for a in atts {
		if a.name == "style" do merge_style(svg, a.value)
	}
	for dim in ([?]string{"width", "height"}) {
		for a in atts do if a.name == dim do elem_set(svg, dim, a.value)
	}
	node_classes := list_strings(t.doc, n, dt.K_CLASSES)
	if classes != nil || len(node_classes) > 0 {
		old, _ := elem_get(svg, "class")
		list := make([dynamic]string, 0, 8, context.temp_allocator)
		rest := old
		for c in strings.fields_iterator(&rest) do append(&list, c)
		append(&list, ..node_classes)
		append(&list, ..classes)
		elem_set(svg, "class", strings.join(list[:], " ", context.temp_allocator))
	}
	alt, has_alt := dt.get_attr(t.doc, n, dt.K_ALT)
	if !has_alt || has_title(tree, root) do return
	append(&tree.elems, Xml_Elem{tag = "title"})
	title := &tree.elems[len(tree.elems) - 1]
	strings.write_string(&title.text, attr_text(t.doc, alt))
	inject_at(&tree.elems[root].children, 0, len(tree.elems) - 1)
}

// ``svg.find("title", SVG_NS)``: a direct ``title`` child in the SVG namespace.
@(private = "file")
has_title :: proc(tree: ^Xml_Tree, root: int) -> bool {
	for c in tree.elems[root].children {
		if tree.elems[c].tag == "{" + SVG_NS + "}title" do return true
	}
	return false
}

// The style declarations of the SVG root updated with those of ``style``.
@(private = "file")
merge_style :: proc(svg: ^Xml_Elem, style: string) {
	keys := make([dynamic]string, 0, 8, context.temp_allocator)
	values := make([dynamic]string, 0, 8, context.temp_allocator)
	old, _ := elem_get(svg, "style")
	for source in ([?]string{old, style}) {
		rest := source
		for decl in strings.split_iterator(&rest, ";") {
			if strings.trim_space(decl) == "" do continue
			key, _, value := strings.partition(decl, ":")
			key, value = strings.trim_space(key), strings.trim_space(value)
			found := false
			for k, i in keys {
				if k == key {
					values[i] = value
					found = true
				}
			}
			if !found {
				append(&keys, key)
				append(&values, value)
			}
		}
	}
	b := strings.builder_make(context.temp_allocator)
	for k, i in keys {
		if i > 0 do strings.write_byte(&b, ' ')
		strings.write_string(&b, k)
		strings.write_string(&b, ": ")
		strings.write_string(&b, values[i])
		strings.write_byte(&b, ';')
	}
	elem_set(svg, "style", strings.to_string(b))
}

// --- parsing ---------------------------------------------------------------------------------

@(private = "file")
parse_xml :: proc(tree: ^Xml_Tree, src: string) -> (root: int, err: string) {
	p := Xml_Parser {
		src    = src,
		tree   = tree,
		scopes = make([dynamic]map[string]string, 0, 16, context.temp_allocator),
	}
	tree.elems = make([dynamic]Xml_Elem, 0, 64, context.temp_allocator)
	skip_misc(&p)
	if p.err != "" do return -1, p.err
	if !at(&p, "<") do return -1, "no element found"
	root = parse_element(&p)
	if p.err != "" do return -1, p.err
	skip_misc(&p)
	if p.err == "" && p.pos < len(p.src) do p.err = "junk after document element"
	return root, p.err
}

@(private = "file")
at :: proc(p: ^Xml_Parser, s: string) -> bool {
	return strings.has_prefix(p.src[p.pos:], s)
}

// Skip white space, comments, processing instructions and the document type.
@(private = "file")
skip_misc :: proc(p: ^Xml_Parser) {
	for p.pos < len(p.src) && p.err == "" {
		switch {
		case strings.index_byte(" \t\r\n", p.src[p.pos]) >= 0:
			p.pos += 1
		case at(p, "<!--"):
			skip_to(p, "-->")
		case at(p, "<?"):
			skip_to(p, "?>")
		case at(p, "<!DOCTYPE"):
			skip_doctype(p)
		case:
			return
		}
	}
}

@(private = "file")
skip_to :: proc(p: ^Xml_Parser, end: string) {
	i := strings.index(p.src[p.pos:], end)
	if i < 0 {
		p.err = "unclosed token"
		return
	}
	p.pos += i + len(end)
}

@(private = "file")
skip_doctype :: proc(p: ^Xml_Parser) {
	depth := 0
	for p.pos < len(p.src) {
		c := p.src[p.pos]
		p.pos += 1
		switch c {
		case '[':
			depth += 1
		case ']':
			depth -= 1
		case '>':
			if depth == 0 do return
		}
	}
	p.err = "unclosed token"
}

@(private = "file")
is_name_char :: proc(c: u8) -> bool {
	letter := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
	return c >= 0x80 || letter || (c >= '0' && c <= '9') || strings.index_byte("_:-.", c) >= 0
}

@(private = "file")
parse_name :: proc(p: ^Xml_Parser) -> string {
	start := p.pos
	for p.pos < len(p.src) && is_name_char(p.src[p.pos]) do p.pos += 1
	if p.pos == start do p.err = "not well-formed (invalid token)"
	return p.src[start:p.pos]
}

@(private = "file")
skip_space :: proc(p: ^Xml_Parser) {
	for p.pos < len(p.src) && strings.index_byte(" \t\r\n", p.src[p.pos]) >= 0 do p.pos += 1
}

// Parse an element at ``<``; returns its index.
@(private = "file")
parse_element :: proc(p: ^Xml_Parser) -> int {
	p.pos += 1
	name := parse_name(p)
	raw := make([dynamic]Xml_Attr, 0, 8, context.temp_allocator)
	empty := parse_attributes(p, &raw)
	if p.err != "" do return -1
	scope := make(map[string]string, 4, context.temp_allocator)
	if len(p.scopes) > 0 do for k, v in p.scopes[len(p.scopes) - 1] do scope[k] = v
	for a in raw {
		if a.key == "xmlns" do scope[""] = a.value
		if strings.has_prefix(a.key, "xmlns:") do scope[a.key[6:]] = a.value
	}
	append(&p.scopes, scope)
	defer pop(&p.scopes)
	idx := len(p.tree.elems)
	append(&p.tree.elems, Xml_Elem{tag = qualify(p, name, true)})
	for a in raw {
		if a.key == "xmlns" || strings.has_prefix(a.key, "xmlns:") do continue
		append(&p.tree.elems[idx].attrs, Xml_Attr{qualify(p, a.key, false), a.value})
	}
	if !empty do parse_content(p, idx, name)
	return idx
}

// Attributes up to ``>`` or ``/>``; true for an empty element.
@(private = "file")
parse_attributes :: proc(p: ^Xml_Parser, raw: ^[dynamic]Xml_Attr) -> bool {
	for p.err == "" {
		skip_space(p)
		switch {
		case at(p, "/>"):
			p.pos += 2
			return true
		case at(p, ">"):
			p.pos += 1
			return false
		case p.pos >= len(p.src):
			p.err = "unclosed token"
			return false
		}
		key := parse_name(p)
		skip_space(p)
		if !at(p, "=") {
			p.err = "not well-formed (invalid token)"
			return false
		}
		p.pos += 1
		skip_space(p)
		append(raw, Xml_Attr{key, parse_attr_value(p)})
	}
	return false
}

@(private = "file")
parse_attr_value :: proc(p: ^Xml_Parser) -> string {
	if p.pos >= len(p.src) || (p.src[p.pos] != '"' && p.src[p.pos] != '\'') {
		p.err = "not well-formed (invalid token)"
		return ""
	}
	q := p.src[p.pos]
	p.pos += 1
	end := strings.index_byte(p.src[p.pos:], q)
	if end < 0 {
		p.err = "unclosed token"
		return ""
	}
	raw := p.src[p.pos:p.pos + end]
	p.pos += end + 1
	b := strings.builder_make(context.temp_allocator)
	decode_chars(p, &b, raw, true)
	return strings.to_string(b)
}

// Expand references; in attribute values white space becomes a space.
@(private = "file")
decode_chars :: proc(p: ^Xml_Parser, b: ^strings.Builder, raw: string, attribute: bool) {
	for i := 0; i < len(raw); i += 1 {
		c := raw[i]
		switch {
		case c == '&':
			end := strings.index_byte(raw[i:], ';')
			if end < 0 {
				p.err = "not well-formed (invalid token)"
				return
			}
			if !write_reference(b, raw[i + 1:i + end]) {
				p.err = "undefined entity"
				return
			}
			i += end
		case c == '\r':
			if i + 1 < len(raw) && raw[i + 1] == '\n' do i += 1
			strings.write_byte(b, ' ' if attribute else '\n')
		case attribute && (c == '\n' || c == '\t'):
			strings.write_byte(b, ' ')
		case c == '<' && attribute:
			p.err = "not well-formed (invalid token)"
			return
		case:
			strings.write_byte(b, c)
		}
	}
}

@(private = "file")
write_reference :: proc(b: ^strings.Builder, name: string) -> bool {
	switch name {
	case "lt":
		strings.write_byte(b, '<')
	case "gt":
		strings.write_byte(b, '>')
	case "amp":
		strings.write_byte(b, '&')
	case "quot":
		strings.write_byte(b, '"')
	case "apos":
		strings.write_byte(b, '\'')
	case:
		if !strings.has_prefix(name, "#") do return false
		hex := strings.has_prefix(name, "#x")
		code, ok := strconv.parse_int(name[2:] if hex else name[1:], 16 if hex else 10)
		if !ok || code <= 0 || code > 0x10FFFF do return false
		strings.write_rune(b, rune(code))
	}
	return true
}

// ``{uri}local`` of a qualified name.
@(private = "file")
qualify :: proc(p: ^Xml_Parser, name: string, is_element: bool) -> string {
	prefix, _, local := strings.partition(name, ":")
	if local == "" {
		local = prefix
		prefix = ""
		if !is_element do return name
	}
	uri: string
	switch prefix {
	case "xml":
		uri = XML_NS
	case:
		found: bool
		uri, found = p.scopes[len(p.scopes) - 1][prefix]
		if !found {
			if prefix != "" do p.err = "unbound prefix"
			return local
		}
	}
	if uri == "" do return local
	return cat("{", uri, "}", local)
}

// Character data and child elements up to ``</name>``.
@(private = "file")
parse_content :: proc(p: ^Xml_Parser, idx: int, name: string) {
	target := &p.tree.elems[idx].text
	for p.err == "" {
		if p.pos >= len(p.src) {
			p.err = "no element found"
			return
		}
		switch {
		case at(p, "</"):
			p.pos += 2
			if parse_name(p) != name do p.err = "mismatched tag"
			skip_space(p)
			if p.err == "" && !at(p, ">") do p.err = "not well-formed (invalid token)"
			p.pos += 1
			return
		case at(p, "<!--"):
			skip_to(p, "-->")
		case at(p, "<?"):
			skip_to(p, "?>")
		case at(p, "<![CDATA["):
			p.pos += 9
			end := strings.index(p.src[p.pos:], "]]>")
			if end < 0 {
				p.err = "unclosed CDATA section"
				return
			}
			strings.write_string(target, p.src[p.pos:p.pos + end])
			p.pos += end + 3
		case at(p, "<"):
			child := parse_element(p)
			if p.err != "" do return
			append(&p.tree.elems[idx].children, child)
			target = &p.tree.elems[child].tail
		case:
			end := strings.index_byte(p.src[p.pos:], '<')
			if end < 0 do end = len(p.src) - p.pos
			decode_chars(p, target, p.src[p.pos:p.pos + end], false)
			p.pos += end
		}
	}
}

// --- serialization ---------------------------------------------------------------------------

@(private = "file")
Qnames :: struct {
	names:      map[string]string, // "{uri}local" to "prefix:local"
	namespaces: [dynamic][2]string, // (uri, prefix) declared at the root
}

@(private = "file")
namespace_prefix :: proc(uri: string) -> (string, bool) {
	for m in NAMESPACE_PREFIXES do if m[0] == uri do return m[1], true
	return "", false
}

// ``ElementTree._namespaces``: the qualified names and the namespaces.
@(private = "file")
collect_qnames :: proc(q: ^Qnames, tree: ^Xml_Tree, idx: int) {
	add_qname(q, tree.elems[idx].tag)
	for a in tree.elems[idx].attrs do add_qname(q, a.key)
	for c in tree.elems[idx].children do collect_qnames(q, tree, c)
}

@(private = "file")
add_qname :: proc(q: ^Qnames, qname: string) {
	if qname in q.names do return
	if !strings.has_prefix(qname, "{") {
		q.names[qname] = qname
		return
	}
	end := strings.index_byte(qname, '}')
	uri, local := qname[1:end], qname[end + 1:]
	prefix, known := namespace_prefix(uri)
	if !known {
		prefix = ""
		for ns in q.namespaces do if ns[0] == uri do prefix = ns[1]
		if prefix == "" do prefix = cat("ns", int_str(len(q.namespaces)))
	}
	if prefix != "xml" && !declared(q, uri) do append(&q.namespaces, [2]string{uri, prefix})
	q.names[qname] = cat(prefix, ":", local) if prefix != "" else local
}

@(private = "file")
declared :: proc(q: ^Qnames, uri: string) -> bool {
	for ns in q.namespaces do if ns[0] == uri do return true
	return false
}

@(private = "file")
serialize_svg :: proc(b: ^strings.Builder, tree: ^Xml_Tree, root: int) {
	q := Qnames {
		names      = make(map[string]string, 32, context.temp_allocator),
		namespaces = make([dynamic][2]string, 0, 4, context.temp_allocator),
	}
	collect_qnames(&q, tree, root)
	// sorted by prefix
	ns := q.namespaces[:]
	for i in 1 ..< len(ns) {
		for j := i; j > 0 && ns[j][1] < ns[j - 1][1]; j -= 1 do ns[j], ns[j - 1] = ns[j - 1], ns[j]
	}
	serialize_elem(b, tree, &q, root, ns)
}

@(private = "file")
serialize_elem :: proc(
	b: ^strings.Builder,
	tree: ^Xml_Tree,
	q: ^Qnames,
	idx: int,
	ns: [][2]string,
) {
	e := &tree.elems[idx]
	tag := q.names[e.tag]
	strings.write_byte(b, '<')
	strings.write_string(b, tag)
	for n in ns {
		strings.write_string(b, " xmlns:" if n[1] != "" else " xmlns")
		strings.write_string(b, n[1])
		strings.write_string(b, "=\"")
		escape_attrib(b, n[0])
		strings.write_byte(b, '"')
	}
	for a in e.attrs {
		strings.write_byte(b, ' ')
		strings.write_string(b, q.names[a.key])
		strings.write_string(b, "=\"")
		escape_attrib(b, a.value)
		strings.write_byte(b, '"')
	}
	text := strings.to_string(e.text)
	if text == "" && len(e.children) == 0 {
		strings.write_string(b, " />")
	} else {
		strings.write_byte(b, '>')
		escape_cdata(b, text)
		for c in e.children {
			serialize_elem(b, tree, q, c, nil)
			escape_cdata(b, strings.to_string(tree.elems[c].tail))
		}
		strings.write_string(b, "</")
		strings.write_string(b, tag)
		strings.write_byte(b, '>')
	}
}

@(private = "file")
escape_cdata :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case:
			strings.write_byte(b, s[i])
		}
	}
}

@(private = "file")
escape_attrib :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case '"':
			strings.write_string(b, "&quot;")
		case '\r':
			strings.write_string(b, "&#13;")
		case '\n':
			strings.write_string(b, "&#10;")
		case '\t':
			strings.write_string(b, "&#09;")
		case:
			strings.write_byte(b, s[i])
		}
	}
}
