package rst

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// Source positions (``Parse_Flag.Spans``): the byte range of every node in
// the text given to ``parse_text``.  The rules are in nodes.odin; this file
// records them while parsing and answers the queries.
//
// The parser works on ``string2lines`` output, whose lines are views of the
// input except where tabs, \v or \f were rewritten, and on views of those
// lines (de-indented blocks).  So a string's source offset follows from its
// data pointer: inside the input it is the difference, and the rewritten
// lines and the copies that still mirror the source (table cell lines) are
// registered as *pieces* that map back to it.  Inline text joined from
// several lines is mapped through those lines.

// Half-open byte range ``[start, end)`` in the parsed text.
Span :: struct {
	start, end: u32,
}

// The parse-time state of the position layer (``Parser.spans``; nil when
// spans are off, so the default path only tests a pointer).
@(private)
Span_Map :: struct {
	text:      string,
	starts:    []u32, // the line table (``Tree.line_starts``)
	tab_width: int,
	pieces:    [dynamic]Piece, // sorted by address
	// Position given to nodes whose lines are not in the text (inserted by
	// ``include``): the end of the inserting directive.
	fallback:  int,
	// Lines that the text of the next ``parse_inline`` was joined from.
	inline_lines: []string,
	// Lookups come nearly in text order (the inliner records a markup node
	// before the text before it): the last piece found, and where the last
	// walks of a few neighbouring rewritten lines stopped, are resumed from.
	last_piece: int,
	walks:      [4]Line_Walk, // by line % 4
}

// A position in a rewritten line: ``out`` bytes of the rewritten line are
// ``b`` bytes of the source, at expanded column ``column``.
@(private = "file")
Line_Walk :: struct {
	line, out, column, b: int,
}

// A string outside the text that maps back to it.
@(private = "file")
Piece :: struct {
	addr: uintptr,
	len:  int,
	// ``line >= 0``: a line rewritten by ``string2lines`` (tabs expanded);
	// ``base`` is the offset of the piece in the rewritten line.  Else the
	// piece's bytes are those of the text at ``base``.
	line: int,
	base: int,
	// ``line >= 0``: from byte ``tail_out`` of the rewritten line on (after
	// its last tab), the bytes are those of the source at ``tail_b``
	tail_out: int,
	tail_b:   int,
}

// --- setup ---------------------------------------------------------------------

// Start recording spans for the parse of ``text`` split into ``lines``;
// ``doc`` is the document node.
@(private)
spans_begin :: proc(p: ^Parser, text: string, lines: []string, doc: Node) {
	a := p.allocator
	sp := new(Span_Map, a)
	sp.text = text
	sp.starts = p.tree.line_starts
	sp.tab_width = p.settings.tab_width
	sp.pieces = make([dynamic]Piece, 0, 8, a)
	for &w in sp.walks do w.line = -1
	base := uintptr(raw_data(text))
	for line, i in lines {
		addr := uintptr(raw_data(line))
		if addr - base <= uintptr(len(text)) || len(line) == 0 do continue
		tail_out, tail_b := line_tail(sp, i)
		append(&sp.pieces, Piece{addr, len(line), i, 0, tail_out, tail_b})
	}
	by_addr :: proc(a, b: Piece) -> bool {return a.addr < b.addr}
	if !slice.is_sorted_by(sp.pieces[:], by_addr) do slice.sort_by(sp.pieces[:], by_addr)
	p.spans = sp
	t := &p.tree
	t.spans = make([dynamic]Span, cap(t.nodes), a) // grows with the tree
	set_span(p, doc, 0, len(text))
}

// --- resolving strings to source offsets -----------------------------------------

// Source offset of byte ``k`` of ``s`` (-1 when ``s`` is not from the text).
@(private)
source_offset :: proc(sp: ^Span_Map, s: string, k: int) -> int {
	if raw_data(s) == nil do return -1
	addr := uintptr(raw_data(s))
	base := uintptr(raw_data(sp.text))
	if addr - base < uintptr(len(sp.text)) do return int(addr - base) + k
	if pc, ok := find_piece(sp, addr); ok {
		off := int(addr - pc.addr) + k
		if pc.line < 0 do return pc.base + off
		e := pc.base + off
		if e >= pc.tail_out do return pc.tail_b + e - pc.tail_out
		return expanded_to_source(sp, pc.line, e)
	}
	if addr - base == uintptr(len(sp.text)) do return len(sp.text) // a view at the end
	return -1
}

// The piece containing ``addr`` (its end included, for empty views): the
// last one found or a neighbour, else by binary search.
@(private = "file")
find_piece :: proc "contextless" (sp: ^Span_Map, addr: uintptr) -> (pc: Piece, ok: bool) {
	for i in max(sp.last_piece - 1, 0) ..< min(sp.last_piece + 2, len(sp.pieces)) {
		// strictly inside: an address at a piece's end may start the next one
		pc = sp.pieces[i]
		if addr - pc.addr >= uintptr(pc.len) do continue
		sp.last_piece = i
		return pc, true
	}
	lo, hi := 0, len(sp.pieces)
	for lo < hi {
		mid := (lo + hi) / 2
		if sp.pieces[mid].addr <= addr {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == 0 do return
	pc = sp.pieces[lo - 1]
	sp.last_piece = lo - 1
	return pc, addr - pc.addr <= uintptr(pc.len)
}

// Source offset of byte ``e`` of line ``line`` as rewritten by
// ``normalize_line``.  An offset inside the expansion of a tab maps to the
// end of the tab.
@(private = "file")
expanded_to_source :: proc(sp: ^Span_Map, line, e: int) -> int {
	end := int(sp.starts[line + 1])
	w := &sp.walks[line % len(sp.walks)]
	if w.line != line || w.out > e do w^ = {line, 0, 0, int(sp.starts[line])}
	for w.out < e && w.b < end {
		// the characters before the next tab are copied as they are
		run := sp.text[w.b:min(end, w.b + e - w.out)]
		n := strings.index_byte(run, '\t')
		if n < 0 do n = len(run)
		if n == 0 {
			width := sp.tab_width - w.column % sp.tab_width if sp.tab_width > 0 else 0
			w.column += width
			w.out += width
			w.b += 1
		} else if is_ascii(run[:n]) { // \v and \f become one space
			w.column += n
			w.out += n
			w.b += n
		} else {
			walk_runes(sp, w, end, e)
		}
	}
	return w.b
}

// Where the rewritten line ``line`` becomes a copy of the source: after its
// last tab, when the rest is valid UTF-8 (``max(int)`` otherwise).
@(private = "file")
line_tail :: proc(sp: ^Span_Map, line: int) -> (tail_out, tail_b: int) {
	start, end := int(sp.starts[line]), int(sp.starts[line + 1])
	last_tab := strings.last_index_byte(sp.text[start:end], '\t')
	if !utf8.valid_string(sp.text[start + last_tab + 1:end]) do return max(int), 0
	if last_tab < 0 do return 0, start
	// the rewritten length of the text up to the last tab
	tail_b = start + last_tab + 1
	column := 0
	for r in sp.text[start:tail_b] { // as ``normalize_line`` writes it
		width := 1 // \v and \f become one space
		switch r {
		case '\t':
			width = sp.tab_width - column % sp.tab_width if sp.tab_width > 0 else 0
			column += width
		case '\v', '\f':
			column += 1
		case:
			width = utf8.rune_size(r)
			column += 1
		}
		tail_out += width
	}
	return
}

// Walk to ``e`` or the next tab, one character at a time.
@(private = "file")
walk_runes :: proc(sp: ^Span_Map, w: ^Line_Walk, end, e: int) {
	for w.out < e && w.b < end && sp.text[w.b] != '\t' {
		r, size := utf8.decode_rune_in_string(sp.text[w.b:end])
		w.column += 1
		w.out += utf8.rune_size(r) // U+FFFD for an invalid byte
		w.b += size
	}
}

// Register ``s`` (a copy) as mirroring the bytes of ``from`` at ``k``: a
// table cell line cut out of a table row.  Nothing is registered when ``s``
// is empty, ``from`` is not from the text, or the bytes differ.
@(private)
span_register_copy :: proc(sp: ^Span_Map, s: string, from: string, k: int) {
	if len(s) == 0 || k + len(s) > len(from) || from[k:k + len(s)] != s do return
	pc := Piece{addr = uintptr(raw_data(s)), len = len(s), line = -1}
	addr := uintptr(raw_data(from)) + uintptr(k)
	base := uintptr(raw_data(sp.text))
	if addr - base < uintptr(len(sp.text)) {
		pc.base = int(addr - base)
	} else if outer, ok := find_piece(sp, addr); ok {
		pc.line = outer.line
		pc.base = outer.base + int(addr - outer.addr)
		pc.tail_out, pc.tail_b = outer.tail_out, outer.tail_b
	} else {
		return
	}
	// copies are made in increasing addresses (the arena grows upwards), so
	// this is an append but when the arena moves to a new block
	n := len(sp.pieces)
	if n == 0 || sp.pieces[n - 1].addr < pc.addr {
		append(&sp.pieces, pc)
		return
	}
	by_addr :: proc(p: Piece, a: uintptr) -> slice.Ordering {return slice.cmp(p.addr, a)}
	i, _ := slice.binary_search_by(sp.pieces[:], pc.addr, by_addr)
	// (``inject_at`` would grow the array by one element at a time)
	if n == cap(sp.pieces) do reserve(&sp.pieces, 2 * n)
	inject_at(&sp.pieces, i, pc)
}

// Offset ``k`` of text joined from ``lines`` with '\n' (and possibly cut
// short) in the source.
@(private)
joined_offset :: proc(sp: ^Span_Map, lines: []string, k: int) -> int {
	if len(lines) == 0 do return -1
	i, start := 0, 0
	for i < len(lines) - 1 && start + len(lines[i]) < k {
		start += len(lines[i]) + 1
		i += 1
	}
	return source_offset(sp, lines[i], k - start)
}

// The source offset of ``s`` when its bytes are those of the source from
// there on (a view of the text, of a copy of it, or of the part of a
// rewritten line after its last tab), else -1.
@(private)
direct_offset :: proc(sp: ^Span_Map, s: string) -> int {
	if raw_data(s) == nil do return -1
	addr := uintptr(raw_data(s))
	if at := addr - uintptr(raw_data(sp.text)); at < uintptr(len(sp.text)) do return int(at)
	pc, ok := find_piece(sp, addr)
	if !ok do return -1
	off := int(addr - pc.addr)
	if pc.line < 0 do return pc.base + off
	if e := pc.base + off; e >= pc.tail_out do return pc.tail_b + e - pc.tail_out
	return -1
}

// --- recording -------------------------------------------------------------------

// Record ``[start, end)`` as the span of ``n``.  Negative (unknown) ends
// fall back to the other end, or to ``Span_Map.fallback``.
@(private)
set_span :: #force_inline proc(p: ^Parser, n: Node, start, end: int) {
	sp := p.spans
	if sp == nil || n == NO_NODE do return
	t := &p.tree
	if 0 <= start && start <= end && end <= len(sp.text) && int(n) < len(t.spans) {
		t.spans[n] = {u32(start), u32(end)} // the usual case
		return
	}
	set_span_checked(p, n, start, end)
}

@(private = "file")
set_span_checked :: proc(p: ^Parser, n: Node, start, end: int) {
	sp := p.spans
	s, e := start, end
	if s < 0 do s = e
	if e < 0 do e = s
	if s < 0 do s, e = sp.fallback, sp.fallback
	s = clamp(s, 0, len(sp.text))
	e = clamp(e, s, len(sp.text))
	t := &p.tree
	if int(n) >= len(t.spans) do resize(&t.spans, max(cap(t.nodes), 2 * len(t.spans)))
	t.spans[n] = {u32(s), u32(e)}
}

// ``n`` spans from byte 0 of ``first`` to the end of the last non-blank line
// of ``lines`` (of ``first`` itself when there is none).
@(private)
span_block :: proc(p: ^Parser, n: Node, first: string, lines: []string) {
	sp := p.spans
	if sp == nil do return
	set_span(p, n, source_offset(sp, first, 0), block_end(sp, first, lines))
}

// ``n`` spans the non-blank lines of ``lines`` (an empty span at ``empty_at``
// when there is none).
@(private)
span_lines :: proc(p: ^Parser, n: Node, lines: []string, empty_at: int) {
	sp := p.spans
	if sp == nil do return
	for line in lines {
		if len(line) == 0 do continue
		set_span(p, n, source_offset(sp, line, 0), block_end(sp, line, lines))
		return
	}
	set_span(p, n, empty_at, empty_at)
}

// ``n`` spans the string ``s`` (a view of a line).
@(private)
span_string :: proc(p: ^Parser, n: Node, s: string) {
	sp := p.spans
	if sp == nil do return
	set_span(p, n, source_offset(sp, s, 0), source_offset(sp, s, len(s)))
}

// The end of the last non-blank line of ``lines``, else of ``first``.
// (``string2lines`` strips trailing whitespace; the lines of a raw-lines
// parse keep it, as their text does.)
@(private = "file")
block_end :: proc(sp: ^Span_Map, first: string, lines: []string) -> int {
	#reverse for line in lines {
		if len(line) > 0 do return source_offset(sp, line, len(line))
	}
	return source_offset(sp, first, len(first))
}

// ``n`` spans its children (an empty span at ``empty_at`` without any);
// ``start`` (>= 0) moves its start back.
@(private)
span_children :: proc(p: ^Parser, n: Node, empty_at: int, start := -1) {
	if p.spans == nil do return
	t := &p.tree
	lo, hi := max(int), -1
	for c := t.nodes[n].first; c != NO_NODE; c = t.nodes[c].next {
		if t.nodes[c].kind == .System_Message do continue
		s, e := node_span(t, c)
		lo, hi = min(lo, s), max(hi, e)
	}
	if hi < 0 do lo, hi = empty_at, empty_at
	if start >= 0 do lo = min(lo, start)
	set_span(p, n, lo, hi)
}

// The recorded start and end of ``n`` (0 without spans).
@(private)
span_start :: #force_inline proc(p: ^Parser, n: Node) -> int {
	start, _ := node_span(&p.tree, n)
	return start
}

@(private)
span_end :: #force_inline proc(p: ^Parser, n: Node) -> int {
	_, end := node_span(&p.tree, n)
	return end
}

// The span of a message reporting line ``line``: that line's text.
@(private)
span_message :: proc(p: ^Parser, n: Node, line: int) {
	sp := p.spans
	if sp == nil do return
	at := line
	if at <= 0 { // no line: the current one (or the last, past the end)
		at = p.cur_line
		if last, past := past_end_line(at); past do at = last
	}
	start, end := line_span(&p.tree, max(at, 1))
	set_span(p, n, start, end)
}

// --- queries -----------------------------------------------------------------------

// Whether the tree has spans (``Parse_Flag.Spans``).
has_spans :: #force_inline proc "contextless" (t: ^Tree) -> bool {
	return len(t.spans) > 0
}

// The byte range ``[start, end)`` of ``n`` in the parsed text (see the rules
// in nodes.odin); ``0, 0`` without spans.
node_span :: proc "contextless" (t: ^Tree, n: Node) -> (start, end: int) {
	if int(n) >= len(t.spans) do return 0, 0
	s := t.spans[n]
	return int(s.start), int(s.end)
}

// Number of lines of the parsed text (``string2lines`` lines).
line_count :: #force_inline proc "contextless" (t: ^Tree) -> int {
	return max(len(t.line_starts) - 1, 0)
}

// The text of line ``line`` (1-based, as ``Node_Data.line``) without its
// indentation, trailing whitespace and line break; an empty range at the
// end of the text past the last line.
line_span :: proc "contextless" (t: ^Tree, line: int) -> (start, end: int) {
	if line < 1 || line > line_count(t) do return len(t.text), len(t.text)
	start, end = int(t.line_starts[line - 1]), int(t.line_starts[line])
	end -= line_break_before(t.text[start:end])
	content := t.text[start:end]
	stripped := lstrip(rstrip(content))
	start += len(content) - len(lstrip(content))
	return start, start + len(stripped)
}

// Length of the ``str.splitlines()`` boundary that ends ``line``.
@(private = "file")
line_break_before :: proc "contextless" (line: string) -> int {
	n := len(line)
	switch {
	case n >= 2 && line[n - 2:] == "\r\n":
		return 2
	case n >= 1 && (line[n - 1] == '\n' || line[n - 1] == '\r'):
		return 1
	case n >= 1 && line[n - 1] >= 0x1C && line[n - 1] <= 0x1E:
		return 1
	case n >= 2 && line[n - 2:] == "\u0085":
		return 2
	case n >= 3 && (line[n - 3:] == "\u2028" || line[n - 3:] == "\u2029"):
		return 3
	}
	return 0
}

// The line (1-based) containing byte ``offset`` of the parsed text.
offset_line :: proc "contextless" (t: ^Tree, offset: int) -> int {
	n := line_count(t)
	lo, hi := 0, n
	for lo < hi {
		mid := (lo + hi) / 2
		if int(t.line_starts[mid + 1]) <= offset {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return min(lo, max(n - 1, 0)) + 1
}
