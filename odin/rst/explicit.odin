package rst

import "core:strings"

// Explicit markup (``Body.explicit_*``, ``Explicit`` state): footnotes,
// citations, hyperlink targets, substitution definitions, directives and
// comments.

body_explicit_markup :: proc(sm: ^State_Machine, line: string, end: int) {
	nodes, blank_finish := explicit_construct(sm, line, end)
	append_chain(sm.parent, nodes.first)
	explicit_list(sm, blank_finish)
}

body_anonymous :: proc(sm: ^State_Machine, line: string, end: int) {
	nodes, blank_finish := anonymous_target(sm, line, end)
	append_chain(sm.parent, nodes.first)
	explicit_list(sm, blank_finish)
}

// ``Body.explicit_list``: a series of explicit constructs (``Explicit`` state).
explicit_list :: proc(sm: ^State_Machine, blank_finish: bool) {
	blank_finish := blank_finish
	frozen := begin_nested_list(sm)
	defer end_nested_list(sm, frozen)
	for {
		l, ok := next_line(sm)
		if !ok do break
		m := classify(l)
		nodes: Node_List
		#partial switch m.t {
		case .Explicit_Markup:
			nodes, blank_finish = explicit_construct(sm, l, m.end)
		case .Anonymous:
			nodes, blank_finish = anonymous_target(sm, l, m.end)
		case:
			previous_line(sm)
			if !blank_finish do append_child(sm.parent, unindent_warning(sm, "Explicit markup"))
			return
		}
		append_chain(sm.parent, nodes.first)
	}
	if !blank_finish do append_child(sm.parent, unindent_warning(sm, "Explicit markup"))
}

// ``\.\.[ ]+`` -> offset after the spaces, or -1
@(private = "file")
explicit_start :: proc "contextless" (line: string) -> int {
	if len(line) < 3 || line[0] != '.' || line[1] != '.' || line[2] != ' ' do return -1
	i := 3
	for i < len(line) && line[i] == ' ' do i += 1
	return i
}

// footnote: \.\.[ ]+\[([0-9]+|\#|\#simplename|\*)\]([ ]+|$)
@(private = "file")
match_footnote :: proc "contextless" (line: string) -> (label: string, end: int, ok: bool) {
	i := explicit_start(line)
	if i < 0 || i >= len(line) || line[i] != '[' do return
	s := i + 1
	close :: proc "contextless" (line: string, s, e: int) -> (string, int, bool) {
		if e < len(line) && line[e] == ']' {
			if end := spaces_or_end(line, e + 1); end >= 0 do return line[s:e], end, true
		}
		return "", 0, false
	}
	// [0-9]+
	j := s
	for j < len(line) && line[j] >= '0' && line[j] <= '9' do j += 1
	if j > s {
		if l, e, found := close(line, s, j); found do return l, e, true
	}
	if s < len(line) && line[s] == '#' {
		if l, e, found := close(line, s, s + 1); found do return l, e, true
		ends := simplename_ends(line, s + 1)
		for k in 0 ..< ends.count {
			if l, e, found := close(line, s, ends.ends[k]); found do return l, e, true
		}
	}
	if s < len(line) && line[s] == '*' {
		if l, e, found := close(line, s, s + 1); found do return l, e, true
	}
	return
}

// citation: \.\.[ ]+\[(simplename)\]([ ]+|$)
@(private = "file")
match_citation :: proc "contextless" (line: string) -> (label: string, end: int, ok: bool) {
	i := explicit_start(line)
	if i < 0 || i >= len(line) || line[i] != '[' do return
	ends := simplename_ends(line, i + 1)
	for k in 0 ..< ends.count {
		e := ends.ends[k]
		if e < len(line) && line[e] == ']' {
			if end = spaces_or_end(line, e + 1); end >= 0 do return line[i + 1:e], end, true
		}
	}
	return
}

// hyperlink_target: \.\.[ ]+_(?![ ]|$)  /  substitution_def: \.\.[ ]+\|(?![ ]|$)
@(private = "file")
match_explicit_char :: proc "contextless" (line: string, c: byte) -> (end: int, ok: bool) {
	i := explicit_start(line)
	if i < 0 || i >= len(line) || line[i] != c do return
	if i + 1 >= len(line) || line[i + 1] == ' ' do return
	return i + 1, true
}

// directive: \.\.[ ]+(simplename)[ ]?::([ ]+|$)
match_directive :: proc "contextless" (line: string) -> (name: string, end: int, ok: bool) {
	i := explicit_start(line)
	if i < 0 do return
	return match_directive_name(line, i)
}

// (simplename)[ ]?::([ ]+|$) at ``i``; without the optional space for the
// SubstitutionDef 'embedded_directive' pattern (simplename)::( +|$).
match_directive_name :: proc "contextless" (line: string, i: int, allow_space := true) -> (name: string, end: int, ok: bool) {
	ends := simplename_ends(line, i)
	for k in 0 ..< ends.count {
		e := ends.ends[k]
		for sp in ([2]int{1, 0}) {
			j := e
			if sp == 1 {
				if !allow_space do continue
				if j >= len(line) || line[j] != ' ' do continue
				j += 1
			}
			if j + 1 < len(line) && line[j] == ':' && line[j + 1] == ':' {
				if end = spaces_or_end(line, j + 2); end >= 0 do return line[i:e], end, true
			}
		}
	}
	return
}

// ``Body.explicit_construct``
explicit_construct :: proc(sm: ^State_Machine, line: string, end: int) -> (nodes: Node_List, blank_finish: bool) {
	errors: Node_List
	if label, mend, ok := match_footnote(line); ok {
		return footnote(sm, line, label, mend, .Footnote)
	}
	if label, mend, ok := match_citation(line); ok {
		return footnote(sm, line, label, mend, .Citation)
	}
	if tend, is_target := match_explicit_char(line, '_'); is_target {
		res, bf, err := hyperlink_target(sm, line, tend)
		if !err do return res, bf
		list_append(&errors, make_message(sm.p, WARNING, "malformed hyperlink target.", abs_line_number(sm)))
	} else if send, is_sub := match_explicit_char(line, '|'); is_sub {
		res, bf, err := substitution_def(sm, line, send)
		if !err do return res, bf
		list_append(&errors, make_message(sm.p, WARNING, "malformed substitution definition.", abs_line_number(sm)))
	} else if name, dend, is_dir := match_directive(line); is_dir {
		return directive(sm, line, name, dend)
	}
	nodes, blank_finish = comment(sm, line, end)
	// attached together with the comment, after it consumed its block
	for e := errors.first; e != nil; e = e.next do e.cur_line = i32(sm.p.cur_line)
	list_extend(&nodes, errors)
	return
}

// ``Body.footnote`` / ``Body.citation``
@(private = "file")
footnote :: proc(sm: ^State_Machine, line: string, label: string, mend: int, kind: Node_Kind) -> (nodes: Node_List, blank_finish: bool) {
	lineno := abs_line_number(sm)
	r := get_first_known_indented(sm, cp_len(line[:mend]))
	fn := make_node(sm, kind, lineno)
	fn.name = label
	fn.raw = join_lines(r.lines, sm.p.allocator)
	fn.cur_line = i32(sm.p.cur_line) // registered before its content is parsed
	manual := kind == .Citation || (label[0] != '#' && label[0] != '*')
	if manual {
		lbl := make_node(sm, .Label, lineno)
		lbl.text = label
		append_child(fn, lbl)
	}
	if len(r.lines) > 0 {
		nested_parse(sm, r.lines, r.offset, fn)
	} else {
		msg := "Footnote content expected." if kind == .Footnote else "Citation content expected."
		append_child(fn, make_message(sm.p, WARNING, msg, reporter_line(sm)))
	}
	list_append(&nodes, fn)
	return nodes, r.blank_finish
}

// --- hyperlink targets --------------------------------------------------------

// ``Body.explicit.patterns.target`` on the escaped text:
//   (_|(?!_)(?P<quote>`?)(?![ `])(?P<name>.+?)(?<![\s\x00])(?P=quote))
//   (?<!(?<!\x00):)(?<![\s\x00])[ ]?:([ ]+|$)
@(private = "file")
match_target :: proc "contextless" (s: string) -> (name: string, end: int, anonymous: bool, ok: bool) {
	tail :: proc "contextless" (s: string, pos: int) -> int {
		// (?<!(?<!\x00):)(?<![\s\x00])[ ]?:([ ]+|$)
		if pos <= 0 || pos > len(s) do return -1
		prev := s[pos - 1]
		if prev == ':' && (pos < 2 || s[pos - 2] != 0) do return -1
		pr := rune_before(s, pos)
		if pr == 0 || is_space(pr) do return -1
		for sp in ([2]int{1, 0}) {
			j := pos
			if sp == 1 {
				if j >= len(s) || s[j] != ' ' do continue
				j += 1
			}
			if j < len(s) && s[j] == ':' {
				if e := spaces_or_end(s, j + 1); e >= 0 do return e
			}
		}
		return -1
	}
	if len(s) == 0 do return
	if s[0] == '_' {
		if e := tail(s, 1); e >= 0 do return "", e, true, true
		return
	}
	q := 0
	quoted := s[0] == '`'
	if quoted do q = 1
	if q >= len(s) || s[q] == ' ' || s[q] == '`' do return
	_, w := rune_at(s, q)
	for e := q + w; e <= len(s); {
		last := rune_before(s, e)
		if !(last == 0 || is_space(last)) {
			pos := e
			if quoted {
				if e < len(s) && s[e] == '`' {
					pos = e + 1
				} else {
					pos = -1
				}
			}
			if pos >= 0 {
				if end = tail(s, pos); end >= 0 do return s[q:e], end, false, true
			}
		}
		if e >= len(s) do break
		_, w2 := rune_at(s, e)
		e += w2
	}
	return
}

// ``Body.hyperlink_target``; ``malformed`` corresponds to ``MarkupError``.
@(private = "file")
hyperlink_target :: proc(sm: ^State_Machine, line: string, mend: int) -> (nodes: Node_List, blank_finish: bool, malformed: bool) {
	a := sm.p.allocator
	lineno := abs_line_number(sm)
	r := get_first_known_indented(sm, cp_len(line[:mend]), until_blank = true, strip_indent = false)
	blank_finish = r.blank_finish
	if len(r.lines) == 0 do return {}, blank_finish, true
	blocktext := concat(line[:mend], join_lines(r.lines, a), allocator = a)
	block := make([]string, len(r.lines), a)
	for l, i in r.lines do block[i] = escape2null(l, a)
	escaped := block[0]
	blockindex := 0
	name: string
	end: int
	for {
		found: bool
		name, end, _, found = match_target(escaped)
		if found do break
		blockindex += 1
		if blockindex >= len(block) do return {}, blank_finish, true
		escaped = concat(escaped, block[blockindex], allocator = a)
	}
	block = block[blockindex:]
	block[0] = strip(escaped[end:])
	list_append(&nodes, make_target(sm, block, blocktext, lineno, name))
	return
}

// ``Body.anonymous_target`` ("__ uri" lines)
anonymous_target :: proc(sm: ^State_Machine, line: string, mend: int) -> (nodes: Node_List, blank_finish: bool) {
	a := sm.p.allocator
	lineno := abs_line_number(sm)
	r := get_first_known_indented(sm, cp_len(line[:mend]), until_blank = true)
	blocktext := concat(line[:mend], join_lines(r.lines, a), allocator = a)
	block := make([]string, len(r.lines), a)
	for l, i in r.lines do block[i] = escape2null(l, a)
	list_append(&nodes, make_target(sm, block, blocktext, lineno, ""))
	return nodes, r.blank_finish
}

// ``Body.make_target`` / ``parse_target``: ``name`` is the escaped target
// name ("" for anonymous targets).
make_target :: proc(sm: ^State_Machine, block: []string, blocktext: string, lineno: int, name: string) -> ^Node {
	a := sm.p.allocator
	t := make_node(sm, .Target, lineno)
	t.raw = blocktext
	t.name = name
	t.cur_line = i32(sm.p.cur_line)
	t.num[1] = 1 if name == "" else 0
	if len(block) > 0 {
		last := strip(block[len(block) - 1])
		if len(last) > 0 && last[len(last) - 1] == '_' {
			parts := make([]string, len(block), a)
			for l, i in block do parts[i] = strip(l)
			if refname, ok := is_reference(strings.join(parts, " ", a), a); ok {
				t.num[0] = i32(Target_Type.Refname)
				t.text = refname
				return t
			}
		}
	}
	t.num[0] = i32(Target_Type.Refuri)
	t.text = normalize_uri(strings.join(block, " ", a), a)
	return t
}

// ``Body.is_reference``: ((?P<simple>simplename)_|`(?![ ])(?P<phrase>.+?)(?<![\s\x00])`_)$
is_reference :: proc(reference: string, allocator := context.allocator) -> (refname: string, ok: bool) {
	s := whitespace_normalize(reference, allocator)
	n := len(s)
	if n >= 2 && s[n - 1] == '_' && simplename_end(s, 0) == n - 1 {
		return unescape(s[:n - 1], allocator), true
	}
	if n >= 4 && s[0] == '`' && s[1] != ' ' && s[n - 2] == '`' && s[n - 1] == '_' {
		last := rune_before(s, n - 2)
		if last != 0 && !is_space(last) do return unescape(s[1:n - 2], allocator), true
	}
	return "", false
}

// --- substitution definitions ---------------------------------------------------

// ``((?![ ])(?P<name>.+?)(?<![\s\x00])\|)([ ]+|$)``
@(private = "file")
match_substitution :: proc "contextless" (s: string) -> (name: string, end: int, ok: bool) {
	if len(s) == 0 || s[0] == ' ' do return
	_, w := rune_at(s, 0)
	for e := w; e < len(s); {
		if s[e] == '|' {
			last := rune_before(s, e)
			if last != 0 && !is_space(last) {
				if end = spaces_or_end(s, e + 1); end >= 0 do return s[:e], end, true
			}
		}
		_, w2 := rune_at(s, e)
		e += w2
	}
	return
}

// ``Body.substitution_def``; ``malformed`` corresponds to ``MarkupError``.
@(private = "file")
substitution_def :: proc(sm: ^State_Machine, line: string, mend: int) -> (nodes: Node_List, blank_finish: bool, malformed: bool) {
	a := sm.p.allocator
	lineno := abs_line_number(sm)
	r := get_first_known_indented(sm, cp_len(line[:mend]), strip_indent = false)
	blank_finish = r.blank_finish
	if len(r.lines) == 0 do return {}, blank_finish, true
	block := make([]string, len(r.lines), a)
	copy(block, r.lines)
	offset := r.offset
	blocktext := concat(line[:mend], join_lines(block, a), allocator = a)
	escaped := escape2null(rstrip(block[0]), a)
	blockindex := 0
	subname: string
	end: int
	for {
		found: bool
		subname, end, found = match_substitution(escaped)
		if found do break
		blockindex += 1
		if blockindex >= len(block) do return {}, blank_finish, true
		escaped = concat(escaped, " ", escape2null(strip(block[blockindex]), a), allocator = a)
	}
	block = block[blockindex:]
	// block[0] = (block[0].strip() + ' ')[start:-1]; escape2null keeps offsets
	first := strip(block[0])
	keep := len(escaped) - end
	block[0] = first[max(len(first) - keep, 0):]
	if len(block[0]) == 0 {
		block = block[1:]
		offset += 1
	}
	for len(block) > 0 && len(strip(block[len(block) - 1])) == 0 do block = block[:len(block) - 1]
	if len(block) == 0 {
		msg := strings.concatenate({"Substitution definition \"", subname, "\" missing contents."}, a)
		list_append(&nodes, make_message_block(sm.p, WARNING, msg, blocktext, source_line(sm, lineno)))
		return
	}
	block[0] = strip(block[0])
	sub := make_node(sm, .Substitution_Definition, lineno)
	sub.raw = blocktext
	sub.name = subname
	// docutils drops the consumed name lines without adjusting ``offset``:
	// inside, absolute numbers run ``blockindex`` behind the source lines.
	sub.num[0] = i32(blockindex)
	// SubstitutionDef state: whitespace transitions, then either an embedded
	// directive or text (both end the state).
	nsm := make_state_machine(sm.p, block, offset, sub)
	nsm.line_delta = sm.line_delta + blockindex
	for {
		l, ok := next_line(&nsm)
		if !ok do break
		if len(l) == 0 do continue
		if l[0] == ' ' {
			body_indent(&nsm)
			continue
		}
		if name, dend, is_dir := match_directive_name(l, 0, allow_space = false); is_dir {
			dnodes, bf := directive(&nsm, l, name, dend)
			append_chain(sub, dnodes.first)
			if !at_eof(&nsm) do blank_finish = bf
		} else if !at_eof(&nsm) {
			blank_finish = is_next_line_blank(&nsm)
		}
		break
	}
	sub.cur_line = i32(sm.p.cur_line) // validated and registered here
	list_append(&nodes, sub)
	return
}

// --- directives & comments --------------------------------------------------------

// ``Body.directive``/``run_directive`` up to the point where the directive
// class is needed: the host runs it from the recorded block.
directive :: proc(sm: ^State_Machine, line: string, name: string, mend: int) -> (nodes: Node_List, blank_finish: bool) {
	lineno := abs_line_number(sm)
	initial := sm.line_offset
	r := get_first_known_indented(sm, cp_len(line[:mend]), strip_top = false)
	last := min(sm.line_offset + 1, len(sm.lines))
	d := make_node(sm, .Directive, lineno)
	d.name = name
	d.raw = join_lines(sm.lines[max(initial, 0):max(last, max(initial, 0))], sm.p.allocator)
	info := new(Directive_Info, sm.p.allocator)
	info.lines = r.lines
	info.line_offset = r.offset
	info.end_offset = abs_line_offset(sm)
	info.blank_finish = r.blank_finish
	d.extra = info
	list_append(&nodes, d)
	return nodes, r.blank_finish || is_next_line_blank(sm)
}

// ``Body.comment``.  ``match_line``/``mend`` describe the explicit-markup
// match; the indented block is taken from the *current* line (which differs
// after a MarkupError, exactly like docutils).
comment :: proc(sm: ^State_Machine, match_line: string, mend: int) -> (nodes: Node_List, blank_finish: bool) {
	if is_next_line_blank(sm) {
		first := match_line[mend:]
		if len(strip(first)) == 0 {
			c := make_node(sm, .Comment, abs_line_number(sm))
			c.cur_line = i32(sm.p.cur_line)
			list_append(&nodes, c)
			return nodes, true
		}
		if strings.has_prefix(first, "end of inclusion from \"") {
			list_append(&nodes, make_node(sm, .Include_End, abs_line_number(sm)))
			return nodes, true
		}
	}
	lineno := abs_line_number(sm)
	r := get_first_known_indented(sm, cp_len(match_line[:mend]))
	lines := r.lines
	for len(lines) > 0 && len(strip(lines[len(lines) - 1])) == 0 do lines = lines[:len(lines) - 1]
	c := make_node(sm, .Comment, lineno)
	c.text = join_lines(lines, sm.p.allocator)
	c.cur_line = i32(sm.p.cur_line)
	list_append(&nodes, c)
	return nodes, r.blank_finish
}
