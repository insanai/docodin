package rst

import "base:runtime"
import "core:strings"

// Parser-wide state shared by all (nested) state machines of one parse.
Parser :: struct {
	allocator:   runtime.Allocator,
	settings:    Settings,
	root:        ^State_Machine, // the outermost machine (reporter line lookups)
	root_line:   int,            // host-supplied "current line" for nested host parses
	depth:       int,            // nesting depth of state machines
	// docutils ``document.current_line``: every state machine reports its
	// cursor moves to ``document.note_source`` (see ``observe``).  A line
	// number, or CUR_NONE / CUR_NO_SOURCE.
	cur_line:    int,
	tree:        Tree, // the nodes of this parse
}

CUR_NONE      :: 0  // line None (cursor just past the end of its input)
CUR_NO_SOURCE :: -1 // line and source None (cursor further out)

// Maximum nesting of block structures.  docutils itself fails with a
// RecursionError between 150 and 200 levels; beyond this limit the content
// is reported (ERROR) instead of risking a native or host stack overflow.
MAX_NESTING :: 160

// Equivalent of a docutils (nested) ``StateMachineWS`` positioned over a
// block of lines.  Line offsets are 0-based; absolute offsets add
// ``input_offset``.
State_Machine :: struct {
	p:            ^Parser,
	lines:        []string,
	input_offset: int,
	line_offset:  int,
	match_titles: bool,
	parent:       Node, // docutils ``state_machine.node``
	// Source line minus absolute line number.  docutils nests table cells
	// with a 1-based ``input_offset``, so inside cells absolute numbers run
	// one ahead of the StringList source information (-1 there, else 0).
	line_delta:   int,
	// docutils parses the 2nd+ members of list-like constructs in a nested
	// state machine, so the root machine (whose line the reporter uses for
	// messages without an explicit line) stays where the first member ended.
	// The specialized-state loops here run in place and freeze that line.
	frozen_line:  int,
}

make_state_machine :: proc(
	p: ^Parser,
	lines: []string,
	input_offset: int,
	parent: Node,
	match_titles := false,
) -> State_Machine {
	return State_Machine {
		p = p,
		lines = lines,
		input_offset = input_offset,
		line_offset = -1,
		match_titles = match_titles,
		parent = parent,
	}
}

// --- cursor ----------------------------------------------------------------

// ``StateMachine.next_line``: advance ``n`` lines; ``ok`` is false past the end
// (``line_offset`` keeps the advanced value, like docutils).
next_line :: #force_inline proc "contextless" (
	sm: ^State_Machine,
	n := 1,
) -> (
	line: string,
	ok: bool,
) {
	sm.line_offset += n
	observe(sm)
	if sm.line_offset < 0 || sm.line_offset >= len(sm.lines) do return "", false
	return sm.lines[sm.line_offset], true
}

previous_line :: #force_inline proc "contextless" (sm: ^State_Machine, n := 1) {
	sm.line_offset -= n
	observe(sm)
}

// ``StateMachine.goto_line`` (absolute offset).
goto_line :: #force_inline proc "contextless" (sm: ^State_Machine, abs_offset: int) {
	sm.line_offset = abs_offset - sm.input_offset
	observe(sm)
}

// ``StateMachine.notify_observers`` -> ``document.note_source``: the
// source line of ``input_lines.info(line_offset)``.  Python indexing: a
// negative offset counts from the end; one past the end has no line.
observe :: #force_inline proc "contextless" (sm: ^State_Machine) {
	n, i := len(sm.lines), sm.line_offset
	switch {
	case i >= 0 && i < n:  sm.p.cur_line = sm.input_offset + i + 1 + sm.line_delta
	case i < 0 && i >= -n: sm.p.cur_line = sm.input_offset + n + i + 1 + sm.line_delta
	case i == n && n > 0:  sm.p.cur_line = CUR_NONE
	case:                  sm.p.cur_line = CUR_NO_SOURCE
	}
}

current_line :: #force_inline proc "contextless" (sm: ^State_Machine) -> string {
	if sm.line_offset < 0 || sm.line_offset >= len(sm.lines) do return ""
	return sm.lines[sm.line_offset]
}

abs_line_offset :: #force_inline proc "contextless" (sm: ^State_Machine) -> int {
	return sm.line_offset + sm.input_offset
}

abs_line_number :: #force_inline proc "contextless" (sm: ^State_Machine) -> int {
	return sm.line_offset + sm.input_offset + 1
}

is_next_line_blank :: #force_inline proc "contextless" (sm: ^State_Machine) -> bool {
	i := sm.line_offset + 1
	if i < 0 || i >= len(sm.lines) do return true
	return len(sm.lines[i]) == 0
}

at_eof :: #force_inline proc "contextless" (sm: ^State_Machine) -> bool {
	return sm.line_offset >= len(sm.lines) - 1
}

// Line number docutils' reporter uses for messages without an explicit
// line: the current line of the outermost state machine.
reporter_line :: proc "contextless" (sm: ^State_Machine) -> int {
	if sm.p.root_line > 0 do return sm.p.root_line
	root := sm.p.root if sm.p.root != nil else sm
	if root.frozen_line > 0 do return root.frozen_line
	return abs_line_number(root)
}

// Enter a docutils ``nested_list_parse``: returns the previous frozen line,
// to be passed to ``end_nested_list``.
begin_nested_list :: #force_inline proc "contextless" (sm: ^State_Machine) -> int {
	saved := sm.frozen_line
	if saved == 0 do sm.frozen_line = abs_line_number(sm)
	return saved
}

end_nested_list :: #force_inline proc "contextless" (sm: ^State_Machine, saved: int) {
	sm.frozen_line = saved
}

// --- indented blocks (StringList.get_indented & friends) -------------------

// Result of an indented-block extraction.
Indented :: struct {
	lines:        []string,
	indent:       int,  // amount of indentation removed (code points)
	offset:       int,  // absolute offset of lines[0]
	blank_finish: bool, // block ended with a blank line or at EOF
}

// ``StringList.get_indented(start, until_blank, strip_indent, block_indent,
// first_indent)``.  Indents are in code points; -1 means "None".
string_list_get_indented :: proc(
	sm: ^State_Machine,
	start: int,
	until_blank, strip_indent: bool,
	block_indent := -1,
	first_indent := -1,
) -> (block: []string, indent: int, blank_finish: bool) {
	lines := sm.lines
	indent = block_indent
	first := first_indent
	if block_indent >= 0 && first < 0 do first = block_indent
	if start < 0 do return nil, max(indent, 0), true
	end := start
	if first >= 0 do end += 1
	last := len(lines)
	end, indent, blank_finish = scan_indented(lines, start, end, until_blank, block_indent, indent)
	if end <= start || start >= last {
		return nil, max(indent, 0), blank_finish
	}
	block = make([]string, end - start, sm.p.allocator)
	copy(block, lines[start:end])
	if first >= 0 do block[0] = cp_slice(block[0], first)
	if indent > 0 && strip_indent {
		for i in (1 if first >= 0 else 0) ..< len(block) {
			block[i] = cp_slice(block[i], indent)
		}
	}
	return block, max(indent, 0), blank_finish
}

// The scanning loop of ``StringList.get_indented``: the end of the indented
// block starting at ``end`` and the minimal indent found (unless given).
@(private = "file")
scan_indented :: proc(
	lines: []string,
	start, first_end: int,
	until_blank: bool,
	block_indent, indent_in: int,
) -> (
	end, indent: int,
	blank_finish: bool,
) {
	end, indent = first_end, indent_in
	blank_finish = true
	for end < len(lines) {
		line := lines[end]
		if len(line) > 0 &&
		   (line[0] != ' ' || (block_indent >= 0 && leading_ws(line) < block_indent)) {
			// Line not indented or insufficiently indented.
			blank_finish = end > start && len(lines[end - 1]) == 0
			break
		}
		if len(line) == 0 {
			if until_blank {
				blank_finish = true
				break
			}
		} else if block_indent < 0 {
			li := leading_ws(line)
			indent = li if indent < 0 else min(indent, li)
		}
		end += 1
	}
	return
}

// ``StateMachineWS.get_indented``
get_indented :: proc(
	sm: ^State_Machine,
	until_blank := false,
	strip_indent := true,
) -> (
	r: Indented,
) {
	r.offset = abs_line_offset(sm)
	r.lines, r.indent, r.blank_finish = string_list_get_indented(
		sm, sm.line_offset, until_blank, strip_indent,
	)
	if len(r.lines) > 0 do next_line(sm, len(r.lines) - 1)
	for len(r.lines) > 0 && len(r.lines[0]) == 0 {
		r.lines = r.lines[1:]
		r.offset += 1
	}
	return
}

// ``StateMachineWS.get_known_indented``
get_known_indented :: proc(
	sm: ^State_Machine,
	indent: int,
	until_blank := false,
	strip_indent := true,
) -> (
	r: Indented,
) {
	r.offset = abs_line_offset(sm)
	r.lines, r.indent, r.blank_finish = string_list_get_indented(
		sm, sm.line_offset, until_blank, strip_indent, block_indent = indent,
	)
	next_line(sm, len(r.lines) - 1)
	for len(r.lines) > 0 && len(r.lines[0]) == 0 {
		r.lines = r.lines[1:]
		r.offset += 1
	}
	return
}

// ``StateMachineWS.get_first_known_indented``
get_first_known_indented :: proc(
	sm: ^State_Machine,
	indent: int,
	until_blank := false,
	strip_indent := true,
	strip_top := true,
) -> (r: Indented) {
	r.offset = abs_line_offset(sm)
	r.lines, r.indent, r.blank_finish = string_list_get_indented(
		sm, sm.line_offset, until_blank, strip_indent, first_indent = indent,
	)
	next_line(sm, len(r.lines) - 1)
	if strip_top {
		for len(r.lines) > 0 && len(strip(r.lines[0])) == 0 {
			r.lines = r.lines[1:]
			r.offset += 1
		}
	}
	return
}

// ``StateMachine.get_text_block``.  ``indent_error_line`` is the absolute
// line number of an unexpectedly indented line (``flush_left``), else 0.
get_text_block :: proc(
	sm: ^State_Machine,
	flush_left := false,
) -> (
	block: []string,
	indent_error_line: int,
) {
	start := sm.line_offset
	end := start
	for end < len(sm.lines) {
		line := sm.lines[end]
		if len(line) == 0 do break
		if flush_left && line[0] == ' ' {
			indent_error_line = source_line(sm, end + sm.input_offset + 1)
			break
		}
		end += 1
	}
	if start < 0 || start > len(sm.lines) do return nil, indent_error_line
	block = sm.lines[start:end]
	next_line(sm, len(block) - 1)
	return
}

// --- node helpers ------------------------------------------------------------

make_node :: #force_inline proc(sm: ^State_Machine, kind: Node_Kind, line: int) -> Node {
	return new_node(&sm.p.tree, kind, line)
}

// A system message.  ``line`` 0 means "no line given".
make_message :: proc(p: ^Parser, level: int, message: string, line: int) -> Node {
	t := &p.tree
	n := new_node(t, .System_Message, line)
	t.nodes[n].text = message
	t.nodes[n].num[0] = i32(level)
	t.nodes[n].cur_line = i32(p.cur_line) // docutils attaches messages where they are created
	return n
}

// A system message carrying a literal block (docutils idiom).
make_message_block :: proc(
	p: ^Parser,
	level: int,
	message: string,
	block: string,
	line: int,
) -> Node {
	n := make_message(p, level, message, line)
	t := &p.tree
	lit := new_node(t, .Literal_Block, 0)
	t.nodes[lit].text = block
	t.nodes[lit].raw = block
	append_child(t, n, lit)
	return n
}

INFO :: 1
WARNING :: 2
ERROR :: 3
SEVERE :: 4

// Decimal representation of ``n`` (allocated).
int_str :: proc(n: int, allocator: runtime.Allocator) -> string {
	buf: [32]byte
	return strings.clone(itoa(buf[:], n), allocator)
}

// Decimal representation of ``n`` in ``buf`` (no allocation).
itoa :: proc "contextless" (buf: []byte, n: int) -> string {
	v := n
	neg := v < 0
	i := len(buf)
	for {
		i -= 1
		d := v % 10
		buf[i] = byte('0' + (-d if neg else d))
		v /= 10
		if v == 0 do break
	}
	if neg {
		i -= 1
		buf[i] = '-'
	}
	return string(buf[i:])
}

join_lines :: proc(lines: []string, allocator: runtime.Allocator) -> string {
	switch len(lines) {
	case 0: return ""
	case 1: return lines[0]
	}
	return strings.join(lines, "\n", allocator)
}

concat :: proc(parts: ..string, allocator := context.allocator) -> string {
	return strings.concatenate(parts, allocator)
}

// docutils ``unindent_warning``: "<X> ends without a blank line; unexpected unindent."
unindent_warning :: proc(sm: ^State_Machine, node_name: string) -> Node {
	msg := concat(
		node_name, " ends without a blank line; unexpected unindent.",
		allocator = sm.p.allocator,
	)
	return make_message(sm.p, WARNING, msg, abs_line_number(sm) + 1)
}

// Nested parse of ``lines`` into ``node`` (``RSTState.nested_parse`` with the
// default ``match_titles=False``).
nested_parse :: proc(
	sm: ^State_Machine,
	lines: []string,
	input_offset: int,
	node: Node,
	line_delta := 0,
) {
	p := sm.p
	if p.depth >= MAX_NESTING {
		block := join_lines(lines, p.allocator)
		msg := make_message_block(
			p, ERROR, "Nesting too deep; content ignored.", block, input_offset + 1,
		)
		append_child(&p.tree, node, msg)
		return
	}
	p.depth += 1
	defer p.depth -= 1
	nsm := make_state_machine(p, lines, input_offset, node)
	nsm.line_delta = sm.line_delta + line_delta
	run_body(&nsm)
}

// Line number as docutils' ``get_source_and_line()`` reports it (from the
// StringList items rather than the absolute offset).
source_line :: #force_inline proc "contextless" (sm: ^State_Machine, abs_line: int) -> int {
	return abs_line + sm.line_delta
}
