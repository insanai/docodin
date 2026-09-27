package rst_tests

import "core:testing"

import rst "../rst"

// Source positions (``Parse_Flag.Spans``) and the editor line index.

@(private = "file")
parse_spans :: proc(text: string, on := true) -> (doc: rst.Node, p: rst.Parser) {
	p = rst.Parser {
		allocator = context.allocator,
		settings  = rst.DEFAULT_SETTINGS,
	}
	p.settings.spans = on
	doc, _, _ = rst.parse_text(&p, text, 0, true)
	return
}

// The first node of ``kind`` in document order (the ``nth`` one from 0).
@(private = "file")
find :: proc(t: ^rst.Tree, n: rst.Node, kind: rst.Node_Kind, nth := 0) -> rst.Node {
	count := nth
	return find_from(t, n, kind, &count)
}

@(private = "file")
find_from :: proc(t: ^rst.Tree, n: rst.Node, kind: rst.Node_Kind, count: ^int) -> rst.Node {
	if rst.node_kind(t, n) == kind {
		if count^ == 0 do return n
		count^ -= 1
	}
	it := rst.children(t, n)
	for c in rst.iterate(&it) {
		if found := find_from(t, c, kind, count); found != rst.NO_NODE do return found
	}
	return rst.NO_NODE
}

@(private = "file")
source_of :: proc(t: ^rst.Tree, text: string, n: rst.Node) -> string {
	start, end := rst.node_span(t, n)
	return text[start:end]
}

@(test)
spans_cover_constructs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := "=====\nTitle\n=====\n\nPara *em* and ``lit``\nref_.\n\n" +
		".. note:: Body\n   more\n\n- item\n\n  nested\n\n:field: value\n\n" +
		"+---+-----+\n| a | b   |\n|   | two |\n+---+-----+\n"
	doc, p := parse_spans(text)
	tree := &p.tree
	testing.expect(t, rst.has_spans(tree))
	Case :: struct {
		kind: rst.Node_Kind,
		nth:  int,
		want: string,
	}
	cases := []Case {
		{.Document, 0, text},
		{.Section_Title, 0, "=====\nTitle\n====="},
		{.Title, 0, "Title"},
		{.Paragraph, 0, "Para *em* and ``lit``\nref_."},
		{.Emphasis, 0, "*em*"},
		{.Literal, 0, "``lit``"},
		{.Reference, 0, "ref_"},
		{.Text, 2, " and "},
		{.Directive, 0, ".. note:: Body\n   more"},
		{.Bullet_List, 0, "- item\n\n  nested"},
		{.Field, 0, ":field: value"},
		{.Field_Name, 0, ":field:"},
		{.Field_Body, 0, "value"},
		{.Table, 0, "+---+-----+\n| a | b   |\n|   | two |\n+---+-----+"},
		{.Entry, 1, "b   |\n|   | two"}, // a cell spans its first to its last text
		{.Paragraph, 5, "b   |\n|   | two"},
	}
	for c in cases {
		n := find(tree, doc, c.kind, c.nth)
		testing.expectf(t, n != rst.NO_NODE, "no %v", c.kind)
		if n == rst.NO_NODE do continue
		testing.expectf(t, source_of(tree, text, n) == c.want, "%v %d: %q, want %q",
			c.kind, c.nth, source_of(tree, text, n), c.want)
	}
}

// Rewritten lines (tabs) map back to the source bytes.
@(test)
spans_through_tabs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := "Para\twith *em*\n\n\tquoted *e*\n"
	doc, p := parse_spans(text)
	tree := &p.tree
	testing.expect_value(t, source_of(tree, text, find(tree, doc, .Emphasis)), "*em*")
	testing.expect_value(t, source_of(tree, text, find(tree, doc, .Block_Quote)), "quoted *e*")
	testing.expect_value(t, source_of(tree, text, find(tree, doc, .Emphasis, 1)), "*e*")
}

// Spans change nothing else, and are off by default.
@(test)
spans_leave_the_tree_unchanged :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := "T\n=\n\n* a *b* c_\n\n  1. x\n\n.. [1] f\n\n=  =\nx  y\n=  =\n\n| l\n|  m\n"
	_, off := parse_spans(text, on = false)
	_, on := parse_spans(text)
	testing.expect(t, !rst.has_spans(&off.tree))
	testing.expect_value(t, len(off.tree.nodes), len(on.tree.nodes))
	for i in 1 ..< len(off.tree.nodes) {
		a := rst.node_data(&off.tree, rst.Node(i))
		b := rst.node_data(&on.tree, rst.Node(i))
		testing.expect(t, a == b)
	}
}

// Children lie inside their parents (messages report a line instead).
@(test)
spans_nest :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := "Title\n=====\n\n* a *b*\n\n  c `d <e_>`_\n\n.. [1] f\n\n=  =\nx  y\n=  =\n\n" +
		"Term : cls\n   Def\n\n-o  option\n\n| l\n|   m\n\n    quote\n\n    -- who\n"
	doc, p := parse_spans(text)
	check_nesting(t, &p.tree, doc, len(text))
}

@(private = "file")
check_nesting :: proc(t: ^testing.T, tree: ^rst.Tree, n: rst.Node, text_len: int) {
	start, end := rst.node_span(tree, n)
	testing.expect(t, 0 <= start && start <= end && end <= text_len)
	if rst.node_kind(tree, n) == .System_Message do return
	it := rst.children(tree, n)
	for c in rst.iterate(&it) {
		if rst.node_kind(tree, c) == .System_Message do continue
		cs, ce := rst.node_span(tree, c)
		testing.expectf(t, start <= cs && ce <= end, "%v %d..%d outside %v %d..%d",
			rst.node_kind(tree, c), cs, ce, rst.node_kind(tree, n), start, end)
		check_nesting(t, tree, c, text_len)
	}
}

@(test)
message_spans_report_their_line :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := "Para\n\n- item\n  text\ntext *open\n"
	doc, p := parse_spans(text)
	msg := find(&p.tree, doc, .System_Message)
	testing.expect_value(t, rst.node_line(&p.tree, msg), 5)
	testing.expect_value(t, source_of(&p.tree, text, msg), "text *open")
}

@(test)
line_table :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := "a\r\n  b  c\n"
	lines, starts := rst.split_lines_table(text, 8, context.allocator)
	testing.expect_value(t, len(lines), 3)
	testing.expect_value(t, len(starts), 4)
	testing.expect_value(t, starts[1], 3)
	testing.expect_value(t, starts[2], 10)
	testing.expect_value(t, starts[3], u32(len(text)))
	_, p := parse_spans(text)
	start, end := rst.line_span(&p.tree, 2)
	testing.expect_value(t, text[start:end], "b")
	testing.expect_value(t, rst.offset_line(&p.tree, 10), 3)
	testing.expect_value(t, rst.offset_line(&p.tree, len(text)), 3)
}

@(test)
line_index_positions :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := "aé\U0001F600b\r\nx\ry\n"
	idx := rst.line_index_make(text)
	b := 1 + 2 + 4 // byte offset of 'b'
	line, col := rst.line_col(&idx, b)
	testing.expect_value(t, line, 0)
	testing.expect_value(t, col, 4) // a, é, and a surrogate pair
	testing.expect_value(t, rst.line_col_offset(&idx, 0, 4), b)
	testing.expect_value(t, rst.line_col_offset(&idx, 0, 3), 3) // inside the pair
	testing.expect_value(t, rst.line_col_offset(&idx, 0, 99), b + 1) // before "\r\n"
	line, col = rst.line_col(&idx, len(text) - 2) // 'y' after a lone '\r'
	testing.expect_value(t, line, 2)
	testing.expect_value(t, col, 0)
	line, col = rst.line_col(&idx, len(text) + 5)
	testing.expect_value(t, line, 3)
	testing.expect_value(t, col, 0)
	testing.expect_value(t, rst.line_col_offset(&idx, 9, 0), len(text))
	for want, enc in ([rst.Position_Encoding]int{.UTF16 = 4, .UTF8 = 7, .UTF32 = 3}) {
		idx.encoding = enc
		_, col = rst.line_col(&idx, b)
		testing.expect_value(t, col, want)
		testing.expect_value(t, rst.line_col_offset(&idx, 0, want), b)
	}
	ascii := rst.line_index_make("ab\ncd")
	line, col = rst.line_col(&ascii, 4)
	testing.expect(t, ascii.ascii && line == 1 && col == 1)
}
