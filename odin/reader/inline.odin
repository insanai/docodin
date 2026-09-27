package reader

import "core:strconv"
import "core:strings"

import dt "../doctree"
import rst "../rst"

// Inline nodes of the parse tree (``TreeBuilder.inline``): the elements
// with their registration (targets, references, footnote and citation
// references, substitution references), interpreted text through the
// roles, and problematic markup.

// ``Ref_Kind`` of the parse tree.
@(private = "file")
Ref_Kind :: rst.Ref_Kind

// A builder of an inline item: appends its nodes to ``out`` and its
// messages to ``msgs``.
@(private = "file")
Inline_Builder :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	lineno: int,
	container: dt.Node,
	out,
	msgs: Node_Out,
)

@(private = "file")
INLINE_BUILDERS := #partial [rst.Node_Kind]Inline_Builder {
	.Text                   = inline_text_node,
	.Emphasis               = inline_simple,
	.Strong                 = inline_simple,
	.Literal                = inline_simple,
	.Inline_Target          = inline_target,
	.Substitution_Reference = substitution_reference,
	.Reference              = reference,
	.Footnote_Reference     = footnote_reference,
	.Citation_Reference     = citation_reference,
	.Interpreted            = interpreted_item,
	.Problematic            = problematic_item,
}

// Build the inline nodes of the chain ``first`` into ``out`` and their
// messages into ``msgs``; ``container`` is ``Inliner.parent``.
build_inline :: proc(
	c: ^Context,
	t: ^rst.Tree,
	first: rst.Node,
	lineno: int,
	container: dt.Node,
	out, msgs: Node_Out,
) {
	c.inliner_parent = container
	for it := first; it != rst.NO_NODE; it = rst.next_sibling(t, it) {
		builder := INLINE_BUILDERS[rst.node_kind(t, it)]
		if builder == nil do panic("reader: unexpected inline item kind")
		builder(c, t, it, lineno, container, out, msgs)
	}
}

@(private = "file")
inline_text_node :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	_: int,
	_: dt.Node,
	out,
	_: Node_Out,
) {
	append(out, dt.new_text(c.doc, rst.node_text(t, n)))
}

// Emphasis, strong and literal.
@(private = "file")
inline_simple :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	_: int,
	_: dt.Node,
	out,
	_: Node_Out,
) {
	d := rst.node_data(t, n)
	tag: dt.Tag = .emphasis if d.kind == .Emphasis else .strong if d.kind == .Strong else .literal
	append(out, dt.new_element(c.doc, tag, d.raw, d.text))
}

@(private = "file")
interpreted_item :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	lineno: int,
	container: dt.Node,
	out, msgs: Node_Out,
) {
	d := rst.node_data(t, n)
	c.inliner_parent = container
	interpreted(c, d.raw, d.text, d.name, lineno, out, msgs)
}

@(private = "file")
problematic_item :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	lineno: int,
	container: dt.Node,
	out, msgs: Node_Out,
) {
	d := rst.node_data(t, n)
	msg := dt.system_message(c.doc, dt.Level(d.num[0]), d.name, {line = lineno})
	c.inliner_parent = container
	append(out, problematic(c, d.text, d.text, msg))
	append(msgs, msg)
}

// ``Inliner.problematic(text, rawsource, message)``.
problematic :: proc(c: ^Context, text, rawsource: string, msg: dt.Node) -> dt.Node {
	doc := c.doc
	msgid := dt.set_id(doc, msg, c.inliner_parent)
	prb := dt.new_element(doc, .problematic, rawsource, text)
	dt.set_attr(doc, prb, dt.K_REFID, dt.str(doc, msgid))
	prbid := dt.set_id(doc, prb)
	dt.add_backref(doc, msg, prbid)
	return prb
}

@(private = "file")
inline_target :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	_: int,
	container: dt.Node,
	out,
	_: Node_Out,
) {
	doc := c.doc
	d := rst.node_data(t, n)
	target := dt.new_element(doc, .target, d.raw, d.text)
	dt.list_append(doc, target, dt.K_NAMES, normalize_name(dt.astext(doc, target)))
	dt.note_explicit_target(doc, target, container)
	append(out, target)
}

@(private = "file")
substitution_reference :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	_: int,
	_: dt.Node,
	out,
	_: Node_Out,
) {
	append(out, substitution_reference_node(c, rst.node_data(t, n)))
}

@(private = "file")
substitution_reference_node :: proc(c: ^Context, d: rst.Node_Data) -> dt.Node {
	doc := c.doc
	subref := dt.new_element(doc, .substitution_reference, d.raw, d.text)
	subref_text := dt.astext(doc, subref)
	dt.note_substitution_ref(doc, subref, subref_text)
	underscores := int(d.num[0])
	if underscores == 0 do return subref
	raw := concat("|", subref_text, "|", "__" if underscores == 2 else "_")
	ref := dt.new_element(doc, .reference, raw)
	if underscores == 2 {
		dt.set_attr(doc, ref, "anonymous", true)
	} else {
		dt.set_attr(doc, ref, dt.K_REFNAME, normalize_name(subref_text))
		dt.note_refname(doc, ref)
	}
	dt.append_child(doc, ref, subref)
	return ref
}

@(private = "file")
reference :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	_: int,
	container: dt.Node,
	out, _: Node_Out,
) {
	doc := c.doc
	d := rst.node_data(t, n)
	switch Ref_Kind(d.num[0]) {
	case .Simple:
		ref := dt.new_element(doc, .reference, d.raw, d.text)
		dt.set_attr(doc, ref, "name", dt.whitespace_normalize_name(d.text))
		if d.num[1] != 0 {
			dt.set_attr(doc, ref, "anonymous", true)
		} else {
			dt.set_attr(doc, ref, dt.K_REFNAME, normalize_name(d.text))
			dt.note_refname(doc, ref)
		}
		append(out, ref)
	case .Phrase:
		phrase_reference(c, t, n, container, out)
	case .Uri:
		ref := dt.new_element(doc, .reference, d.raw, d.text)
		dt.set_attr(doc, ref, dt.K_REFURI, d.name)
		append(out, ref)
	case .Pep:
		s := &doc.settings
		uri := concat(s.pep_base_url, py_format_int(s.pep_file_url_template, py_int(d.name)))
		ref := dt.new_element(doc, .reference, d.raw, d.text)
		dt.set_attr(doc, ref, dt.K_REFURI, uri)
		append(out, ref)
	case .Rfc:
		uri := concat(doc.settings.rfc_base_url, "rfc", itoa(py_int(d.name)), ".html")
		ref := dt.new_element(doc, .reference, d.raw, d.text)
		dt.set_attr(doc, ref, dt.K_REFURI, uri)
		append(out, ref)
	}
}

// ``(K, REF_PHRASE, rawsource, text, alias_type, (alias, target_raw))``
@(private = "file")
phrase_reference :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	container: dt.Node,
	out: ^[dynamic]dt.Node,
) {
	doc := c.doc
	d := rst.node_data(t, n)
	text := d.text
	info, _ := rst.phrase_info(t, n)
	target, alias := embedded_target(c, info)
	if target != 0 && text == "" do text = alias
	unescaped := dt.unescape(text)
	ref := dt.new_element(doc, .reference, d.raw, text)
	dt.set_attr(doc, ref, "name", dt.whitespace_normalize_name(unescaped))
	append(out, ref)
	if has_suffix(d.raw, "__") {
		switch {
		case target != 0 && info.alias_type == .Name:
			dt.set_attr(doc, ref, dt.K_REFNAME, alias)
			dt.note_refname(doc, ref)
		case target != 0 && info.alias_type == .Uri:
			dt.set_attr(doc, ref, dt.K_REFURI, alias)
		case:
			dt.set_attr(doc, ref, "anonymous", true)
		}
		return
	}
	if target == 0 {
		dt.set_attr(doc, ref, dt.K_REFNAME, normalize_name(unescaped))
		dt.note_refname(doc, ref)
		return
	}
	dt.list_append(doc, target, dt.K_NAMES, normalize_name(unescaped))
	if info.alias_type == .Name {
		dt.set_attr(doc, ref, dt.K_REFNAME, alias)
		dt.note_indirect_target(doc, target)
		dt.note_refname(doc, ref)
	} else {
		dt.set_attr(doc, ref, dt.K_REFURI, alias)
	}
	dt.note_implicit_target(doc, target, container)
	append(out, target)
}

// The target of an embedded alias (``<alias_>`` or ``<uri>``) and the
// alias (normalized reference name or URI); 0 without alias.
@(private = "file")
embedded_target :: proc(c: ^Context, info: rst.Phrase_Info) -> (target: dt.Node, alias: string) {
	doc := c.doc
	switch info.alias_type {
	case .None:
		return 0, ""
	case .Name:
		target = dt.new_element(doc, .target, info.target_raw)
		alias = normalize_name(info.alias)
		dt.set_attr(doc, target, dt.K_REFNAME, alias)
		set_indirect_reference_name(c, target, dt.whitespace_normalize_name(info.alias))
	case .Uri:
		target = dt.new_element(doc, .target, info.target_raw)
		alias = info.alias
		dt.set_attr(doc, target, dt.K_REFURI, alias)
		dt.set_flag(doc, target, .Referenced)
	}
	return
}

@(private = "file")
footnote_reference :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	_: int,
	_: dt.Node,
	out,
	_: Node_Out,
) {
	append(out, footnote_reference_node(c, rst.node_text(t, n)))
}

@(private = "file")
footnote_reference_node :: proc(c: ^Context, label: string) -> dt.Node {
	doc := c.doc
	refname := normalize_name(label)
	refnode := dt.new_element(doc, .footnote_reference, concat("[", label, "]_"))
	if has_prefix(refname, "#") {
		refname = refname[1:]
		dt.set_attr(doc, refnode, "auto", 1)
		dt.note_autofootnote_ref(doc, refnode)
	} else if refname == "*" {
		refname = ""
		dt.set_attr(doc, refnode, "auto", "*")
		dt.note_symbol_footnote_ref(doc, refnode)
	} else {
		dt.append_child(doc, refnode, dt.new_text(doc, label))
	}
	if refname != "" {
		dt.set_attr(doc, refnode, dt.K_REFNAME, refname)
		dt.note_footnote_ref(doc, refnode)
	}
	return refnode
}

@(private = "file")
citation_reference :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	_: int,
	_: dt.Node,
	out,
	_: Node_Out,
) {
	doc := c.doc
	label := rst.node_text(t, n)
	refnode := dt.new_element(doc, .citation_reference, concat("[", label, "]_"), label)
	dt.set_attr(doc, refnode, dt.K_REFNAME, normalize_name(label))
	dt.note_citation_ref(doc, refnode)
	append(out, refnode)
}

// Python ``int(s)`` of a string the parser matched as digits.
py_int :: proc(s: string) -> int {
	v, _ := strconv.parse_int(s, 10)
	return v
}

// ``template % value`` for a template with one integer conversion
// (``%d``, ``%4d``, ``%04d``; ``%%`` is a percent sign).
py_format_int :: proc(template: string, value: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(template); {
		ch := template[i]
		switch {
		case ch != '%' || i + 1 >= len(template):
			strings.write_byte(&b, ch)
			i += 1
		case template[i + 1] == '%':
			strings.write_byte(&b, '%')
			i += 2
		case:
			i = write_int_conversion(&b, template, i + 1, value)
		}
	}
	return strings.to_string(b)
}

// Write ``value`` for the conversion ``%[0][width]d`` whose flags start at
// ``j``; returns the offset after the conversion character.
@(private = "file")
write_int_conversion :: proc(b: ^strings.Builder, template: string, j_in: int, value: int) -> int {
	j := j_in
	zero := template[j] == '0'
	width := 0
	for j < len(template) && template[j] >= '0' && template[j] <= '9' {
		width = width * 10 + int(template[j] - '0')
		j += 1
	}
	digits := itoa(value)
	for _ in len(digits) ..< width do strings.write_byte(b, '0' if zero else ' ')
	strings.write_string(b, digits)
	return min(j + 1, len(template)) // past the conversion character
}
