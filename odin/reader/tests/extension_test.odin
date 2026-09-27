package reader_tests

import "core:strings"
import "core:testing"

import dt "../../doctree"
import reader ".."

// The reader's ``Extension``: directives and roles beyond docutils' own,
// found before the standard registry, without lookup messages; a reader
// without one is plain docutils.

@(private = "file")
run_shout :: proc(c: ^reader.Context, d: ^reader.Directive) -> (reader.Nodes, reader.Failure) {
	n := dt.new_element(c.doc, .paragraph, "", strings.to_upper(d.arguments[0], c.allocator))
	return reader.result_of(c, n), nil
}

@(private = "file")
SHOUT := reader.Directive_Spec {
	required_arguments        = 1,
	final_argument_whitespace = true,
	run                       = run_shout,
}

@(private = "file")
run_kbd :: proc(
	c: ^reader.Context,
	r: ^reader.Role,
	rawtext, text: string,
	lineno: int,
	opts: ^reader.Options,
	out, msgs: reader.Node_Out,
) {
	n := dt.new_element(c.doc, .literal, rawtext, text)
	dt.list_append(c.doc, n, dt.K_CLASSES, "kbd")
	append(out, n)
}

@(private = "file")
DIRECTIVES := [?]reader.Registry_Entry{{"shout", &SHOUT}}
@(private = "file")
ROLES := [?]reader.Role{{kind = .Extension, name = "kbd", run = run_kbd}}

@(private = "file")
TEXT :: ".. shout:: hello\n\nPress :kbd:`Ctrl`.\n"

@(private = "file")
pformat_with :: proc(ext: ^reader.Extension) -> string {
	s := dt.default_settings()
	s.report_level = 1
	s.warning_stream = .Collect
	doc, _ := reader.parse_document(TEXT, s, "test.rst", extension = ext)
	defer dt.destroy(doc)
	return dt.pformat(doc, doc.root, allocator = context.temp_allocator)
}

@(test)
extension_directives_and_roles :: proc(t: ^testing.T) {
	ext := reader.Extension {
		directives = DIRECTIVES[:],
		roles      = ROLES[:],
	}
	got := pformat_with(&ext)
	testing.expect(t, strings.contains(got, "<paragraph>\n        HELLO"), got)
	testing.expect(t, strings.contains(got, "<literal classes=\"kbd\">\n            Ctrl"), got)
	testing.expect(t, !strings.contains(got, "system_message"), got)
}

@(test)
no_extension_is_plain_docutils :: proc(t: ^testing.T) {
	got := pformat_with(nil)
	testing.expect(t, strings.contains(got, `Unknown directive type "shout".`), got)
	testing.expect(t, strings.contains(got, `Unknown interpreted text role "kbd".`), got)
}
