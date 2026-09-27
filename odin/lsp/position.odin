package lsp

// Positions.
//
// The server works with byte offsets into the document's text: the parser
// records the source span of every node (``Parse_Flag.Spans``,
// ``rst.node_span``), and its line table (``Tree.line_starts``) gives the
// lines as docutils numbers them (``string2lines``).  LSP positions (lines
// broken at \n, \r\n and \r; UTF-16 or UTF-8 columns) are converted at the
// protocol boundary with ``rst.Line_Index``.

import "core:strings"

import rst "../rst"

Encoding :: rst.Position_Encoding

// A byte range ``[start, end)`` of the document's text.
Span :: struct {
	start, end: i32,
}

// An LSP position (in the negotiated encoding).
Lsp_Pos :: struct {
	line, character: int,
}

to_lsp :: proc(idx: ^rst.Line_Index, offset: i32) -> Lsp_Pos {
	line, col := rst.line_col(idx, int(offset))
	return {line, col}
}

from_lsp :: proc(idx: ^rst.Line_Index, p: Lsp_Pos) -> i32 {
	return i32(rst.line_col_offset(idx, p.line, p.character))
}

// ``p`` lies in ``s`` (the end included: a cursor just after a name).
span_contains :: #force_inline proc "contextless" (s: Span, p: i32) -> bool {
	return s.start <= p && p <= s.end
}

// The source span of node ``n`` (spans are on in every parse the server
// makes).
node_span :: proc(t: ^rst.Tree, n: rst.Node) -> Span {
	start, end := rst.node_span(t, n)
	return {i32(start), i32(end)}
}

// The offset of ``s`` in the parsed text (-1 if it is not a view of it:
// a line whose tabs were expanded, a joined string).
view_offset :: proc(t: ^rst.Tree, s: string) -> int {
	if len(s) == 0 do return -1
	at := int(uintptr(raw_data(s))) - int(uintptr(raw_data(t.text)))
	return at if at >= 0 && at + len(s) <= len(t.text) else -1
}

// --- lines as the parser numbers them (1-based) ------------------------------------------

// The content of ``line``: without indentation, trailing whitespace and
// line break (empty for a blank line).
content_span :: proc(t: ^rst.Tree, line: int) -> Span {
	start, end := rst.line_span(t, line)
	return {i32(start), i32(end)}
}

line_blank :: proc(t: ^rst.Tree, line: int) -> bool {
	s := content_span(t, line)
	return s.start == s.end
}

// The text of ``line`` with its indentation, without trailing whitespace
// and line break.
line_text :: proc(t: ^rst.Tree, line: int) -> string {
	if line < 1 || line > rst.line_count(t) do return ""
	start := int(t.line_starts[line - 1])
	return t.text[start:content_span(t, line).end] if !line_blank(t, line) else ""
}

// The whole of ``line`` (its line break excluded).
whole_line :: proc(t: ^rst.Tree, line: int) -> Span {
	if line < 1 || line > rst.line_count(t) do return {i32(len(t.text)), i32(len(t.text))}
	start, end := int(t.line_starts[line - 1]), int(t.line_starts[line])
	for end > start && strings.index_byte("\r\n\x1c\x1d\x1e", t.text[end - 1]) >= 0 do end -= 1
	return {i32(start), i32(end)}
}

// The last non-blank line at or before ``line`` (not before ``floor``).
last_nonblank :: proc(t: ^rst.Tree, line, floor: int) -> int {
	l := min(line, rst.line_count(t))
	for l > floor && line_blank(t, l) do l -= 1
	return l
}

// The line (1-based) of an offset.
line_of :: #force_inline proc(t: ^rst.Tree, offset: i32) -> int {
	return rst.offset_line(t, int(offset))
}

// The first occurrence of ``needle`` in ``within`` (on its first line with
// ``first_line``).
find_in :: proc(t: ^rst.Tree, within: Span, needle: string, first_line := true) -> (Span, bool) {
	text := t.text[within.start:within.end]
	if first_line {
		if nl := strings.index_any(text, "\r\n"); nl >= 0 do text = text[:nl]
	}
	at := strings.index(text, needle)
	if at < 0 || needle == "" do return {}, false
	start := within.start + i32(at)
	return {start, start + i32(len(needle))}, true
}

// A line of one repeated punctuation character.
is_adornment :: proc(line: string) -> bool {
	return rst.match_line(line)
}

is_blank :: #force_inline proc(s: string) -> bool {
	return len(rst.strip(s)) == 0
}
