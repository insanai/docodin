package texmath

// Python string semantics the converters depend on: the character classes of
// ``str.isalpha``, ``isdigit``, ``isspace`` and ``isprintable``, ``str.upper``,
// ``unicodedata.normalize("NFC", ...)``, ``repr(str)``, ``float(str)`` and
// ``repr(float)``.  The tables are generated from Python's ``unicodedata``
// (``scripts/gen_math_tables.py``), so the results are those of the Python
// that runs docutils.

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// A table entry keyed by a string (tables are sorted by key, in byte order).
Str_Entry :: struct {
	key, value: string,
}

// A table entry keyed by a character (tables are sorted by key).
Rune_Entry :: struct {
	key:   rune,
	value: string,
}

// A primary composite of NFC: ``first`` followed by ``second`` composes.
Composition :: struct {
	first, second, composite: rune,
}

// A range of characters with a nonzero canonical combining class.
Combining_Class :: struct {
	lo, hi: rune,
	class:  u8,
}

// Binary search of `key` in a table of `Str_Entry` sorted by key.
lookup :: proc "contextless" (table: []Str_Entry, key: string) -> (string, bool) {
	lo, hi := 0, len(table)
	for lo < hi {
		mid := (lo + hi) / 2
		if table[mid].key < key {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(table) && table[lo].key == key {
		return table[lo].value, true
	}
	return "", false
}

// Is `key` in the sorted table?
has_key :: proc "contextless" (table: []Str_Entry, key: string) -> bool {
	_, found := lookup(table, key)
	return found
}

// Is `name` in a sorted list of names?
has_name :: proc "contextless" (names: []string, name: string) -> bool {
	lo, hi := 0, len(names)
	for lo < hi {
		mid := (lo + hi) / 2
		if names[mid] < name {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo < len(names) && names[lo] == name
}

// Binary search of `key` in a table of `Rune_Entry` sorted by key.
lookup_rune :: proc "contextless" (table: []Rune_Entry, key: rune) -> (string, bool) {
	lo, hi := 0, len(table)
	for lo < hi {
		mid := (lo + hi) / 2
		if table[mid].key < key {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(table) && table[lo].key == key {
		return table[lo].value, true
	}
	return "", false
}

in_ranges :: proc "contextless" (r: rune, table: [][2]rune) -> bool {
	lo, hi := 0, len(table)
	for lo < hi {
		mid := (lo + hi) / 2
		if table[mid][1] < r {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo < len(table) && table[lo][0] <= r
}

is_alpha :: proc "contextless" (r: rune) -> bool {
	if r < 0x80 {
		return ('a' <= r && r <= 'z') || ('A' <= r && r <= 'Z')
	}
	return in_ranges(r, ALPHA_RANGES[:])
}

is_digit :: proc "contextless" (r: rune) -> bool {
	if r < 0x80 {
		return '0' <= r && r <= '9'
	}
	return in_ranges(r, DIGIT_RANGES[:])
}

is_space :: proc "contextless" (r: rune) -> bool {
	return in_ranges(r, SPACE_RANGES[:])
}

is_printable :: proc "contextless" (r: rune) -> bool {
	return !in_ranges(r, UNPRINTABLE_RANGES[:])
}

// The value of a Unicode decimal digit (``unicodedata.decimal``), or -1.
decimal_value :: proc "contextless" (r: rune) -> int {
	lo, hi := 0, len(DECIMAL_ZEROS)
	for lo < hi {
		mid := (lo + hi) / 2
		if DECIMAL_ZEROS[mid] + 9 < r {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(DECIMAL_ZEROS) && DECIMAL_ZEROS[lo] <= r {
		return int(r - DECIMAL_ZEROS[lo])
	}
	return -1
}

// ``s.isalpha()``: not empty, and letters only.
str_isalpha :: proc(s: string) -> bool {
	for r in s {
		if !is_alpha(r) {
			return false
		}
	}
	return len(s) > 0
}

// ``s.strip()`` of white space (``left``/``right`` select the ends).
py_strip :: proc(s: string, left := true, right := true) -> string {
	start, end := 0, len(s)
	for left && start < end {
		r, size := utf8.decode_rune_in_string(s[start:])
		if !is_space(r) {
			break
		}
		start += size
	}
	for right && end > start {
		r, size := utf8.decode_last_rune_in_string(s[start:end])
		if !is_space(r) {
			break
		}
		end -= size
	}
	return s[start:end]
}

// The number of code points (Python's ``len``).
cp_len :: proc(s: string) -> int {
	return utf8.rune_count_in_string(s)
}

// The byte offset of code point `n` of `s` (clamped to the length).
cp_offset :: proc(s: string, n: int) -> int {
	count := 0
	for _, offset in s {
		if count == n {
			return offset
		}
		count += 1
	}
	return len(s)
}

// ``char.upper()`` (which may be several characters).
upper :: proc(r: rune, b: ^strings.Builder) {
	if value, found := lookup_rune(UPPER_CASE[:], r); found {
		strings.write_string(b, value)
	} else {
		strings.write_rune(b, r)
	}
}

// ``repr(s)``: a Python string literal.
write_repr :: proc(b: ^strings.Builder, s: string) {
	quote: rune = '\''
	if strings.contains_rune(s, '\'') && !strings.contains_rune(s, '"') {
		quote = '"'
	}
	strings.write_rune(b, quote)
	for r in s {
		switch r {
		case quote, '\\':
			strings.write_byte(b, '\\')
			strings.write_rune(b, r)
		case '\t':
			strings.write_string(b, "\\t")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case:
			write_repr_char(b, r)
		}
	}
	strings.write_rune(b, quote)
}

@(private = "file")
write_repr_char :: proc(b: ^strings.Builder, r: rune) {
	if r < ' ' || r == 0x7f || (r >= 0x80 && !is_printable(r)) {
		write_hex_escape(b, r)
	} else {
		strings.write_rune(b, r)
	}
}

@(private = "file")
write_hex_escape :: proc(b: ^strings.Builder, r: rune) {
	hex := "0123456789abcdef"
	kind, digits := byte('x'), 2
	if r > 0xffff {
		kind, digits = 'U', 8
	} else if r > 0xff {
		kind, digits = 'u', 4
	}
	strings.write_byte(b, '\\')
	strings.write_byte(b, kind)
	for shift := 4 * (digits - 1); shift >= 0; shift -= 4 {
		strings.write_byte(b, hex[(int(r) >> uint(shift)) & 0xf])
	}
}

// Normalization form C
// --------------------

@(private = "file")
S_BASE :: 0xAC00
@(private = "file")
L_BASE :: 0x1100
@(private = "file")
V_BASE :: 0x1161
@(private = "file")
T_BASE :: 0x11A7
@(private = "file")
T_COUNT :: 28
@(private = "file")
N_COUNT :: 588 // V_COUNT * T_COUNT
@(private = "file")
S_COUNT :: 11172

combining_class :: proc "contextless" (r: rune) -> u8 {
	lo, hi := 0, len(COMBINING_CLASSES)
	for lo < hi {
		mid := (lo + hi) / 2
		if COMBINING_CLASSES[mid].hi < r {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(COMBINING_CLASSES) && COMBINING_CLASSES[lo].lo <= r {
		return COMBINING_CLASSES[lo].class
	}
	return 0
}

@(private = "file")
decompose :: proc(r: rune, out: ^[dynamic]rune) {
	if S_BASE <= r && r < S_BASE + S_COUNT {
		index := int(r - S_BASE)
		append(out, rune(L_BASE + index / N_COUNT))
		append(out, rune(V_BASE + index % N_COUNT / T_COUNT))
		if index % T_COUNT != 0 {
			append(out, rune(T_BASE + index % T_COUNT))
		}
		return
	}
	if parts, found := lookup_rune(DECOMPOSITIONS[:], r); found {
		for part in parts {
			decompose(part, out)
		}
		return
	}
	append(out, r)
}

// The Hangul syllable composed of `first` and `second` (LV or LVT).
@(private = "file")
compose_hangul :: proc "contextless" (first, second: rune) -> (rune, bool) {
	if L_BASE <= first && first < L_BASE + 19 && V_BASE <= second && second < V_BASE + 21 {
		return rune(S_BASE + (int(first - L_BASE) * 21 + int(second - V_BASE)) * T_COUNT), true
	}
	is_lv := S_BASE <= first && first < S_BASE + S_COUNT && (first - S_BASE) % T_COUNT == 0
	if is_lv && T_BASE < second && second < T_BASE + T_COUNT {
		return first + second - T_BASE, true
	}
	return 0, false
}

@(private = "file")
compose_pair :: proc "contextless" (first, second: rune) -> (rune, bool) {
	if composite, found := compose_hangul(first, second); found {
		return composite, true
	}
	lo, hi := 0, len(COMPOSITIONS)
	for lo < hi {
		mid := (lo + hi) / 2
		entry := COMPOSITIONS[mid]
		if entry.first < first || (entry.first == first && entry.second < second) {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(COMPOSITIONS) && COMPOSITIONS[lo].first == first {
		if COMPOSITIONS[lo].second == second {
			return COMPOSITIONS[lo].composite, true
		}
	}
	return 0, false
}

// Sort the runs of combining characters by their combining class (stable).
@(private = "file")
reorder :: proc(runes: []rune) {
	for i in 1 ..< len(runes) {
		class := combining_class(runes[i])
		if class == 0 {
			continue
		}
		for j := i; j > 0; j -= 1 {
			previous := combining_class(runes[j - 1])
			if previous == 0 || previous <= class {
				break
			}
			runes[j - 1], runes[j] = runes[j], runes[j - 1]
		}
	}
}

// ``unicodedata.normalize("NFC", s)``.
nfc :: proc(s: string) -> string {
	decomposed := make([dynamic]rune, 0, len(s))
	for r in s {
		decompose(r, &decomposed)
	}
	reorder(decomposed[:])
	out := make([dynamic]rune, 0, len(decomposed))
	starter := -1
	last_class := -1 // of the last character after the starter; -1: none
	for r in decomposed {
		class := int(combining_class(r))
		if starter >= 0 && (last_class == -1 || last_class < class) {
			if composite, found := compose_pair(out[starter], r); found {
				out[starter] = composite
				continue
			}
		}
		if class == 0 {
			starter, last_class = len(out), -1
		} else {
			last_class = class
		}
		append(&out, r)
	}
	return utf8.runes_to_string(out[:])
}

// float
// -----

// ``float(s)``; false where Python raises ValueError.
py_float :: proc(s: string) -> (value: f64, ok: bool) {
	ascii := make([dynamic]byte, 0, len(s))
	for r in s {
		switch {
		case is_space(r):
			append(&ascii, ' ')
		case decimal_value(r) >= 0:
			append(&ascii, byte('0' + decimal_value(r)))
		case r < 0x80 && r != 0:
			append(&ascii, byte(r))
		case:
			append(&ascii, '?')
		}
	}
	text := strip_underscores(string(ascii[:])) or_return
	text = strings.trim(text, " \t\n\v\f\r")
	if len(text) == 0 {
		return 0, false
	}
	return parse_number(text)
}

// Remove the underscores between digits; false for a misplaced one.
@(private = "file")
strip_underscores :: proc(s: string) -> (string, bool) {
	if !strings.contains_rune(s, '_') {
		return s, true
	}
	out := make([dynamic]byte, 0, len(s))
	prev: byte
	for c in transmute([]byte)s {
		if c == '_' {
			if !is_ascii_digit(prev) {
				return "", false
			}
		} else {
			append(&out, c)
			if prev == '_' && !is_ascii_digit(c) {
				return "", false
			}
		}
		prev = c
	}
	return string(out[:]), prev != '_'
}

@(private = "file")
is_ascii_digit :: #force_inline proc "contextless" (c: byte) -> bool {
	return '0' <= c && c <= '9'
}

// Parse ``[sign] (inf | infinity | nan | digits [. digits] [e [sign] digits])``.
@(private = "file")
parse_number :: proc(text: string) -> (f64, bool) {
	body := text
	negative := false
	if body[0] == '+' || body[0] == '-' {
		negative = body[0] == '-'
		body = body[1:]
	}
	lower := strings.to_lower(body)
	switch lower {
	case "inf", "infinity":
		return negative ? -INF : INF, true
	case "nan":
		return NAN, true
	}
	if !valid_decimal(body) {
		return 0, false
	}
	// the syntax is valid: out of range, `parse_f64` returns an infinity (and false)
	value, _ := strconv.parse_f64(body)
	return negative ? -value : value, true
}

@(private = "file")
INF :: f64(0h7ff0000000000000)
@(private = "file")
NAN :: f64(0h7ff8000000000000)

// ``digits [. digits] [e [sign] digits]`` (at least one digit before the exponent).
@(private = "file")
valid_decimal :: proc(s: string) -> bool {
	i, digits := skip_digits(s, 0)
	if i < len(s) && s[i] == '.' {
		fraction: int
		i, fraction = skip_digits(s, i + 1)
		digits += fraction
	}
	if digits == 0 {
		return false
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i += 1
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			i += 1
		}
		exponent: int
		i, exponent = skip_digits(s, i)
		if exponent == 0 {
			return false
		}
	}
	return i == len(s)
}

// The index after the ASCII digits from `start`, and their number.
@(private = "file")
skip_digits :: proc(s: string, start: int) -> (end: int, count: int) {
	end = start
	for end < len(s) && is_ascii_digit(s[end]) {
		end += 1
	}
	return end, end - start
}

// ``repr(value)`` of a float: the shortest digits that round trip.
write_float_repr :: proc(b: ^strings.Builder, value: f64) {
	bits := transmute(u64)value
	if bits & 0x7ff0000000000000 == 0x7ff0000000000000 {
		if bits & 0x000fffffffffffff != 0 {
			strings.write_string(b, "nan")
		} else {
			strings.write_string(b, value < 0 ? "-inf" : "inf")
		}
		return
	}
	buf: [64]byte
	formatted := string(strconv.generic_ftoa(buf[:], value, 'e', -1, 64))
	if formatted[0] == '-' {
		strings.write_byte(b, '-')
	}
	mark := strings.index_byte(formatted, 'e')
	digits := strings.concatenate({formatted[1:2], formatted[3:max(mark, 3)]})
	exponent, _ := strconv.parse_int(formatted[mark + 1:])
	write_digits(b, digits, exponent + 1)
}

// Python's short float format: `digits` with the decimal point at `point`.
@(private = "file")
write_digits :: proc(b: ^strings.Builder, digits: string, point: int) {
	if -4 < point && point <= 16 {
		if point <= 0 {
			strings.write_string(b, "0.")
			for _ in 0 ..< -point {
				strings.write_byte(b, '0')
			}
			strings.write_string(b, digits)
			return
		}
		if point >= len(digits) {
			strings.write_string(b, digits)
			for _ in 0 ..< point - len(digits) {
				strings.write_byte(b, '0')
			}
			strings.write_string(b, ".0")
			return
		}
		strings.write_string(b, digits[:point])
		strings.write_byte(b, '.')
		strings.write_string(b, digits[point:])
		return
	}
	strings.write_string(b, digits[:1])
	if len(digits) > 1 {
		strings.write_byte(b, '.')
		strings.write_string(b, digits[1:])
	}
	exponent := point - 1
	strings.write_string(b, exponent < 0 ? "e-" : "e+")
	if abs(exponent) < 10 {
		strings.write_byte(b, '0')
	}
	strings.write_int(b, abs(exponent))
}
