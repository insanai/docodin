package publish_tests

import "core:strings"
import "core:testing"

import pb "../"
import wr "../../writers"

// Unit tests of the native publisher; tests/native_publish_differential.py
// compares it with docutils end to end.

DOC :: "Title\n=====\n\nText *em*.\n\n`bad\n"

@(test)
defaults_per_writer :: proc(t: ^testing.T) {
	html := pb.default_settings(.Html5, allocator = context.temp_allocator)
	testing.expect_value(t, html["initial_header_level"].(string), "2")
	testing.expect_value(t, html["output_encoding_error_handler"].(string), "xmlcharrefreplace")
	testing.expect_value(t, len(html["stylesheet_path"].([]string)), 2)
	testing.expect_value(t, html["stylesheet_dirs"].([]string)[1],
		"<docutils>/writers/html5_polyglot")
	xetex := pb.default_settings(.Xetex, allocator = context.temp_allocator)
	testing.expect_value(t, xetex["template"].(string), "xelatex.tex")
	_, has_font_encoding := xetex["font_encoding"]
	testing.expect(t, !has_font_encoding)
	xml := pb.default_settings(.Xml, allocator = context.temp_allocator)
	testing.expect_value(t, xml["doctype_declaration"].(int), 1)
	testing.expect(t, pb.is_setting(.Latex, "documentclass"))
	testing.expect(t, !pb.is_setting(.Html5, "documentclass"))
}

@(test)
validators_convert_strings :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	s := pb.default_settings(.Html5)
	overrides := []pb.Override {
		{"report_level", "info"},
		{"halt_level", "3"},
		{"footnote_backlinks", "no"},
		{"smart_quotes", "alt"},
		{"stylesheet_path", "a.css, , b.css"},
		{"output_encoding", "latin-1:backslashreplace"},
		{"rfc_base_url", "http://rfc"},
		{"expose_internals", "line:source"},
		{"smartquotes_locales", "de:«»‹›,fr:« : »:‹ : ›"},
		{"title", "3"}, // no validator: as given
		{"tab_width", 4}, // not a string: as given
	}
	err, _ := pb.apply_overrides(&s, .Html5, overrides)
	testing.expect_value(t, err, "")
	testing.expect_value(t, s["report_level"].(int), 1)
	testing.expect_value(t, s["halt_level"].(int), 3)
	testing.expect_value(t, s["footnote_backlinks"].(bool), false)
	testing.expect_value(t, s["smart_quotes"].(string), "alt")
	testing.expect_value(t, strings.join(s["stylesheet_path"].([]string), "|"), "a.css|b.css")
	testing.expect_value(t, s["output_encoding"].(string), "latin-1")
	testing.expect_value(t, s["output_encoding_error_handler"].(string), "backslashreplace")
	testing.expect_value(t, s["rfc_base_url"].(string), "http://rfc/")
	testing.expect_value(t, len(s["expose_internals"].([]string)), 2)
	testing.expect_value(t, s["smartquotes_locales"].([]string)[1], "fr:« : »:‹ : ›")
	testing.expect_value(t, s["title"].(string), "3")
	testing.expect_value(t, s["tab_width"].(int), 4)
}

@(test)
validators_reject_bad_values :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	bad := []pb.Override {
		{"report_level", "loud"},
		{"tab_width", "-1"},
		{"footnote_backlinks", "maybe"},
		{"output_encoding_error_handler", "shrug"},
		{"strip_classes", "Not A Class"},
		{"smartquotes_locales", "de"},
		{"math_output", "PNG"},
	}
	for o in bad {
		s := pb.default_settings(.Html5)
		err, which := pb.apply_overrides(&s, .Html5, {o})
		testing.expectf(t, err != "", "%s=%v accepted", o.name, o.value)
		testing.expect_value(t, which.name, o.name)
	}
	_, _, _, status, err, _ := pb.publish(DOC, "", "html5", {{"report_level", "loud"}})
	e, is_settings := err.(pb.Settings_Error)
	testing.expect(t, is_settings)
	testing.expect_value(t, e.setting, "report_level")
	testing.expect_value(t, status, 1)
	_, _, _, _, err, _ = pb.publish(DOC, "", "odt", nil)
	e, is_settings = err.(pb.Settings_Error)
	testing.expect(t, is_settings && e.message == `Writer "odt" not found.`)
}

// Where docutils would use a Python library: the feature, detail and line.
@(test)
reports_python_needs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	Case :: struct {
		text, writer: string,
		overrides:    []pb.Override,
		need:         pb.Python_Need,
	}
	cases := []Case {
		{"x\n\n.. code:: python\n\n   x = 1\n", "pseudoxml", nil,
		 {.Pygments, "python", "doc.rst", 3}},
		{".. role:: py(code)\n   :language: c\n\n:py:`x`\n", "pseudoxml", nil,
		 {.Pygments, "c", "doc.rst", 4}},
		{".. raw:: html\n   :url: https://example.org/x\n", "xml", nil,
		 {.Url, "https://example.org/x", "doc.rst", 1}},
		{".. include:: x.md\n   :parser: markdown\n", "xml", nil,
		 {.Parser, "markdown", "doc.rst", 1}},
		{".. math:: x\n", "html5", {{"math_output", "MathML ttm"}},
		 {.Mathml_Converter, "ttm", "doc.rst", 1}},
		{"x\n", "pseudoxml", {{"output_encoding", "latin-9"}}, {.Codec, "latin-9", "", 0}},
		{"\u00e9\n", "pseudoxml", {{"output_encoding", "ascii:namereplace"}},
		 {.Codec, "namereplace", "", 0}},
		{"x\n", "odt", nil, {.Writer, "odt", "", 0}},
	}
	for c in cases {
		_, _, _, _, _, needs := pb.publish(c.text, "doc.rst", c.writer, c.overrides)
		testing.expectf(t, len(needs) == 1 && needs[0] == c.need, "%q: %v", c.text, needs)
	}
	plain := []Case {
		{".. image:: a.png\n   :scale: 50\n", "html5", nil, {}}, // missing file: native warning
		{".. code::\n\n   x = 1\n", "pseudoxml", nil, {}},
		{".. code:: python\n\n   x\n", "pseudoxml", {{"syntax_highlight", "none"}}, {}},
		{".. image:: a.png\n   :scale: 50\n", "latex", nil, {}},
		{".. image:: a.png\n   :scale: 50\n   :width: 1\n   :height: 2\n", "html5", nil, {}},
		{".. figure:: missing.png\n   :figwidth: image\n", "html5", nil, {}},
	}
	for c in plain {
		_, _, _, _, _, needs := pb.publish(c.text, "doc.rst", c.writer, c.overrides)
		testing.expectf(t, len(needs) == 0, "%q: %v", c.text, needs)
	}
}

@(test)
publishes_pseudoxml :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	output, parts, messages, status, err, _ := pb.publish(DOC, "doc.rst", "pseudoxml", nil)
	testing.expect(t, err == nil)
	testing.expect_value(t, status, 0)
	head := `<document ids="title" names="title" source="doc.rst" title="Title">`
	testing.expect(t, strings.has_prefix(output, head))
	whole, _ := wr.part(parts, "whole")
	testing.expect_value(t, whole, output)
	testing.expect_value(t, len(messages), 1)
	testing.expect_value(t, messages[0].level, 2)
	testing.expect(t, strings.has_prefix(messages[0].text, "doc.rst:6: (WARNING/2) Inline "))
	testing.expect(t, strings.has_suffix(messages[0].text, "\n"))
	_, _, quiet, _, _, _ := pb.publish(DOC, "", "pseudoxml", {{"report_level", 3}})
	testing.expect_value(t, len(quiet), 0)
	source, _, _, _, _, _ := pb.publish(DOC, "", "pseudoxml", nil)
	testing.expect(t, strings.contains(source, `source="<string>"`))
}

@(test)
every_writer_writes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	starts := [?][2]string {
		{"html", "<!DOCTYPE html>"},
		{"xhtml", "<!DOCTYPE html>"},
		{"xml", `<?xml version="1.0" encoding="utf-8"?>`},
		{"latex", "\\documentclass[a4paper]{article}"},
		{"xetex", "\\documentclass[a4paper]{article}"},
	}
	for s in starts {
		output, parts, _, _, err, _ := pb.publish(DOC, "", s[0], nil)
		testing.expectf(t, err == nil, "%s: %v", s[0], err)
		testing.expectf(t, strings.has_prefix(output, s[1]), "%s: %.40s", s[0], output)
		testing.expect(t, len(parts.items) >= 4)
	}
}

@(test)
halting_raises_system_message :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := "`one\n\n`two\n"
	output, _, messages, status, err, _ := pb.publish(text, "", "pseudoxml", {{"halt_level", 2}})
	halt, halted := err.(pb.System_Message)
	testing.expect(t, halted)
	testing.expect_value(t, halt.level, 2)
	testing.expect_value(t, output, "")
	testing.expect_value(t, len(messages), 1) // the reader stops at the first
	testing.expect_value(t, status, 1) // no document: no exit status level
	testing.expect_value(t, pb.error_report(err),
		"Exiting due to level-2 (WARNING) system message.\n")
}

@(test)
exit_status_levels :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	_, _, _, status, err, _ := pb.publish(DOC, "", "pseudoxml", {{"exit_status_level", "warning"}})
	testing.expect(t, err == nil)
	testing.expect_value(t, status, 12)
	_, _, _, status, _, _ = pb.publish(DOC, "", "pseudoxml", {{"exit_status_level", 3}})
	testing.expect_value(t, status, 0)
}

@(test)
output_encodings :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := "Café — x\n"
	_, _, _, status, err, _ := pb.publish(text, "", "pseudoxml", {{"output_encoding", "ascii"}})
	u, is_unicode := err.(pb.Unicode_Error)
	testing.expect(t, is_unicode)
	testing.expect_value(t, status, 1)
	testing.expect_value(t, u.chars, "é")
	report := pb.error_report(err)
	testing.expect(t, strings.has_prefix(report,
		"UnicodeEncodeError: 'ascii' codec can't encode character '\\xe9' in position "))
	output, _, _, _, err2, _ := pb.publish(text, "", "pseudoxml",
		{{"output_encoding", "ascii:backslashreplace"}})
	testing.expect(t, err2 == nil)
	testing.expect(t, strings.contains(output, "Caf\\xe9 \\u2014 x"))
	s := pb.default_settings(.Pseudoxml)
	s["output_encoding"] = "latin-1"
	bytes := pb.encode_output("Café", s)
	testing.expect_value(t, string(bytes), "Caf\xe9")
	s["output_encoding"] = "utf-16"
	testing.expect_value(t, len(pb.encode_output("ab", s)), 6)
}

@(test)
decoding_input :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text, err := pb.decode(transmute([]u8)string("\xef\xbb\xbfA\r\nB\rC"), "utf-8-sig", "strict")
	testing.expect_value(t, err, "")
	testing.expect_value(t, pb.universal_newlines(text), "A\nB\nC")
	_, err = pb.decode(transmute([]u8)string("ok\xff"), "utf-8", "strict")
	want := "UnicodeDecodeError: 'utf-8' codec can't decode byte 0xff in position 2: " +
		"invalid start byte"
	testing.expect_value(t, err, want)
	text, _ = pb.decode(transmute([]u8)string("\xe9"), "latin-1", "strict")
	testing.expect_value(t, text, "é")
}

@(test)
explicit_false_trim_keeps_the_space :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := "x [#]_\n\n.. [#] f\n"
	trim, _, _, _, _, _ := pb.publish(text, "", "pseudoxml",
		{{"footnote_references", "superscript"}})
	keep, _, _, _, _, _ := pb.publish(text, "", "pseudoxml",
		{{"footnote_references", "superscript"}, {"trim_footnote_reference_space", false}})
	testing.expect(t, strings.contains(trim, "        x\n"))
	testing.expect(t, strings.contains(keep, "        x \n"))
}

@(test)
transform_halts_like_docutils :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := "Para.\n\n.. class:: a\n"
	_, _, messages, status, err, _ := pb.publish(text, "", "pseudoxml",
		{{"halt_level", 3}, {"exit_status_level", 3}})
	halt, halted := err.(pb.System_Message)
	testing.expect(t, halted && halt.level == 3)
	testing.expect_value(t, len(messages), 1)
	testing.expect(t, strings.has_prefix(messages[0].text, "<string>:3: (ERROR/3) No suitable"))
	testing.expect_value(t, status, 1) // no message below the halting one reached level 3
}

// Without a docutils data directory (``<docutils>``, the default), the
// standard include files and stylesheets come from the embedded copies.
@(test)
embedded_docutils_data :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := ".. include:: <isonum.txt>\n\n|copy| 2026\n"
	out, _, messages, status, err, _ := pb.publish(text, "doc.rst", "html5", nil)
	testing.expect_value(t, err, pb.Error{})
	testing.expect_value(t, status, 0)
	testing.expect_value(t, len(messages), 0)
	testing.expect(t, strings.contains(out, "<p>© 2026</p>"), out)
	testing.expect(t, strings.contains(out, "<style type=\"text/css\">"), out)
	linked, _, _, _, _, _ := pb.publish(text, "doc.rst", "html5", {{"embed_stylesheet", "no"}})
	testing.expect(t, strings.contains(linked, `href="minimal.css"`), linked)
}
