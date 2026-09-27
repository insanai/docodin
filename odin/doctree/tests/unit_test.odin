package doctree_tests

import "core:strings"
import "core:testing"

import dt ".."

// Unit tests of behaviour the differential fixtures do not reach.

@(private = "file")
new_doc :: proc() -> ^dt.Doc {
	s := dt.default_settings()
	s.warning_stream = .Collect
	return dt.new_document("unit.rst", s)
}

@(test)
test_float_and_int_parsing :: proc(t: ^testing.T) {
	cases := [?]struct {
		f:    f64,
		want: string,
	} {
		{1.5, "1.5"},
		{0.1, "0.1"},
		{1e16, "1e+16"},
		{1.5e16, "1.5e+16"},
		{123456789.125, "123456789.125"},
		{1e-05, "1e-05"},
		{0.0001, "0.0001"},
		{100.0, "100.0"},
		{0.0, "0.0"},
		{-2.25, "-2.25"},
		{12345678901234567.0, "1.2345678901234568e+16"},
	}
	for c in cases do testing.expect_value(t, dt.py_float_repr(c.f), c.want)
	ints := [?]struct {
		s:  string,
		v:  int,
		ok: bool,
	}{{"007", 7, true}, {" -12 ", -12, true}, {"1_000", 1000, true}, {"1__0", 0, false},
		{"_1", 0, false}, {"", 0, false}, {"+3", 3, true}, {"x", 0, false}}
	for c in ints {
		v, ok := dt.py_parse_int(c.s)
		testing.expect_value(t, ok, c.ok)
		if ok do testing.expect_value(t, v, c.v)
	}
	free_all(context.temp_allocator)
}

@(test)
test_attribute_validators :: proc(t: ^testing.T) {
	doc := new_doc()
	defer dt.destroy(doc)
	cases := [?]struct {
		key:   string,
		value: dt.Attr_Value,
		want:  string, // normalized value, or the error text
	} {
		{"width", "50 %", "50%"},
		{"width", "007px", "7px"},
		{"height", "1.50em", "1.5em"},
		{"width", "1.2.3", "\"1.2.3\" is no valid measure."},
		{"colwidth", "2.50*", "2.5"},
		{"colwidth", "0", "\"0\" is no proportional measure."},
		{"level", "x", "invalid literal for int() with base 10: 'x'"},
		{"enumtype", "roman", "\"roman\" is not one of \"arabic\", \"loweralpha\", " +
			"\"lowerroman\", \"upperalpha\", \"upperroman\"."},
		{"type", "a b", "\"a b\" is no NMTOKEN."},
		{"refid", "Foo", "\"Foo\" is no valid id or class name."},
		{"auto", 1, "1"},
	}
	for c in cases {
		v, err := dt.validate_value(doc, c.key, c.value)
		got := err
		if err == "" {
			b := strings.builder_make(context.temp_allocator)
			dt.write_attr_value(&b, doc, v)
			got = strings.to_string(b)
		}
		testing.expectf(t, got == c.want, "%s=%v: got %q, want %q", c.key, c.value, got, c.want)
	}
	free_all(context.temp_allocator)
}

@(test)
test_setup_child_and_copies :: proc(t: ^testing.T) {
	doc := new_doc()
	defer dt.destroy(doc)
	dt.note_source(doc, "inc.rst", 4)
	sec := dt.new_element(doc, .section)
	para := dt.new_element(doc, .paragraph, "", "text")
	dt.append_child(doc, sec, para) // no document yet: nothing propagated
	_, has_line := dt.line(doc, para)
	testing.expect(t, !has_line)
	dt.append_child(doc, doc.root, sec)
	ln, _ := dt.line(doc, sec)
	src, _ := dt.source(doc, sec)
	testing.expect_value(t, ln, 5)
	testing.expect_value(t, src, "inc.rst")
	testing.expect(t, dt.in_document(doc, para))
	dt.list_append(doc, sec, "names", "intro")
	dt.note_implicit_target(doc, sec)
	cp := dt.copy_document(doc)
	defer dt.destroy(cp)
	testing.expect_value(t, dt.om_len(&cp.ids), 0)
	testing.expect_value(t, dt.pformat(cp, cp.root, allocator = context.temp_allocator),
		"<document source=\"unit.rst\">\n")
	deep := dt.import_deep(cp, doc, sec)
	testing.expect_value(t, dt.pformat(cp, deep, allocator = context.temp_allocator),
		"<section ids=\"intro\" names=\"intro\">\n    <paragraph>\n        text\n")
	free_all(context.temp_allocator)
}

@(private = "file")
is_para :: proc(doc: ^dt.Doc, n: dt.Node, _: rawptr) -> bool {
	return dt.tag(doc, n) == .paragraph
}

@(test)
test_traversal :: proc(t: ^testing.T) {
	doc := new_doc()
	defer dt.destroy(doc)
	a := dt.new_element(doc, .section)
	b := dt.new_element(doc, .paragraph, "", "b")
	c := dt.new_element(doc, .paragraph, "", "c")
	dt.extend_children(doc, doc.root, {a, c})
	dt.append_child(doc, a, b)
	found := dt.traverse(doc, doc.root, dt.Predicate{fn = is_para})
	testing.expect_value(t, len(found), 2)
	testing.expect_value(t, dt.next_node(doc, b, dt.Tag_Set{.Text}), dt.first_child(doc, b))
	sib := dt.traverse(doc, b, nil, include_self = false, descend = false, ascend = true)
	testing.expect_value(t, len(sib), 1) // c, the following sibling of the parent
	testing.expect_value(t, sib[0], c)
	// replacing the current node visits the replacements after the first
	it := dt.findall(doc, doc.root, dt.Tag_Set{.paragraph, .strong})
	seen := 0
	for n in dt.next(&it) {
		seen += 1
		if n == c {
			x := dt.new_element(doc, .strong, "", "x")
			y := dt.new_element(doc, .strong, "", "y")
			dt.replace_self_list(doc, c, {x, y})
		}
	}
	testing.expect_value(t, seen, 3) // b, c, y
	free_all(context.temp_allocator)
}

@(private = "file")
Seen :: struct {
	count: int,
}

@(private = "file")
fixed_location :: proc(
	doc: ^dt.Doc,
	data: rawptr,
	line: Maybe(int),
) -> (
	Maybe(string),
	Maybe(int),
) {
	return "hook.rst", 42
}

@(test)
test_reporter :: proc(t: ^testing.T) {
	doc := new_doc()
	defer dt.destroy(doc)
	dt.attach_observer(doc, dt.observe_parse_message)
	doc.reporter.source_and_line = fixed_location
	msg := dt.warning(doc, "careful")
	testing.expect_value(t, dt.astext(doc, msg), "hook.rst:42: (WARNING/2) careful")
	testing.expect_value(t, len(doc.parse_messages), 1)
	testing.expect_value(t, dt.debug(doc, "hidden"), dt.Node(0))
	dt.info(doc, "quiet") // below report_level: not written
	testing.expect_value(t, len(doc.reporter.written), 1)
	dt.severe(doc, "stop")
	testing.expect(t, doc.reporter.halted)
	testing.expect_value(t, len(doc.parse_messages), 2) // the halting message is not observed
	testing.expect_value(t, doc.reporter.max_level, 2)
	free_all(context.temp_allocator)
}

@(test)
test_attributes :: proc(t: ^testing.T) {
	doc := new_doc()
	defer dt.destroy(doc)
	fn := dt.new_element(doc, .footnote)
	testing.expect(t, dt.has_attr(doc, fn, "backrefs"))
	testing.expect(t, !dt.has_attr(doc, dt.new_element(doc, .paragraph), "backrefs"))
	dt.delete_attr(doc, fn, "ids")
	testing.expect(t, !dt.has_attr(doc, fn, "ids"))
	dt.set_attr(doc, fn, "refuri", dt.new_list(doc))
	dt.set_attr(doc, fn, "auto", dt.Attr_None{})
	dt.set_attr(doc, fn, "anonymous", true)
	want := "<footnote anonymous=\"1\" auto=\"True\" refuri=\"\">"
	testing.expect_value(t, dt.starttag(doc, fn), want)
	lit := dt.new_element(doc, .literal_block, "raw", "a\\ b")
	testing.expect_value(t, dt.astext(doc, lit), "a\\ b")
	testing.expect_value(t, dt.unescape("a\x00 b\x00c", true), "a\\ b\\c")
	testing.expect_value(t, dt.starttag(doc, lit), "<literal_block xml:space=\"preserve\">")
	free_all(context.temp_allocator)
}

@(test)
test_default_settings :: proc(t: ^testing.T) {
	h := dt.default_settings(.Html5)
	testing.expect_value(t, h.math_output, "MathML")
	testing.expect_value(t, h.initial_header_level, 2)
	testing.expect_value(t, h.footnote_references, "brackets")
	testing.expect_value(t, len(h.stylesheet_path), 2)
	l := dt.default_settings(.Latex)
	testing.expect_value(t, l.footnote_references, "superscript")
	testing.expect_value(t, l.table_style[0], "standard")
	p := dt.default_settings()
	testing.expect_value(t, p.auto_id_prefix, "%")
	testing.expect_value(t, p.report_level, 2)
	testing.expect_value(t, p.halt_level, 4)
	testing.expect(t, p.doctitle_xform && p.docinfo_xform && !p.sectsubtitle_xform)
}
