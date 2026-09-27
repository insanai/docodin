package rst

import "base:runtime"
import "core:strings"

// Port of the docutils ``Body``/``Text``/``Line`` states (the list states are in
// lists.odin).  Procedures are named after the docutils transition methods
// they implement and keep their cursor movements, so line numbers and system
// messages match docutils exactly.

Transition :: enum u8 {
	Blank,
	Indent,
	Bullet,
	Enumerator,
	Field_Marker,
	Option_Marker,
	Doctest,
	Line_Block,
	Grid_Table_Top,
	Simple_Table_Top,
	Explicit_Markup,
	Anonymous,
	Line,
	Text,
}

Line_Match :: struct {
	t:      Transition,
	end:    int,        // match.end() in bytes
	enumer: Enum_Match, // Enumerator
	name:   string,     // Field_Marker name
}

// First matching ``Body`` transition for ``line`` (docutils transition order).
classify :: proc "contextless" (line: string) -> (m: Line_Match) {
	if len(line) == 0 { m.t = .Blank; return }
	if line[0] == ' ' { m.t = .Indent; return }
	ok: bool
	if line[0] < 0x80 && ASCII_FLAGS[line[0]] & FLAG_ALNUM != 0 {
		// a word character: only an enumerator can match before 'text'
		if m.enumer, ok = match_enumerator(line); ok {
			m.t = .Enumerator
			m.end = m.enumer.end
		} else {
			m.t = .Text
		}
		return
	}
	if m.end, ok = match_bullet(line); ok { m.t = .Bullet; return }
	if m.enumer, ok = match_enumerator(line); ok {
		m.t = .Enumerator
		m.end = m.enumer.end
		return
	}
	if m.name, m.end, ok = match_field_marker(line); ok { m.t = .Field_Marker; return }
	if m.end, ok = match_option_marker(line); ok { m.t = .Option_Marker; return }
	if match_doctest(line) { m.t = .Doctest; return }
	if m.end, ok = match_line_block(line); ok { m.t = .Line_Block; return }
	if match_grid_table_top(line) { m.t = .Grid_Table_Top; return }
	if match_simple_table_top(line) { m.t = .Simple_Table_Top; return }
	if m.end, ok = match_explicit_markup(line); ok { m.t = .Explicit_Markup; return }
	if m.end, ok = match_anonymous(line); ok { m.t = .Anonymous; return }
	if match_line(line) { m.t = .Line; return }
	m.t = .Text
	return
}

// ``StateMachine.run`` with the ``Body`` state.  Transitions return true
// when a sub-state (``Text``/``Line``) hit the end of input: docutils runs
// that state's ``eof()`` and stops without reading another line.
run_body :: proc(sm: ^State_Machine) {
	for {
		line, ok := next_line(sm)
		if !ok do return
		if body_transition(sm, line) do return
	}
}

// ``RFC2822Body``: the leading run of RFC 2822 header fields (PEP reader).
run_rfc2822_body :: proc(sm: ^State_Machine) {
	for {
		line, ok := next_line(sm)
		if !ok do return
		m := classify(line)
		if m.t == .Blank do continue
		if m.t == .Indent { // whitespace transitions keep the RFC2822Body state
			body_indent(sm)
			continue
		}
		if m.t == .Text {
			if end, is_rfc := match_rfc2822(line); is_rfc {
				rfc2822_field_list(sm, line, end)
				break
			}
		}
		if body_dispatch(sm, line, m) do return
		break
	}
	run_body(sm)
}

body_transition :: proc(sm: ^State_Machine, line: string) -> (eof: bool) {
	return body_dispatch(sm, line, classify(line))
}

body_dispatch :: proc(sm: ^State_Machine, line: string, m: Line_Match) -> (eof: bool) {
	switch m.t {
	case .Blank:
	case .Indent:
		body_indent(sm)
	case .Bullet:
		body_bullet(sm, line, m.end)
	case .Enumerator:
		if !body_enumerator(sm, line, m.enumer) do return body_text(sm, line)
	case .Field_Marker:
		body_field_marker(sm, line, m.name, m.end)
	case .Option_Marker:
		if !body_option_marker(sm, line, m.end) do return body_text(sm, line)
	case .Doctest:
		body_doctest(sm)
	case .Line_Block:
		body_line_block(sm, line, m.end)
	case .Grid_Table_Top:
		body_table(sm, .Grid)
	case .Simple_Table_Top:
		body_table(sm, .Simple)
	case .Explicit_Markup:
		body_explicit_markup(sm, line, m.end)
	case .Anonymous:
		body_anonymous(sm, line, m.end)
	case .Line:
		return body_line(sm, line)
	case .Text:
		return body_text(sm, line)
	}
	return false
}

// --- block quotes -----------------------------------------------------------

body_indent :: proc(sm: ^State_Machine) {
	t := &sm.p.tree
	r := get_indented(sm)
	block_quote(sm, r.lines, r.offset, sm.parent)
	if !r.blank_finish do append_child(t, sm.parent, unindent_warning(sm, "Block quote"))
}

// ``Body.block_quote``: appends block quotes (and attributions) to ``out``.
block_quote :: proc(sm: ^State_Machine, lines: []string, line_offset: int, out: Node) {
	t := &sm.p.tree
	indented := lines
	offset := line_offset
	before := t.nodes[out].last
	// docutils attaches the block quotes and attribution messages together,
	// after the loop
	defer {
		it := children_after(t, out, before)
		for bq in iterate(&it) do t.nodes[bq].cur_line = i32(sm.p.cur_line)
	}
	for len(indented) > 0 {
		bq := make_node(sm, .Block_Quote, offset + 1)
		t.nodes[bq].raw = join_block(sm.p, indented)
		split := split_attribution(sm, indented, offset)
		nested_parse(sm, split.quote, offset, bq)
		append_child(t, out, bq)
		span_block(sm.p, bq, indented[0], split.quote)
		if !split.found do break
		attr := make_node(sm, .Attribution, 1 + offset + split.attr_offset)
		t.nodes[attr].num[1] = i32(reporter_line(sm))
		t.nodes[attr].cur_line = i32(sm.p.cur_line)
		t.nodes[attr].raw = rstrip(join_block(sm.p, split.attribution))
		attr_text := t.nodes[attr].raw
		inlines := parse_inline_lines(sm.p, split.attribution, attr_text, int(t.nodes[attr].line))
		append_chain(t, attr, inlines.first)
		append_child(t, bq, attr)
		span_block(sm.p, attr, indented[split.attr_offset], split.attribution)
		span_children(sm.p, bq, 0, span_start(sm.p, bq))
		indented = split.rest
		offset = split.rest_offset
		for len(indented) > 0 && len(indented[0]) == 0 {
			indented = indented[1:]
			offset += 1
		}
	}
}

Attribution_Split :: struct {
	quote:       []string,
	attribution: []string,
	attr_offset: int,
	rest:        []string,
	rest_offset: int,
	found:       bool,
}

// attribution_pattern: (---?(?!-)|—) *(?=[^ \n])  -> match.end() or -1
match_attribution :: proc "contextless" (line: string) -> int {
	i := 0
	if len(line) >= 3 && line[:3] == "—" {
		i = 3
	} else if len(line) >= 2 && line[0] == '-' && line[1] == '-' {
		if len(line) >= 3 && line[2] == '-' {
			i = 3
			if len(line) > 3 && line[3] == '-' do return -1
		} else {
			i = 2
		}
	} else {
		return -1
	}
	for i < len(line) && line[i] == ' ' do i += 1
	if i >= len(line) || line[i] == '\n' do return -1
	return i
}

split_attribution :: proc(
	sm: ^State_Machine,
	indented: []string,
	line_offset: int,
) -> (
	r: Attribution_Split,
) {
	blank := -2
	nonblank_seen := false
	for i in 0 ..< len(indented) {
		line := indented[i]
		if len(line) == 0 {
			blank = i
			continue
		}
		if nonblank_seen && blank == i - 1 {
			if mend := match_attribution(line); mend >= 0 {
				if r = attribution_at(sm, indented, line_offset, i, mend); r.found do return
			}
		}
		nonblank_seen = true
	}
	r.quote = indented
	return
}

// The split at a candidate attribution line ``i`` (``found`` when valid).
@(private = "file")
attribution_at :: proc(
	sm: ^State_Machine,
	indented: []string,
	line_offset, i, mend: int,
) -> (
	r: Attribution_Split,
) {
	attribution_end, indent, ok := check_attribution(indented, i)
	if !ok do return
	end := min(attribution_end, len(indented))
	a_lines := make([]string, end - i, sm.p.allocator)
	copy(a_lines, indented[i:end])
	a_lines[0] = a_lines[0][mend:]
	for k in 1 ..< len(a_lines) do a_lines[k] = cp_slice(a_lines[k], indent)
	r.quote = indented[:i]
	r.attribution = a_lines
	r.attr_offset = i
	r.rest = indented[end:]
	r.rest_offset = line_offset + attribution_end
	r.found = true
	return
}

check_attribution :: proc "contextless" (
	indented: []string,
	start: int,
) -> (
	end: int,
	indent: int,
	ok: bool,
) {
	indent = -1
	i := start + 1
	broke := false
	for j := start + 1; j < len(indented); j += 1 {
		i = j
		line := indented[j]
		if len(line) == 0 {
			broke = true
			break
		}
		li := leading_ws(line)
		if indent < 0 {
			indent = li
		} else if li != indent {
			return 0, 0, false
		}
	}
	if !broke do i += 1
	return i, max(indent, 0), true
}

// --- doctest & line blocks ----------------------------------------------------

body_doctest :: proc(sm: ^State_Machine) {
	t := &sm.p.tree
	lineno := abs_line_number(sm)
	block, _ := get_text_block(sm)
	n := make_node(sm, .Doctest_Block, lineno)
	t.nodes[n].text = join_block(sm.p, block)
	append_child(t, sm.parent, n)
	if len(block) > 0 do span_block(sm.p, n, block[0], block)
}

body_line_block :: proc(sm: ^State_Machine, line: string, end: int) {
	t := &sm.p.tree
	block := make_node(sm, .Line_Block, abs_line_number(sm))
	append_child(t, sm.parent, block)
	lineno := abs_line_number(sm)
	ln, blank_finish := line_block_line(sm, line, end, lineno)
	append_child(t, block, ln)
	if !blank_finish {
		// LineBlock state (blank lines end the block)
		frozen := begin_nested_list(sm)
		defer end_nested_list(sm, frozen)
		for {
			l, ok := next_line(sm)
			if !ok do break
			m := classify(l)
			if m.t != .Line_Block {
				previous_line(sm)
				break
			}
			ln2, bf := line_block_line(sm, l, m.end, abs_line_number(sm))
			append_child(t, block, ln2)
			blank_finish = bf
		}
	}
	if !blank_finish {
		msg := make_message(sm.p, WARNING, "Line block ends without a blank line.", lineno + 1)
		append_child(t, sm.parent, msg)
	}
	// docutils attaches the nested blocks created below at this line
	t.nodes[block].cur_line = i32(sm.p.cur_line)
	if first := t.nodes[block].first; first != NO_NODE {
		if t.nodes[first].num[0] < 0 do t.nodes[first].num[0] = 0
		nest_line_block_lines(sm, block)
	}
	span_children(sm.p, block, 0)
}

line_block_line :: proc(
	sm: ^State_Machine,
	line: string,
	end: int,
	lineno: int,
) -> (
	ln: Node,
	blank_finish: bool,
) {
	t := &sm.p.tree
	r := get_first_known_indented(sm, cp_len(line[:end]), until_blank = true)
	text := join_block(sm.p, r.lines)
	ln = make_node(sm, .Line, lineno)
	t.nodes[ln].raw = text
	t.nodes[ln].num[1] = i32(reporter_line(sm)) // indent lives in num[0]
	t.nodes[ln].cur_line = i32(sm.p.cur_line)
	append_chain(t, ln, parse_inline_lines(sm.p, r.lines, text, lineno).first)
	span_block(sm.p, ln, line, r.lines)
	t.nodes[ln].num[0] = -1 // indent None
	if rstrip(line) != "|" do t.nodes[ln].num[0] = i32(end - 2) // len(match.group(1)) - 1
	return ln, r.blank_finish
}

nest_line_block_lines :: proc(sm: ^State_Machine, block: Node) {
	t := &sm.p.tree
	prev: i32 = 0
	it := children(t, block)
	for c in iterate(&it) {
		if t.nodes[c].num[0] < 0 do t.nodes[c].num[0] = prev
		prev = t.nodes[c].num[0]
	}
	nest_line_block_segment(sm, block, 0)
}

// Lines deeper than this many distinct indentation levels stay flat
// (docutils would recurse until RecursionError).
MAX_LINE_BLOCK_DEPTH :: 64

nest_line_block_segment :: proc(sm: ^State_Machine, block: Node, depth: int) {
	t := &sm.p.tree
	if depth >= MAX_LINE_BLOCK_DEPTH do return
	least := max(i32)
	it := children(t, block)
	for c in iterate(&it) do least = min(least, t.nodes[c].num[0])
	items := Node_List{}
	sub := NO_NODE
	it = children(t, block)
	for c in iterate(&it) {
		if t.nodes[c].num[0] > least {
			if sub == NO_NODE do sub = make_node(sm, .Line_Block, int(t.nodes[c].line))
			append_child(t, sub, c)
		} else {
			if sub != NO_NODE {
				nest_line_block_segment(sm, sub, depth + 1)
				span_children(sm.p, sub, 0)
				list_append(t, &items, sub)
				sub = NO_NODE
			}
			list_append(t, &items, c)
		}
	}
	if sub != NO_NODE {
		nest_line_block_segment(sm, sub, depth + 1)
		span_children(sm.p, sub, 0)
		list_append(t, &items, sub)
	}
	set_children(t, block, items)
}

// --- transitions & section titles ---------------------------------------------

// ``Body.line``: section title overline or transition marker.
body_line :: proc(sm: ^State_Machine, line: string) -> (eof: bool) {
	t := &sm.p.tree
	if sm.match_titles do return line_state(sm, line)
	stripped := strip(line)
	if stripped == "::" do return body_text(sm, line)
	if len(stripped) < 4 {
		append_child(t, sm.parent, make_message(sm.p, INFO,
			"Unexpected possible title overline or transition.\n" +
			"Treating it as ordinary text because it's so short.",
			abs_line_number(sm)))
		return body_text(sm, line)
	}
	append_child(t, sm.parent, make_message_block(sm.p, ERROR,
		"Unexpected section title or transition.", line, abs_line_number(sm)))
	return false
}

// ``Line`` state: second line of an overlined title or a transition.
line_state :: proc(sm: ^State_Machine, overline: string) -> (eof: bool) {
	t := &sm.p.tree
	a := sm.p.allocator
	l2, ok := next_line(sm)
	if !ok { // Line.eof
		if len(strip(overline)) < 4 do return state_correction(sm, 1)
		tr := make_node(sm, .Transition, abs_line_number(sm) - 1)
		t.nodes[tr].raw = overline
		append_child(t, sm.parent, tr)
		span_string(sm.p, tr, strip(overline))
		return true
	}
	if len(l2) == 0 { // Line.blank
		marker := strip(overline)
		if len(marker) < 4 do return state_correction(sm, 1)
		tr := make_node(sm, .Transition, abs_line_number(sm) - 1)
		t.nodes[tr].raw = marker
		append_child(t, sm.parent, tr)
		span_string(sm.p, tr, marker)
		return false
	}
	if l2[0] != ' ' && match_line(l2) { // Line.underline
		blocktext := concat(overline, "\n", l2, allocator = a)
		lineno := abs_line_number(sm) - 1
		if len(rstrip(overline)) < 4 do return short_overline(sm, lineno, 1)
		append_child(t, sm.parent, make_message_block(sm.p, ERROR,
			"Invalid section title or transition marker.", blocktext, lineno))
		return false
	}
	return line_title(sm, overline, l2)
}

// ``Line.text`` / ``Line.indent``: potential over- & underlined title.
@(private = "file")
line_title :: proc(sm: ^State_Machine, overline, l2: string) -> (eof: bool) {
	t := &sm.p.tree
	a := sm.p.allocator
	lineno := abs_line_number(sm) - 1
	title := l2
	l3, ok3 := next_line(sm)
	if !ok3 { // EOF raised inside the transition method: the run continues
		blocktext := concat(overline, "\n", title, allocator = a)
		if len(rstrip(overline)) < 4 do return short_overline(sm, lineno, 2)
		append_child(t, sm.parent, make_message_block(sm.p, ERROR,
			"Incomplete section title.", blocktext, lineno))
		return false
	}
	source := concat(overline, "\n", title, "\n", l3, allocator = a)
	ov := rstrip(overline)
	un := rstrip(l3)
	if !match_line(un) {
		if len(ov) < 4 do return short_overline(sm, lineno, 2)
		append_child(t, sm.parent, make_message_block(sm.p, ERROR,
			"Missing matching underline for section title overline.", source, lineno))
		return false
	} else if ov != un {
		if len(ov) < 4 do return short_overline(sm, lineno, 2)
		append_child(t, sm.parent, make_message_block(sm.p, ERROR,
			"Title overline & underline mismatch.", source, lineno))
		return false
	}
	title = rstrip(title)
	messages: Node_List
	if column_width(title) > len(ov) {
		if len(ov) < 4 do return short_overline(sm, lineno, 2)
		msg := make_message_block(sm.p, WARNING, "Title overline too short.", source, lineno)
		list_append(t, &messages, msg)
	}
	style := concat(ov[:1], un[:1], allocator = a)
	emit_section_title(sm, lstrip(title), source, style, lineno + 1, messages, {overline, un})
	return false
}

@(private = "file")
short_overline :: proc(sm: ^State_Machine, lineno: int, lines: int) -> (eof: bool) {
	t := &sm.p.tree
	append_child(t, sm.parent, make_message(sm.p, INFO,
		"Possible incomplete section title.\n" +
		"Treating the overline as ordinary text because it's so short.",
		lineno))
	return state_correction(sm, lines)
}

// ``Line.state_correction`` + the ``StateCorrection('Body', 'text')`` retry:
// back up and treat the overline as ordinary text.
@(private = "file")
state_correction :: proc(sm: ^State_Machine, lines: int) -> (eof: bool) {
	previous_line(sm, lines)
	// run loop: previous_line(); next_line() -> the overline again
	previous_line(sm)
	line, _ := next_line(sm)
	return body_text(sm, line)
}

// ``lines``: the first and the last adornment or title line (spans).
emit_section_title :: proc(
	sm: ^State_Machine,
	title: string,
	source: string,
	style: string,
	lineno: int,
	messages: Node_List,
	lines: [2]string,
) {
	t := &sm.p.tree
	n := make_node(sm, .Section_Title, lineno)
	t.nodes[n].raw = title
	t.nodes[n].text = source
	t.nodes[n].name = style
	tn := make_node(sm, .Title, lineno)
	t.nodes[tn].raw = title
	t.nodes[tn].num[1] = i32(reporter_line(sm))
	append_chain(t, tn, parse_inline(sm.p, title, lineno).first)
	append_child(t, n, tn)
	append_chain(t, n, messages.first)
	append_child(t, sm.parent, n)
	span_string(sm.p, tn, title)
	span_block(sm.p, n, lines[0], []string{lines[1]})
}

// --- Text state: paragraphs, definition lists, titles --------------------------

// ``Body.text`` followed by the ``Text`` state on the next line.  Returns
// true when the ``Text`` state hit the end of input (``Text.eof``).
body_text :: proc(sm: ^State_Machine, line1: string) -> (eof: bool) {
	l2, ok := next_line(sm)
	if !ok {
		text_blank(sm, line1)
		return true
	}
	if len(l2) == 0 {
		text_blank(sm, line1)
		return false
	}
	if l2[0] == ' ' {
		text_indent(sm, line1)
		return false
	}
	if match_line(l2) && text_underline(sm, line1, l2) do return false
	text_text(sm, line1)
	return false
}

// ``Text.blank`` / ``Text.eof``: end of a one-line paragraph.
@(private = "file")
text_blank :: proc(sm: ^State_Machine, line1: string) {
	lines := [1]string{line1}
	literalnext := paragraph(sm, lines[:], abs_line_number(sm) - 1, sm.parent)
	if literalnext do literal_block(sm, sm.parent)
}

// ``Text.text``: multi-line paragraph.
@(private = "file")
text_text :: proc(sm: ^State_Machine, line1: string) {
	t := &sm.p.tree
	startline := abs_line_number(sm) - 1
	block, err_line := get_text_block(sm, flush_left = true)
	lines := make([]string, len(block) + 1, sm.p.allocator)
	lines[0] = line1
	copy(lines[1:], block)
	literalnext := paragraph(sm, lines, startline, sm.parent)
	if err_line > 0 {
		msg := make_message(sm.p, ERROR, "Unexpected indentation.", err_line)
		append_child(t, sm.parent, mark_source_line(sm.p, msg))
	}
	if literalnext {
		next_line(sm)
		literal_block(sm, sm.parent)
	}
}

// ``Text.underline``; false means "TransitionCorrection('text')".
@(private = "file")
text_underline :: proc(sm: ^State_Machine, line1: string, l2: string) -> bool {
	t := &sm.p.tree
	a := sm.p.allocator
	lineno := abs_line_number(sm)
	title := rstrip(line1)
	underline := rstrip(l2)
	source := concat(title, "\n", underline, allocator = a)
	messages: Node_List
	if column_width(title) > len(underline) {
		if len(underline) < 4 {
			if sm.match_titles {
				append_child(t, sm.parent, make_message(sm.p, INFO,
					"Possible title underline, too short for the title.\n" +
					"Treating it as ordinary text because it's so short.",
					lineno))
			}
			return false
		}
		blocktext := concat(line1, "\n", l2, allocator = a)
		msg := make_message_block(sm.p, WARNING, "Title underline too short.", blocktext, lineno)
		list_append(t, &messages, msg)
	}
	if !sm.match_titles {
		blocktext := concat(line1, "\n", l2, allocator = a)
		append_chain(t, sm.parent, messages.first)
		msg := make_message_block(sm.p, ERROR,
			"Unexpected section title.", blocktext, source_line(sm, abs_line_number(sm)))
		append_child(t, sm.parent, mark_source_line(sm.p, msg))
		return true
	}
	emit_section_title(sm, title, source, underline[:1], lineno - 1, messages, {line1, underline})
	return true
}

// ``RSTState.paragraph``: appends the paragraph to ``out``; returns whether a
// literal block follows ("::").
paragraph :: proc(
	sm: ^State_Machine,
	lines: []string,
	lineno: int,
	out: Node,
) -> (
	literalnext: bool,
) {
	t := &sm.p.tree
	data := rstrip(join_block(sm.p, lines))
	text := data
	if ends_with_literal_marker(data) {
		if len(data) == 2 do return true
		switch data[len(data) - 3] {
		case ' ', '\n':
			text = rstrip(data[:len(data) - 3])
		case:
			text = data[:len(data) - 1]
		}
		literalnext = true
	}
	para := make_node(sm, .Paragraph, lineno)
	t.nodes[para].raw = data
	t.nodes[para].num[1] = i32(reporter_line(sm))
	t.nodes[para].cur_line = i32(sm.p.cur_line)
	append_chain(t, para, parse_inline_lines(sm.p, lines, text, lineno).first)
	append_child(t, out, para)
	if sp := sm.p.spans; sp != nil {
		end := joined_offset(sp, lines, nil, len(data))
		set_span(sm.p, para, source_offset(sp, lines[0], 0), end)
	}
	return
}

// re.search(r'(?<!\\)(\\\\)*::$', data)
ends_with_literal_marker :: proc "contextless" (data: string) -> bool {
	n := len(data)
	if n < 2 || data[n - 1] != ':' || data[n - 2] != ':' do return false
	backslashes := 0
	for i := n - 3; i >= 0 && data[i] == '\\'; i -= 1 do backslashes += 1
	return backslashes % 2 == 0
}

// ``Text.literal_block``: indented or quoted literal block after "::".
literal_block :: proc(sm: ^State_Machine, out: Node) {
	t := &sm.p.tree
	r := get_indented(sm)
	lines := r.lines
	for len(lines) > 0 && len(lines[len(lines) - 1]) == 0 do lines = lines[:len(lines) - 1]
	if len(lines) == 0 {
		quoted_literal_block(sm, out)
		return
	}
	lb := make_node(sm, .Literal_Block, r.offset + 1)
	t.nodes[lb].text = join_block(sm.p, lines)
	t.nodes[lb].raw = t.nodes[lb].text
	append_child(t, out, lb)
	span_block(sm.p, lb, lines[0], lines)
	if !r.blank_finish do append_child(t, out, unindent_warning(sm, "Literal block"))
}

// ``Text.quoted_literal_block`` with the ``QuotedLiteralBlock`` state.
quoted_literal_block :: proc(sm: ^State_Machine, out: Node) {
	t := &sm.p.tree
	offset := max(sm.line_offset, 0)
	lines := sm.lines[min(offset, len(sm.lines)):]
	q := make_state_machine(sm.p, lines, abs_line_offset(sm), out)
	messages: Node_List
	ctx_start, ctx_end, initial_lineno := scan_quoted_literal(&q, &messages)
	// QuotedLiteralBlock.eof
	before := t.nodes[out].last
	if ctx_start >= 0 {
		lb := make_node(sm, .Literal_Block, initial_lineno)
		t.nodes[lb].text = join_block(sm.p, lines[ctx_start:ctx_end])
		t.nodes[lb].raw = t.nodes[lb].text
		append_child(t, out, lb)
		span_block(sm.p, lb, lines[ctx_start], lines[ctx_start:ctx_end])
	} else {
		append_child(t, out, make_message(sm.p, WARNING,
			"Literal block expected; none found.", abs_line_number(&q)))
		previous_line(&q)
	}
	append_chain(t, out, messages.first)
	goto_line(sm, abs_line_offset(&q))
	// docutils collects these in a detached container and attaches them
	// after returning to the enclosing machine's line
	it := children_after(t, out, before)
	for n in iterate(&it) {
		if t.nodes[n].kind == .System_Message do t.nodes[n].cur_line = i32(sm.p.cur_line)
	}
}

// The ``QuotedLiteralBlock`` state loop: the quoted lines' offsets
// (``ctx_start`` -1 when none) and the first one's line number.
@(private = "file")
scan_quoted_literal :: proc(
	q: ^State_Machine,
	messages: ^Node_List,
) -> (
	ctx_start, ctx_end, initial_lineno: int,
) {
	t := &q.p.tree
	ctx_start, ctx_end = -1, -1
	quote: byte = 0
	for {
		line, ok := next_line(q)
		if !ok do break
		if quote != 0 && len(line) > 0 && line[0] == quote { // 'quoted' (checked first)
			ctx_end = q.line_offset + 1
			continue
		}
		if len(line) == 0 { // blank
			if ctx_start >= 0 do break
			continue
		}
		if line[0] == ' ' { // indent
			list_append(t, messages, make_message(q.p, ERROR,
				"Unexpected indentation.", abs_line_number(q)))
			previous_line(q)
			break
		}
		if quote == 0 && is_punct7(line[0]) { // initial_quoted
			quote = line[0]
			initial_lineno = abs_line_number(q)
			ctx_start, ctx_end = q.line_offset, q.line_offset + 1
			continue
		}
		// text
		if ctx_start >= 0 {
			list_append(t, messages, make_message(q.p, ERROR,
				"Inconsistent literal block quoting.", abs_line_number(q)))
			previous_line(q)
		}
		break
	}
	return
}

// ``Text.indent``: definition list.
@(private = "file")
text_indent :: proc(sm: ^State_Machine, termline: string) {
	t := &sm.p.tree
	dl := make_node(sm, .Definition_List, abs_line_number(sm) - 1)
	item, blank_finish := definition_list_item(sm, termline)
	append_child(t, dl, item)
	append_child(t, sm.parent, dl)
	// DefinitionList state, with the Definition state for second lines
	frozen := begin_nested_list(sm)
	defer end_nested_list(sm, frozen)
	for {
		l, ok := next_line(sm)
		if !ok do break
		m := classify(l)
		if m.t == .Blank do continue
		if m.t != .Text {
			previous_line(sm)
			break
		}
		l2, ok2 := next_line(sm)
		if !ok2 || len(l2) == 0 || l2[0] != ' ' {
			previous_line(sm, 2)
			break
		}
		it, bf := definition_list_item(sm, l)
		append_child(t, dl, it)
		blank_finish = bf
	}
	span_children(sm.p, dl, 0)
	if !blank_finish do append_child(t, sm.parent, unindent_warning(sm, "Definition list"))
}

definition_list_item :: proc(
	sm: ^State_Machine,
	termline: string,
) -> (
	item: Node,
	blank_finish: bool,
) {
	t := &sm.p.tree
	dd_lineno := abs_line_number(sm)
	dt_lineno := dd_lineno - 1
	r := get_indented(sm)
	item = make_node(sm, .Definition_List_Item, dt_lineno)
	t.nodes[item].raw = concat(
		termline, "\n" if len(r.lines) > 0 else "", join_block(sm.p, r.lines),
		allocator = sm.p.allocator,
	)
	term(sm, termline, dt_lineno, item)
	dd := make_node(sm, .Definition, dd_lineno)
	append_child(t, item, dd)
	if strings.has_suffix(termline, "::") {
		append_child(t, dd, make_message(sm.p, INFO,
			"Blank line missing before literal block (after the \"::\")? " +
			"Interpreted as a definition list item.",
			dd_lineno))
	}
	nested_parse(sm, r.lines, r.offset, dd)
	span_block(sm.p, item, termline, r.lines)
	span_lines(sm.p, dd, r.lines, span_end(sm.p, item))
	return item, r.blank_finish
}

// ``Text.term``: the term and optional classifiers, appended to ``item``.
term :: proc(sm: ^State_Machine, line: string, lineno: int, item: Node) {
	t := &sm.p.tree
	a := sm.p.allocator
	dt := make_node(sm, .Term, lineno)
	t.nodes[dt].raw = line
	t.nodes[dt].num[1] = i32(reporter_line(sm))
	t.nodes[dt].cur_line = i32(sm.p.cur_line)
	append_child(t, item, dt)
	current := dt
	it := chain(t, parse_inline(sm.p, line, lineno).first)
	for n in iterate(&it) {
		pieces: [dynamic]string
		if t.nodes[n].kind == .Text do pieces = split_classifiers(t.nodes[n].text, a)
		if len(pieces) <= 1 {
			append_child(t, current, n)
			continue
		}
		head := make_node(sm, .Text, lineno)
		t.nodes[head].text = rstrip(pieces[0])
		append_child(t, current, head)
		span_classifier_piece(sm.p, line, n, head)
		for part in pieces[1:] {
			c := make_node(sm, .Classifier, lineno)
			t.nodes[c].raw = unescape(part, a, restore_backslashes = true)
			txt := make_node(sm, .Text, lineno)
			t.nodes[txt].text = part
			append_child(t, c, txt)
			append_child(t, item, c)
			span_classifier_piece(sm.p, line, n, txt)
			current = c
		}
	}
	if sm.p.spans == nil do return
	// the term from the line start, the classifiers over their pieces
	start := source_offset(sm.p.spans, line, 0)
	span_children(sm.p, dt, start, start)
	it = children(t, item)
	for c in iterate(&it) do if t.nodes[c].kind == .Classifier do span_children(sm.p, c, 0)
}

// The span of ``piece``, a Text node cut from the Text node ``whole`` of
// the inline markup of the single line ``line``.
@(private = "file")
span_classifier_piece :: proc(p: ^Parser, line: string, whole, piece: Node) {
	sp := p.spans
	if sp == nil do return
	t := &p.tree
	whole_start, _ := node_span(t, whole)
	k := 0 // offset of ``whole`` in ``line``
	for k < len(line) && source_offset(sp, line, k) < whole_start do k += 1
	k += int(uintptr(raw_data(t.nodes[piece].text)) - uintptr(raw_data(t.nodes[whole].text)))
	text := t.nodes[piece].text
	set_span(p, piece, source_offset(sp, line, k), source_offset(sp, line, k + len(text)))
}

// re.split(' +: +', text)
@(private = "file")
split_classifiers :: proc(text: string, a: runtime.Allocator) -> [dynamic]string {
	pieces := make([dynamic]string, 0, 2, a)
	start, i := 0, 0
	for i < len(text) {
		if text[i] != ' ' {
			i += 1
			continue
		}
		j := i
		for j < len(text) && text[j] == ' ' do j += 1
		if j < len(text) && text[j] == ':' && j + 1 < len(text) && text[j + 1] == ' ' {
			k := j + 1
			for k < len(text) && text[k] == ' ' do k += 1
			append(&pieces, text[start:i])
			start = k
			i = k
		} else {
			i = j
		}
	}
	append(&pieces, text[start:])
	return pieces
}
