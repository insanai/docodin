package reader_tests

import "core:strings"
import "core:testing"

import dt "../../doctree"
import reader ".."

// Unit tests of the native reader.  The differential test
// (tests/native_reader_differential.py) compares it with docutils on
// thousands of documents; these tests pin down a few results (expected
// output from docutils 0.22.4) and the helpers.

@(private = "file")
parse_pformat :: proc(text: string) -> string {
	s := dt.default_settings()
	s.report_level = 5
	s.warning_stream = .Collect
	s.file_insertion_enabled = false
	doc := reader.parse(text, s, "test.rst")
	defer dt.destroy(doc)
	return dt.pformat(doc, doc.root, allocator = context.temp_allocator)
}

@(test)
test_sections_and_references :: proc(t: ^testing.T) {
	got := parse_pformat("Title\n=====\n\nA *para* with `ref`_.\n\n.. _ref: mail@example.org\n")
	want := strings.concatenate({
		"<document source=\"test.rst\">\n",
		"    <section ids=\"title\" names=\"title\">\n",
		"        <title>\n",
		"            Title\n",
		"        <paragraph>\n",
		"            A \n",
		"            <emphasis>\n",
		"                para\n",
		"             with \n",
		"            <reference name=\"ref\" refname=\"ref\">\n",
		"                ref\n",
		"            .\n",
		"        <target ids=\"ref\" names=\"ref\" refuri=\"mailto:mail@example.org\">\n",
	}, context.temp_allocator)
	testing.expect_value(t, got, want)
	free_all(context.temp_allocator)
}

@(test)
test_directives_and_roles :: proc(t: ^testing.T) {
	text := strings.concatenate({
		".. note:: Note *text*\n   :class: special\n   :name: my note\n\n",
		".. unknown:: arg\n\n",
		".. role:: custom(emphasis)\n   :class: x\n\n",
		":custom:`hi` :pep:`8`\n",
	}, context.temp_allocator)
	want := strings.concatenate({
		"<document source=\"test.rst\">\n",
		"    <note classes=\"special\" ids=\"my-note\" names=\"my\\ note\">\n",
		"        <paragraph>\n",
		"            Note \n",
		"            <emphasis>\n",
		"                text\n",
		"    <system_message level=\"1\" line=\"5\" source=\"test.rst\" type=\"INFO\">\n",
		"        <paragraph>\n",
		"            No directive entry for \"unknown\" in module ",
		"\"docutils.parsers.rst.languages.en\".\n",
		"            Trying \"unknown\" as canonical directive name.\n",
		"    <system_message level=\"3\" line=\"5\" source=\"test.rst\" type=\"ERROR\">\n",
		"        <paragraph>\n",
		"            Unknown directive type \"unknown\".\n",
		"        <literal_block xml:space=\"preserve\">\n",
		"            .. unknown:: arg\n",
		"    <paragraph>\n",
		"        <emphasis classes=\"x\">\n",
		"            hi\n",
		"         \n",
		"        <reference refuri=\"https://peps.python.org/pep-0008\">\n",
		"            PEP 8\n",
	}, context.temp_allocator)
	testing.expect_value(t, parse_pformat(text), want)
	free_all(context.temp_allocator)
}

@(test)
test_pending_and_substitutions :: proc(t: ^testing.T) {
	text := strings.concatenate({
		".. contents:: Table\n   :depth: 2\n   :local:\n\n",
		"Section\n-------\n\n.. |u| unicode:: U+2014\n",
	}, context.temp_allocator)
	want := `<document source="test.rst">
    <topic classes="contents local" ids="table" names="table">
        <title>
            Table
        <pending>
            .. internal attributes:
                 .transform: docutils.transforms.parts.Contents
                 .details:
                   depth: 2
                   local: None
    <section ids="section" names="section">
        <title>
            Section
        <substitution_definition names="u">
            —
`
	testing.expect_value(t, parse_pformat(text), want)
	free_all(context.temp_allocator)
}

@(test)
test_string_list_views :: proc(t: ^testing.T) {
	a := context.temp_allocator
	root := reader.sl_make({"a", "b", "c", "d"}, "src", a)
	view := reader.sl_slice(root, 1, 3) // b, c
	testing.expect_value(t, view.parent_offset, 1)
	// inserting into a view also inserts into its parent
	reader.sl_insert_line(view, 1, "x", {"other", 7})
	testing.expect_value(t, reader.sl_len(root), 5)
	testing.expect_value(t, root.data[2], "x")
	info, has_offset, ok := reader.sl_info(root, 2)
	testing.expect(t, ok && has_offset && info.source == "other" && info.offset == 7)
	// just past the end: the source of the last line, no offset
	info, has_offset, ok = reader.sl_info(root, 5)
	testing.expect(t, ok && !has_offset && info.source == "src")
	_, _, ok = reader.sl_info(root, 6)
	testing.expect(t, !ok)
	// deleting from the view deletes from the parent
	reader.sl_delete(view, 1)
	testing.expect_value(t, reader.sl_len(root), 4)
	testing.expect_value(t, root.data[2], "c")
	// trimming does not touch the parent
	reader.sl_trim_start(view)
	testing.expect_value(t, view.parent_offset, 2)
	testing.expect_value(t, reader.sl_len(root), 4)
	free_all(context.temp_allocator)
}

@(test)
test_python_string_helpers :: proc(t: ^testing.T) {
	parts := reader.py_split_max("  a b   c  d ", 1)
	testing.expect_value(t, len(parts), 2)
	testing.expect_value(t, parts[0], "a")
	testing.expect_value(t, parts[1], "b   c  d ")
	testing.expect_value(t, reader.py_format_int("pep-%04d", 8), "pep-0008")
	testing.expect_value(t, reader.py_format_int("%3d%%", 7), "  7%")
	testing.expect_value(t, reader.expandtabs("a\tb\n\tc", 4), "a   b\n    c")
	free_all(context.temp_allocator)
}

@(test)
test_include :: proc(t: ^testing.T) {
	s := dt.default_settings()
	s.report_level = 5
	s.warning_stream = .Collect
	text := ".. include:: <isonum.txt>\n\n|copy| 2026\n\n.. include:: missing.rst\n"
	doc := reader.parse(text, s, "test.rst")
	defer dt.destroy(doc)
	copy_name, found := dt.lookup(doc, "copy")
	testing.expect(t, found && dt.om_has(&doc.substitution_defs, copy_name))
	// the included definitions come from the standard file
	def, _ := dt.om_get(&doc.substitution_defs, copy_name)
	src, _ := dt.source(doc, def)
	testing.expect(t, strings.has_suffix(src, "parsers/rst/include/isonum.txt"))
	// the missing file: a SEVERE message with docutils' text
	last := dt.last_child(doc, doc.root)
	testing.expect_value(t, dt.tag(doc, last), dt.Tag.system_message)
	want := strings.concatenate({
		"Problems with \"include\" directive path:\n",
		"InputError: [Errno 2] No such file or directory: 'missing.rst'.",
	}, context.temp_allocator)
	para := dt.first_child(doc, last)
	testing.expect_value(t, dt.astext(doc, para), want)
	free_all(context.temp_allocator)
}
