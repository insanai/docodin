package rst

import "core:slice"
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
	base := uintptr(raw_data(text))
	for line, i in lines {
		addr := uintptr(raw_data(line))
		if addr - base <= uintptr(len(text)) || len(line) == 0 do continue
		append(&sp.pieces, Piece{addr = addr, len = len(line), line = i})
	}
	slice.sort_by(sp.pieces[:], proc(a, b: Piece) -> bool {return a.addr < b.addr})
	p.spans = sp
	t := &p.tree
	t.spans = make([dynamic]Span, 0, cap(t.nodes), a)
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
		return expanded_to_source(sp, pc.line, pc.base + off)
	}
	if addr - base == uintptr(len(sp.text)) do return len(sp.text) // a view at the end
	return -1
}

// The piece containing ``addr`` (its end included, for empty views).
@(private = "file")
find_piece :: proc "contextless" (sp: ^Span_Map, addr: uintptr) -> (pc: Piece, ok: bool) {
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
	return pc, addr - pc.addr <= uintptr(pc.len)
}

// Source offset of byte ``e`` of line ``line`` as rewritten by
// ``normalize_line``.  An offset inside the expansion of a tab maps to the
// end of the tab.
@(private = "file")
expanded_to_source :: proc(sp: ^Span_Map, line, e: int) -> int {
	b := int(sp.starts[line])
	end := int(sp.starts[line + 1])
	out, column := 0, 0
	for out < e && b < end {
		r, w := utf8.decode_rune_in_string(sp.text[b:end])
		width := 0
		switch r {
		case '\t':
			if sp.tab_width > 0 do width = sp.tab_width - column % sp.tab_width
			column += width
		case '\v', '\f':
			width = 1
			column += 1
		case:
			width = utf8.rune_size(r)
			column += 1
		}
		out += width
		b += w
	}
	return b
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
	} else {
		return
	}
	by_addr :: proc(p: Piece, a: uintptr) -> slice.Ordering {return slice.cmp(p.addr, a)}
	i, _ := slice.binary_search_by(sp.pieces[:], pc.addr, by_addr)
	// (``inject_at`` grows the array by one element at a time)
	if len(sp.pieces) == cap(sp.pieces) do reserve(&sp.pieces, 2 * len(sp.pieces) + 8)
	inject_at(&sp.pieces, i, pc)
}

// Offset ``k`` of text joined from ``lines`` with '\n' (and possibly cut
// short) in the source.  ``cum`` (optional) holds the offset of each line
// in the joined text.
@(private)
joined_offset :: proc(sp: ^Span_Map, lines: []string, cum: []int, k: int) -> int {
	if len(lines) == 0 do return -1
	i := 0
	if cum != nil {
		// the first line whose end reaches k
		lo, hi := 0, len(lines) - 1
		for lo < hi {
			mid := (lo + hi) / 2
			if cum[mid] + len(lines[mid]) < k {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		i = lo
		return source_offset(sp, lines[i], k - cum[i])
	}
	start := 0
	for i < len(lines) - 1 && start + len(lines[i]) < k {
		start += len(lines[i]) + 1
		i += 1
	}
	return source_offset(sp, lines[i], k - start)
}

// --- recording -------------------------------------------------------------------

// Record ``[start, end)`` as the span of ``n``.  Negative (unknown) ends
// fall back to the other end, or to ``Span_Map.fallback``.
@(private)
set_span :: proc(p: ^Parser, n: Node, start, end: int) {
	sp := p.spans
	if sp == nil || n == NO_NODE do return
	s, e := start, end
	if s < 0 do s = e
	if e < 0 do e = s
	if s < 0 do s, e = sp.fallback, sp.fallback
	s = clamp(s, 0, len(sp.text))
	e = clamp(e, s, len(sp.text))
	t := &p.tree
	if int(n) >= len(t.spans) do resize(&t.spans, len(t.nodes))
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
