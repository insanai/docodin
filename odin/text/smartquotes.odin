package text

// SmartyPants: typographic quotes, dashes and ellipses.  A port of
// ``docutils.utils.smartquotes`` (docutils 0.22.4) that reproduces its output
// character for character, including the quirks of its regular expressions.
//
// Every rule of the original is a ``str.replace`` or a ``re.sub`` whose match
// contains an ASCII quote character.  The rules run as separate passes, each
// over the output of the previous one, exactly like the original: text that a
// rule inserts (for example the no-break space of French quotes) is seen by
// the following rules.  A regex rule is reproduced by a scanner that visits
// the quote characters and tests the context the pattern's groups and
// lookarounds would see.  A pass with nothing to do returns its input.
//
// Strings are UTF-8; results are allocated with ``context.allocator`` (the
// passes allocate freely: use an arena).

import "core:strings"
import "core:unicode/utf8"

import rst "../rst"

ENDASH :: "–"
EMDASH :: "—"
ELLIPSIS :: "…"
APOSTROPHE :: "’"

// Token types of ``educate_tokens``: "tag", "literal" and anything else.
Token_Kind :: enum u8 {
	Text,
	Literal,
	Tag,
}

Dashes :: enum u8 {
	None,
	Regular, // "---" en dash, "--" em dash (yes, backwards)
	Old_School, // "---" em dash, "--" en dash
	Old_School_Inverted, // as Regular
}

Backticks :: enum u8 {
	None,
	Double, // ``text''
	Double_And_Single, // and `text'
}

// The transformations selected by an ``attr`` string.
Actions :: struct {
	quotes:    bool,
	backticks: Backticks,
	dashes:    Dashes,
	ellipses:  bool,
	stupefy:   bool, // attr "-1": typographic characters back to ASCII
	quot:      bool, // "&quot;" to '"'
}

// Quotation marks of a language (``smartchars``).
Quotes :: struct {
	open_primary:    string,
	close_primary:   string,
	open_secondary:  string,
	close_secondary: string,
}

// ``smartchars`` of an unknown language: ASCII quotes.
ASCII_QUOTES :: Quotes{`"`, `"`, "'", "'"}

Language_Quotes :: struct {
	tag:    string,
	quotes: Quotes,
}

// State of ``educate_tokens`` across the tokens of one text block.
Educator :: struct {
	actions:  Actions,
	quotes:   Quotes,
	english:  bool, // ``language.startswith("en")``: the decade rule applies
	previous: string, // ``prev_token_last_char``
}

// ``attr`` of ``educate_tokens``: "1", "2", "3", "-1" or letter codes.
parse_attr :: proc(attr: string) -> (a: Actions) {
	switch attr {
	case "1", "2", "3":
		a = {quotes = true, backticks = .Double, ellipses = true}
		a.dashes = Dashes(attr[0] - '0')
		return
	case "-1":
		return {stupefy = true}
	}
	has :: proc(s: string, c: byte) -> bool {return strings.index_byte(s, c) >= 0}
	a.quotes = has(attr, 'q')
	a.ellipses = has(attr, 'e')
	a.quot = has(attr, 'w')
	switch {
	case has(attr, 'B'): a.backticks = .Double_And_Single
	case has(attr, 'b'): a.backticks = .Double
	}
	switch {
	case has(attr, 'i'): a.dashes = .Old_School_Inverted
	case has(attr, 'D'): a.dashes = .Old_School
	case has(attr, 'd'): a.dashes = .Regular
	}
	return
}

// ``smartchars(language)``: the quotes of ``language.lower()`` (ASCII case
// folding only) or ASCII quotes.
quotes_for :: proc(language: string) -> Quotes {
	buf: [32]u8
	if len(language) > len(buf) do return ASCII_QUOTES
	for i in 0 ..< len(language) {
		c := language[i]
		buf[i] = c + 32 if c >= 'A' && c <= 'Z' else c
	}
	key := string(buf[:len(language)])
	lo, hi := 0, len(LANGUAGE_QUOTES)
	for lo < hi {
		mid := (lo + hi) / 2
		switch tag := LANGUAGE_QUOTES[mid].tag; {
		case key < tag: hi = mid
		case key > tag: lo = mid + 1
		case:           return LANGUAGE_QUOTES[mid].quotes
		}
	}
	return ASCII_QUOTES
}

educator_make :: proc(attr, language: string, quotes: Quotes) -> Educator {
	return Educator {
		actions = parse_attr(attr),
		quotes = quotes,
		english = strings.has_prefix(language, "en"),
		previous = " ",
	}
}

// One step of ``educate_tokens``: the educated form of a token.
educate_token :: proc(e: ^Educator, kind: Token_Kind, text: string) -> string {
	if kind == .Tag || len(text) == 0 do return text
	_, width := utf8.decode_last_rune_in_string(text)
	educated := text if kind == .Literal else educate_text(e, text)
	e.previous = text[len(text) - width:]
	return educated
}

@(private = "file")
educate_text :: proc(e: ^Educator, text: string) -> string {
	a, q := e.actions, e.quotes
	s := escape(text)
	if a.quot do s = replace(s, "&quot;", `"`)
	switch a.dashes {
	case .None:
	case .Regular, .Old_School_Inverted:
		s = replace(s, "---", ENDASH)
		s = replace(s, "--", EMDASH)
	case .Old_School:
		s = replace(s, "---", EMDASH)
		s = replace(s, "--", ENDASH)
	}
	if a.ellipses {
		s = replace(s, "...", ELLIPSIS)
		s = replace(s, ". . .", ELLIPSIS)
	}
	if a.backticks != .None {
		s = replace(s, "``", q.open_primary)
		s = replace(s, "''", q.close_primary)
	}
	if a.backticks == .Double_And_Single {
		s = replace(s, "`", q.open_secondary)
		s = replace(s, "'", q.close_secondary)
	}
	if a.quotes do s = educate_quotes_after(s, e.previous, q, e.english)
	if a.stupefy do s = stupefy(s, q)
	return unescape(s)
}

// ``educateQuotes(context + text)[1:]``: the last character of the previous
// token (quotes turned into ";") is the context of the quote rules.
@(private = "file")
educate_quotes_after :: proc(s, previous: string, q: Quotes, english: bool) -> string {
	if !has_quote(s) do return s
	ctx := ";" if previous == `"` || previous == "'" else previous
	joined := strings.concatenate({ctx, s})
	return educate_quotes(joined, q, english)[len(ctx):]
}

@(private = "file")
has_quote :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		if s[i] == '"' || s[i] == '\'' do return true
	}
	return false
}

// ``str.replace`` (an empty `old` matches between all characters).
replace :: proc(s, old, new: string) -> string {
	out, _ := strings.replace_all(s, old, new)
	return out
}

// ``educateQuotes(text, language)``; `english`: the language starts with "en".
educate_quotes :: proc(text: string, q: Quotes, english: bool) -> string {
	if !has_quote(text) do return text
	s := sub(text, '\'', .Start, q.close_secondary)
	s = sub(s, '"', .Start, q.close_primary)
	s = sub(s, '"', .Adjacent, strings.concatenate({q.open_primary, q.open_secondary}))
	s = sub(s, '\'', .Adjacent, strings.concatenate({q.open_secondary, q.open_primary}))
	s = sub(s, '\'', .Open_Before_Space, q.close_secondary)
	s = sub(s, '"', .Open_Before_Space, q.close_primary)
	if english do s = sub(s, '\'', .Decade, APOSTROPHE)
	s = sub(s, '\'', .Opening, q.open_secondary)
	if q.close_secondary != APOSTROPHE do s = sub(s, '\'', .Apostrophe, APOSTROPHE)
	s = sub(s, '\'', .Closing_Secondary, q.close_secondary)
	s = sub(s, '\'', .Any, q.open_secondary)
	s = sub(s, '"', .Opening, q.open_primary)
	s = sub(s, '"', .Closing_Primary, q.close_primary)
	return sub(s, '"', .Any, q.open_primary)
}

// The regular expressions of ``RegularExpressions``, by the context they
// require around the quote character Q (the ``'`` or ``"`` of the rule):
//   P = [-!"  #\$\%'()*+,.\/:;<=>?\@\[\\\]\^_`{|}~]    (punct, ASCII)
//   B = [([{]|[-–—]   S = [\s\u200B\u200C]   \w = alnum or "_"
Rule :: enum u8 {
	// START_*: ``^Q(?=P\\B)``, a *literal* backslash and "B"
	Start,
	// ADJACENT_*: ``QR(?=\w)``, R is the other quote
	Adjacent,
	// OPEN_*: ``(B)Q(?=P? )``
	Open_Before_Space,
	// DECADE: ``Q(?=\d{2}s)``
	Decade,
	// OPENING_*: ``(S|B)Q(?=\w|P)``
	Opening,
	// APOSTROPHE: ``(?<=(\w|\d))Q(?=\w)``
	Apostrophe,
	// CLOSING_SECONDARY: ``(?<!\s)Q``
	Closing_Secondary,
	// CLOSING_PRIMARY: ``(?<!\s)Q|Q(?=\s)``
	Closing_Primary,
	// ``str.replace``
	Any,
}

// ``re.sub`` of `rule` for the quote character `quote` with the literal
// replacement `rep` (a group before the quote is kept).  A match consumes
// its quote (Adjacent: both quotes) after a group character that is never a
// quote, so no match can take a character another one needs: testing each
// quote in turn finds the matches of the left-to-right regex search.
@(private = "file")
sub :: proc(s: string, quote: u8, rule: Rule, rep: string) -> string {
	b: strings.Builder
	start := 0
	for i := 0; i < len(s); {
		j := strings.index_byte(s[i:], quote)
		if j < 0 do break
		i += j
		n := match_length(s, i, rule)
		if n == 0 {
			i += 1
			continue
		}
		if start == 0 do strings.builder_init(&b, 0, len(s) + len(rep) * 2)
		strings.write_string(&b, s[start:i])
		strings.write_string(&b, rep)
		i += n
		start = i
	}
	if start == 0 do return s
	strings.write_string(&b, s[start:])
	return strings.to_string(b)
}

// Length in bytes of the match of `rule` at the quote s[i] (0: no match).
@(private = "file")
match_length :: proc(s: string, i: int, rule: Rule) -> int {
	prev := rune_before(s, i)
	switch rule {
	case .Start:
		ok := i == 0 && i + 3 < len(s) && is_punct(rune(s[i + 1]))
		return 1 if ok && s[i + 2] == '\\' && s[i + 3] == 'B' else 0
	case .Adjacent:
		other: u8 = '\'' if s[i] == '"' else '"'
		ok := i + 1 < len(s) && s[i + 1] == other && is_word(rune_after(s, i + 2))
		return 2 if ok else 0
	case .Open_Before_Space:
		return 1 if is_bracket_or_dash(prev) && space_follows(s, i + 1) else 0
	case .Decade:
		return 1 if decade_follows(s, i + 1) else 0
	case .Opening:
		next := rune_after(s, i + 1)
		ok := is_bracket_or_dash(prev) || is_separator(prev)
		return 1 if ok && (is_word(next) || is_punct(next)) else 0
	case .Apostrophe:
		return 1 if is_word(prev) && is_word(rune_after(s, i + 1)) else 0
	case .Closing_Secondary:
		return 1 if !is_space(prev) else 0
	case .Closing_Primary:
		return 1 if !is_space(prev) || is_space(rune_after(s, i + 1)) else 0
	case .Any:
		return 1
	}
	return 0
}

// Lookahead ``(?=P? )`` at s[i].
@(private = "file")
space_follows :: proc(s: string, i: int) -> bool {
	if i >= len(s) do return false
	if s[i] == ' ' do return true
	return is_punct(rune(s[i])) && i + 1 < len(s) && s[i + 1] == ' '
}

// Lookahead ``(?=\d{2}s)`` at s[i].
@(private = "file")
decade_follows :: proc(s: string, i: int) -> bool {
	i := i
	for _ in 0 ..< 2 {
		r, width := utf8.decode_rune_in_string(s[i:])
		if width == 0 || !rst.is_decimal(r) do return false
		i += width
	}
	return i < len(s) && s[i] == 's'
}

// NO_CHAR: the position is at the start or the end of the string; it is in
// no character class.
@(private = "file")
NO_CHAR :: rune(-1)

@(private = "file")
rune_before :: #force_inline proc(s: string, i: int) -> rune {
	if i <= 0 do return NO_CHAR
	if s[i - 1] < 0x80 do return rune(s[i - 1])
	r, _ := utf8.decode_last_rune_in_string(s[:i])
	return r
}

@(private = "file")
rune_after :: #force_inline proc(s: string, i: int) -> rune {
	if i >= len(s) do return NO_CHAR
	if s[i] < 0x80 do return rune(s[i])
	r, _ := utf8.decode_rune_in_string(s[i:])
	return r
}

// Regex ``\w``.
@(private = "file")
is_word :: #force_inline proc(r: rune) -> bool {
	return r == '_' || (r >= 0 && rst.is_alnum(r))
}

// Regex ``\s``.
@(private = "file")
is_space :: #force_inline proc(r: rune) -> bool {
	return r >= 0 && rst.is_space(r)
}

// ``[-!"  #\$\%'()*+,.\/:;<=>?\@\[\\\]\^_`{|}~]``: ASCII punctuation
// (without "&") and the space.
@(private = "file")
is_punct :: #force_inline proc(r: rune) -> bool {
	switch r {
	case ' ', '!', '"', '#', '$', '%', '\'', '(', ')', '*', '+', ',', '-', '.', '/':
		return true
	case ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~':
		return true
	}
	return false
}

// ``[([{]|[-–—]``
@(private = "file")
is_bracket_or_dash :: #force_inline proc(r: rune) -> bool {
	switch r {
	case '(', '[', '{', '-', 0x2013, 0x2014:
		return true
	}
	return false
}

// ``[\s\u200B\u200C]``
@(private = "file")
is_separator :: #force_inline proc(r: rune) -> bool {
	return r == 0x200B || r == 0x200C || is_space(r)
}

// ``stupefyEntities``: typographic characters back to ASCII.
stupefy :: proc(text: string, q: Quotes) -> string {
	s := replace(text, ENDASH, "-")
	s = replace(s, EMDASH, "--")
	s = replace(s, q.open_secondary, "'")
	s = replace(s, q.close_secondary, "'")
	s = replace(s, q.open_primary, `"`)
	s = replace(s, q.close_primary, `"`)
	return replace(s, ELLIPSIS, "...")
}

// ``processEscapes(text)``: backslash escapes to character references.  The
// original replaces "\\" first and then "\"", "\'", "\.", "\-", "\`" (in
// any order: a backslash left after the first pass is not followed by
// another), which is one left-to-right scan.
escape :: proc(text: string) -> string {
	b: strings.Builder
	start := 0
	for i := 0; i + 1 < len(text); {
		j := strings.index_byte(text[i:], '\\')
		if j < 0 || i + j + 1 >= len(text) do break
		i += j
		ref := escape_reference(text[i + 1])
		if len(ref) == 0 {
			i += 1
			continue
		}
		if start == 0 do strings.builder_init(&b, 0, len(text) + 16)
		strings.write_string(&b, text[start:i])
		strings.write_string(&b, ref)
		i += 2
		start = i
	}
	if start == 0 do return text
	strings.write_string(&b, text[start:])
	return strings.to_string(b)
}

@(private = "file")
escape_reference :: proc(c: u8) -> string {
	switch c {
	case '\\': return "&#92;"
	case '"':  return "&#34;"
	case '\'': return "&#39;"
	case '.':  return "&#46;"
	case '-':  return "&#45;"
	case '`':  return "&#96;"
	}
	return ""
}

// ``processEscapes(text, restore=True)``: the six character references back
// to characters (wherever they come from).  A restored character never forms
// part of another reference, so one scan equals the original's six passes.
unescape :: proc(text: string) -> string {
	b: strings.Builder
	start := 0
	for i := 0; i + 5 <= len(text); {
		j := strings.index_byte(text[i:], '&')
		if j < 0 || i + j + 5 > len(text) do break
		i += j
		c := unescape_reference(text[i:i + 5])
		if c == 0 {
			i += 1
			continue
		}
		if start == 0 do strings.builder_init(&b, 0, len(text))
		strings.write_string(&b, text[start:i])
		strings.write_byte(&b, c)
		i += 5
		start = i
	}
	if start == 0 do return text
	strings.write_string(&b, text[start:])
	return strings.to_string(b)
}

@(private = "file")
unescape_reference :: proc(ref: string) -> u8 {
	switch ref {
	case "&#92;": return '\\'
	case "&#34;": return '"'
	case "&#39;": return '\''
	case "&#46;": return '.'
	case "&#45;": return '-'
	case "&#96;": return '`'
	}
	return 0
}
