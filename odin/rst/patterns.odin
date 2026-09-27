package rst

// Hand-written equivalents of the regular expressions used by the docutils
// state machine (``Body.patterns``, ``Body.explicit``, ``Inliner.simplename``).
// Each matcher documents the regex it implements; where Python's backtracking
// order influences the result, candidates are tried in the same order.

// ---------------------------------------------------------------------------
// simplename: (?:(?!_)\w)+(?:[-._+:](?:(?!_)\w)+)*
// ---------------------------------------------------------------------------

MAX_NAME_ENDS :: 64

// Possible end offsets of a ``simplename`` starting at ``start``, longest first
// (the order in which a greedy regex backtracks).  ``count`` is 0 when no
// simplename starts at ``start``.  Filled in place by ``simplename_ends``
// (declare it ``= ---``: the array is large and only ``count`` entries are
// written).
Name_Ends :: struct {
	ends:  [MAX_NAME_ENDS]int,
	count: int,
}

simplename_ends :: proc "contextless" (s: string, start: int, out: ^Name_Ends) {
	n := 0
	i := start
	for {
		run_start := i
		i = word_run_end(s, i)
		if i == run_start do break
		if n < MAX_NAME_ENDS {
			out.ends[n] = i
			n += 1
		} else {
			out.ends[n - 1] = i // keep the longest; very long chains are pathological
		}
		if !chain_continues(s, i) do break
		i += 1
	}
	out.count = n
	for k in 0 ..< n / 2 do out.ends[k], out.ends[n - 1 - k] = out.ends[n - 1 - k], out.ends[k]
}

// Longest simplename at ``start`` (0 length if none).
simplename_end :: proc "contextless" (s: string, start: int) -> int {
	i := start
	for {
		run_start := i
		i = word_run_end(s, i)
		if i == run_start || !chain_continues(s, i) do break
		i += 1
	}
	return max(i, start)
}

// End of the run of word characters (``(?:(?!_)\w)*``) at ``i``.
@(private = "file")
word_run_end :: #force_inline proc "contextless" (s: string, i: int) -> int {
	j := i
	for j < len(s) {
		c := s[j]
		if c < 0x80 {
			if ASCII_FLAGS[c] & FLAG_ALNUM == 0 do break
			j += 1
			continue
		}
		r, w := rune_at(s, j)
		if !is_alnum(r) do break
		j += w
	}
	return j
}

// A separator ``[-._+:]`` followed by a word character at ``i``.
@(private = "file")
chain_continues :: #force_inline proc "contextless" (s: string, i: int) -> bool {
	if i >= len(s) do return false
	switch s[i] {
	case '-', '.', '_', '+', ':':
		r, _ := rune_at(s, i + 1)
		return is_alnum(r)
	}
	return false
}

is_simplename :: proc "contextless" (s: string) -> bool {
	return len(s) > 0 && simplename_end(s, 0) == len(s)
}

// ---------------------------------------------------------------------------
// Body.patterns
// ---------------------------------------------------------------------------

// Skip ``( +|$)`` at ``i``; returns the end offset or -1.
spaces_or_end :: #force_inline proc "contextless" (s: string, i: int) -> int {
	if i >= len(s) do return len(s)
	if s[i] != ' ' do return -1
	j := i
	for j < len(s) && s[j] == ' ' do j += 1
	return j
}

// 'bullet': [-+*•‣⁃]( +|$)
match_bullet :: proc "contextless" (line: string) -> (end: int, ok: bool) {
	r, w := rune_at(line, 0)
	switch r {
	case '-', '+', '*', 0x2022, 0x2023, 0x2043:
		end = spaces_or_end(line, w)
		return end, end >= 0
	}
	return 0, false
}

Enum_Format :: enum u8 {
	Parens, // (1)
	Rparen, // 1)
	Period, // 1.
}

@(rodata)
ENUM_PREFIX := [Enum_Format]string{.Parens = "(", .Rparen = "", .Period = ""}
@(rodata)
ENUM_SUFFIX := [Enum_Format]string{.Parens = ")", .Rparen = ")", .Period = "."}

Enum_Sequence :: enum u8 {
	None,
	Arabic,
	Loweralpha,
	Upperalpha,
	Lowerroman,
	Upperroman,
	Auto, // '#'
}

@(rodata)
ENUM_SEQUENCE_NAMES := [Enum_Sequence]string {
	.None       = "",
	.Arabic     = "arabic",
	.Loweralpha = "loweralpha",
	.Upperalpha = "upperalpha",
	.Lowerroman = "lowerroman",
	.Upperroman = "upperroman",
	.Auto       = "#",
}

Enum_Match :: struct {
	format: Enum_Format,
	text:   string, // enumerator text without prefix/suffix
	end:    int,    // match.end()
}

@(private = "file")
is_lower_roman :: #force_inline proc "contextless" (b: byte) -> bool {
	switch b {
	case 'i', 'v', 'x', 'l', 'c', 'd', 'm': return true
	}
	return false
}

@(private = "file")
is_upper_roman :: #force_inline proc "contextless" (b: byte) -> bool {
	switch b {
	case 'I', 'V', 'X', 'L', 'C', 'D', 'M': return true
	}
	return false
}

// 'enumerator': (\((enum)\)|(enum)\)|(enum)\.)( +|$) with
// enum = ([0-9]+|[a-z]|[A-Z]|[ivxlcdm]+|[IVXLCDM]+|#)
match_enumerator :: proc "contextless" (line: string) -> (m: Enum_Match, ok: bool) {
	for format in Enum_Format {
		start := 0
		if format == .Parens {
			if len(line) == 0 || line[0] != '(' do continue
			start = 1
		}
		suffix := ENUM_SUFFIX[format][0]
		// try the enum alternatives in regex order
		candidates, nc := enum_candidates(line, start)
		for k in 0 ..< nc {
			j := candidates[k]
			if j < len(line) && line[j] == suffix {
				end := spaces_or_end(line, j + 1)
				if end >= 0 {
					return Enum_Match{format = format, text = line[start:j], end = end}, true
				}
			}
		}
	}
	return {}, false
}

// Candidate ends of ``enum`` starting at ``start``, in regex alternative order.
@(private = "file")
enum_candidates :: proc "contextless" (line: string, start: int) -> (candidates: [6]int, nc: int) {
	{ // [0-9]+
		j := start
		for j < len(line) && line[j] >= '0' && line[j] <= '9' do j += 1
		if j > start do candidates[nc] = j; nc += int(j > start)
	}
	if start >= len(line) do return
	b := line[start]
	if b >= 'a' && b <= 'z' { candidates[nc] = start + 1; nc += 1 }
	if b >= 'A' && b <= 'Z' { candidates[nc] = start + 1; nc += 1 }
	{
		j := start
		for j < len(line) && is_lower_roman(line[j]) do j += 1
		if j > start { candidates[nc] = j; nc += 1 }
	}
	{
		j := start
		for j < len(line) && is_upper_roman(line[j]) do j += 1
		if j > start { candidates[nc] = j; nc += 1 }
	}
	if b == '#' { candidates[nc] = start + 1; nc += 1 }
	return
}

// ``RomanNumeral.from_string``: 0 for an invalid numeral.
roman_to_int :: proc "contextless" (s: string) -> int {
	buf: [64]byte
	chars, ok := roman_upper(s, buf[:])
	if !ok do return 0
	return roman_value(chars)
}

// Upper-case copy of ``s`` in ``buf``; fails unless ``s`` is entirely upper or
// lower case ASCII made of Roman numeral letters.
@(private = "file")
roman_upper :: proc "contextless" (s: string, buf: []byte) -> (chars: string, ok: bool) {
	if len(s) == 0 do return
	// str.isupper()/islower() need at least one cased character
	upper, lower, has_cased := true, true, false
	for i in 0 ..< len(s) {
		b := s[i]
		if b >= 0x80 do return
		is_lower, is_upper := b >= 'a' && b <= 'z', b >= 'A' && b <= 'Z'
		if is_lower do upper = false
		if is_upper do lower = false
		if is_lower || is_upper do has_cased = true
	}
	if !has_cased || (!upper && !lower) do return
	if len(s) > len(buf) do return
	for i in 0 ..< len(s) {
		b := s[i]
		if b >= 'a' && b <= 'z' do b -= 32
		switch b {
		case 'I', 'V', 'X', 'L', 'C', 'D', 'M':
		case: return
		}
		buf[i] = b
	}
	return string(buf[:len(s)]), true
}

// Value of an upper-case numeral made of valid letters; 0 when malformed.
@(private = "file")
roman_value :: proc "contextless" (chars: string) -> int {
	at :: #force_inline proc "contextless" (s: string, i: int, b: byte) -> bool {
		return i < len(s) && s[i] == b
	}
	at2 :: #force_inline proc "contextless" (s: string, i: int, a, b: byte) -> bool {
		return i + 1 < len(s) && s[i] == a && s[i + 1] == b
	}
	result, idx := 0, 0
	for _ in 0 ..< 4 {
		if !at(chars, idx, 'M') do break
		result += 1000
		idx += 1
	}
	if idx == len(chars) do return result
	// hundreds, tens, units share the same shape
	Digit :: struct {nine, four: [2]byte, five, one: byte, v9, v4, v5, v1: int}
	digits := [3]Digit {
		{{'C', 'M'}, {'C', 'D'}, 'D', 'C', 900, 400, 500, 100},
		{{'X', 'C'}, {'X', 'L'}, 'L', 'X', 90, 40, 50, 10},
		{{'I', 'X'}, {'I', 'V'}, 'V', 'I', 9, 4, 5, 1},
	}
	for d in digits {
		if at2(chars, idx, d.nine[0], d.nine[1]) {
			result += d.v9
			idx += 2
		} else if at2(chars, idx, d.four[0], d.four[1]) {
			result += d.v4
			idx += 2
		} else {
			if at(chars, idx, d.five) {
				result += d.v5
				idx += 1
			}
			for _ in 0 ..< 3 {
				if !at(chars, idx, d.one) do break
				result += d.v1
				idx += 1
			}
		}
		if idx == len(chars) do return result
	}
	return 0
}

// ``RomanNumeral(n).to_uppercase()``; empty when out of range (1..4999).
int_to_roman :: proc(n: int, buf: []byte) -> string {
	if n < 1 || n > 4999 do return ""
	@(static, rodata) values := [13]int{1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1}
	@(static, rodata) names := [13]string {
		"M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I",
	}
	v := n
	k := 0
	for value, i in values {
		for v >= value {
			v -= value
			for c in transmute([]byte)names[i] {
				if k < len(buf) {
					buf[k] = c
					k += 1
				}
			}
		}
	}
	return string(buf[:k])
}

// 'field_marker': :(?![: ])([^:\\]|\\.|:(?!([ `]|$)))*(?<! ):( +|$)
// Returns the field name (between the colons) and match.end().
match_field_marker :: proc "contextless" (line: string) -> (name: string, end: int, ok: bool) {
	if len(line) < 3 || line[0] != ':' || line[1] == ':' || line[1] == ' ' do return
	i := 1
	for i < len(line) {
		switch line[i] {
		case '\\':
			if i + 1 >= len(line) do return
			_, w := rune_at(line, i + 1)
			i += 1 + w
		case ':':
			if i + 1 >= len(line) || line[i + 1] == ' ' {
				if line[i - 1] == ' ' do return
				e := spaces_or_end(line, i + 1)
				return line[1:i], e, true
			}
			if line[i + 1] == '`' do return
			i += 1
		case:
			_, w := rune_at(line, i)
			i += w
		}
	}
	return
}

// ---------------------------------------------------------------------------
// 'option_marker': %(option)s(, %(option)s)*(  +| ?$)
//   option   = (shortopt|longopt)
//   shortopt = (-|\+)[a-zA-Z0-9]( ?optarg)?
//   longopt  = (--|/)[a-zA-Z0-9][a-zA-Z0-9_-]*([ =]optarg)?
//   optarg   = ([a-zA-Z][a-zA-Z0-9_-]*|<[^<>]+>)
// ---------------------------------------------------------------------------

@(private = "file")
is_ascii_alnum :: #force_inline proc "contextless" (b: byte) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')
}

@(private = "file")
is_ascii_alpha :: #force_inline proc "contextless" (b: byte) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

@(private = "file")
is_optname_char :: #force_inline proc "contextless" (b: byte) -> bool {
	return is_ascii_alnum(b) || b == '_' || b == '-'
}

// End of an ``optarg`` at ``i`` (only the maximal match can lead to a
// successful overall match), or -1.
@(private = "file")
optarg_end :: proc "contextless" (s: string, i: int) -> int {
	if i >= len(s) do return -1
	if is_ascii_alpha(s[i]) {
		j := i + 1
		for j < len(s) && is_optname_char(s[j]) do j += 1
		return j
	}
	if s[i] == '<' {
		j := i + 1
		for j < len(s) && s[j] != '<' && s[j] != '>' do j += 1
		if j > i + 1 && j < len(s) && s[j] == '>' do return j + 1
	}
	return -1
}

// Candidate end offsets of one ``option`` at ``i`` in backtracking order.
@(private = "file")
option_ends :: proc "contextless" (s: string, i: int) -> (ends: [4]int, n: int) {
	if i >= len(s) do return
	// shortopt
	if (s[i] == '-' || s[i] == '+') && i + 1 < len(s) && is_ascii_alnum(s[i + 1]) {
		base := i + 2
		if base < len(s) && s[base] == ' ' do add_option_end(&ends, &n, optarg_end(s, base + 1))
		add_option_end(&ends, &n, optarg_end(s, base))
		add_option_end(&ends, &n, base)
		return
	}
	// longopt
	return longopt_ends(s, i)
}

@(private = "file")
add_option_end :: #force_inline proc "contextless" (ends: ^[4]int, n: ^int, e: int) {
	if e >= 0 && n^ < 4 {
		ends[n^] = e
		n^ += 1
	}
}

// Ends of a ``--long`` or ``/dos`` option (with and without its argument).
@(private = "file")
longopt_ends :: proc "contextless" (s: string, i: int) -> (ends: [4]int, n: int) {
	prefix := 0
	if i + 1 < len(s) && s[i] == '-' && s[i + 1] == '-' {
		prefix = 2
	} else if s[i] == '/' {
		prefix = 1
	}
	if prefix == 0 do return
	j := i + prefix
	if j >= len(s) || !is_ascii_alnum(s[j]) do return
	j += 1
	for j < len(s) && is_optname_char(s[j]) do j += 1
	if j < len(s) && (s[j] == ' ' || s[j] == '=') {
		add_option_end(&ends, &n, optarg_end(s, j + 1))
	}
	add_option_end(&ends, &n, j)
	return
}

@(private = "file")
option_rest :: proc "contextless" (s: string, i: int, depth: int) -> int {
	if depth < 32 && i + 1 < len(s) && s[i] == ',' && s[i + 1] == ' ' {
		ends, n := option_ends(s, i + 2)
		for k in 0 ..< n {
			if e := option_rest(s, ends[k], depth + 1); e >= 0 do return e
		}
	}
	// terminator (  +| ?$)
	if i + 1 < len(s) && s[i] == ' ' && s[i + 1] == ' ' {
		j := i + 2
		for j < len(s) && s[j] == ' ' do j += 1
		return j
	}
	if i == len(s) do return i
	if s[i] == ' ' && i + 1 == len(s) do return i + 1
	return -1
}

match_option_marker :: proc "contextless" (line: string) -> (end: int, ok: bool) {
	ends, n := option_ends(line, 0)
	for k in 0 ..< n {
		if e := option_rest(line, ends[k], 0); e >= 0 do return e, true
	}
	return 0, false
}

// 'doctest': >>>( +|$)
match_doctest :: #force_inline proc "contextless" (line: string) -> bool {
	return len(line) >= 3 && line[:3] == ">>>" && spaces_or_end(line, 3) >= 0
}

// 'line_block': \|( +|$) -> end offset
match_line_block :: #force_inline proc "contextless" (line: string) -> (end: int, ok: bool) {
	if len(line) == 0 || line[0] != '|' do return 0, false
	end = spaces_or_end(line, 1)
	return end, end >= 0
}

// 'grid_table_top': \+-[-+]+-\+ *$
match_grid_table_top :: proc "contextless" (line: string) -> bool {
	s := rstrip_spaces(line)
	n := len(s)
	if n < 5 || s[0] != '+' || s[1] != '-' || s[n - 2] != '-' || s[n - 1] != '+' do return false
	for i in 2 ..< n - 2 {
		if s[i] != '-' && s[i] != '+' do return false
	}
	return true
}

// Grid table head/body separator: \+=[=+]+=\+ *$
match_grid_head_sep :: proc "contextless" (line: string) -> bool {
	s := rstrip_spaces(line)
	n := len(s)
	if n < 5 || s[0] != '+' || s[1] != '=' || s[n - 2] != '=' || s[n - 1] != '+' do return false
	for i in 2 ..< n - 2 {
		if s[i] != '=' && s[i] != '+' do return false
	}
	return true
}

// 'simple_table_top': =+( +=+)+ *$
match_simple_table_top :: proc "contextless" (line: string) -> bool {
	s := rstrip_spaces(line)
	if len(s) == 0 || s[0] != '=' || s[len(s) - 1] != '=' do return false
	has_gap := false
	for i in 0 ..< len(s) {
		switch s[i] {
		case '=':
		case ' ': has_gap = true
		case: return false
		}
	}
	return has_gap
}

// simple_table_border_pat / head_body_separator_pat: =+[ =]*$ (on rstripped text)
match_simple_border :: proc "contextless" (line: string) -> bool {
	s := rstrip_spaces(line)
	if len(s) == 0 || s[0] != '=' do return false
	for i in 0 ..< len(s) {
		if s[i] != '=' && s[i] != ' ' do return false
	}
	return true
}

// SimpleTableParser.span_pat: -[ -]*$
match_simple_span :: proc "contextless" (line: string) -> bool {
	s := rstrip_spaces(line)
	if len(s) == 0 || s[0] != '-' do return false
	for i in 0 ..< len(s) {
		if s[i] != '-' && s[i] != ' ' do return false
	}
	return true
}

rstrip_spaces :: #force_inline proc "contextless" (s: string) -> string {
	n := len(s)
	for n > 0 && s[n - 1] == ' ' do n -= 1
	return s[:n]
}

// 'explicit_markup': \.\.( +|$)
match_explicit_markup :: #force_inline proc "contextless" (line: string) -> (end: int, ok: bool) {
	if len(line) < 2 || line[0] != '.' || line[1] != '.' do return 0, false
	end = spaces_or_end(line, 2)
	return end, end >= 0
}

// 'anonymous': __( +|$)
match_anonymous :: #force_inline proc "contextless" (line: string) -> (end: int, ok: bool) {
	if len(line) < 2 || line[0] != '_' || line[1] != '_' do return 0, false
	end = spaces_or_end(line, 2)
	return end, end >= 0
}

// 'line': ([!-/:-@[-`{-~])\1* *$ — a line of one repeated punctuation char.
match_line :: proc "contextless" (line: string) -> bool {
	s := rstrip_spaces(line)
	if len(s) == 0 || !is_punct7(s[0]) do return false
	c := s[0]
	for i in 1 ..< len(s) {
		if s[i] != c do return false
	}
	return true
}

// RFC2822Body 'rfc2822': [!-9;-~]+:( +|$) -> match.end()
match_rfc2822 :: proc "contextless" (line: string) -> (end: int, ok: bool) {
	i := 0
	for i < len(line) {
		b := line[i]
		if (b >= '!' && b <= '9') || (b >= ';' && b <= '~') {
			i += 1
		} else {
			break
		}
	}
	if i == 0 || i >= len(line) || line[i] != ':' do return 0, false
	end = spaces_or_end(line, i + 1)
	return end, end >= 0
}

// Match every Body transition pattern that precedes 'text' (used by the
// specialized list states, where any of them ends the list).
matches_body_construct :: proc "contextless" (line: string) -> bool {
	if _, ok := match_bullet(line); ok do return true
	if _, ok := match_enumerator(line); ok do return true
	if _, _, ok := match_field_marker(line); ok do return true
	if _, ok := match_option_marker(line); ok do return true
	if match_doctest(line) do return true
	if _, ok := match_line_block(line); ok do return true
	if match_grid_table_top(line) do return true
	if match_simple_table_top(line) do return true
	if _, ok := match_explicit_markup(line); ok do return true
	if _, ok := match_anonymous(line); ok do return true
	return match_line(line)
}
