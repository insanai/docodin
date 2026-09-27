package doctree

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Python ``str`` semantics that docutils output depends on: ``lower()``
// (full case mapping with the final-sigma rule), ``isspace()``,
// ``split()``, ``splitlines()``, ``repr()`` and ``str()`` of attribute
// values.  The Unicode data is generated (unicode_tables.odin).

Lower_Run :: struct {
	lo, hi: rune,
	stride: i32, // 1, or 2 for alternating upper/lower case pairs
	delta:  i32,
}

Rune_String :: struct {
	cp: rune,
	s:  string,
}

Ascii_Run :: struct {
	lo, hi: rune,
	first:  u8,
	step:   u8, // 0: all map to ``first``; 1: consecutive
}

@(private)
in_ranges :: proc(r: rune, table: [][2]rune) -> bool {
	lo, hi := 0, len(table)
	for lo < hi {
		mid := (lo + hi) / 2
		if r < table[mid][0] {
			hi = mid
		} else if r > table[mid][1] {
			lo = mid + 1
		} else {
			return true
		}
	}
	return false
}

// ``str.isspace()`` of one character.
py_isspace :: proc(r: rune) -> bool {
	if r < 0x80 do return r == ' ' || (r >= 0x09 && r <= 0x0D) || (r >= 0x1C && r <= 0x1F)
	return in_ranges(r, SPACE_RANGES[:])
}

// ``str.isprintable()`` of one character.
py_isprintable :: proc(r: rune) -> bool {
	if r < 0x80 do return r >= 0x20 && r < 0x7F
	return !in_ranges(r, NONPRINTABLE_RANGES[:])
}

@(private = "file")
lower_single :: proc(r: rune) -> rune {
	if r < 0x80 {
		return r + 32 if r >= 'A' && r <= 'Z' else r
	}
	lo, hi := 0, len(LOWER_RUNS)
	for lo < hi {
		mid := (lo + hi) / 2
		run := LOWER_RUNS[mid]
		if r < run.lo {
			hi = mid
		} else if r > run.hi {
			lo = mid + 1
		} else {
			if (i32(r) - i32(run.lo)) % run.stride == 0 do return r + rune(run.delta)
			return r
		}
	}
	return r
}

@(private = "file")
lower_multi :: proc(r: rune) -> (string, bool) {
	for m in LOWER_MULTI do if m.cp == r do return m.s, true
	return "", false
}

// CPython ``handle_capital_sigma``: is the U+03A3 at ``i`` word-final?
@(private = "file")
final_sigma :: proc(runes: []rune, i: int) -> bool {
	j := i - 1
	for j >= 0 && in_ranges(runes[j], CASE_IGNORABLE_RANGES[:]) do j -= 1
	if j < 0 || !in_ranges(runes[j], CASED_RANGES[:]) do return false
	j = i + 1
	for j < len(runes) && in_ranges(runes[j], CASE_IGNORABLE_RANGES[:]) do j += 1
	return j == len(runes) || !in_ranges(runes[j], CASED_RANGES[:])
}

@(private = "file")
is_ascii :: proc(s: string) -> bool {
	for i in 0 ..< len(s) do if s[i] >= 0x80 do return false
	return true
}

// ``str.lower()``.
py_lower :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(0, len(s), allocator)
	if is_ascii(s) {
		for i in 0 ..< len(s) {
			c := s[i]
			strings.write_byte(&b, c + 32 if c >= 'A' && c <= 'Z' else c)
		}
		return strings.to_string(b)
	}
	runes := utf8.string_to_runes(s, context.temp_allocator)
	for r, i in runes {
		if r == 0x3A3 {
			strings.write_rune(&b, 0x3C2 if final_sigma(runes, i) else 0x3C3)
		} else if m, ok := lower_multi(r); ok {
			strings.write_string(&b, m)
		} else {
			strings.write_rune(&b, lower_single(r))
		}
	}
	return strings.to_string(b)
}

// ``str.split()``: the words between runs of whitespace.
py_split :: proc(s: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, 4, allocator)
	start := -1
	for r, i in s {
		if py_isspace(r) {
			if start >= 0 do append(&out, s[start:i])
			start = -1
		} else if start < 0 {
			start = i
		}
	}
	if start >= 0 do append(&out, s[start:])
	return out[:]
}

// ``' '.join(s.split())``.
py_normalize_space :: proc(s: string, allocator := context.temp_allocator) -> string {
	return strings.join(py_split(s, context.temp_allocator), " ", allocator)
}

@(private = "file")
line_break :: proc(r: rune) -> bool {
	switch r {
	case '\n', '\r', 0x0B, 0x0C, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029:
		return true
	}
	return false
}

// ``str.splitlines(keepends)``.
py_splitlines :: proc(
	s: string,
	keepends := false,
	allocator := context.temp_allocator,
) -> []string {
	out := make([dynamic]string, 0, 4, allocator)
	start, i := 0, 0
	for i < len(s) {
		r, w := utf8.decode_rune_in_string(s[i:])
		if !line_break(r) {
			i += w
			continue
		}
		end := i
		i += w
		if r == '\r' && i < len(s) && s[i] == '\n' do i += 1
		append(&out, s[start:i] if keepends else s[start:end])
		start = i
	}
	if start < len(s) do append(&out, s[start:])
	return out[:]
}

// Write ``repr(s)`` for a Python ``str``.
write_py_repr :: proc(b: ^strings.Builder, s: string) {
	quote: rune = '\''
	if strings.contains_rune(s, '\'') && !strings.contains_rune(s, '"') do quote = '"'
	strings.write_rune(b, quote)
	for r in s {
		switch {
		case r == quote || r == '\\':
			strings.write_byte(b, '\\')
			strings.write_rune(b, r)
		case r == '\t':
			strings.write_string(b, "\\t")
		case r == '\n':
			strings.write_string(b, "\\n")
		case r == '\r':
			strings.write_string(b, "\\r")
		case r < ' ' || r == 0x7F:
			write_hex_escape(b, 'x', r, 2)
		case r < 0x7F || py_isprintable(r):
			strings.write_rune(b, r)
		case r <= 0xFF:
			write_hex_escape(b, 'x', r, 2)
		case r <= 0xFFFF:
			write_hex_escape(b, 'u', r, 4)
		case:
			write_hex_escape(b, 'U', r, 8)
		}
	}
	strings.write_rune(b, quote)
}

@(private = "file")
write_hex_escape :: proc(b: ^strings.Builder, kind: u8, r: rune, digits: int) {
	HEX := "0123456789abcdef"
	strings.write_byte(b, '\\')
	strings.write_byte(b, kind)
	for i := digits - 1; i >= 0; i -= 1 {
		strings.write_byte(b, HEX[(u32(r) >> uint(4 * i)) & 0xF])
	}
}

write_int :: proc(b: ^strings.Builder, i: int) {
	buf: [32]u8
	strings.write_string(b, strconv.write_int(buf[:], i64(i), 10))
}

// Write ``str(value)`` (``'%s' % value``) of an attribute value.
write_py_str :: proc(b: ^strings.Builder, doc: ^Doc, value: Attr_Value) {
	switch v in value {
	case string:
		strings.write_string(b, v)
	case int:
		write_int(b, v)
	case bool:
		strings.write_string(b, "True" if v else "False")
	case List:
		strings.write_byte(b, '[')
		for s, i in doc.lists[v] {
			if i > 0 do strings.write_string(b, ", ")
			write_py_repr(b, str(doc, s))
		}
		strings.write_byte(b, ']')
	case Attr_None:
		strings.write_string(b, "None")
	case:
		strings.write_string(b, "None")
	}
}

// Write ``repr(value)`` of a ``pending`` detail value (not a node).
write_detail_repr :: proc(b: ^strings.Builder, value: Detail_Value) {
	#partial switch v in value {
	case string:
		write_py_repr(b, v)
	case int:
		write_int(b, v)
	case bool:
		strings.write_string(b, "True" if v else "False")
	case []string:
		strings.write_byte(b, '[')
		for s, i in v {
			if i > 0 do strings.write_string(b, ", ")
			write_py_repr(b, s)
		}
		strings.write_byte(b, ']')
	case []Node:
		strings.write_string(b, "[]")
	case:
		strings.write_string(b, "None")
	}
}
