package rst

// Character classification mirroring CPython semantics used by docutils:
// ``str.isspace`` (regex ``\s``), ``str.isalnum`` (regex ``\w`` minus "_"),
// ``unicodedata.combining`` and East Asian width, plus the inline-markup
// punctuation classes of ``docutils.utils.punctuation_chars``.
// Tables live in the generated file unicode_tables.odin.

import "core:unicode/utf8"

// Bit flags of the generated ASCII_FLAGS table.
FLAG_SPACE        :: 1
FLAG_ALNUM        :: 2
FLAG_START_PREFIX :: 4
FLAG_END_SUFFIX   :: 8
FLAG_PUNCT7       :: 16

in_ranges :: proc "contextless" (r: rune, table: [][2]rune) -> bool {
	lo, hi := 0, len(table)
	for lo < hi {
		mid := (lo + hi) / 2
		switch {
		case r < table[mid][0]: hi = mid
		case r > table[mid][1]: lo = mid + 1
		case:                   return true
		}
	}
	return false
}

is_space :: #force_inline proc "contextless" (r: rune) -> bool {
	if r < 0x80 do return ASCII_FLAGS[r] & FLAG_SPACE != 0
	return in_ranges(r, SPACE_RANGES[:])
}

// Regex ``(?!_)\w``: Python ``str.isalnum()``.
is_alnum :: #force_inline proc "contextless" (r: rune) -> bool {
	if r < 0x80 do return ASCII_FLAGS[r] & FLAG_ALNUM != 0
	return in_ranges(r, ALNUM_RANGES[:])
}

is_decimal :: #force_inline proc "contextless" (r: rune) -> bool {
	if r < 0x80 do return r >= '0' && r <= '9'
	return in_ranges(r, DECIMAL_RANGES[:])
}

// Character class ``[openers delimiters]`` of the inline start-string prefix.
is_start_prefix_char :: #force_inline proc "contextless" (r: rune) -> bool {
	if r < 0x80 do return ASCII_FLAGS[r] & FLAG_START_PREFIX != 0
	return in_ranges(r, START_PREFIX_RANGES[:])
}

// Character class ``[\x00 closing_delimiters delimiters closers]`` of the
// inline end-string suffix.
is_end_suffix_char :: #force_inline proc "contextless" (r: rune) -> bool {
	if r < 0x80 do return ASCII_FLAGS[r] & FLAG_END_SUFFIX != 0
	return in_ranges(r, END_SUFFIX_RANGES[:])
}

// docutils ``nonalphanum7bit``: ``[!-/:-@[-`{-~]``
is_punct7 :: #force_inline proc "contextless" (b: byte) -> bool {
	return b < 0x80 && ASCII_FLAGS[b] & FLAG_PUNCT7 != 0
}

is_combining :: #force_inline proc "contextless" (r: rune) -> bool {
	return r >= 0x300 && in_ranges(r, COMBINING_RANGES[:])
}

is_wide :: #force_inline proc "contextless" (r: rune) -> bool {
	return r >= 0x1100 && in_ranges(r, WIDE_RANGES[:])
}

// ``punctuation_chars.match_chars``: is (c1, c2) an open/close pair?
match_chars :: proc "contextless" (c1, c2: rune) -> bool {
	for pair in QUOTE_PAIRS {
		if pair[0] == c1 && pair[1] == c2 do return true
	}
	return false
}

// ``docutils.utils.column_width``
column_width :: proc "contextless" (s: string) -> int {
	width := 0
	for r in s {
		switch {
		case r < 0x300:     width += 1
		case is_combining(r): // zero width
		case is_wide(r):    width += 2
		case:               width += 1
		}
	}
	return width
}

// Rune ending right before byte offset ``i`` (0 if at the start).
rune_before :: #force_inline proc "contextless" (s: string, i: int) -> rune {
	if i <= 0 do return 0
	b := s[i - 1]
	if b < 0x80 do return rune(b)
	r, _ := utf8.decode_last_rune_in_string(s[:i])
	return r
}

// Rune starting at byte offset ``i`` and its byte width (0, 0 at the end).
rune_at :: #force_inline proc "contextless" (s: string, i: int) -> (rune, int) {
	if i >= len(s) do return 0, 0
	b := s[i]
	if b < 0x80 do return rune(b), 1
	return utf8.decode_rune_in_string(s[i:])
}

// ``str.rstrip()``
rstrip :: proc "contextless" (s: string) -> string {
	end := len(s)
	for end > 0 {
		b := s[end - 1]
		if b < 0x80 {
			if ASCII_FLAGS[b] & FLAG_SPACE == 0 do break
			end -= 1
		} else {
			r, w := utf8.decode_last_rune_in_string(s[:end])
			if !is_space(r) do break
			end -= w
		}
	}
	return s[:end]
}

// ``str.lstrip()``
lstrip :: proc "contextless" (s: string) -> string {
	start := 0
	for start < len(s) {
		r, w := rune_at(s, start)
		if !is_space(r) do break
		start += w
	}
	return s[start:]
}

strip :: #force_inline proc "contextless" (s: string) -> string {
	return rstrip(lstrip(s))
}

// Number of leading whitespace code points (``len(s) - len(s.lstrip())``).
leading_ws :: proc "contextless" (s: string) -> int {
	n, i := 0, 0
	for i < len(s) {
		r, w := rune_at(s, i)
		if !is_space(r) do break
		i += w
		n += 1
	}
	return n
}

// Byte offset after skipping ``n`` code points (``s[n:]`` in Python).
cp_offset :: proc "contextless" (s: string, n: int) -> int {
	i := 0
	for k := 0; k < n && i < len(s); k += 1 {
		if s[i] < 0x80 {
			i += 1
		} else {
			_, w := utf8.decode_rune_in_string(s[i:])
			i += w
		}
	}
	return i
}

cp_slice :: #force_inline proc "contextless" (s: string, n: int) -> string {
	return s[cp_offset(s, n):]
}

cp_len :: proc "contextless" (s: string) -> int {
	n := 0
	for i in 0 ..< len(s) {
		// count bytes that start a code point (not UTF-8 continuation bytes)
		if s[i] & 0xC0 != 0x80 do n += 1
	}
	return n
}
