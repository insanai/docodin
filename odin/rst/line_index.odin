package rst

import "core:unicode/utf8"

// Editor positions (LSP ``Position``): a line index over a text converts
// byte offsets to 0-based lines and columns and back, as ruff's
// ``LineIndex`` does.  Lines end at \n, \r\n or \r, as LSP defines them;
// this is not the ``string2lines`` numbering of ``Node_Data.line``, which
// also breaks lines at \x1c-\x1e, U+0085, U+2028 and U+2029 (see
// ``line_span`` and ``offset_line`` for that one).
// Columns count UTF-16 code units by default (LSP's default position
// encoding), or UTF-8 bytes or code points.  An ASCII text takes a fast
// path: columns are byte offsets.

Position_Encoding :: enum u8 {
	UTF16, // LSP's default
	UTF8,
	UTF32,
}

Line_Index :: struct {
	text:     string,
	starts:   []u32, // byte offset of the start of each line (at least one)
	ascii:    bool,  // the text is ASCII: every encoding counts bytes
	encoding: Position_Encoding,
}

line_index_make :: proc(
	text: string,
	encoding := Position_Encoding.UTF16,
	allocator := context.allocator,
) -> Line_Index {
	starts := make([dynamic]u32, 0, count_newlines(text) + 2, allocator)
	append(&starts, 0)
	for i := next_cr_lf(text, 0); i < len(text); i = next_cr_lf(text, i + 1) {
		if text[i] == '\r' && i + 1 < len(text) && text[i + 1] == '\n' do i += 1
		append(&starts, u32(i + 1))
	}
	return {text, starts[:], is_ascii(text), encoding}
}

line_index_destroy :: proc(idx: ^Line_Index, allocator := context.allocator) {
	delete(idx.starts, allocator)
	idx.starts = nil
}

// 0-based line and column of byte ``offset``.  An offset past the end
// gives the end of the text; one inside a UTF-8 sequence counts from the
// start of its character.
line_col :: proc(idx: ^Line_Index, offset: int) -> (line, col: int) {
	at := clamp(offset, 0, len(idx.text))
	lo, hi := 0, len(idx.starts)
	for lo < hi {
		mid := (lo + hi) / 2
		if int(idx.starts[mid]) <= at {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	line = lo - 1
	start := int(idx.starts[line])
	if idx.ascii || idx.encoding == .UTF8 do return line, at - start
	for b := start; b < at; {
		r, w := utf8.decode_rune_in_string(idx.text[b:])
		if b + w > at do break // inside a character
		col += encoded_len(idx.encoding, r)
		b += w
	}
	return
}

// Byte offset of the 0-based ``line`` and ``col``.  A column past the end
// of the line gives the end of the line (before its line break), a line
// past the last one the end of the text, and a column inside a character
// (half a surrogate pair) the start of that character.
line_col_offset :: proc(idx: ^Line_Index, line, col: int) -> int {
	if line < 0 do return 0
	if line >= len(idx.starts) do return len(idx.text)
	start := int(idx.starts[line])
	end := line_end(idx, line)
	if idx.ascii || idx.encoding == .UTF8 do return start + clamp(col, 0, end - start)
	b, units := start, 0
	for b < end {
		r, w := utf8.decode_rune_in_string(idx.text[b:end])
		units += encoded_len(idx.encoding, r)
		if units > col do break
		b += w
	}
	return b
}

// End of the text of ``line`` (its line break excluded).
@(private = "file")
line_end :: proc(idx: ^Line_Index, line: int) -> int {
	if line + 1 >= len(idx.starts) do return len(idx.text)
	end := int(idx.starts[line + 1])
	if end > 0 && idx.text[end - 1] == '\n' do end -= 1
	if end > int(idx.starts[line]) && idx.text[end - 1] == '\r' do end -= 1
	return end
}

@(private = "file")
encoded_len :: #force_inline proc "contextless" (e: Position_Encoding, r: rune) -> int {
	switch e {
	case .UTF16: return 2 if r >= 0x10000 else 1
	case .UTF8:  return utf8.rune_size(r)
	case .UTF32: return 1
	}
	return 1
}
