package rst_tests

import "core:mem"
import "core:strings"
import "core:testing"

import rst "../rst"

// Unit tests of the parser package (``odin test odin/tests``).  Conformance
// with docutils is tested from Python (tests/), against docutils itself.

@(private = "file")
parse :: proc(text: string, allocator := context.allocator) -> (doc: ^rst.Node, p: rst.Parser) {
	p = rst.Parser {
		allocator = allocator,
		settings  = rst.DEFAULT_SETTINGS,
	}
	doc, _, _ = rst.parse_text(&p, text, 0, true)
	return
}

@(private = "file")
kinds :: proc(n: ^rst.Node) -> []rst.Node_Kind {
	out := make([dynamic]rst.Node_Kind, context.temp_allocator)
	for c := n.first; c != nil; c = c.next do append(&out, c.kind)
	return out[:]
}

@(private = "file")
messages :: proc(n: ^rst.Node, out: ^[dynamic]^rst.Node) {
	for c := n.first; c != nil; c = c.next {
		if c.kind == .System_Message do append(out, c)
		messages(c, out)
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
	doc, _ := parse("Title\n=====\n\nPara *em*.\n\n- a\n- b\n\n::\n\n  code\n\n----\n\n.. note:: x\n")
	testing.expect(t, slice_equal(kinds(doc), []rst.Node_Kind {
		.Section_Title, .Paragraph, .Bullet_List, .Literal_Block, .Transition, .Directive,
	})) // a lone "::" paragraph is dropped
	para := doc.first.next
	testing.expect(t, slice_equal(kinds(para), []rst.Node_Kind{.Text, .Emphasis, .Text}))
	testing.expect_value(t, rst.child_count(para.next), 2)
	directive := doc.last
	testing.expect_value(t, directive.name, "note")
	info := directive.extra.(^rst.Directive_Info)
	testing.expect_value(t, info.lines[0], "x")
}

@(test)
tables :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	doc, _ := parse("+---+---+\n| a | b |\n+===+===+\n| c | d |\n+---+---+\n\n=  =\nx  y\n=  =\n")
	testing.expect(t, slice_equal(kinds(doc), []rst.Node_Kind{.Table, .Table}))
	msgs := make([dynamic]^rst.Node)
	messages(doc, &msgs)
	testing.expect_value(t, len(msgs), 0)
}

@(test)
system_messages_have_docutils_lines :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	doc, _ := parse("Para\n\n- item\ntext\n\n+---+\n| x  |\n+---+\n")
	msgs := make([dynamic]^rst.Node)
	messages(doc, &msgs)
	testing.expect_value(t, len(msgs), 2)
	testing.expect_value(t, msgs[0].text, "Bullet list ends without a blank line; unexpected unindent.")
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
	for n := nodes.first; n != nil; n = n.next do if n.kind != .Text do append(&got, n.kind)
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
	doc, _ := parse(strings.to_string(b))
	msgs := make([dynamic]^rst.Node)
	messages(doc, &msgs)
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
	testing.expect_value(t, doc.first.text, "Line 2 exceeds the line-length-limit.")
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

	_, _ = parse("Title\n=====\n\n* a *b*\n\n  c `d <e_>`_\n\n.. [1] f\n\n=  =\nx  y\n=  =\n", mem.arena_allocator(&arena))
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
	doc, _ := parse(".. comment\n   more\n\nx\n\n+---+\n| a |\n+---+\n")
	comment := doc.first
	testing.expect_value(t, comment.kind, rst.Node_Kind.Comment)
	testing.expect_value(t, comment.cur_line, 3)
	table := doc.last
	testing.expect_value(t, table.kind, rst.Node_Kind.Table)
	testing.expect_value(t, table.cur_line, rst.CUR_NONE)
}
