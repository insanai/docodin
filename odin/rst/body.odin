package rst

import "core:strconv"
import "core:strings"

// Port of the docutils ``Body``/``Text``/``Line`` states and the specialized
// list states.  Procedures are named after the docutils transition methods
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
	if m.end, ok = match_bullet(line); ok { m.t = .Bullet; return }
	if m.enumer, ok = match_enumerator(line); ok { m.t = .Enumerator; m.end = m.enumer.end; return }
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
	r := get_indented(sm)
	block_quote(sm, r.lines, r.offset, sm.parent)
	if !r.blank_finish do append_child(sm.parent, unindent_warning(sm, "Block quote"))
}

// ``Body.block_quote``: appends block quotes (and attributions) to ``out``.
block_quote :: proc(sm: ^State_Machine, lines: []string, line_offset: int, out: ^Node) {
	indented := lines
	offset := line_offset
	before := out.last
	// docutils attaches the block quotes and attribution messages together,
	// after the loop
	defer for bq := before.next if before != nil else out.first; bq != nil; bq = bq.next {
		bq.cur_line = i32(sm.p.cur_line)
	}
	for len(indented) > 0 {
		bq := make_node(sm, .Block_Quote, offset + 1)
		bq.raw = join_lines(indented, sm.p.allocator)
		split := split_attribution(sm, indented, offset)
		nested_parse(sm, split.quote, offset, bq)
		append_child(out, bq)
		if !split.found do break
		attr := make_node(sm, .Attribution, 1 + offset + split.attr_offset)
		attr.num[1] = i32(reporter_line(sm))
		attr.cur_line = i32(sm.p.cur_line)
		attr.raw = rstrip(join_lines(split.attribution, sm.p.allocator))
		append_chain(attr, parse_inline(sm.p, attr.raw, int(attr.line)).first)
		append_child(bq, attr)
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

split_attribution :: proc(sm: ^State_Machine, indented: []string, line_offset: int) -> (r: Attribution_Split) {
	blank := -2
	nonblank_seen := false
	for i in 0 ..< len(indented) {
		line := indented[i]
		if len(line) > 0 {
			if nonblank_seen && blank == i - 1 {
				if mend := match_attribution(line); mend >= 0 {
					attribution_end, indent, ok := check_attribution(indented, i)
					if ok {
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
				}
			}
			nonblank_seen = true
		} else {
			blank = i
		}
	}
	r.quote = indented
	return
}

check_attribution :: proc "contextless" (indented: []string, start: int) -> (end: int, indent: int, ok: bool) {
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

// --- lists --------------------------------------------------------------------

// ``Body.list_item``: parse one list item starting at the current line.
list_item :: proc(sm: ^State_Machine, indent: int) -> (item: ^Node, blank_finish: bool) {
	line := current_line(sm)
	lineno := abs_line_number(sm)
	indent_cp := cp_len(line[:indent])
	r: Indented
	if len(line) > indent {
		r = get_known_indented(sm, indent_cp)
	} else {
		r = get_first_known_indented(sm, indent_cp)
	}
	item = make_node(sm, .List_Item, lineno)
	item.raw = join_lines(r.lines, sm.p.allocator)
	if len(r.lines) > 0 do nested_parse(sm, r.lines, r.offset, item)
	return item, r.blank_finish
}

body_bullet :: proc(sm: ^State_Machine, line: string, end: int) {
	ul := make_node(sm, .Bullet_List, abs_line_number(sm))
	_, w := rune_at(line, 0)
	ul.name = line[:w]
	append_child(sm.parent, ul)
	item, blank_finish := list_item(sm, end)
	append_child(ul, item)
	// BulletList state
	frozen := begin_nested_list(sm)
	defer end_nested_list(sm, frozen)
	for {
		l, ok := next_line(sm)
		if !ok do break
		m := classify(l)
		if m.t == .Blank do continue
		if m.t != .Bullet || !strings.has_prefix(l, ul.name) {
			previous_line(sm)
			break
		}
		it, bf := list_item(sm, m.end)
		append_child(ul, it)
		blank_finish = bf
	}
	if !blank_finish do append_child(sm.parent, unindent_warning(sm, "Bullet list"))
}

ORDINAL_NONE :: min(int)

// ``Body.parse_enumerator``
parse_enumerator :: proc "contextless" (m: Enum_Match, expected := Enum_Sequence.None) -> (seq: Enum_Sequence, ordinal: int) {
	text := m.text
	if text == "#" {
		seq = .Auto
	} else if expected != .None {
		if sequence_matches(expected, text) do seq = expected
	} else if text == "i" {
		seq = .Lowerroman
	} else if text == "I" {
		seq = .Upperroman
	}
	if seq == .None {
		for s in ([]Enum_Sequence{.Arabic, .Loweralpha, .Upperalpha, .Lowerroman, .Upperroman}) {
			if sequence_matches(s, text) {
				seq = s
				break
			}
		}
	}
	switch seq {
	case .Auto:
		ordinal = 1
	case .Arabic:
		ordinal = 0
		for i in 0 ..< len(text) {
			if ordinal > max(int) / 20 do break // saturate absurdly long numbers
			ordinal = ordinal * 10 + int(text[i] - '0')
		}
	case .Loweralpha:
		ordinal = int(text[0]) - 'a' + 1
	case .Upperalpha:
		ordinal = int(text[0]) - 'A' + 1
	case .Lowerroman, .Upperroman:
		ordinal = roman_to_int(text)
		if ordinal == 0 do ordinal = ORDINAL_NONE
	case .None:
		ordinal = ORDINAL_NONE
	}
	return
}

// ``enum.sequenceregexps[sequence].match(text)`` (patterns end with '$').
sequence_matches :: proc "contextless" (seq: Enum_Sequence, text: string) -> bool {
	if len(text) == 0 do return false
	switch seq {
	case .Arabic:
		for i in 0 ..< len(text) do if text[i] < '0' || text[i] > '9' do return false
		return true
	case .Loweralpha:
		return len(text) == 1 && text[0] >= 'a' && text[0] <= 'z'
	case .Upperalpha:
		return len(text) == 1 && text[0] >= 'A' && text[0] <= 'Z'
	case .Lowerroman:
		for i in 0 ..< len(text) {
			switch text[i] {
			case 'i', 'v', 'x', 'l', 'c', 'd', 'm':
			case: return false
			}
		}
		return true
	case .Upperroman:
		for i in 0 ..< len(text) {
			switch text[i] {
			case 'I', 'V', 'X', 'L', 'C', 'D', 'M':
			case: return false
			}
		}
		return true
	case .Auto, .None:
	}
	return false
}

// ``Body.make_enumerator``: next enumerator and auto-enumerator prefixes.
make_enumerator :: proc(ordinal: int, seq: Enum_Sequence, format: Enum_Format, buf: []byte) -> (next_enum: string, auto_enum: string, ok: bool) {
	num_buf: [32]byte
	enumerator: string
	switch seq {
	case .Auto:
		enumerator = "#"
	case .Arabic:
		enumerator = strconv.write_int(num_buf[:], i64(ordinal), 10)
	case .Loweralpha, .Upperalpha:
		if ordinal > 26 || ordinal < 1 do return
		num_buf[0] = byte(ordinal - 1) + ('a' if seq == .Loweralpha else 'A')
		enumerator = string(num_buf[:1])
	case .Lowerroman, .Upperroman:
		enumerator = int_to_roman(ordinal, num_buf[:])
		if len(enumerator) == 0 do return
		if seq == .Lowerroman {
			for i in 0 ..< len(enumerator) do num_buf[i] += 32
		}
	case .None:
		return
	}
	prefix, suffix := ENUM_PREFIX[format], ENUM_SUFFIX[format]
	n := 0
	for s in ([]string{prefix, enumerator, suffix, " "}) {
		n += copy(buf[n:], s)
	}
	next_enum = string(buf[:n])
	m := n
	for s in ([]string{prefix, "#", suffix, " "}) {
		m += copy(buf[m:], s)
	}
	auto_enum = string(buf[n:m])
	ok = true
	return
}

// ``Body.is_enumerated_list_item``
is_enumerated_list_item :: proc(sm: ^State_Machine, ordinal: int, seq: Enum_Sequence, format: Enum_Format) -> bool {
	if ordinal == ORDINAL_NONE do return false
	next, ok := next_line(sm)
	previous_line(sm)
	if !ok do return true
	if len(next) == 0 do return true
	r, _ := rune_at(next, 0)
	if is_space(r) do return true
	buf: [96]byte
	if next_enum, auto_enum, made := make_enumerator(ordinal + 1, seq, format, buf[:]); made {
		if strings.has_prefix(next, next_enum) || strings.has_prefix(next, auto_enum) do return true
	}
	return false
}

@(private = "file")
seq_or_arabic :: #force_inline proc "contextless" (seq: Enum_Sequence) -> Enum_Sequence {
	return .Arabic if seq == .Auto else seq
}

// ``Body.enumerator``; false means "TransitionCorrection('text')".
body_enumerator :: proc(sm: ^State_Machine, line: string, m: Enum_Match) -> bool {
	seq, ordinal := parse_enumerator(m)
	if !is_enumerated_list_item(sm, ordinal, seq, m.format) do return false
	el := make_node(sm, .Enumerated_List, abs_line_number(sm))
	append_child(sm.parent, el)
	list_seq := seq_or_arabic(seq)
	el.name = ENUM_SEQUENCE_NAMES[list_seq]
	el.text = ENUM_PREFIX[m.format]
	el.raw = ENUM_SUFFIX[m.format]
	if ordinal != 1 {
		el.num[0] = i32(clamp(ordinal, int(min(i32)), int(max(i32))))
		el.num[1] = 1
		msg := strings.concatenate({"Enumerated list start value not ordinal-1: \"", m.text, "\" (ordinal ", int_str(ordinal, sm.p.allocator), ")"}, sm.p.allocator)
		// reported with ``base_node=enumlist``: the node's (source) line
		append_child(sm.parent, make_message(sm.p, INFO, msg, source_line(sm, int(el.line))))
	}
	item, blank_finish := list_item(sm, m.end)
	append_child(el, item)
	// EnumeratedList state
	frozen := begin_nested_list(sm)
	defer end_nested_list(sm, frozen)
	lastordinal := ordinal
	auto := seq == .Auto
	for {
		l, ok := next_line(sm)
		if !ok do break
		lm := classify(l)
		if lm.t == .Blank do continue
		valid := false
		if lm.t == .Enumerator {
			s2, o2 := parse_enumerator(lm.enumer, list_seq)
			valid = lm.enumer.format == m.format
			if valid && s2 != .Auto {
				valid = s2 == list_seq && !auto && o2 != ORDINAL_NONE && o2 == lastordinal + 1
			}
			valid = valid && is_enumerated_list_item(sm, o2, s2, lm.enumer.format)
			if valid {
				if s2 == .Auto do auto = true
				it, bf := list_item(sm, lm.end)
				append_child(el, it)
				blank_finish = bf
				lastordinal = o2
				continue
			}
		}
		previous_line(sm)
		break
	}
	if !blank_finish do append_child(sm.parent, unindent_warning(sm, "Enumerated list"))
	return true
}

// --- field lists ----------------------------------------------------------------

body_field_marker :: proc(sm: ^State_Machine, line: string, name: string, end: int) {
	fl := make_node(sm, .Field_List, abs_line_number(sm))
	append_child(sm.parent, fl)
	f, blank_finish := field(sm, line, name, end)
	append_child(fl, f)
	// FieldList state
	frozen := begin_nested_list(sm)
	defer end_nested_list(sm, frozen)
	for {
		l, ok := next_line(sm)
		if !ok do break
		m := classify(l)
		if m.t == .Blank do continue
		if m.t != .Field_Marker {
			previous_line(sm)
			break
		}
		f2, bf := field(sm, l, m.name, m.end)
		append_child(fl, f2)
		blank_finish = bf
	}
	if !blank_finish do append_child(sm.parent, unindent_warning(sm, "Field list"))
}

// ``Body.field``: children are ``Field_Name`` (raw = name, inline children)
// and ``Field_Body``.
field :: proc(sm: ^State_Machine, line: string, name: string, end: int) -> (f: ^Node, blank_finish: bool) {
	lineno := abs_line_number(sm)
	r := get_first_known_indented(sm, cp_len(line[:end]))
	f = make_node(sm, .Field, lineno)
	fname := make_node(sm, .Field_Name, lineno)
	fname.raw = name
	fname.num[1] = i32(reporter_line(sm))
	fname.cur_line = i32(sm.p.cur_line)
	append_chain(fname, parse_inline(sm.p, name, lineno).first)
	append_child(f, fname)
	fbody := make_node(sm, .Field_Body, lineno)
	fbody.raw = join_lines(r.lines, sm.p.allocator)
	append_child(f, fbody)
	if len(r.lines) > 0 do nested_parse(sm, r.lines, r.offset, fbody)
	return f, r.blank_finish
}

// ``RFC2822Body.rfc2822``
rfc2822_field_list :: proc(sm: ^State_Machine, line: string, end: int) {
	fl := make_node(sm, .Field_List, abs_line_number(sm))
	fl.name = "rfc2822"
	append_child(sm.parent, fl)
	f, blank_finish := rfc2822_field(sm, line, end)
	append_child(fl, f)
	// RFC2822List state
	frozen := begin_nested_list(sm)
	defer end_nested_list(sm, frozen)
	for {
		l, ok := next_line(sm)
		if !ok do break
		m := classify(l)
		if m.t == .Text {
			if e, is_rfc := match_rfc2822(l); is_rfc {
				f2, bf := rfc2822_field(sm, l, e)
				append_child(fl, f2)
				blank_finish = bf
				continue
			}
		}
		previous_line(sm)
		break
	}
	if !blank_finish do append_child(sm.parent, unindent_warning(sm, "RFC2822-style field list"))
}

rfc2822_field :: proc(sm: ^State_Machine, line: string, end: int) -> (f: ^Node, blank_finish: bool) {
	name := line[:strings.index_byte(line, ':')]
	lineno := abs_line_number(sm)
	r := get_first_known_indented(sm, cp_len(line[:end]), until_blank = true)
	f = make_node(sm, .Field, lineno)
	fname := make_node(sm, .Field_Name, lineno)
	fname.raw = name // plain text (no inline parsing)
	t := make_node(sm, .Text, lineno)
	t.text = name
	append_child(fname, t)
	append_child(f, fname)
	fbody := make_node(sm, .Field_Body, lineno)
	fbody.raw = join_lines(r.lines, sm.p.allocator)
	append_child(f, fbody)
	if len(r.lines) > 0 do nested_parse(sm, r.lines, r.offset, fbody)
	return f, r.blank_finish
}

// --- option lists -------------------------------------------------------------

// ``Body.option_marker``; false means "TransitionCorrection('text')".
body_option_marker :: proc(sm: ^State_Machine, line: string, end: int) -> bool {
	lineno := abs_line_number(sm)
	item, blank_finish, status, err := option_list_item(sm, line, end)
	switch status {
	case .Not_Item:
		return false
	case .Markup_Error:
		// "This shouldn't happen; pattern won't match." — kept for fidelity.
		append_child(sm.parent, make_message(sm.p, ERROR, concat("Invalid option list marker: ", err, allocator = sm.p.allocator), reporter_line(sm)))
		r := get_first_known_indented(sm, cp_len(line[:end]))
		block_quote(sm, r.lines, r.offset, sm.parent)
		if !r.blank_finish do append_child(sm.parent, unindent_warning(sm, "Option list"))
		return true
	case .Ok:
	}
	ol := make_node(sm, .Option_List, lineno)
	append_child(sm.parent, ol)
	append_child(ol, item)
	// OptionList state
	frozen := begin_nested_list(sm)
	defer end_nested_list(sm, frozen)
	for {
		l, ok := next_line(sm)
		if !ok do break
		m := classify(l)
		if m.t == .Blank do continue
		if m.t == .Option_Marker {
			it, bf, st, _ := option_list_item(sm, l, m.end)
			if st == .Ok {
				append_child(ol, it)
				blank_finish = bf
				continue
			}
		}
		previous_line(sm)
		break
	}
	if !blank_finish do append_child(sm.parent, unindent_warning(sm, "Option list"))
	return true
}

Option_Status :: enum u8 {Ok, Not_Item, Markup_Error}

option_list_item :: proc(sm: ^State_Machine, line: string, end: int) -> (item: ^Node, blank_finish: bool, status: Option_Status, err: string) {
	offset := abs_line_offset(sm)
	lineno := abs_line_number(sm)
	group := make_node(sm, .Option_Group, lineno)
	if err = parse_option_marker(sm, line[:end], group); err != "" {
		return nil, false, .Markup_Error, err
	}
	r := get_first_known_indented(sm, cp_len(line[:end]))
	if len(r.lines) == 0 {
		goto_line(sm, offset)
		return nil, false, .Not_Item, ""
	}
	item = make_node(sm, .Option_List_Item, lineno)
	desc := make_node(sm, .Description, lineno)
	desc.raw = join_lines(r.lines, sm.p.allocator)
	append_child(item, group)
	append_child(item, desc)
	nested_parse(sm, r.lines, r.offset, desc)
	item.cur_line = i32(sm.p.cur_line)
	return item, r.blank_finish, .Ok, ""
}

// ``Body.parse_option_marker``: fills ``group`` with ``Option`` nodes.
// Returns the ``MarkupError`` text on failure.
parse_option_marker :: proc(sm: ^State_Machine, marker: string, group: ^Node) -> (err: string) {
	a := sm.p.allocator
	text := rstrip(marker)
	// re.split(r', (?![^<]*>)', text)
	pieces := make([dynamic]string, 0, 2, a)
	start := 0
	for i := 0; i + 1 < len(text); i += 1 {
		if text[i] != ',' || text[i + 1] != ' ' do continue
		inside := false
		for j := i + 2; j < len(text); j += 1 {
			if text[j] == '<' do break
			if text[j] == '>' {
				inside = true
				break
			}
		}
		if inside do continue
		append(&pieces, text[start:i])
		start = i + 2
		i += 1
	}
	append(&pieces, text[start:])
	for optionstring in pieces {
		tokens := make([dynamic]string, 0, 3, a)
		for t in split_whitespace(optionstring, a) do append(&tokens, t)
		if len(tokens) == 0 do return option_markup_error(sm, 0, optionstring)
		delimiter := " "
		if eq := strings.index_byte(tokens[0], '='); eq >= 0 {
			first, rest := tokens[0][:eq], tokens[0][eq + 1:]
			tokens[0] = first
			inject_at(&tokens, 1, rest)
			delimiter = "="
		} else if cp_len(tokens[0]) > 2 && ((tokens[0][0] == '-' && !strings.has_prefix(tokens[0], "--")) || tokens[0][0] == '+') {
			first, rest := tokens[0][:2], tokens[0][2:]
			tokens[0] = first
			inject_at(&tokens, 1, rest)
			delimiter = ""
		}
		if len(tokens) > 1 && strings.has_prefix(tokens[1], "<") && strings.has_suffix(tokens[len(tokens) - 1], ">") {
			joined := strings.join(tokens[1:], " ", a)
			resize(&tokens, 2)
			tokens[1] = joined
		}
		if len(tokens) > 2 do return option_markup_error(sm, len(tokens), optionstring)
		opt := make_node(sm, .Option, int(group.line))
		opt.raw = optionstring
		os := make_node(sm, .Option_String, int(group.line))
		os.text = tokens[0]
		append_child(opt, os)
		if len(tokens) > 1 {
			arg := make_node(sm, .Option_Argument, int(group.line))
			arg.text = tokens[1]
			arg.name = delimiter
			append_child(opt, arg)
		}
		append_child(group, opt)
	}
	return ""
}

@(private = "file")
option_markup_error :: proc(sm: ^State_Machine, count: int, optionstring: string) -> string {
	return strings.concatenate({
		"wrong number of option tokens (=", int_str(count, sm.p.allocator),
		"), should be 1 or 2: \"", optionstring, "\"",
	}, sm.p.allocator)
}

// --- doctest & line blocks ----------------------------------------------------

body_doctest :: proc(sm: ^State_Machine) {
	lineno := abs_line_number(sm)
	block, _ := get_text_block(sm)
	n := make_node(sm, .Doctest_Block, lineno)
	n.text = join_lines(block, sm.p.allocator)
	append_child(sm.parent, n)
}

body_line_block :: proc(sm: ^State_Machine, line: string, end: int) {
	block := make_node(sm, .Line_Block, abs_line_number(sm))
	append_child(sm.parent, block)
	lineno := abs_line_number(sm)
	ln, blank_finish := line_block_line(sm, line, end, lineno)
	append_child(block, ln)
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
			append_child(block, ln2)
			blank_finish = bf
		}
	}
	if !blank_finish {
		append_child(sm.parent, make_message(sm.p, WARNING, "Line block ends without a blank line.", lineno + 1))
	}
	// docutils attaches the nested blocks created below at this line
	block.cur_line = i32(sm.p.cur_line)
	if block.first != nil {
		if block.first.num[0] < 0 do block.first.num[0] = 0
		nest_line_block_lines(sm, block)
	}
}

line_block_line :: proc(sm: ^State_Machine, line: string, end: int, lineno: int) -> (ln: ^Node, blank_finish: bool) {
	r := get_first_known_indented(sm, cp_len(line[:end]), until_blank = true)
	text := join_lines(r.lines, sm.p.allocator)
	ln = make_node(sm, .Line, lineno)
	ln.raw = text
	ln.num[1] = i32(reporter_line(sm)) // indent lives in num[0]
	ln.cur_line = i32(sm.p.cur_line)
	append_chain(ln, parse_inline(sm.p, text, lineno).first)
	ln.num[0] = -1 // indent None
	if rstrip(line) != "|" do ln.num[0] = i32(end - 2) // len(match.group(1)) - 1
	return ln, r.blank_finish
}

nest_line_block_lines :: proc(sm: ^State_Machine, block: ^Node) {
	prev: i32 = 0
	for c := block.first; c != nil; c = c.next {
		if c.num[0] < 0 do c.num[0] = prev
		prev = c.num[0]
	}
	nest_line_block_segment(sm, block, 0)
}

// Lines deeper than this many distinct indentation levels stay flat
// (docutils would recurse until RecursionError).
MAX_LINE_BLOCK_DEPTH :: 64

nest_line_block_segment :: proc(sm: ^State_Machine, block: ^Node, depth: int) {
	if depth >= MAX_LINE_BLOCK_DEPTH do return
	least := max(i32)
	for c := block.first; c != nil; c = c.next do least = min(least, c.num[0])
	items := Node_List{}
	sub: ^Node = nil
	for c := block.first; c != nil; {
		next := c.next
		if c.num[0] > least {
			if sub == nil do sub = make_node(sm, .Line_Block, int(c.line))
			append_child(sub, c)
		} else {
			if sub != nil {
				nest_line_block_segment(sm, sub, depth + 1)
				list_append(&items, sub)
				sub = nil
			}
			list_append(&items, c)
		}
		c = next
	}
	if sub != nil {
		nest_line_block_segment(sm, sub, depth + 1)
		list_append(&items, sub)
	}
	block.first, block.last = items.first, items.last
}

// --- transitions & section titles ---------------------------------------------

// ``Body.line``: section title overline or transition marker.
body_line :: proc(sm: ^State_Machine, line: string) -> (eof: bool) {
	if sm.match_titles do return line_state(sm, line)
	stripped := strip(line)
	if stripped == "::" do return body_text(sm, line)
	if len(stripped) < 4 {
		append_child(sm.parent, make_message(sm.p, INFO,
			"Unexpected possible title overline or transition.\nTreating it as ordinary text because it's so short.",
			abs_line_number(sm)))
		return body_text(sm, line)
	}
	append_child(sm.parent, make_message_block(sm.p, ERROR, "Unexpected section title or transition.", line, abs_line_number(sm)))
	return false
}

// ``Line`` state: second line of an overlined title or a transition.
line_state :: proc(sm: ^State_Machine, overline: string) -> (eof: bool) {
	a := sm.p.allocator
	l2, ok := next_line(sm)
	if !ok { // Line.eof
		if len(strip(overline)) < 4 do return state_correction(sm, 1)
		tr := make_node(sm, .Transition, abs_line_number(sm) - 1)
		tr.raw = overline
		append_child(sm.parent, tr)
		return true
	}
	if len(l2) == 0 { // Line.blank
		marker := strip(overline)
		if len(marker) < 4 do return state_correction(sm, 1)
		tr := make_node(sm, .Transition, abs_line_number(sm) - 1)
		tr.raw = marker
		append_child(sm.parent, tr)
		return false
	}
	if l2[0] != ' ' && match_line(l2) { // Line.underline
		blocktext := concat(overline, "\n", l2, allocator = a)
		lineno := abs_line_number(sm) - 1
		if len(rstrip(overline)) < 4 do return short_overline(sm, lineno, 1)
		append_child(sm.parent, make_message_block(sm.p, ERROR, "Invalid section title or transition marker.", blocktext, lineno))
		return false
	}
	// Line.text / Line.indent: potential over- & underlined title
	lineno := abs_line_number(sm) - 1
	title := l2
	l3, ok3 := next_line(sm)
	if !ok3 { // EOF raised inside the transition method: the run continues
		blocktext := concat(overline, "\n", title, allocator = a)
		if len(rstrip(overline)) < 4 do return short_overline(sm, lineno, 2)
		append_child(sm.parent, make_message_block(sm.p, ERROR, "Incomplete section title.", blocktext, lineno))
		return false
	}
	source := concat(overline, "\n", title, "\n", l3, allocator = a)
	ov := rstrip(overline)
	un := rstrip(l3)
	if !match_line(un) {
		if len(ov) < 4 do return short_overline(sm, lineno, 2)
		append_child(sm.parent, make_message_block(sm.p, ERROR, "Missing matching underline for section title overline.", source, lineno))
		return false
	} else if ov != un {
		if len(ov) < 4 do return short_overline(sm, lineno, 2)
		append_child(sm.parent, make_message_block(sm.p, ERROR, "Title overline & underline mismatch.", source, lineno))
		return false
	}
	title = rstrip(title)
	messages: Node_List
	if column_width(title) > len(ov) {
		if len(ov) < 4 do return short_overline(sm, lineno, 2)
		list_append(&messages, make_message_block(sm.p, WARNING, "Title overline too short.", source, lineno))
	}
	style := concat(ov[:1], un[:1], allocator = a)
	emit_section_title(sm, lstrip(title), source, style, lineno + 1, messages)
	return false
}

@(private = "file")
short_overline :: proc(sm: ^State_Machine, lineno: int, lines: int) -> (eof: bool) {
	append_child(sm.parent, make_message(sm.p, INFO,
		"Possible incomplete section title.\nTreating the overline as ordinary text because it's so short.",
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

emit_section_title :: proc(sm: ^State_Machine, title: string, source: string, style: string, lineno: int, messages: Node_List) {
	n := make_node(sm, .Section_Title, lineno)
	n.raw = title
	n.text = source
	n.name = style
	t := make_node(sm, .Title, lineno)
	t.raw = title
	t.num[1] = i32(reporter_line(sm))
	append_chain(t, parse_inline(sm.p, title, lineno).first)
	append_child(n, t)
	append_chain(n, messages.first)
	append_child(sm.parent, n)
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
	startline := abs_line_number(sm) - 1
	block, err_line := get_text_block(sm, flush_left = true)
	lines := make([]string, len(block) + 1, sm.p.allocator)
	lines[0] = line1
	copy(lines[1:], block)
	literalnext := paragraph(sm, lines, startline, sm.parent)
	if err_line > 0 {
		append_child(sm.parent, make_message(sm.p, ERROR, "Unexpected indentation.", err_line))
	}
	if literalnext {
		next_line(sm)
		literal_block(sm, sm.parent)
	}
}

// ``Text.underline``; false means "TransitionCorrection('text')".
@(private = "file")
text_underline :: proc(sm: ^State_Machine, line1: string, l2: string) -> bool {
	a := sm.p.allocator
	lineno := abs_line_number(sm)
	title := rstrip(line1)
	underline := rstrip(l2)
	source := concat(title, "\n", underline, allocator = a)
	messages: Node_List
	if column_width(title) > len(underline) {
		if len(underline) < 4 {
			if sm.match_titles {
				append_child(sm.parent, make_message(sm.p, INFO,
					"Possible title underline, too short for the title.\nTreating it as ordinary text because it's so short.",
					lineno))
			}
			return false
		}
		blocktext := concat(line1, "\n", l2, allocator = a)
		list_append(&messages, make_message_block(sm.p, WARNING, "Title underline too short.", blocktext, lineno))
	}
	if !sm.match_titles {
		blocktext := concat(line1, "\n", l2, allocator = a)
		append_chain(sm.parent, messages.first)
		append_child(sm.parent, make_message_block(sm.p, ERROR, "Unexpected section title.", blocktext, source_line(sm, abs_line_number(sm))))
		return true
	}
	emit_section_title(sm, title, source, underline[:1], lineno - 1, messages)
	return true
}

// ``RSTState.paragraph``: appends the paragraph to ``out``; returns whether a
// literal block follows ("::").
paragraph :: proc(sm: ^State_Machine, lines: []string, lineno: int, out: ^Node) -> (literalnext: bool) {
	data := rstrip(join_lines(lines, sm.p.allocator))
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
	p := make_node(sm, .Paragraph, lineno)
	p.raw = data
	p.num[1] = i32(reporter_line(sm))
	p.cur_line = i32(sm.p.cur_line)
	append_chain(p, parse_inline(sm.p, text, lineno).first)
	append_child(out, p)
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
literal_block :: proc(sm: ^State_Machine, out: ^Node) {
	r := get_indented(sm)
	lines := r.lines
	for len(lines) > 0 && len(lines[len(lines) - 1]) == 0 do lines = lines[:len(lines) - 1]
	if len(lines) == 0 {
		quoted_literal_block(sm, out)
		return
	}
	lb := make_node(sm, .Literal_Block, r.offset + 1)
	lb.text = join_lines(lines, sm.p.allocator)
	lb.raw = lb.text
	append_child(out, lb)
	if !r.blank_finish do append_child(out, unindent_warning(sm, "Literal block"))
}

// ``Text.quoted_literal_block`` with the ``QuotedLiteralBlock`` state.
quoted_literal_block :: proc(sm: ^State_Machine, out: ^Node) {
	offset := max(sm.line_offset, 0)
	lines := sm.lines[min(offset, len(sm.lines)):]
	q := make_state_machine(sm.p, lines, abs_line_offset(sm), out)
	messages: Node_List
	ctx_start, ctx_end := -1, -1
	quote: byte = 0
	initial_lineno := 0
	loop: for {
		line, ok := next_line(&q)
		if !ok do break
		if quote != 0 && len(line) > 0 && line[0] == quote { // 'quoted' (checked first)
			ctx_end = q.line_offset + 1
			continue
		}
		if len(line) == 0 { // blank
			if ctx_start >= 0 do break loop
			continue
		}
		if line[0] == ' ' { // indent
			list_append(&messages, make_message(sm.p, ERROR, "Unexpected indentation.", abs_line_number(&q)))
			previous_line(&q)
			break loop
		}
		if quote == 0 && is_punct7(line[0]) { // initial_quoted
			quote = line[0]
			initial_lineno = abs_line_number(&q)
			ctx_start, ctx_end = q.line_offset, q.line_offset + 1
			continue
		}
		// text
		if ctx_start >= 0 {
			list_append(&messages, make_message(sm.p, ERROR, "Inconsistent literal block quoting.", abs_line_number(&q)))
			previous_line(&q)
		}
		break loop
	}
	// QuotedLiteralBlock.eof
	before := out.last
	if ctx_start >= 0 {
		lb := make_node(sm, .Literal_Block, initial_lineno)
		lb.text = join_lines(lines[ctx_start:ctx_end], sm.p.allocator)
		lb.raw = lb.text
		append_child(out, lb)
	} else {
		append_child(out, make_message(sm.p, WARNING, "Literal block expected; none found.", abs_line_number(&q)))
		previous_line(&q)
	}
	append_chain(out, messages.first)
	goto_line(sm, abs_line_offset(&q))
	// docutils collects these in a detached container and attaches them
	// after returning to the enclosing machine's line
	for n := before.next if before != nil else out.first; n != nil; n = n.next {
		if n.kind == .System_Message do n.cur_line = i32(sm.p.cur_line)
	}
}

// ``Text.indent``: definition list.
@(private = "file")
text_indent :: proc(sm: ^State_Machine, termline: string) {
	dl := make_node(sm, .Definition_List, abs_line_number(sm) - 1)
	item, blank_finish := definition_list_item(sm, termline)
	append_child(dl, item)
	append_child(sm.parent, dl)
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
		append_child(dl, it)
		blank_finish = bf
	}
	if !blank_finish do append_child(sm.parent, unindent_warning(sm, "Definition list"))
}

definition_list_item :: proc(sm: ^State_Machine, termline: string) -> (item: ^Node, blank_finish: bool) {
	dd_lineno := abs_line_number(sm)
	dt_lineno := dd_lineno - 1
	r := get_indented(sm)
	item = make_node(sm, .Definition_List_Item, dt_lineno)
	item.raw = concat(termline, "\n" if len(r.lines) > 0 else "", join_lines(r.lines, sm.p.allocator), allocator = sm.p.allocator)
	term(sm, termline, dt_lineno, item)
	dd := make_node(sm, .Definition, dd_lineno)
	append_child(item, dd)
	if strings.has_suffix(termline, "::") {
		append_child(dd, make_message(sm.p, INFO,
			"Blank line missing before literal block (after the \"::\")? Interpreted as a definition list item.",
			dd_lineno))
	}
	nested_parse(sm, r.lines, r.offset, dd)
	return item, r.blank_finish
}

// ``Text.term``: the term and optional classifiers, appended to ``item``.
term :: proc(sm: ^State_Machine, line: string, lineno: int, item: ^Node) {
	a := sm.p.allocator
	dt := make_node(sm, .Term, lineno)
	dt.raw = line
	dt.num[1] = i32(reporter_line(sm))
	dt.cur_line = i32(sm.p.cur_line)
	append_child(item, dt)
	current := dt
	inl := parse_inline(sm.p, line, lineno)
	for n := inl.first; n != nil; {
		next := n.next
		if n.kind != .Text {
			append_child(current, n)
			n = next
			continue
		}
		// re.split(' +: +', text)
		text := n.text
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
		if len(pieces) == 0 {
			append_child(current, n)
		} else {
			append(&pieces, text[start:])
			head := make_node(sm, .Text, lineno)
			head.text = rstrip(pieces[0])
			append_child(current, head)
			for part in pieces[1:] {
				c := make_node(sm, .Classifier, lineno)
				c.raw = unescape(part, a, restore_backslashes = true)
				t := make_node(sm, .Text, lineno)
				t.text = part
				append_child(c, t)
				append_child(item, c)
				current = c
			}
		}
		n = next
	}
}
