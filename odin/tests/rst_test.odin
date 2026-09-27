package rst_tests

import "core:mem"
import "core:strings"
import "core:testing"

import "../check"
import rst "../rst"

// Unit tests of the parser package (``odin test odin/tests``).  Conformance
// with docutils is tested from Python (tests/), against docutils itself.

@(private = "file")
parse :: proc(text: string, allocator := context.allocator) -> (doc: rst.Node, p: rst.Parser) {
	p = rst.Parser {
		allocator = allocator,
		settings  = rst.DEFAULT_SETTINGS,
	}
	doc, _, _ = rst.parse_text(&p, text, 0, true)
	return
}

@(private = "file")
kinds :: proc(tree: ^rst.Tree, n: rst.Node) -> []rst.Node_Kind {
	out := make([dynamic]rst.Node_Kind, context.temp_allocator)
	it := rst.children(tree, n)
	for c in rst.iterate(&it) do append(&out, rst.node_kind(tree, c))
	return out[:]
}

@(private = "file")
messages :: proc(tree: ^rst.Tree, n: rst.Node, out: ^[dynamic]rst.Node_Data) {
	it := rst.children(tree, n)
	for c in rst.iterate(&it) {
		if rst.node_kind(tree, c) == .System_Message do append(out, rst.node_data(tree, c))
		messages(tree, c, out)
	}
}

@(test)
split_lines_matches_string2lines :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	lines := rst.split_lines("a\tb  \r\nc d\ve\n\n", 8, context.allocator)
	testing.expect_value(t, len(lines), 4)
	testing.expect_value(t, lines[0], "a       b")
	testing.expect_value(t, lines[1], "c")
	testing.expect_value(t, lines[2], "d e")
	testing.expect_value(t, lines[3], "")
}

@(test)
block_structure :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	doc, p := parse(
		"Title\n=====\n\nPara *em*.\n\n- a\n- b\n\n::\n\n  code\n\n----\n\n.. note:: x\n",
	)
	tree := &p.tree
	testing.expect(t, slice_equal(kinds(tree, doc), []rst.Node_Kind {
		.Section_Title, .Paragraph, .Bullet_List, .Literal_Block, .Transition, .Directive,
	})) // a lone "::" paragraph is dropped
	para := rst.next_sibling(tree, rst.first_child(tree, doc))
	testing.expect(t, slice_equal(kinds(tree, para), []rst.Node_Kind{.Text, .Emphasis, .Text}))
	testing.expect_value(t, rst.child_count(tree, rst.next_sibling(tree, para)), 2)
	directive := rst.last_child(tree, doc)
	testing.expect_value(t, rst.node_name(tree, directive), "note")
	info, has_info := rst.directive_info(tree, directive)
	testing.expect(t, has_info)
	testing.expect_value(t, info.lines[0], "x")
}

@(test)
tables :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	doc, p := parse("+---+---+\n| a | b |\n+===+===+\n| c | d |\n+---+---+\n\n=  =\nx  y\n=  =\n")
	testing.expect(t, slice_equal(kinds(&p.tree, doc), []rst.Node_Kind{.Table, .Table}))
	msgs := make([dynamic]rst.Node_Data)
	messages(&p.tree, doc, &msgs)
	testing.expect_value(t, len(msgs), 0)
}

@(test)
system_messages_have_docutils_lines :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	doc, p := parse("Para\n\n- item\ntext\n\n+---+\n| x  |\n+---+\n")
	msgs := make([dynamic]rst.Node_Data)
	messages(&p.tree, doc, &msgs)
	testing.expect_value(t, len(msgs), 2)
	testing.expect_value(t, msgs[0].text,
		"Bullet list ends without a blank line; unexpected unindent.")
	testing.expect_value(t, msgs[0].line, 4)
	testing.expect_value(t, msgs[0].num[0], rst.WARNING)
	testing.expect_value(t, msgs[1].text, "Malformed table.\nRight border not aligned or missing.")
	testing.expect_value(t, msgs[1].line, 7)
	testing.expect_value(t, msgs[1].num[0], rst.ERROR)
}

@(test)
inline_markup :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p := rst.Parser{allocator = context.allocator, settings = rst.DEFAULT_SETTINGS}
	nodes := rst.parse_inline(&p, "**b** ``l`` `t <http://x>`_ :r:`i` [1]_ *open", 1)
	got := make([dynamic]rst.Node_Kind)
	it := rst.chain(&p.tree, nodes.first)
	for n in rst.iterate(&it) {
		if kind := rst.node_kind(&p.tree, n); kind != .Text do append(&got, kind)
	}
	testing.expect(t, slice_equal(got[:], []rst.Node_Kind {
		.Strong, .Literal, .Reference, .Interpreted, .Footnote_Reference, .Problematic,
	}))
}

@(test)
deep_nesting_is_bounded :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	b := strings.builder_make()
	for i in 0 ..< 400 {
		for _ in 0 ..< i do strings.write_byte(&b, ' ')
		strings.write_string(&b, "- x\n\n")
	}
	doc, p := parse(strings.to_string(b))
	msgs := make([dynamic]rst.Node_Data)
	messages(&p.tree, doc, &msgs)
	// reported where the limit is reached, instead of overflowing the stack
	testing.expect(t, len(msgs) > 0)
	for m in msgs do testing.expect_value(t, m.text, "Nesting too deep; content ignored.")
}

@(test)
line_length_limit :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p := rst.Parser{allocator = context.allocator, settings = rst.DEFAULT_SETTINGS}
	p.settings.line_length_limit = 10
	doc, _, final_offset := rst.parse_text(&p, "short\nthis line is too long\n", 0, true)
	testing.expect_value(t, final_offset, -1)
	message := rst.node_text(&p.tree, rst.first_child(&p.tree, doc))
	testing.expect_value(t, message, "Line 2 exceeds the line-length-limit.")
}

// Everything a parse allocates comes from the parser's allocator.
@(test)
allocates_only_from_parser_allocator :: proc(t: ^testing.T) {
	arena_buf := make([]byte, 4 * mem.Megabyte, context.temp_allocator)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	context.temp_allocator = mem.panic_allocator()

	source := "Title\n=====\n\n* a *b*\n\n  c `d <e_>`_\n\n.. [1] f\n\n=  =\nx  y\n=  =\n"
	_, _ = parse(source, mem.arena_allocator(&arena))
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, track.total_allocation_count, 0)
}

@(private = "file")
slice_equal :: proc(a, b: []rst.Node_Kind) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if x != b[i] do return false
	return true
}

// docutils' ``document.current_line`` as seen when nodes are attached: a
// comment is attached after its block (including the blank line after it) was
// consumed; a table after its cells' nested parses ran past their input.
@(test)
current_line_tracking :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	doc, p := parse(".. comment\n   more\n\nx\n\n+---+\n| a |\n+---+\n")
	comment := rst.node_data(&p.tree, rst.first_child(&p.tree, doc))
	testing.expect_value(t, comment.kind, rst.Node_Kind.Comment)
	testing.expect_value(t, comment.cur_line, 3)
	table := rst.node_data(&p.tree, rst.last_child(&p.tree, doc))
	testing.expect_value(t, table.kind, rst.Node_Kind.Table)
	testing.expect_value(t, table.cur_line, rst.CUR_NONE)
}

@(test)
html_writer_produces_valid_html :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	source :=
		"Hello World\n===========\n\n" +
		"This is **bold** and *italic* and ``code``.\n\n" +
		"- item 1\n- item 2\n\n" +
		".. note::\n   Important message.\n"
	doc, p := parse(source)
	html := rst.write_html(doc, &p, rst.Html_Config{standalone = true, embed_css = true})
	testing.expect(t, strings.contains(html, "<!DOCTYPE html>"))
	testing.expect(t, strings.contains(html, "<h1 id=\"hello-world\">"))
	testing.expect(t, strings.contains(html, "<strong>bold</strong>"))
	testing.expect(t, strings.contains(html, "<em>italic</em>"))
	testing.expect(t, strings.contains(html, "<code>code</code>"))
	testing.expect(t, strings.contains(html, "<ul>"))
	testing.expect(t, strings.contains(html, "<li>item 1</li>"))
	testing.expect(t, strings.contains(html, "<div class=\"admonition note\">"))
}

@(test)
latex_writer_produces_valid_latex :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	source :=
		"LaTeX Title\n===========\n\n" +
		"Paragraph with $100 & 50% discount.\n\n" +
		".. note::\n   Be careful.\n"
	doc, p := parse(source)
	latex := rst.write_latex(doc, &p, rst.Latex_Config{standalone = true})
	testing.expect(t, strings.contains(latex, "\\documentclass[11pt,a4paper]{article}"))
	testing.expect(t, strings.contains(latex, "\\section{"))
	testing.expect(t, strings.contains(latex, "\\$100 \\& 50\\% discount."))
	testing.expect(t, strings.contains(latex, "\\begin{quote}"))
	testing.expect(t, strings.contains(latex, "\\textbf{NOTE:}\\newline"))
	testing.expect(t, strings.contains(latex, "\\end{document}"))
}


@(test)
inline_position_locates_problems :: proc(t: ^testing.T) {
	s := "first line\nsecond *line"
	row, from_end := rst.inline_position_unpack(rst.inline_position(s, strings.index_byte(s, '*')))
	testing.expect_value(t, row, 1)
	testing.expect_value(t, from_end, len("*line"))
}

@(test)
check_reports_elm_diagnostics :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := "Title\n=====\n\n- item with *emphasis\ncontinued\n"
	messages := check.check_text(text, check.DEFAULT_OPTIONS)
	testing.expect_value(t, len(messages), 2)
	src := check.source_lines(text, 8)
	b := strings.builder_make()
	for m in messages do check.format_elm(&b, "doc.rst", src, m, false)
	report := strings.to_string(b)
	testing.expect(t, strings.contains(report, "-- UNCLOSED EMPHASIS "))
	testing.expect(t, strings.contains(report, "doc.rst:4:13\n"))
	testing.expect(t, strings.contains(report, "4| - item with *emphasis\n               ^\n"))
	hint := "Hint: Put a blank line before this line, or indent it"
	testing.expect(t, strings.contains(report, hint))
	docutils := strings.builder_make()
	check.format_docutils(&docutils, "doc.rst", messages[0])
	testing.expect_value(t, strings.to_string(docutils),
		"doc.rst:4: (WARNING/2) Inline emphasis start-string without end-string.\n")
}
