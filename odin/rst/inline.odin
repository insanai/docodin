package rst

import "base:runtime"
import "core:strings"

// Inline markup parser: a port of ``docutils.parsers.rst.states.Inliner``.
//
// The docutils regular expressions are replaced by scanners that try
// candidates in the same order as Python's backtracking engine.  Offsets are
// byte offsets into the NUL-escaped text (``escape2null``).  As in docutils,
// after each construct the search restarts on the *remaining* string, where
// ``^`` matches again (``rem`` below).
//
// Scans that fail are memoized so that pathological input (thousands of
// unmatched start-strings, long name chains) stays linear instead of the
// quadratic behaviour of the regex version.

@(private = "file")
End_Kind :: enum u8 {
	Emphasis,
	Strong,
	Literal,
	Target,
	Substitution,
	Interpreted,
}

@(private = "file")
Inliner :: struct {
	p:          ^Parser,
	s:          string, // escaped text
	lineno:     int,
	charlevel:  bool,
	allocator:  runtime.Allocator,
	no_end:     [End_Kind]int, // searches from >= no_end[k] find nothing
	name_fail:  int,           // refname scans failing before this offset
	role_fail:  int,           // role scans failing before this offset
	depth:      int,
	// ``inline_position`` cache: the rows (newlines) before ``row_at`` and
	// the end of its line
	row_at:     int,
	row:        int,
	row_end:    int,
	// source positions (nil when off): the lines the text was joined from
	// and the offset of each in the text
	spans:      ^Span_Map,
	lines:      []string,
	line_at:    []int,
	one_line:   [1]string, // ``lines`` of a text that is a single view
	one_at:     [1]int,
}

@(private = "file")
Start_Kind :: enum u8 {
	None,
	Strong,
	Emphasis,
	Literal,
	Target,
	Substitution,
	Reference,          // name_ / name__
	Footnote_Reference, // [1]_ [#]_ [#x]_ [*]_
	Citation_Reference, // [CIT]_
	Backquote,          // `...` with optional :role: prefix
}

// A match of the initial pattern (kind ``.None``: no match).  Small, as it
// is returned by value along the whole matcher chain.
@(private = "file")
Initial_Match :: struct {
	kind:      Start_Kind,
	anonymous: bool, // Reference: name__
	has_role:  bool, // Backquote: with a :role: prefix
	start:     int,  // match.start()
	end:       int,  // match.end() (end of start-string / whole construct)
	// Reference: the reference name; footnote or citation reference: the
	// label; Backquote: the role
	name:      string,
	bq_start:  int, // Backquote: the backquote
	bq_end:    int,
}

parse_inline :: proc(p: ^Parser, text: string, lineno: int) -> (out: Node_List) {
	if len(text) == 0 do return
	tree_init(&p.tree, p.allocator)
	t := &p.tree
	il := Inliner {
		p          = p,
		s          = escape2null(text, p.allocator),
		lineno     = lineno,
		charlevel  = p.settings.character_level_inline_markup,
		allocator  = p.allocator,
	}
	if p.spans != nil do inline_spans_begin(&il, text)
	for &v in il.no_end do v = max(int)
	il.name_fail = -1
	il.role_fail = -1
	s := il.s
	rem := 0    // start of the "remaining" string
	ustart := 0 // start of unprocessed text
	for rem < len(s) {
		m := search_initial(&il, rem)
		if m.kind == .None do break
		before_end, inlines, new_rem, trim := dispatch(&il, m, rem)
		if inlines.first != NO_NODE {
			pending := s[ustart:before_end]
			if trim do pending = rstrip(pending)
			list_extend(t, &out, implicit_inline(&il, pending))
			list_extend(t, &out, inlines)
			ustart = new_rem
		}
		rem = new_rem
	}
	list_extend(t, &out, implicit_inline(&il, s[ustart:]))
	return
}

// ``parse_inline`` of ``text``, which was joined from ``lines`` with '\n'
// (and possibly cut short): the lines locate the inline nodes in the source.
@(private)
parse_inline_lines :: proc(p: ^Parser, lines: []string, text: string, lineno: int) -> Node_List {
	if p.spans == nil do return parse_inline(p, text, lineno)
	p.spans.inline_lines = lines
	defer p.spans.inline_lines = nil
	return parse_inline(p, text, lineno)
}

@(private = "file")
inline_spans_begin :: proc(il: ^Inliner, text: string) {
	sp := il.p.spans
	il.spans = sp
	il.lines = sp.inline_lines
	sp.inline_lines = nil // nested parses (none today) start afresh
	if len(il.lines) <= 1 {
		il.one_line[0] = text
		il.lines, il.line_at = il.one_line[:], il.one_at[:]
		return
	}
	il.line_at = make([]int, len(il.lines), il.allocator)
	at := 0
	for line, i in il.lines {
		il.line_at[i] = at
		at += len(line) + 1
	}
}

// Record the text range ``[start, end)`` as the span of ``n``.
@(private = "file")
inline_span :: proc(il: ^Inliner, n: Node, start, end: int) {
	if il.spans == nil do return
	s := joined_offset(il.spans, il.lines, il.line_at, start)
	e := joined_offset(il.spans, il.lines, il.line_at, end)
	set_span(il.p, n, s, e)
}

// Offset of ``sub`` (a view of the escaped text) in the text.
@(private = "file")
text_offset :: #force_inline proc "contextless" (il: ^Inliner, sub: string) -> int {
	return int(uintptr(raw_data(sub)) - uintptr(raw_data(il.s)))
}

// --- recognition helpers ---------------------------------------------------------

@(private = "file")
prefix_ok :: #force_inline proc "contextless" (il: ^Inliner, i, rem: int) -> bool {
	if i == rem do return true
	r := rune_before(il.s, i)
	if il.charlevel do return il.s[i - 1] != 0
	return is_space(r) || is_start_prefix_char(r)
}

// end_string_suffix at ``pos``
@(private = "file")
suffix_ok :: #force_inline proc "contextless" (il: ^Inliner, pos: int) -> bool {
	if il.charlevel || pos >= len(il.s) do return true
	r, _ := rune_at(il.s, pos)
	return is_space(r) || is_end_suffix_char(r)
}

// non_whitespace_after: (?!\s)
@(private = "file")
non_ws_at :: #force_inline proc "contextless" (s: string, pos: int) -> bool {
	if pos >= len(s) do return true
	r, _ := rune_at(s, pos)
	return !is_space(r)
}

@(private = "file")
byte_at :: #force_inline proc "contextless" (s: string, i: int) -> byte {
	return s[i] if i >= 0 && i < len(s) else 0
}

// ``Inliner.patterns.initial.search(remaining)``: the leftmost position
// where an alternative of the pattern matches.  Candidates are the bytes
// ``* ` _ | [ :`` and word starts (``name_`` references).  The scanner jumps
// from one such byte to the next: a word start can only begin a reference
// when its ``simplename`` chain reaches the next one, and that byte is a '_'
// or a ':' (see ``chain_start``).
@(private = "file")
search_initial :: proc(il: ^Inliner, rem: int) -> (m: Initial_Match) {
	s := il.s
	i := rem
	for i < len(s) {
		j := next_inline_special(s, i)
		if j < len(s) && (s[j] == '_' || s[j] == ':') {
			// word starts whose chain may reach the '_' at or through ``j``
			live := chain_start(s, i, j)
			if m = search_references(il, live, j, rem); m.kind != .None do return
		}
		if j >= len(s) do break
		if prefix_ok(il, j, rem) {
			if m = match_at(il, j); m.kind != .None do return
		}
		i = j + 1
	}
	return
}

// The 'whole' alternative (``name_`` references) at the word starts in
// ``s[from:to]``.
@(private = "file")
search_references :: proc(il: ^Inliner, from, to, rem: int) -> (m: Initial_Match) {
	s := il.s
	i := from
	for i < to {
		c := s[i]
		w := 1
		word: bool
		if c < 0x80 {
			word = ASCII_FLAGS[c] & FLAG_ALNUM != 0
		} else {
			r: rune
			r, w = rune_at(s, i)
			word = is_alnum(r)
		}
		if word && i >= il.name_fail && prefix_ok(il, i, rem) {
			if m = match_reference(il, i); m.kind != .None do return
		}
		i += w
	}
	return
}

@(private = "file")
match_at :: proc(il: ^Inliner, i: int) -> (m: Initial_Match) {
	c := il.s[i]
	if m = match_start_string(il, i); m.kind != .None do return
	// 'whole' alternatives
	if c == '[' {
		if m = match_footnote_ref(il, i); m.kind != .None do return
	} else if c != '*' && c != '`' && c != '_' && c != '|' && c != ':' && i >= il.name_fail {
		if m = match_reference(il, i); m.kind != .None do return
	}
	// 'backquote' alternative with optional :role: prefix
	if c == ':' && i >= il.role_fail {
		if m = match_role_backquote(il, i); m.kind != .None do return
	}
	if c == '`' && byte_at(il.s, i + 1) != '`' && non_ws_at(il.s, i + 1) {
		return {kind = .Backquote, start = i, end = i + 1, bq_start = i, bq_end = i + 1}
	}
	return
}

// The 'start' alternatives of the initial pattern (start-strings).
@(private = "file")
match_start_string :: proc(il: ^Inliner, i: int) -> (m: Initial_Match) {
	s := il.s
	m.start = i
	switch s[i] {
	case '*':
		if byte_at(s, i + 1) == '*' {
			if non_ws_at(s, i + 2) {
				m.kind, m.end = .Strong, i + 2
				return
			}
		} else if non_ws_at(s, i + 1) {
			m.kind, m.end = .Emphasis, i + 1
			return
		}
	case '`':
		if byte_at(s, i + 1) == '`' && non_ws_at(s, i + 2) {
			m.kind, m.end = .Literal, i + 2
			return
		}
	case '_':
		if byte_at(s, i + 1) == '`' && non_ws_at(s, i + 2) {
			m.kind, m.end = .Target, i + 2
			return
		}
	case '|':
		if byte_at(s, i + 1) != '|' && non_ws_at(s, i + 1) {
			m.kind, m.end = .Substitution, i + 1
			return
		}
	}
	return
}

// Named references: (simplename)(__?) + end-string suffix.
@(private = "file")
match_reference :: proc(il: ^Inliner, i: int) -> (m: Initial_Match) {
	s := il.s
	m.start = i
	if fail := ascii_chain_without_reference(s, i); fail >= 0 {
		il.name_fail = fail
		return
	}
	ends: Name_Ends = ---
	simplename_ends(s, i, &ends)
	for k in 0 ..< ends.count {
		e := ends.ends[k]
		if byte_at(s, e) != '_' do continue
		if byte_at(s, e + 1) == '_' && suffix_ok(il, e + 2) {
			m.kind, m.end, m.name, m.anonymous = .Reference, e + 2, s[i:e], true
			return
		}
		if suffix_ok(il, e + 1) {
			m.kind, m.end, m.name = .Reference, e + 1, s[i:e]
			return
		}
	}
	if ends.count > 0 do il.name_fail = ends.ends[0]
	return
}

// The end of the ASCII ``simplename`` chain at ``i`` when no '_' follows
// any of its word runs (no ``name_`` reference can start at ``i``: the value
// ``simplename_ends`` would give ``name_fail``); -1 when the chain has a '_'
// or a non-ASCII character (the full match decides).
@(private = "file")
ascii_chain_without_reference :: proc "contextless" (s: string, i: int) -> int {
	is_word :: #force_inline proc "contextless" (c: byte) -> bool {
		return c < 0x80 && ASCII_FLAGS[c] & FLAG_ALNUM != 0
	}
	j := i
	for {
		for j < len(s) && is_word(s[j]) do j += 1
		if j >= len(s) do return j
		switch s[j] {
		case '_':
			return -1
		case '-', '.', '+', ':':
			if j + 1 < len(s) && is_word(s[j + 1]) {
				j += 1
				continue
			}
			if j + 1 < len(s) && s[j + 1] >= 0x80 do return -1
		case 0x80 ..= 0xFF:
			return -1
		}
		return j
	}
}

// Interpreted text with a role prefix: :(simplename):`(?!`)(?!\s)
@(private = "file")
match_role_backquote :: proc(il: ^Inliner, i: int) -> (m: Initial_Match) {
	s := il.s
	m.start = i
	ends: Name_Ends = ---
	simplename_ends(s, i + 1, &ends)
	for k in 0 ..< ends.count {
		e := ends.ends[k]
		if byte_at(s, e) == ':' &&
		   byte_at(s, e + 1) == '`' &&
		   byte_at(s, e + 2) != '`' &&
		   non_ws_at(s, e + 2) {
			m.kind, m.end = .Backquote, e + 2
			m.name, m.has_role = s[i + 1:e], true
			m.bq_start, m.bq_end = e + 1, e + 2
			return
		}
	}
	if ends.count > 0 do il.role_fail = ends.ends[0]
	return
}

// \[([0-9]+|\#(simplename)?|\*|(?P<citationlabel>simplename))(?P<fnend>\]_) + suffix
@(private = "file")
match_footnote_ref :: proc(il: ^Inliner, i: int) -> (m: Initial_Match) {
	s := il.s
	close := footnote_ref_close
	FN :: Start_Kind.Footnote_Reference
	j := i + 1
	for j < len(s) && s[j] >= '0' && s[j] <= '9' do j += 1
	if j > i + 1 {
		if m = close(il, i, j, FN); m.kind != .None do return
	}
	if byte_at(s, i + 1) == '#' {
		ends: Name_Ends = ---
		simplename_ends(s, i + 2, &ends)
		for k in 0 ..< ends.count {
			if m = close(il, i, ends.ends[k], FN); m.kind != .None do return
		}
		if m = close(il, i, i + 2, FN); m.kind != .None do return
	}
	if byte_at(s, i + 1) == '*' {
		if m = close(il, i, i + 2, FN); m.kind != .None do return
	}
	ends: Name_Ends = ---
	simplename_ends(s, i + 1, &ends)
	for k in 0 ..< ends.count {
		if m = close(il, i, ends.ends[k], .Citation_Reference); m.kind != .None do return
	}
	return
}

// ``\]_`` + end-string suffix at ``e``: the reference labelled ``s[i + 1:e]``.
@(private = "file")
footnote_ref_close :: proc(il: ^Inliner, i, e: int, kind: Start_Kind) -> Initial_Match {
	if byte_at(il.s, e) == ']' && byte_at(il.s, e + 1) == '_' && suffix_ok(il, e + 2) {
		return {kind = kind, start = i, end = e + 2, name = il.s[i + 1:e]}
	}
	return {}
}

// ``Inliner.quoted_start``
@(private = "file")
quoted_start :: proc "contextless" (il: ^Inliner, start, end, rem: int) -> bool {
	if start == rem do return false
	if end >= len(il.s) do return true
	pre := rune_before(il.s, start)
	post, _ := rune_at(il.s, end)
	return match_chars(pre, post)
}

// --- dispatch ----------------------------------------------------------------

@(private = "file")
dispatch :: proc(
	il: ^Inliner,
	m: Initial_Match,
	rem: int,
) -> (
	before_end: int,
	inlines: Node_List,
	new_rem: int,
	trim: bool,
) {
	t := &il.p.tree
	switch m.kind {
	case .Strong:       return inline_obj(il, m, rem, .Strong, .Strong, "strong")
	case .Emphasis:     return inline_obj(il, m, rem, .Emphasis, .Emphasis, "emphasis")
	case .Literal:      return inline_obj(il, m, rem, .Literal, .Literal, "literal")
	case .Target:       return inline_obj(il, m, rem, .Target, .Inline_Target, "target")
	case .Substitution:
		return inline_obj(
			il, m, rem, .Substitution, .Substitution_Reference, "substitution_reference",
		)
	case .Backquote:    return interpreted_or_phrase_ref(il, m, rem)
	case .Reference:
		n := make_inline(il, .Reference)
		t.nodes[n].num[0] = i32(Ref_Kind.Simple)
		t.nodes[n].num[1] = 1 if m.anonymous else 0
		t.nodes[n].text = m.name
		t.nodes[n].raw = il.s[m.start:m.end]
		inline_span(il, n, m.start, m.end)
		list_append(t, &inlines, n)
		return m.start, inlines, m.end, false
	case .Footnote_Reference, .Citation_Reference:
		is_footnote := m.kind == .Footnote_Reference
		n := make_inline(il, .Footnote_Reference if is_footnote else .Citation_Reference)
		t.nodes[n].text = m.name
		inline_span(il, n, m.start, m.end)
		list_append(t, &inlines, n)
		// docutils trims the preceding space for footnote references only
		trim = is_footnote && il.p.settings.trim_footnote_reference_space
		return m.start, inlines, m.end, trim
	case .None:
	}
	return m.end, {}, m.end, false
}

@(private = "file")
make_inline :: #force_inline proc(il: ^Inliner, kind: Node_Kind) -> Node {
	return new_node(&il.p.tree, kind, il.lineno)
}

// ``text`` starts at byte ``start`` of the inline source; its position is kept
// for diagnostics (see ``inline_position``).
@(private = "file")
problematic :: proc(il: ^Inliner, text: string, message: string, start: int) -> Node {
	t := &il.p.tree
	n := make_inline(il, .Problematic)
	t.nodes[n].raw = text
	t.nodes[n].text = text
	t.nodes[n].name = message
	t.nodes[n].num[0] = WARNING
	t.nodes[n].num[1] = problematic_position(il, start)
	inline_span(il, n, start, start + len(text)) // unescaping keeps the length
	return n
}

// Position of byte ``start`` of the inline source ``s``, packed as
// ``row << 16 | distance to the end of its line`` (``row``: newlines before
// it).  The distance from the line end locates the text in the source line
// whatever the block's indentation (inline sources are de-indented).
inline_position :: proc "contextless" (s: string, start: int) -> i32 {
	row := 0
	line_end := len(s)
	for i in 0 ..< len(s) {
		if s[i] != '\n' do continue
		if i < start {
			row += 1
		} else {
			line_end = i
			break
		}
	}
	return i32(min(row, 0x7FFF) << 16 | min(line_end - start, 0xFFFF))
}

// ``inline_position`` counting rows from the previous call (problematic
// markup comes in text order): linear instead of quadratic in the number
// of problematic nodes.
@(private = "file")
problematic_position :: proc(il: ^Inliner, start: int) -> i32 {
	s := il.s
	if start < il.row_at do il.row_at, il.row, il.row_end = 0, 0, 0
	if start > il.row_end || il.row_end == 0 {
		il.row += count_newlines(s[il.row_at:start])
		il.row_at = start
		next := strings.index_byte(s[start:], '\n')
		il.row_end = len(s) if next < 0 else start + next
	}
	return i32(min(il.row, 0x7FFF) << 16 | min(il.row_end - start, 0xFFFF))
}

// Inverse of ``inline_position``.
inline_position_unpack :: proc "contextless" (pos: i32) -> (row, from_line_end: int) {
	return int(pos >> 16), int(pos & 0xFFFF)
}

// ``Inliner.inline_obj``
@(private = "file")
inline_obj :: proc(
	il: ^Inliner,
	m: Initial_Match,
	rem: int,
	kind: End_Kind,
	node_kind: Node_Kind,
	class_name: string,
) -> (
	before_end: int,
	inlines: Node_List,
	new_rem: int,
	trim: bool,
) {
	t := &il.p.tree
	matchstart, matchend := m.start, m.end
	if quoted_start(il, matchstart, matchend, rem) do return matchend, {}, matchend, false
	es, ee, found := search_end(il, kind, matchend)
	if found && es > matchend {
		text := il.s[matchend:es]
		if kind == .Literal {
			text = unescape(text, il.allocator, restore_backslashes = true)
		}
		n := make_inline(il, node_kind)
		t.nodes[n].raw = unescape(il.s[matchstart:ee], il.allocator, restore_backslashes = true)
		t.nodes[n].text = text
		// num[0]: the underscores in the end-string
		if kind == .Substitution do t.nodes[n].num[0] = i32(ee - es - 1)
		inline_span(il, n, matchstart, ee)
		list_append(t, &inlines, n)
		return matchstart, inlines, ee, false
	}
	parts := []string{"Inline ", class_name, " start-string without end-string."}
	msg := strings.concatenate(parts, il.allocator)
	text := unescape(il.s[matchstart:matchend], il.allocator, restore_backslashes = true)
	list_append(t, &inlines, problematic(il, text, msg, matchstart))
	return matchstart, inlines, matchend, false
}

// First match of an end-string pattern in ``s[from:]``: returns the absolute
// start/end of group(1).
@(private = "file")
search_end :: proc(il: ^Inliner, kind: End_Kind, from: int) -> (start, end: int, found: bool) {
	if from >= il.no_end[kind] do return
	s := il.s
	for p := from; p < len(s); p += 1 {
		next := strings.index_byte(s[p:], END_STRING_CHAR[kind])
		if next < 0 do break
		p += next
		if !end_string_start(kind, s, p) do continue
		if p > from {
			prev := rune_before(s, p)
			if is_space(prev) do continue
			if kind != .Literal && s[p - 1] == 0 do continue
		}
		if e := end_string_end(il, kind, p); e >= 0 do return p, e, true
	}
	il.no_end[kind] = from
	return
}

// The first character of the end-strings of ``kind``.
@(private = "file", rodata)
END_STRING_CHAR := [End_Kind]byte {
	.Emphasis     = '*',
	.Strong       = '*',
	.Literal      = '`',
	.Target       = '`',
	.Substitution = '|',
	.Interpreted  = '`',
}

// Whether an end-string of ``kind`` can start at ``p``.
@(private = "file")
end_string_start :: #force_inline proc "contextless" (kind: End_Kind, s: string, p: int) -> bool {
	c := s[p]
	switch kind {
	case .Emphasis, .Strong: return c == '*'
	case .Literal:           return c == '`' && byte_at(s, p + 1) == '`'
	case .Target:            return c == '`'
	case .Substitution:      return c == '|'
	case .Interpreted:
	}
	return false
}

// End of the end-string of ``kind`` starting at ``p`` (with its suffix), or -1.
@(private = "file")
end_string_end :: proc(il: ^Inliner, kind: End_Kind, p: int) -> int {
	s := il.s
	switch kind {
	case .Emphasis:
		if suffix_ok(il, p + 1) do return p + 1
	case .Strong:
		if byte_at(s, p + 1) == '*' && suffix_ok(il, p + 2) do return p + 2
	case .Literal:
		if suffix_ok(il, p + 2) do return p + 2
	case .Target:
		if suffix_ok(il, p + 1) do return p + 1
	case .Substitution:
		// \|_{0,2} (greedy)
		u := 0
		for u < 2 && byte_at(s, p + 1 + u) == '_' do u += 1
		for k := u; k >= 0; k -= 1 {
			if suffix_ok(il, p + 1 + k) do return p + 1 + k
		}
	case .Interpreted:
	}
	return -1
}

// End pattern of interpreted text / phrase references:
//   (?<!(?<!\x00)[\s\x00])
//   (` (?P<suffix>(?P<role>:simplename:)?(?P<refend>__?)?)) end_string_suffix
@(private = "file")
search_interpreted_end :: proc(
	il: ^Inliner,
	from: int,
) -> (
	start, end: int,
	role: string,
	found: bool,
) {
	if from >= il.no_end[.Interpreted] do return
	s := il.s
	for p := from; p < len(s); p += 1 {
		next := strings.index_byte(s[p:], '`')
		if next < 0 do break
		p += next
		if p > from && !interpreted_end_prefix_ok(s, p, from) do continue
		// role candidates first (greedy optional group)
		if byte_at(s, p + 1) == ':' {
			ends: Name_Ends = ---
			simplename_ends(s, p + 2, &ends)
			for k in 0 ..< ends.count {
				e := ends.ends[k]
				if byte_at(s, e) != ':' do continue
				if after := refend_end(il, e + 1); after >= 0 do return p, after, s[p + 2:e], true
			}
		}
		if after := refend_end(il, p + 1); after >= 0 do return p, after, "", true
	}
	il.no_end[.Interpreted] = from
	return
}

// The lookbehind of the interpreted end-string at ``p > from``: no
// whitespace/NUL before, unless escaped (itself preceded by NUL).
@(private = "file")
interpreted_end_prefix_ok :: proc "contextless" (s: string, p, from: int) -> bool {
	prev := rune_before(s, p)
	if prev != 0 && !is_space(prev) do return true
	pw := p - 1
	if prev >= 0x80 do pw = p - rune_width(prev)
	return pw > from && s[pw - 1] == 0
}

// (?P<refend>__?)? + end-string suffix at ``after``: match.end() or -1.
@(private = "file")
refend_end :: proc(il: ^Inliner, after: int) -> int {
	s := il.s
	if byte_at(s, after) == '_' && byte_at(s, after + 1) == '_' && suffix_ok(il, after + 2) {
		return after + 2
	}
	if byte_at(s, after) == '_' && suffix_ok(il, after + 1) do return after + 1
	if suffix_ok(il, after) do return after
	return -1
}

@(private = "file")
rune_width :: #force_inline proc "contextless" (r: rune) -> int {
	switch {
	case r < 0x80:    return 1
	case r < 0x800:   return 2
	case r < 0x10000: return 3
	}
	return 4
}

// ``Inliner.interpreted_or_phrase_ref``
@(private = "file")
interpreted_or_phrase_ref :: proc(
	il: ^Inliner,
	m: Initial_Match,
	rem: int,
) -> (
	before_end: int,
	inlines: Node_List,
	new_rem: int,
	trim: bool,
) {
	t := &il.p.tree
	matchstart, matchend := m.bq_start, m.bq_end
	if !m.has_role && quoted_start(il, m.start, m.end, rem) {
		return matchend, {}, matchend, false
	}
	es, ee, erole, found := search_interpreted_end(il, matchend)
	if found && es > matchend {
		n, start := interpreted_node(il, m, es, ee, erole)
		list_append(t, &inlines, n)
		return start, inlines, ee, false
	}
	text := unescape(il.s[matchstart:matchend], il.allocator, restore_backslashes = true)
	list_append(t, &inlines, problematic(il, text,
		"Inline interpreted text or phrase reference start-string without end-string.",
		matchstart))
	return matchstart, inlines, matchend, false
}

// The node of the interpreted text or phrase reference ``m`` whose
// end-string is ``s[es:ee]`` (``erole``: its role suffix), and where it
// starts (``match.start()``).
@(private = "file")
interpreted_node :: proc(
	il: ^Inliner,
	m: Initial_Match,
	es, ee: int,
	erole: string,
) -> (
	n: Node,
	start: int,
) {
	a := il.allocator
	s := il.s
	role, position := m.name, "prefix" if m.has_role else ""
	if erole != "" {
		if m.has_role {
			text := unescape(s[m.start:ee], a, restore_backslashes = true)
			message := "Multiple roles in interpreted text " +
				"(both prefix and suffix present; only one allowed)."
			return problematic(il, text, message, m.start), m.start
		}
		role, position = erole, "suffix"
	}
	escaped := s[m.bq_end:es]
	rawsource := unescape(s[m.bq_start:ee], a, restore_backslashes = true)
	if len(rawsource) > 0 && rawsource[len(rawsource) - 1] == '_' {
		if role != "" {
			text := unescape(s[m.start:ee], a, restore_backslashes = true)
			parts := []string{
				"Mismatch: both interpreted text role ", position, " and reference suffix.",
			}
			return problematic(il, text, strings.concatenate(parts, a), m.start), m.start
		}
		n = phrase_ref(il, rawsource, escaped)
		inline_span(il, n, m.bq_start, ee)
		return n, m.bq_start
	}
	t := &il.p.tree
	n = make_inline(il, .Interpreted)
	t.nodes[n].raw = unescape(s[m.start:ee], a, restore_backslashes = true)
	t.nodes[n].text = escaped
	t.nodes[n].name = role
	inline_span(il, n, m.start, ee)
	return n, m.start
}

// ``Inliner.phrase_ref``: builds a Reference (``Ref_Kind.Phrase``).  The host
// finishes name normalisation and target registration.
@(private = "file")
phrase_ref :: proc(il: ^Inliner, rawsource: string, escaped: string) -> Node {
	a := il.allocator
	t := &il.p.tree
	n := make_inline(il, .Reference)
	t.nodes[n].num[0] = i32(Ref_Kind.Phrase)
	t.nodes[n].raw = rawsource
	t.nodes[n].text = escaped
	start, lt, found := search_embedded_link(escaped)
	if !found do return n
	text := escaped[:start]
	t.nodes[n].text = text
	aliastext := escaped[lt + 1:len(escaped) - 1]
	info: Phrase_Info
	info.target_raw = escaped[start:]
	info.rawtext = unescape(text, a, restore_backslashes = true)
	rawaliastext := unescape(aliastext, a, restore_backslashes = true)
	underscore_escaped := strings.has_suffix(rawaliastext, "\\_")
	_, _, _, is_uri := uri_whole_at(il, aliastext, 0, nil)
	if strings.has_suffix(aliastext, "_") && !(underscore_escaped || is_uri) {
		info.alias_type = .Name
		info.alias = unescape(aliastext[:len(aliastext) - 1], a)
	} else {
		info.alias_type = .Uri
		parts := split_escaped_whitespace(aliastext, a)
		for &part in parts do part = remove_whitespace(part, a)
		alias := unescape(strings.join(parts, " ", a), a)
		alias = adjust_uri(il, alias)
		if strings.has_suffix(alias, "\\_") {
			alias = concat(alias[:len(alias) - 2], "_", allocator = a)
		}
		info.alias = alias
	}
	if text == "" do info.rawtext = rawaliastext
	set_phrase_info(t, n, info)
	return n
}

// ``Inliner.adjust_uri``: e-mail addresses get a "mailto:" scheme.
@(private = "file")
adjust_uri :: proc(il: ^Inliner, uri: string) -> string {
	return adjust_uri_text(uri, il.charlevel, il.allocator)
}

// ``Inliner.adjust_uri`` for hosts: an e-mail address gets a "mailto:"
// scheme (``charlevel``: the ``character_level_inline_markup`` setting).
adjust_uri_text :: proc(uri: string, charlevel: bool, allocator: runtime.Allocator) -> string {
	// email pattern + '$' matched at the start
	if end, ok := email_at(uri, 0, charlevel, nil); ok && end == len(uri) {
		return concat("mailto:", uri, allocator = allocator)
	}
	return uri
}

// embedded_link: ((?:[ \n]+|^)<(?!\s)(([^<>]|\x00[<>])+)(?<![\s\x00])>)$
// Returns match.start(0) and the offset of '<'.
@(private = "file")
search_embedded_link :: proc "contextless" (s: string) -> (start, lt: int, ok: bool) {
	n := len(s)
	if n < 3 || s[n - 1] != '>' do return
	valid := embedded_link_valid
	for k := 0; k < n; k += 1 {
		if s[k] == ' ' || s[k] == '\n' {
			j := k
			for j < n && (s[j] == ' ' || s[j] == '\n') do j += 1
			if j < n && s[j] == '<' && valid(s, j) do return k, j, true
			k = j - 1 // later starts in this run reach the same '<'
			continue
		}
		if k == 0 && s[0] == '<' && valid(s, 0) do return 0, 0, true
	}
	return
}

// <(?!\s)(([^<>]|\x00[<>])+)(?<![\s\x00])>$ with '<' at ``lt``.
@(private = "file")
embedded_link_valid :: proc "contextless" (s: string, lt: int) -> bool {
	n := len(s)
	a, b := lt + 1, n - 1 // content s[a:b]
	if b <= a do return false
	first, _ := rune_at(s, a)
	if is_space(first) do return false
	last := rune_before(s, b)
	if last == 0 || is_space(last) do return false
	i := a
	for i < b {
		c := s[i]
		if c == 0 && i + 1 < b && (s[i + 1] == '<' || s[i + 1] == '>') {
			i += 2
		} else if c == '<' || c == '>' {
			return false
		} else {
			i += 1
		}
	}
	return true
}

// --- implicit inline markup: standalone URIs, e-mail, PEP & RFC references ---------

// ``Inliner.implicit_inline``
@(private = "file")
implicit_inline :: proc(il: ^Inliner, text: string) -> (out: Node_List) {
	t := &il.p.tree
	rest := text
	for len(rest) > 0 {
		if il.depth < 32 {
			if m, found := search_implicit(il, rest); found {
				il.depth += 1
				list_extend(t, &out, implicit_inline(il, rest[:m.start]))
				il.depth -= 1
				ref := implicit_reference(il, rest[m.start:m.end], m)
				at := text_offset(il, rest)
				inline_span(il, ref, at + m.start, at + m.end)
				list_append(t, &out, ref)
				rest = rest[m.end:]
				continue
			}
		}
		txt := make_inline(il, .Text)
		t.nodes[txt].text = rest
		at := text_offset(il, rest)
		inline_span(il, txt, at, at + len(rest))
		list_append(t, &out, txt)
		break
	}
	return
}

@(private = "file")
Implicit_Match :: struct {
	start, end: int,
	kind:       Ref_Kind, // Uri, Pep or Rfc
	num:        string,   // PEP / RFC number
	is_email:   bool,
}

// First implicit reference in ``s``, trying the patterns in docutils order:
// standalone URI / e-mail, then PEP and RFC references (when enabled).
@(private = "file")
search_implicit :: proc(il: ^Inliner, s: string) -> (m: Implicit_Match, found: bool) {
	if ms, me, scheme, is_email, ok := search_uri(il, s); ok {
		if is_email || scheme_known(scheme) {
			return {start = ms, end = me, kind = .Uri, is_email = is_email}, true
		}
	}
	if il.p.settings.pep_references {
		if ms, me, num, ok := search_pep(il, s); ok {
			return {start = ms, end = me, kind = .Pep, num = num}, true
		}
	}
	if il.p.settings.rfc_references {
		if ms, me, num, ok := search_rfc(il, s); ok {
			return {start = ms, end = me, kind = .Rfc, num = num}, true
		}
	}
	return
}

// The Reference node for implicit reference ``m`` (text ``whole``).
@(private = "file")
implicit_reference :: proc(il: ^Inliner, whole: string, m: Implicit_Match) -> Node {
	t := &il.p.tree
	n := make_inline(il, .Reference)
	t.nodes[n].num[0] = i32(m.kind)
	t.nodes[n].raw = unescape(whole, il.allocator, restore_backslashes = true)
	t.nodes[n].text = whole
	if m.kind != .Uri {
		t.nodes[n].name = m.num
		return n
	}
	t.nodes[n].name = unescape(whole, il.allocator)
	if m.is_email do t.nodes[n].name = concat("mailto:", t.nodes[n].name, allocator = il.allocator)
	return n
}

scheme_known :: proc(scheme: string) -> bool {
	buf: [64]byte
	if len(scheme) > len(buf) do return false
	for i in 0 ..< len(scheme) {
		c := scheme[i]
		buf[i] = c + 32 if c >= 'A' && c <= 'Z' else c
	}
	key := string(buf[:len(scheme)])
	lo, hi := 0, len(URI_SCHEMES)
	for lo < hi {
		mid := (lo + hi) / 2
		switch {
		case URI_SCHEMES[mid] < key: lo = mid + 1
		case URI_SCHEMES[mid] > key: hi = mid
		case: return true
		}
	}
	return false
}

// uric: [-_.!~*'()[\];/:@&=+$,%a-zA-Z0-9\x00]
@(private = "file")
is_uric :: #force_inline proc "contextless" (c: byte) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', 0:
		return true
	case '-', '_', '.', '!', '~', '*', '\'', '(', ')', '[', ']', ';', '/', ':', '@', '&', '=',
	     '+', '$', ',', '%':
		return true
	}
	return false
}

// urilast: [_~*/=+a-zA-Z0-9]
@(private = "file")
is_urilast :: #force_inline proc "contextless" (c: byte) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '~', '*', '/', '=', '+':
		return true
	}
	return false
}

// emailc: [-_!~*'{|}/#?^`&=+$%a-zA-Z0-9\x00]
@(private = "file")
is_emailc :: #force_inline proc "contextless" (c: byte) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', 0:
		return true
	case '-', '_', '!', '~', '*', '\'', '{', '|', '}', '/', '#', '?', '^', '`', '&', '=', '+',
	     '$', '%':
		return true
	}
	return false
}

// uri_end: (?:urilast|uric(?=[>])) for the character at q
@(private = "file")
uri_end_at :: #force_inline proc "contextless" (s: string, q: int) -> bool {
	if q < 0 || q >= len(s) do return false
	c := s[q]
	return is_urilast(c) || (is_uric(c) && q + 1 < len(s) && s[q + 1] == '>')
}

// Leftmost ``Inliner.patterns.uri`` match in ``s``.  An absolute URI needs
// a ':' and an e-mail address an '@' after a run of scheme or local-part
// characters: only the starts in such runs are tried (``next_uri_anchor``).
@(private = "file")
search_uri :: proc(
	il: ^Inliner,
	s: string,
) -> (
	start, end: int,
	scheme: string,
	is_email: bool,
	found: bool,
) {
	email_fail := -1 // e-mail local parts failing before this offset
	for from := 0; from < len(s); {
		anchor, live := next_uri_anchor(s, from)
		if anchor >= len(s) do return
		for i in live ..< anchor {
			c := s[i]
			if !(is_emailc(c) || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) do continue
			if i > 0 {
				if il.charlevel {
					if s[i - 1] == 0 do continue
				} else {
					r := rune_before(s, i)
					if !(is_space(r) || is_start_prefix_char(r)) do continue
				}
			}
			if e, sc, email, ok := uri_whole_at(il, s, i, &email_fail); ok {
				return i, e, sc, email, true
			}
		}
		from = anchor + 1
	}
	return
}

// ``patterns.uri.match(s[i:])`` (absolute URI or e-mail + end-string suffix).
@(private = "file")
uri_whole_at :: proc(
	il: ^Inliner,
	s: string,
	i: int,
	email_fail: ^int,
) -> (
	end: int,
	scheme: string,
	is_email: bool,
	ok: bool,
) {
	if e, sc, found := absolute_uri_at(il, s, i); found do return e, sc, false, true
	if e, found := email_at(s, i, il.charlevel, email_fail); found {
		if il.charlevel || e >= len(s) || suffix_char_ok(s, e) do return e, "", true, true
	}
	return
}

@(private = "file")
suffix_char_ok :: #force_inline proc "contextless" (s: string, pos: int) -> bool {
	if pos >= len(s) do return true
	r, _ := rune_at(s, pos)
	return is_space(r) || is_end_suffix_char(r)
}

// (?P<absolute>(?P<scheme>[a-zA-Z][a-zA-Z0-9.+-]*):
//   (((//?)?uric*uri_end)(\?uric*uri_end)?(\#uric*uri_end)?)) + suffix
@(private = "file")
absolute_uri_at :: proc(il: ^Inliner, s: string, i: int) -> (end: int, scheme: string, ok: bool) {
	c := s[i]
	if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) do return
	j := i + 1
	for j < len(s) && is_scheme_char(s[j]) do j += 1
	if j >= len(s) || s[j] != ':' do return
	scheme = s[i:j]
	body := j + 1
	run := body
	for run < len(s) && is_uric(s[run]) do run += 1
	for p := run; p > body; p -= 1 {
		if !uri_end_at(s, p - 1) do continue
		// optional query ('?' is not a uric, so only possible at the run end)
		if p < len(s) && s[p] == '?' {
			if e, found := query_and_suffix(il, s, p); found do return e, scheme, true
		}
		if e, found := fragment_and_suffix(il, s, p); found do return e, scheme, true
	}
	return
}

// [a-zA-Z0-9.+-]
@(private = "file")
is_scheme_char :: #force_inline proc "contextless" (b: byte) -> bool {
	switch b {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '+', '-':
		return true
	}
	return false
}

// (\?uric*uri_end) at ``p`` followed by the optional fragment and suffix.
@(private = "file")
query_and_suffix :: proc(il: ^Inliner, s: string, p: int) -> (end: int, ok: bool) {
	qrun := p + 1
	for qrun < len(s) && is_uric(s[qrun]) do qrun += 1
	for q := qrun; q > p + 1; q -= 1 {
		if !uri_end_at(s, q - 1) do continue
		if e, found := fragment_and_suffix(il, s, q); found do return e, true
	}
	return
}

@(private = "file")
fragment_and_suffix :: proc(il: ^Inliner, s: string, p: int) -> (end: int, ok: bool) {
	if p < len(s) && s[p] == '#' {
		frun := p + 1
		for frun < len(s) && is_uric(s[frun]) do frun += 1
		for f := frun; f > p + 1; f -= 1 {
			if !uri_end_at(s, f - 1) do continue
			if il.charlevel || suffix_char_ok(s, f) do return f, true
		}
	}
	if il.charlevel || suffix_char_ok(s, p) do return p, true
	return
}

// email: emailc+(?:\.emailc+)*(?<!\x00)@emailc+(?:\.emailc*)*uri_end
// Returns the end of the first candidate (longest host first) followed by
// a valid end-string suffix.  ``email_fail`` (optional) memoizes local parts
// that cannot reach an '@' within one subject string.
@(private = "file")
email_at :: proc(s: string, i: int, charlevel: bool, email_fail: ^int) -> (end: int, ok: bool) {
	if email_fail != nil && i < email_fail^ do return
	if i >= len(s) || !is_emailc(s[i]) do return
	j := email_local_end(s, i)
	if j >= len(s) || s[j] != '@' || s[j - 1] == 0 {
		if email_fail != nil do email_fail^ = j
		return
	}
	h := j + 1
	if h >= len(s) || !is_emailc(s[h]) do return
	run := h
	for run < len(s) && (is_emailc(s[run]) || s[run] == '.') do run += 1
	for q := min(run, len(s) - 1); q > h; q -= 1 {
		if !uri_end_at(s, q) do continue
		f := q + 1
		if charlevel || suffix_char_ok(s, f) do return f, true
	}
	return
}

// pep-(?P<pepnum1>\d+)(.txt)? + suffix at ``i``.
@(private = "file")
pep_dash_at :: proc(il: ^Inliner, s: string, i: int) -> (end: int, num: string, ok: bool) {
	d := i + 4
	for e := decimal_run_end(s, d); e > d; e -= rune_width(rune_before(s, e)) {
		// (.txt)? : any character then "txt"
		if e < len(s) && s[e] != '\n' {
			_, w := rune_at(s, e)
			t := e + w + 3
			if strings.has_prefix(s[e + w:], "txt") && (il.charlevel || suffix_char_ok(s, t)) {
				return t, s[d:e], true
			}
		}
		if il.charlevel || suffix_char_ok(s, e) do return e, s[d:e], true
	}
	return
}

// emailc+(?:\.emailc+)* starting at ``i``: the end of the local part.
@(private = "file")
email_local_end :: proc "contextless" (s: string, i: int) -> int {
	j := i
	for {
		for j < len(s) && is_emailc(s[j]) do j += 1
		if j + 1 < len(s) && s[j] == '.' && is_emailc(s[j + 1]) {
			j += 1
			continue
		}
		return j
	}
}

// pep: ((pep-(?P<pepnum1>\d+)(.txt)?)|(PEP\s+(?P<pepnum2>\d+))) + prefix/suffix
@(private = "file")
search_pep :: proc(il: ^Inliner, s: string) -> (start, end: int, num: string, found: bool) {
	for i := 0; i < len(s); i += 1 {
		if s[i] != 'p' && s[i] != 'P' do continue
		if !inline_prefix_ok(il, s, i) do continue
		if strings.has_prefix(s[i:], "pep-") {
			if e, n, ok := pep_dash_at(il, s, i); ok do return i, e, n, true
		} else if strings.has_prefix(s[i:], "PEP") {
			j := i + 3
			ws := j
			for ws < len(s) {
				r, w := rune_at(s, ws)
				if !is_space(r) do break
				ws += w
			}
			if ws == j do continue
			if e := decimal_run_end(s, ws); e > ws {
				if il.charlevel || suffix_char_ok(s, e) do return i, e, s[ws:e], true
			}
		}
	}
	return
}

// rfc: (RFC(-|\s+)?(?P<rfcnum>\d+)) + prefix/suffix
@(private = "file")
search_rfc :: proc(il: ^Inliner, s: string) -> (start, end: int, num: string, found: bool) {
	for i := 0; i < len(s); i += 1 {
		if s[i] != 'R' || !strings.has_prefix(s[i:], "RFC") do continue
		if !inline_prefix_ok(il, s, i) do continue
		j := i + 3
		starts: [2]int
		ns := 0
		if byte_at(s, j) == '-' {
			starts[ns] = j + 1
			ns += 1
		} else {
			ws := j
			for ws < len(s) {
				r, w := rune_at(s, ws)
				if !is_space(r) do break
				ws += w
			}
			if ws > j {
				starts[ns] = ws
				ns += 1
			}
		}
		starts[ns] = j
		ns += 1
		for k in 0 ..< ns {
			if e := decimal_run_end(s, starts[k]); e > starts[k] {
				if il.charlevel || suffix_char_ok(s, e) do return i, e, s[starts[k]:e], true
			}
		}
	}
	return
}

@(private = "file")
inline_prefix_ok :: proc "contextless" (il: ^Inliner, s: string, i: int) -> bool {
	if i == 0 do return true
	if il.charlevel do return s[i - 1] != 0
	r := rune_before(s, i)
	return is_space(r) || is_start_prefix_char(r)
}

// End of the run of decimal digits (regex ``\d+``) starting at ``i``.
@(private = "file")
decimal_run_end :: proc "contextless" (s: string, i: int) -> int {
	j := i
	for j < len(s) {
		r, w := rune_at(s, j)
		if !is_decimal(r) do break
		j += w
	}
	return j
}
