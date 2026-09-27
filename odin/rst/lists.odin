package rst

import "base:runtime"
import "core:strconv"
import "core:strings"

// The list constructs of the docutils ``Body`` state and their specialized
// states (``BulletList``, ``EnumeratedList``, ``FieldList``, ``OptionList``,
// ``RFC2822List``); see body.odin.

// --- lists --------------------------------------------------------------------

// ``Body.list_item``: parse one list item starting at the current line.
list_item :: proc(sm: ^State_Machine, indent: int) -> (item: Node, blank_finish: bool) {
	t := &sm.p.tree
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
	t.nodes[item].raw = join_lines(r.lines, sm.p.allocator)
	if len(r.lines) > 0 do nested_parse(sm, r.lines, r.offset, item)
	return item, r.blank_finish
}

body_bullet :: proc(sm: ^State_Machine, line: string, end: int) {
	t := &sm.p.tree
	ul := make_node(sm, .Bullet_List, abs_line_number(sm))
	_, w := rune_at(line, 0)
	t.nodes[ul].name = line[:w]
	append_child(t, sm.parent, ul)
	item, blank_finish := list_item(sm, end)
	append_child(t, ul, item)
	// BulletList state
	frozen := begin_nested_list(sm)
	defer end_nested_list(sm, frozen)
	for {
		l, ok := next_line(sm)
		if !ok do break
		m := classify(l)
		if m.t == .Blank do continue
		if m.t != .Bullet || !strings.has_prefix(l, t.nodes[ul].name) {
			previous_line(sm)
			break
		}
		it, bf := list_item(sm, m.end)
		append_child(t, ul, it)
		blank_finish = bf
	}
	if !blank_finish do append_child(t, sm.parent, unindent_warning(sm, "Bullet list"))
}

ORDINAL_NONE :: min(int)

// ``Body.parse_enumerator``
parse_enumerator :: proc "contextless" (
	m: Enum_Match,
	expected := Enum_Sequence.None,
) -> (
	seq: Enum_Sequence,
	ordinal: int,
) {
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
	return seq, enumerator_ordinal(seq, text)
}

// The ordinal of enumerator ``text`` in sequence ``seq`` (or ORDINAL_NONE).
@(private = "file")
enumerator_ordinal :: proc "contextless" (seq: Enum_Sequence, text: string) -> (ordinal: int) {
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
make_enumerator :: proc(
	ordinal: int,
	seq: Enum_Sequence,
	format: Enum_Format,
	buf: []byte,
) -> (
	next_enum: string,
	auto_enum: string,
	ok: bool,
) {
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
is_enumerated_list_item :: proc(
	sm: ^State_Machine,
	ordinal: int,
	seq: Enum_Sequence,
	format: Enum_Format,
) -> bool {
	if ordinal == ORDINAL_NONE do return false
	next, ok := next_line(sm)
	previous_line(sm)
	if !ok do return true
	if len(next) == 0 do return true
	r, _ := rune_at(next, 0)
	if is_space(r) do return true
	buf: [96]byte
	next_enum, auto_enum, made := make_enumerator(ordinal + 1, seq, format, buf[:])
	if !made do return false
	return strings.has_prefix(next, next_enum) || strings.has_prefix(next, auto_enum)
}

@(private = "file")
seq_or_arabic :: #force_inline proc "contextless" (seq: Enum_Sequence) -> Enum_Sequence {
	return .Arabic if seq == .Auto else seq
}

// ``Body.enumerator``; false means "TransitionCorrection('text')".
body_enumerator :: proc(sm: ^State_Machine, line: string, m: Enum_Match) -> bool {
	t := &sm.p.tree
	seq, ordinal := parse_enumerator(m)
	if !is_enumerated_list_item(sm, ordinal, seq, m.format) do return false
	el := make_node(sm, .Enumerated_List, abs_line_number(sm))
	append_child(t, sm.parent, el)
	list_seq := seq_or_arabic(seq)
	t.nodes[el].name = ENUM_SEQUENCE_NAMES[list_seq]
	t.nodes[el].text = ENUM_PREFIX[m.format]
	t.nodes[el].raw = ENUM_SUFFIX[m.format]
	if ordinal != 1 {
		t.nodes[el].num[0] = i32(clamp(ordinal, int(min(i32)), int(max(i32))))
		t.nodes[el].num[1] = 1
		msg := strings.concatenate({
			"Enumerated list start value not ordinal-1: \"", m.text,
			"\" (ordinal ", int_str(ordinal, sm.p.allocator), ")",
		}, sm.p.allocator)
		// reported with ``base_node=enumlist``: the node's (source) line
		lineno := source_line(sm, int(t.nodes[el].line))
		append_child(t, sm.parent, mark_source_line(sm.p, make_message(sm.p, INFO, msg, lineno)))
	}
	item, blank_finish := list_item(sm, m.end)
	append_child(t, el, item)
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
		if lm.t == .Enumerator {
			s2, o2 := parse_enumerator(lm.enumer, list_seq)
			if next_enumerator_valid(
				sm, lm.enumer, m.format, s2, o2, list_seq, lastordinal, auto,
			) {
				if s2 == .Auto do auto = true
				it, bf := list_item(sm, lm.end)
				append_child(t, el, it)
				blank_finish = bf
				lastordinal = o2
				continue
			}
		}
		previous_line(sm)
		break
	}
	if !blank_finish do append_child(t, sm.parent, unindent_warning(sm, "Enumerated list"))
	return true
}

// ``EnumeratedList.enumerator``: whether ``e`` (parsed as ``seq``/``ordinal``)
// continues the list.
@(private = "file")
next_enumerator_valid :: proc(
	sm: ^State_Machine,
	e: Enum_Match,
	format: Enum_Format,
	seq: Enum_Sequence,
	ordinal: int,
	list_seq: Enum_Sequence,
	lastordinal: int,
	auto: bool,
) -> bool {
	valid := e.format == format
	if valid && seq != .Auto {
		valid = seq == list_seq && !auto && ordinal != ORDINAL_NONE && ordinal == lastordinal + 1
	}
	return valid && is_enumerated_list_item(sm, ordinal, seq, e.format)
}

// --- field lists ----------------------------------------------------------------

body_field_marker :: proc(sm: ^State_Machine, line: string, name: string, end: int) {
	t := &sm.p.tree
	fl := make_node(sm, .Field_List, abs_line_number(sm))
	append_child(t, sm.parent, fl)
	f, blank_finish := field(sm, line, name, end)
	append_child(t, fl, f)
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
		append_child(t, fl, f2)
		blank_finish = bf
	}
	if !blank_finish do append_child(t, sm.parent, unindent_warning(sm, "Field list"))
}

// ``Body.field``: children are ``Field_Name`` (raw = name, inline children)
// and ``Field_Body``.
field :: proc(
	sm: ^State_Machine,
	line: string,
	name: string,
	end: int,
) -> (
	f: Node,
	blank_finish: bool,
) {
	t := &sm.p.tree
	lineno := abs_line_number(sm)
	r := get_first_known_indented(sm, cp_len(line[:end]))
	f = make_node(sm, .Field, lineno)
	fname := make_node(sm, .Field_Name, lineno)
	t.nodes[fname].raw = name
	t.nodes[fname].num[1] = i32(reporter_line(sm))
	t.nodes[fname].cur_line = i32(sm.p.cur_line)
	append_chain(t, fname, parse_inline(sm.p, name, lineno).first)
	append_child(t, f, fname)
	fbody := make_node(sm, .Field_Body, lineno)
	t.nodes[fbody].raw = join_lines(r.lines, sm.p.allocator)
	append_child(t, f, fbody)
	if len(r.lines) > 0 do nested_parse(sm, r.lines, r.offset, fbody)
	return f, r.blank_finish
}

// ``RFC2822Body.rfc2822``
rfc2822_field_list :: proc(sm: ^State_Machine, line: string, end: int) {
	t := &sm.p.tree
	fl := make_node(sm, .Field_List, abs_line_number(sm))
	t.nodes[fl].name = "rfc2822"
	append_child(t, sm.parent, fl)
	f, blank_finish := rfc2822_field(sm, line, end)
	append_child(t, fl, f)
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
				append_child(t, fl, f2)
				blank_finish = bf
				continue
			}
		}
		previous_line(sm)
		break
	}
	if !blank_finish {
		append_child(t, sm.parent, unindent_warning(sm, "RFC2822-style field list"))
	}
}

rfc2822_field :: proc(
	sm: ^State_Machine,
	line: string,
	end: int,
) -> (
	f: Node,
	blank_finish: bool,
) {
	t := &sm.p.tree
	name := line[:strings.index_byte(line, ':')]
	lineno := abs_line_number(sm)
	r := get_first_known_indented(sm, cp_len(line[:end]), until_blank = true)
	f = make_node(sm, .Field, lineno)
	fname := make_node(sm, .Field_Name, lineno)
	t.nodes[fname].raw = name // plain text (no inline parsing)
	txt := make_node(sm, .Text, lineno)
	t.nodes[txt].text = name
	append_child(t, fname, txt)
	append_child(t, f, fname)
	fbody := make_node(sm, .Field_Body, lineno)
	t.nodes[fbody].raw = join_lines(r.lines, sm.p.allocator)
	append_child(t, f, fbody)
	if len(r.lines) > 0 do nested_parse(sm, r.lines, r.offset, fbody)
	return f, r.blank_finish
}

// --- option lists -------------------------------------------------------------

// ``Body.option_marker``; false means "TransitionCorrection('text')".
body_option_marker :: proc(sm: ^State_Machine, line: string, end: int) -> bool {
	t := &sm.p.tree
	lineno := abs_line_number(sm)
	item, blank_finish, status, err := option_list_item(sm, line, end)
	switch status {
	case .Not_Item:
		return false
	case .Markup_Error:
		// "This shouldn't happen; pattern won't match." — kept for fidelity.
		msg := concat("Invalid option list marker: ", err, allocator = sm.p.allocator)
		append_child(t, sm.parent, make_message(sm.p, ERROR, msg, reporter_line(sm)))
		r := get_first_known_indented(sm, cp_len(line[:end]))
		block_quote(sm, r.lines, r.offset, sm.parent)
		if !r.blank_finish do append_child(t, sm.parent, unindent_warning(sm, "Option list"))
		return true
	case .Ok:
	}
	ol := make_node(sm, .Option_List, lineno)
	append_child(t, sm.parent, ol)
	append_child(t, ol, item)
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
				append_child(t, ol, it)
				blank_finish = bf
				continue
			}
		}
		previous_line(sm)
		break
	}
	if !blank_finish do append_child(t, sm.parent, unindent_warning(sm, "Option list"))
	return true
}

Option_Status :: enum u8 {Ok, Not_Item, Markup_Error}

option_list_item :: proc(
	sm: ^State_Machine,
	line: string,
	end: int,
) -> (
	item: Node,
	blank_finish: bool,
	status: Option_Status,
	err: string,
) {
	t := &sm.p.tree
	offset := abs_line_offset(sm)
	lineno := abs_line_number(sm)
	group := make_node(sm, .Option_Group, lineno)
	if err = parse_option_marker(sm, line[:end], group); err != "" {
		return NO_NODE, false, .Markup_Error, err
	}
	r := get_first_known_indented(sm, cp_len(line[:end]))
	if len(r.lines) == 0 {
		goto_line(sm, offset)
		return NO_NODE, false, .Not_Item, ""
	}
	item = make_node(sm, .Option_List_Item, lineno)
	desc := make_node(sm, .Description, lineno)
	t.nodes[desc].raw = join_lines(r.lines, sm.p.allocator)
	append_child(t, item, group)
	append_child(t, item, desc)
	nested_parse(sm, r.lines, r.offset, desc)
	t.nodes[item].cur_line = i32(sm.p.cur_line)
	return item, r.blank_finish, .Ok, ""
}

// ``Body.parse_option_marker``: fills ``group`` with ``Option`` nodes.
// Returns the ``MarkupError`` text on failure.
parse_option_marker :: proc(sm: ^State_Machine, marker: string, group: Node) -> (err: string) {
	for optionstring in split_option_marker(rstrip(marker), sm.p.allocator) {
		if err = parse_option(sm, optionstring, group); err != "" do return
	}
	return ""
}

// re.split(r', (?![^<]*>)', text)
@(private = "file")
split_option_marker :: proc(text: string, a: runtime.Allocator) -> [dynamic]string {
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
	return pieces
}

// One option of ``Body.parse_option_marker``, appended to ``group``.
@(private = "file")
parse_option :: proc(sm: ^State_Machine, optionstring: string, group: Node) -> (err: string) {
	t := &sm.p.tree
	a := sm.p.allocator
	tokens := make([dynamic]string, 0, 3, a)
	for t in split_whitespace(optionstring, a) do append(&tokens, t)
	if len(tokens) == 0 do return option_markup_error(sm, 0, optionstring)
	delimiter := " "
	t0 := tokens[0]
	// a short option with its argument attached ("-ofile", "+x")
	attached := cp_len(t0) > 2 && ((t0[0] == '-' && !strings.has_prefix(t0, "--")) || t0[0] == '+')
	if eq := strings.index_byte(t0, '='); eq >= 0 {
		first, rest := t0[:eq], t0[eq + 1:]
		tokens[0] = first
		inject_at(&tokens, 1, rest)
		delimiter = "="
	} else if attached {
		first, rest := t0[:2], t0[2:]
		tokens[0] = first
		inject_at(&tokens, 1, rest)
		delimiter = ""
	}
	if len(tokens) > 1 &&
	   strings.has_prefix(tokens[1], "<") &&
	   strings.has_suffix(tokens[len(tokens) - 1], ">") {
		joined := strings.join(tokens[1:], " ", a)
		resize(&tokens, 2)
		tokens[1] = joined
	}
	if len(tokens) > 2 do return option_markup_error(sm, len(tokens), optionstring)
	opt := make_node(sm, .Option, int(t.nodes[group].line))
	t.nodes[opt].raw = optionstring
	os := make_node(sm, .Option_String, int(t.nodes[group].line))
	t.nodes[os].text = tokens[0]
	append_child(t, opt, os)
	if len(tokens) > 1 {
		arg := make_node(sm, .Option_Argument, int(t.nodes[group].line))
		t.nodes[arg].text = tokens[1]
		t.nodes[arg].name = delimiter
		append_child(t, opt, arg)
	}
	append_child(t, group, opt)
	return ""
}

@(private = "file")
option_markup_error :: proc(sm: ^State_Machine, count: int, optionstring: string) -> string {
	return strings.concatenate({
		"wrong number of option tokens (=", int_str(count, sm.p.allocator),
		"), should be 1 or 2: \"", optionstring, "\"",
	}, sm.p.allocator)
}
