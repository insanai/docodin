package rst

import "base:intrinsics"
import "base:runtime"
import "core:strings"

// Parser configuration (the subset of docutils settings that affects parsing).
Settings :: struct {
	tab_width:                     int,
	line_length_limit:             int,
	character_level_inline_markup: bool,
	pep_references:                bool,
	rfc_references:                bool,
	trim_footnote_reference_space: bool,
	rfc2822:                       bool, // PEP-style RFC 2822 header fields
	spans:                         bool, // record source positions (``node_span``)
}

DEFAULT_SETTINGS :: Settings {
	tab_width         = 8,
	line_length_limit = 10_000,
}

// ``docutils.statemachine.string2lines(text, tab_width, convert_whitespace=True)``:
// split at ``str.splitlines()`` boundaries, turn \v and \f into spaces, expand
// tabs and strip trailing whitespace.  Lines without tabs/\v/\f are zero-copy
// slices of ``input``.
split_lines :: proc(input: string, tab_width: int, allocator: runtime.Allocator) -> []string {
	lines, _ := split_lines_table(input, tab_width, allocator, false)
	return lines
}

// ``split_lines`` and, with ``table``, the line table: the byte offset in
// ``input`` of each line's start, followed by ``len(input)``.
split_lines_table :: proc(
	input: string,
	tab_width: int,
	allocator: runtime.Allocator,
	table := true,
) -> (
	lines: []string,
	starts: []u32,
) {
	estimate := count_newlines(input) + 1
	out := make([dynamic]string, 0, estimate, allocator)
	table_out: [dynamic]u32
	if table do table_out = make([dynamic]u32, 0, estimate + 1, allocator)
	start, i, n := 0, 0, len(input)
	rewrite := false // the current line has a \t, \v or \f
	for i < n {
		if i + BLOCK <= n {
			breaks := line_break_mask(input, i)
			tabs := tab_mask(input, i)
			if breaks == 0 {
				rewrite ||= tabs != 0
				i += BLOCK
				continue
			}
			k := uint(count_trailing_zeros16(breaks))
			rewrite ||= tabs & (u16(1 << k) - 1) != 0
			i += int(k)
		}
		sep := line_break_at(input, i)
		if sep == 0 {
			switch input[i] {
			case '\t', '\v', '\f':
				rewrite = true
			}
			i += 1
			continue
		}
		append(&out, normalize_line(input[start:i], rewrite, tab_width, allocator))
		if table do append(&table_out, u32(start))
		i += sep
		start = i
		rewrite = false
	}
	if start < n {
		append(&out, normalize_line(input[start:], rewrite, tab_width, allocator))
		if table do append(&table_out, u32(start))
	}
	if table do append(&table_out, u32(n))
	return out[:], table_out[:]
}

// Length of the ``str.splitlines()`` boundary at ``i`` (0: none).
@(private = "file")
line_break_at :: #force_inline proc "contextless" (s: string, i: int) -> int {
	n := len(s)
	switch s[i] {
	case '\n', 0x1C, 0x1D, 0x1E:
		return 1
	case '\r':
		return 2 if i + 1 < n && s[i + 1] == '\n' else 1
	case 0xC2: // U+0085 NEXT LINE
		if i + 1 < n && s[i + 1] == 0x85 do return 2
	case 0xE2: // U+2028 LINE SEPARATOR, U+2029 PARAGRAPH SEPARATOR
		if i + 2 < n && s[i + 1] == 0x80 && (s[i + 2] == 0xA8 || s[i + 2] == 0xA9) do return 3
	}
	return 0
}

@(private = "file")
count_trailing_zeros16 :: #force_inline proc "contextless" (m: u16) -> u16 {
	return intrinsics.count_trailing_zeros(m)
}

// One line of ``string2lines``: ``rewrite`` when it contains \t, \v or \f.
@(private = "file")
normalize_line :: proc(
	line: string,
	rewrite: bool,
	tab_width: int,
	allocator: runtime.Allocator,
) -> string {
	if !rewrite do return rstrip(line)
	b := strings.builder_make_len_cap(0, len(line) + 16, allocator)
	column := 0
	for r in line {
		switch r {
		case '\t':
			if tab_width > 0 {
				spaces := tab_width - column % tab_width
				for _ in 0 ..< spaces do strings.write_byte(&b, ' ')
				column += spaces
			}
		case '\v', '\f':
			strings.write_byte(&b, ' ')
			column += 1
		case:
			strings.write_rune(&b, r)
			column += 1
		}
	}
	return rstrip(strings.to_string(b))
}

// First line (1-based) longer than ``limit`` code points, or 0.
find_overlong_line :: proc(lines: []string, limit: int) -> int {
	for line, i in lines {
		if len(line) > limit && cp_len(line) > limit do return i + 1
	}
	return 0
}
