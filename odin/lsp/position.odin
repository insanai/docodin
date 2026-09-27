package lsp

// Positions.
//
// The server works in the parser's coordinates: 0-based lines and byte
// columns in the parser's input lines (tabs expanded, trailing whitespace
// stripped, as ``string2lines`` makes them).  LSP positions count UTF-16
// code units (or bytes, when the client accepts UTF-8) in the original
// lines; they are converted at the protocol boundary.
//
// The parse tree records line numbers but no columns yet, so ``locate_text``
// finds a construct's source text from a starting position.  This is the
// one place to change when odin/rst provides byte spans (``node_span``,
// ``line_col``): the analysis only calls ``locate_text`` and the
// conversions here.

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"

import rst "../rst"

Encoding :: enum u8 {
	Utf16,
	Utf8,
}

// A position in the parser's coordinates.
Pos :: struct {
	line, col: i32,
}

Span :: struct {
	start, end: Pos,
}

// An LSP position (in the negotiated encoding).
Lsp_Pos :: struct {
	line, character: int,
}

// Line starts of a text; lines end at "\n", "\r\n" or "\r" (the LSP line
// breaks).  A text ending with a line break has a last, empty line.
line_starts :: proc(text: string, allocator := context.allocator) -> []i32 {
	starts := make([dynamic]i32, 0, 64, allocator)
	append(&starts, 0)
	for i := 0; i < len(text); i += 1 {
		switch text[i] {
		case '\n':
			append(&starts, i32(i + 1))
		case '\r':
			if i + 1 < len(text) && text[i + 1] == '\n' do i += 1
			append(&starts, i32(i + 1))
		}
	}
	return starts[:]
}

// Line ``line`` of ``text`` without its line break.
line_text :: proc(text: string, starts: []i32, line: int) -> string {
	if line < 0 || line >= len(starts) do return ""
	start := int(starts[line])
	end := len(text) if line + 1 >= len(starts) else int(starts[line + 1])
	for end > start && (text[end - 1] == '\n' || text[end - 1] == '\r') do end -= 1
	return text[start:end]
}

// Byte offset in ``text`` of an LSP position (clamped to the text).
lsp_offset :: proc(text: string, starts: []i32, p: Lsp_Pos, enc: Encoding) -> int {
	if p.line < 0 do return 0
	if p.line >= len(starts) do return len(text)
	line := line_text(text, starts, p.line)
	return int(starts[p.line]) + byte_col_of_character(line, p.character, enc)
}

// Byte column of the LSP character ``character`` in ``line``.
byte_col_of_character :: proc(line: string, character: int, enc: Encoding) -> int {
	if enc == .Utf8 do return clamp(character, 0, len(line))
	units := 0
	for r, i in line {
		if units >= character do return i
		units += 2 if r >= 0x10000 else 1
	}
	return len(line)
}

// LSP characters in ``line[:col]``.
character_of_byte_col :: proc(line: string, byte_col: int, enc: Encoding) -> int {
	col := clamp(byte_col, 0, len(line))
	if enc == .Utf8 do return col
	units := 0
	for r in line[:col] do units += 2 if r >= 0x10000 else 1
	return units
}

// A document's lines in both coordinates.
Line_Index :: struct {
	text:      string,
	starts:    []i32,
	lines:     []string, // original lines
	expanded:  []string, // the parser's input lines
	tab_width: int,
}

line_index_make :: proc(text: string, tab_width: int, allocator: runtime.Allocator) -> Line_Index {
	ix := Line_Index {
		text      = text,
		starts    = line_starts(text, allocator),
		tab_width = tab_width,
	}
	ix.lines = make([]string, len(ix.starts), allocator)
	ix.expanded = make([]string, len(ix.starts), allocator)
	for i in 0 ..< len(ix.starts) {
		ix.lines[i] = line_text(text, ix.starts, i)
		ix.expanded[i] = expand_line(ix.lines[i], tab_width, allocator)
	}
	return ix
}

line_count :: proc(ix: ^Line_Index) -> int {
	return len(ix.lines)
}

// Expanded line ``line`` ("" outside the document).
expanded :: proc(ix: ^Line_Index, line: int) -> string {
	return ix.expanded[line] if line >= 0 && line < len(ix.expanded) else ""
}

// ``string2lines`` for one line: tabs expanded, \v and \f as spaces,
// trailing whitespace stripped.
@(private = "file")
expand_line :: proc(line: string, tab_width: int, allocator: runtime.Allocator) -> string {
	if strings.index_any(line, "\t\v\f") < 0 do return rst.rstrip(line)
	b := strings.builder_make(0, len(line) + 16, allocator)
	column := 0
	for r in line {
		switch r {
		case '\t':
			spaces := tab_width - column % tab_width if tab_width > 0 else 0
			for _ in 0 ..< spaces do strings.write_byte(&b, ' ')
			column += spaces
		case '\v', '\f':
			strings.write_byte(&b, ' ')
			column += 1
		case:
			strings.write_rune(&b, r)
			column += 1
		}
	}
	return rst.rstrip(strings.to_string(b))
}

// Byte column in the original line of the expanded column ``col``.
original_col :: proc(ix: ^Line_Index, line, col: int) -> int {
	if line < 0 || line >= len(ix.lines) do return 0
	orig := ix.lines[line]
	if len(orig) == len(ix.expanded[line]) || strings.index_byte(orig, '\t') < 0 {
		return min(col, len(orig))
	}
	e, column := 0, 0
	for r, i in orig {
		if e >= col do return i
		if r == '\t' {
			spaces := ix.tab_width - column % ix.tab_width if ix.tab_width > 0 else 0
			e += spaces
			column += spaces
		} else {
			e += utf8.rune_size(r)
			column += 1
		}
	}
	return len(orig)
}

// Expanded column of the byte column ``col`` of the original line.
expanded_col :: proc(ix: ^Line_Index, line, col: int) -> int {
	if line < 0 || line >= len(ix.lines) do return 0
	orig := ix.lines[line]
	if strings.index_byte(orig, '\t') < 0 do return col
	e, column := 0, 0
	for r, i in orig {
		if i >= col do return e
		if r == '\t' {
			spaces := ix.tab_width - column % ix.tab_width if ix.tab_width > 0 else 0
			e += spaces
			column += spaces
		} else {
			e += utf8.rune_size(r)
			column += 1
		}
	}
	return e
}

to_lsp :: proc(ix: ^Line_Index, p: Pos, enc: Encoding) -> Lsp_Pos {
	line := clamp(int(p.line), 0, max(len(ix.lines) - 1, 0))
	if len(ix.lines) == 0 do return {}
	col := original_col(ix, line, int(p.col))
	return {line, character_of_byte_col(ix.lines[line], col, enc)}
}

from_lsp :: proc(ix: ^Line_Index, p: Lsp_Pos, enc: Encoding) -> Pos {
	if len(ix.lines) == 0 do return {}
	line := clamp(p.line, 0, len(ix.lines) - 1)
	col := byte_col_of_character(ix.lines[line], p.character, enc)
	return {i32(line), i32(expanded_col(ix, line, col))}
}

pos_less :: #force_inline proc "contextless" (a, b: Pos) -> bool {
	return a.line < b.line || (a.line == b.line && a.col < b.col)
}

// ``p`` lies in ``s`` (the end included: a cursor just after a name).
span_contains :: proc "contextless" (s: Span, p: Pos) -> bool {
	return !pos_less(p, s.start) && !pos_less(s.end, p)
}

// The non-blank part of line ``line``.
line_content_span :: proc(ix: ^Line_Index, line: int) -> Span {
	text := expanded(ix, line)
	indent := len(text) - len(rst.lstrip(text))
	l := i32(line)
	return {{l, i32(indent)}, {l, i32(len(text))}}
}

// The last non-blank line at or before ``line`` (not before ``floor``).
trim_blank_end :: proc(ix: ^Line_Index, line, floor: int) -> int {
	l := min(line, line_count(ix) - 1)
	for l > floor && is_blank(expanded(ix, l)) do l -= 1
	return l
}

is_blank :: #force_inline proc(s: string) -> bool {
	return len(rst.strip(s)) == 0
}

// --- locating source text --------------------------------------------------------------

// Find ``needle`` (a construct's source: its lines joined by "\n", without
// their indentation) from ``from``, on lines up to ``last_line``.  A
// needle spanning lines must end its first line and begin (after the
// indentation) each following line.
locate_text :: proc(ix: ^Line_Index, from: Pos, last: int, needle: string) -> (Span, bool) {
	nl := strings.index_byte(needle, '\n')
	first := needle if nl < 0 else needle[:nl]
	last_line := min(last, line_count(ix) - 1)
	for l := int(from.line); l <= last_line; l += 1 {
		text := expanded(ix, l)
		start := int(from.col) if l == int(from.line) else 0
		if start > len(text) do continue
		if nl < 0 {
			idx := strings.index(text[start:], first)
			if idx < 0 do continue
			col := i32(start + idx)
			return {{i32(l), col}, {i32(l), col + i32(len(first))}}, true
		}
		if !strings.has_suffix(text, first) || len(text) - len(first) < start do continue
		if end, ok := match_continuation(ix, l + 1, needle[nl + 1:]); ok {
			col := i32(len(text) - len(first))
			return {{i32(l), col}, end}, true
		}
	}
	return {}, false
}

// The remaining lines of a needle, from line ``line``: the end position.
@(private = "file")
match_continuation :: proc(ix: ^Line_Index, line: int, rest: string) -> (Pos, bool) {
	rest := rest
	l := line
	for {
		text := expanded(ix, l)
		body := rst.lstrip(text)
		indent := len(text) - len(body)
		nl := strings.index_byte(rest, '\n')
		if nl < 0 {
			if !strings.has_prefix(body, rest) do return {}, false
			return {i32(l), i32(indent + len(rest))}, true
		}
		if rst.rstrip(body) != rst.rstrip(rest[:nl]) do return {}, false
		rest = rest[nl + 1:]
		l += 1
		if l >= line_count(ix) do return {}, false
	}
}
