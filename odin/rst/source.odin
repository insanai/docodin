package rst

import "base:intrinsics"
import "base:runtime"
import "core:unicode/utf8"

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
	pool := Line_Pool{allocator = allocator}
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
		append(&out, normalize_line(input[start:i], rewrite, tab_width, &pool))
		if table do append(&table_out, u32(start))
		i += sep
		start = i
		rewrite = false
	}
	if start < n {
		append(&out, normalize_line(input[start:], rewrite, tab_width, &pool))
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
// Python expands a tab to the next multiple of ``tab_width`` columns,
// counting a column per code point, and turns \v and \f into spaces; other
// characters are copied (an invalid UTF-8 byte becomes U+FFFD, as Odin
// decodes it).  Lines are short: one scalar pass over the bytes, writing
// into a buffer cut from a shared block.
@(private = "file")
normalize_line :: proc(
	line: string,
	rewrite: bool,
	tab_width: int,
	pool: ^Line_Pool,
) -> string {
	if !rewrite do return rstrip(line)
	// at most tab_width bytes per tab, 3 per invalid byte
	buf := pool_take(pool, len(line) * max(tab_width, 3))
	n, column := 0, 0
	for i := 0; i < len(line); {
		// a run of plain ASCII is copied at once
		j := plain_ascii_end(line, i)
		if j > i {
			n += copy(buf[n:], line[i:j])
			column += j - i
			i = j
			continue
		}
		c := line[i]
		switch {
		case c == '\t':
			spaces := tab_width - column % tab_width if tab_width > 0 else 0
			for k in 0 ..< spaces do buf[n + k] = ' '
			n += spaces
			column += spaces
			i += 1
			continue
		case c == '\v' || c == '\f':
			buf[n] = ' '
			n += 1
			i += 1
		case:
			r, size := utf8.decode_rune_in_string(line[i:])
			bytes := line[i:i + size] if r != utf8.RUNE_ERROR else "\uFFFD" // or U+FFFD itself
			n += copy(buf[n:], bytes)
			i += size
		}
		column += 1
	}
	pool_return(pool, buf[n:])
	return rstrip(string(buf[:n]))
}

// The end of the run of ASCII other than \t, \v and \f at ``i``: eight
// bytes at a time (SWAR), then byte by byte.
@(private = "file")
plain_ascii_end :: proc "contextless" (s: string, i: int) -> int {
	ONES :: 0x0101010101010101
	HIGH :: 0x8080808080808080
	has_byte :: #force_inline proc "contextless" (x: u64, b: u64) -> u64 {
		y := x ~ (ONES * b)
		return (y - ONES) & ~y & HIGH
	}
	j := i
	for ; j + 8 <= len(s); j += 8 {
		x := intrinsics.unaligned_load((^u64)(raw_data(s)[j:]))
		if (x & HIGH) | has_byte(x, '\t') | has_byte(x, '\v') | has_byte(x, '\f') != 0 do break
	}
	for j < len(s) {
		switch s[j] {
		case '\t', '\v', '\f', 0x80 ..= 0xFF:
			return j
		}
		j += 1
	}
	return j
}

// Rewritten lines are cut from shared blocks: one allocation per block,
// not per line.
@(private = "file")
Line_Pool :: struct {
	free:      []u8,
	allocator: runtime.Allocator,
}

@(private = "file")
LINE_BLOCK :: 64 * 1024

// ``size`` bytes (not zeroed) at the start of the pool's free space.
@(private = "file")
pool_take :: proc(pool: ^Line_Pool, size: int) -> []u8 {
	if size > len(pool.free) {
		block, _ := runtime.mem_alloc_non_zeroed(max(size, LINE_BLOCK), 1, pool.allocator)
		pool.free = block
	}
	buf := pool.free[:size]
	pool.free = pool.free[size:]
	return buf
}

// Give back ``unused``, the end of the last buffer taken.
@(private = "file")
pool_return :: proc(pool: ^Line_Pool, unused: []u8) {
	if len(unused) > 0 && raw_data(unused[len(unused):]) == raw_data(pool.free) {
		pool.free = ([^]u8)(raw_data(unused))[:len(unused) + len(pool.free)]
	}
}

// First line (1-based) longer than ``limit`` code points, or 0.
find_overlong_line :: proc(lines: []string, limit: int) -> int {
	for line, i in lines {
		if len(line) > limit && cp_len(line) > limit do return i + 1
	}
	return 0
}
