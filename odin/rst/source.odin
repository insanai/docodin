package rst

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
	lines := make([dynamic]string, 0, estimate_line_count(input), allocator)
	start := 0
	i := 0
	n := len(input)
	for i < n {
		b := input[i]
		sep := 0
		switch b {
		case '\n', 0x1C, 0x1D, 0x1E:
			sep = 1
		case '\r':
			sep = 2 if i + 1 < n && input[i + 1] == '\n' else 1
		case 0xC2: // U+0085 NEXT LINE
			if i + 1 < n && input[i + 1] == 0x85 do sep = 2
		case 0xE2: // U+2028 LINE SEPARATOR, U+2029 PARAGRAPH SEPARATOR
			if i + 2 < n && input[i + 1] == 0x80 {
				if input[i + 2] == 0xA8 || input[i + 2] == 0xA9 do sep = 3
			}
		}
		if sep == 0 {
			i += 1
			continue
		}
		append(&lines, normalize_line(input[start:i], tab_width, allocator))
		i += sep
		start = i
	}
	if start < n {
		append(&lines, normalize_line(input[start:], tab_width, allocator))
	}
	return lines[:]
}

@(private = "file")
estimate_line_count :: proc(s: string) -> int {
	// One cheap pass; avoids repeated growth of the line array.
	count := 1
	for i in 0 ..< len(s) {
		if s[i] == '\n' do count += 1
	}
	return count
}

@(private = "file")
normalize_line :: proc(line: string, tab_width: int, allocator: runtime.Allocator) -> string {
	needs_rewrite := false
	for i in 0 ..< len(line) {
		switch line[i] {
		case '\t', '\v', '\f':
			needs_rewrite = true
		}
		if needs_rewrite do break
	}
	if !needs_rewrite do return rstrip(line)

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
