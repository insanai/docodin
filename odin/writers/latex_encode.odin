package writers

import "core:strings"
import "core:unicode/utf8"

// LaTeX encoding of text (``LaTeXTranslator.encode`` and ``CharMaps``).

Char_Map :: struct {
	code: rune,
	tex:  string,
}

// Unicode chars that are not recognized by LaTeX's utf8 encoding.
@(rodata)
UNSUPPORTED_UNICODE := [?]Char_Map {
	{0x2000, "\\enskip"},
	{0x2001, "\\quad"},
	{0x2002, "\\enskip"},
	{0x2003, "\\quad"},
	{0x2008, "\\,"},
	{0x200b, "\\hspace{0pt}"},
	{0x202F, "\\,"},
	{0x2011, "\\hbox{-}"},
	{0x212b, "\\AA"},
	{0x21d4, "\\ensuremath{\\Leftrightarrow}"},
	{0x2260, "\\ensuremath{\\neq}"},
	{0x2261, "\\ensuremath{\\equiv}"},
	{0x2264, "\\ensuremath{\\le}"},
	{0x2265, "\\ensuremath{\\ge}"},
	{0x2660, "\\ensuremath{\\spadesuit}"},
	{0x2663, "\\ensuremath{\\clubsuit}"},
	{0xfb00, "ff"},
	{0xfb01, "fi"},
	{0xfb02, "fl"},
	{0xfb03, "ffi"},
	{0xfb04, "ffl"},
}

// Unicode chars that are recognized by LaTeX's utf8 encoding.
@(rodata)
UTF8_SUPPORTED_UNICODE := [?]Char_Map {
	{0x00A0, "~"},
	{0x00AB, "\\guillemotleft{}"},
	{0x00bb, "\\guillemotright{}"},
	{0x200C, "\\textcompwordmark{}"},
	{0x2013, "\\textendash{}"},
	{0x2014, "\\textemdash{}"},
	{0x2018, "\\textquoteleft{}"},
	{0x2019, "\\textquoteright{}"},
	{0x201A, "\\quotesinglbase{}"},
	{0x201C, "\\textquotedblleft{}"},
	{0x201D, "\\textquotedblright{}"},
	{0x201E, "\\quotedblbase{}"},
	{0x2030, "\\textperthousand{}"},
	{0x2031, "\\textpertenthousand{}"},
	{0x2039, "\\guilsinglleft{}"},
	{0x203A, "\\guilsinglright{}"},
	{0x2423, "\\textvisiblespace{}"},
	{0x2020, "\\dag{}"},
	{0x2021, "\\ddag{}"},
	{0x2026, "\\dots{}"},
	{0x2122, "\\texttrademark{}"},
}

// Recognized with "utf8", if textcomp is loaded.
@(rodata)
TEXTCOMP := [?]Char_Map {
	{0x00a2, "\\textcent{}"},
	{0x00a4, "\\textcurrency{}"},
	{0x00a5, "\\textyen{}"},
	{0x00a6, "\\textbrokenbar{}"},
	{0x00a7, "\\textsection{}"},
	{0x00a8, "\\textasciidieresis{}"},
	{0x00a9, "\\textcopyright{}"},
	{0x00aa, "\\textordfeminine{}"},
	{0x00ac, "\\textlnot{}"},
	{0x00ae, "\\textregistered{}"},
	{0x00af, "\\textasciimacron{}"},
	{0x00b0, "\\textdegree{}"},
	{0x00b1, "\\textpm{}"},
	{0x00b2, "\\texttwosuperior{}"},
	{0x00b3, "\\textthreesuperior{}"},
	{0x00b4, "\\textasciiacute{}"},
	{0x00b5, "\\textmu{}"},
	{0x00b6, "\\textparagraph{}"},
	{0x00b9, "\\textonesuperior{}"},
	{0x00ba, "\\textordmasculine{}"},
	{0x00bc, "\\textonequarter{}"},
	{0x00bd, "\\textonehalf{}"},
	{0x00be, "\\textthreequarters{}"},
	{0x00d7, "\\texttimes{}"},
	{0x00f7, "\\textdiv{}"},
	{0x0192, "\\textflorin{}"},
	{0x02b9, "\\textasciiacute{}"},
	{0x02ba, "\\textacutedbl{}"},
	{0x2016, "\\textbardbl{}"},
	{0x2022, "\\textbullet{}"},
	{0x2032, "\\textasciiacute{}"},
	{0x2033, "\\textacutedbl{}"},
	{0x2035, "\\textasciigrave{}"},
	{0x2036, "\\textgravedbl{}"},
	{0x203b, "\\textreferencemark{}"},
	{0x203d, "\\textinterrobang{}"},
	{0x2044, "\\textfractionsolidus{}"},
	{0x2045, "\\textlquill{}"},
	{0x2046, "\\textrquill{}"},
	{0x2052, "\\textdiscount{}"},
	{0x20a1, "\\textcolonmonetary{}"},
	{0x20a3, "\\textfrenchfranc{}"},
	{0x20a4, "\\textlira{}"},
	{0x20a6, "\\textnaira{}"},
	{0x20a9, "\\textwon{}"},
	{0x20ab, "\\textdong{}"},
	{0x20ac, "\\texteuro{}"},
	{0x20b1, "\\textpeso{}"},
	{0x20b2, "\\textguarani{}"},
	{0x2103, "\\textcelsius{}"},
	{0x2116, "\\textnumero{}"},
	{0x2117, "\\textcircledP{}"},
	{0x211e, "\\textrecipe{}"},
	{0x2120, "\\textservicemark{}"},
	{0x2122, "\\texttrademark{}"},
	{0x2126, "\\textohm{}"},
	{0x2127, "\\textmho{}"},
	{0x212e, "\\textestimated{}"},
	{0x2190, "\\textleftarrow{}"},
	{0x2191, "\\textuparrow{}"},
	{0x2192, "\\textrightarrow{}"},
	{0x2193, "\\textdownarrow{}"},
	{0x2212, "\\textminus{}"},
	{0x2217, "\\textasteriskcentered{}"},
	{0x221a, "\\textsurd{}"},
	{0x2422, "\\textblank{}"},
	{0x25e6, "\\textopenbullet{}"},
	{0x25ef, "\\textbigcircle{}"},
	{0x266a, "\\textmusicalnote{}"},
	{0x26ad, "\\textmarried{}"},
	{0x26ae, "\\textdivorced{}"},
	{0x27e8, "\\textlangle{}"},
	{0x27e9, "\\textrangle{}"},
}

// Unicode chars that require a feature/package to render.
@(rodata)
PIFONT := [?]Char_Map {
	{0x2665, "\\ding{170}"},
	{0x2666, "\\ding{169}"},
	{0x2713, "\\ding{51}"},
	{0x2717, "\\ding{55}"},
}

char_map :: proc(table: []Char_Map, r: rune) -> (string, bool) {
	for m in table {
		if m.code == r do return m.tex, true
	}
	return "", false
}

// ``CharMaps.special``: characters that normally need escaping.
@(private = "file")
special_char :: proc(r: rune) -> (string, bool) {
	switch r {
	case '#':
		return "\\#", true
	case '$':
		return "\\$", true
	case '%':
		return "\\%", true
	case '&':
		return "\\&", true
	case '~':
		return "\\textasciitilde{}", true
	case '_':
		return "\\_", true
	case '^':
		return "\\textasciicircum{}", true
	case '"':
		return "\\textquotedbl{}", true
	case '[':
		return "{[}", true
	case ']':
		return "{]}", true
	case 0x00AD:
		return "\\-", true
	}
	return "", false
}

// ``CharMaps.alltt``: characters that need escaping even in `alltt`.
@(private = "file")
alltt_char :: proc(r: rune) -> (string, bool) {
	switch r {
	case '\\':
		return "\\textbackslash{}", true
	case '{':
		return "\\{", true
	case '}':
		return "\\}", true
	}
	return "", false
}

@(private = "file")
is_ot1 :: proc(t: ^Latex) -> bool {
	return (t.s.font_encoding == "OT1" || t.s.font_encoding == "") && !t.is_xetex
}

// The replacement of ``r`` in the translation table of ``_encoding_table``
// (the later updates of the table take precedence).
@(private = "file")
encode_char :: proc(t: ^Latex, r: rune) -> (string, bool) {
	if !t.is_xetex {
		if s, ok := char_map(PIFONT[:], r); ok do return s, true
		if r >= 0x80 && !strings.has_prefix(t.latex_encoding, "utf8") {
			if s, ok := char_map(TEXTCOMP[:], r); ok do return s, true
			if s, ok := char_map(UTF8_SUPPORTED_UNICODE[:], r); ok do return s, true
			if s, ok := char_map(UNSUPPORTED_UNICODE[:], r); ok do return s, true
		}
	}
	if t.insert_non_breaking_blanks {
		if r == ' ' do return "~", true
		if r == '\t' do return strings.repeat("~", t.s.tab_width, context.temp_allocator), true
	}
	if is_ot1(t) {
		if t.literal {
			if r == '_' do return "\\underline{~}", true
			if r == '\\' do return "\\reflectbox{/}", true
		} else {
			switch r {
			case '|':
				return "\\textbar{}", true
			case '<':
				return "\\textless{}", true
			case '>':
				return "\\textgreater{}", true
			}
		}
	}
	if !t.alltt {
		if r == '_' && t.inside_citation_reference_label do return "", false
		if s, ok := special_char(r); ok do return s, true
	}
	return alltt_char(r)
}

// ``_require_character_support``: preamble requirements of characters.
@(private = "file")
require_character_support :: proc(t: ^Latex, text: string) {
	for r in text {
		if r < 0x80 do continue
		if _, ok := char_map(TEXTCOMP[:], r); ok && !t.fallback_stylesheet {
			t.requirements["textcomp"] = preamble_cmd("textcomp")
		} else if _, is_pi := char_map(PIFONT[:], r); is_pi {
			t.requirements["pifont"] = "\\usepackage{pifont}"
		} else if tex, un := char_map(UNSUPPORTED_UNICODE[:], r);
		   un && t.latex_encoding == "utf8" {
			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, "\\DeclareUnicodeCharacter{")
			write_hex4(&b, r)
			strings.write_string(&b, "}{")
			strings.write_string(&b, tex)
			strings.write_string(&b, "}")
			t.requirements[cat("_inputenc", int_str(int(r)))] = strings.to_string(b)
		}
	}
}

@(private = "file")
write_hex4 :: proc(b: ^strings.Builder, r: rune) {
	digits := "0123456789ABCDEF"
	buf: [8]u8
	n := 0
	for v := u32(r); v > 0 || n < 4; v >>= 4 {
		buf[n] = digits[v & 0xF]
		n += 1
	}
	for i := n - 1; i >= 0; i -= 1 do strings.write_byte(b, buf[i])
}

// ``LaTeXTranslator.encode(text)``.
latex_encode :: proc(t: ^Latex, text: string) -> string {
	if t.verbatim do return text
	if is_ot1(t) && t.literal do t.requirements["graphicx"] = t.graphicx_package
	if !t.is_xetex do require_character_support(t, text)
	b := strings.builder_make(context.temp_allocator)
	for r in text {
		if s, ok := encode_char(t, r); ok {
			strings.write_string(&b, s)
		} else {
			strings.write_rune(&b, r)
		}
	}
	res := strings.to_string(b)
	if !t.is_xetex do res = separate_ligatures(res, t.literal)
	if t.insert_newline do res = insert_newlines(res)
	if t.literal && !t.insert_non_breaking_blanks {
		res, _ = strings.replace_all(res, "  ", " ~", context.temp_allocator)
	}
	return res
}

// Break up input ligatures, e.g. "--" to "-{}-" (twice, so that "---"
// becomes "-{}-{}-").
@(private = "file")
separate_ligatures :: proc(text: string, literal: bool) -> string {
	chars := "-,`'\"<>" if literal else "-"
	res := text
	for _ in 0 ..< 2 {
		for i in 0 ..< len(chars) {
			c := chars[i:i + 1]
			pair := cat(c, c)
			if strings.contains(res, pair) {
				res, _ = strings.replace_all(res, pair, cat(c, "{}", c), context.temp_allocator)
			}
		}
	}
	return res
}

// Literal line breaks: blank lines (except the last) get a "~".
@(private = "file")
insert_newlines :: proc(text: string) -> string {
	lines := strings.split(text, "\n", context.temp_allocator)
	for &l, i in lines {
		if i < len(lines) - 1 && is_blank(l) do l = cat(l, "~")
	}
	return strings.join(lines, "\\\\\n", context.temp_allocator)
}

// ``not s.lstrip()``: empty or whitespace only.
is_blank :: proc(s: string) -> bool {
	for r in s {
		if !is_py_space(r) do return false
	}
	return true
}

is_py_space :: proc(r: rune) -> bool {
	switch r {
	case ' ', '\t', '\n', '\r', '\v', '\f', 0x1c ..= 0x1f, 0x85, 0xa0, 0x1680, 0x2000 ..= 0x200a,
	     0x2028, 0x2029, 0x202f, 0x205f, 0x3000:
		return true
	}
	return false
}

// ``attval``: whitespace characters replaced by spaces, then encoded.
latex_attval :: proc(t: ^Latex, text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(text) {
		c := text[i]
		switch c {
		case '\n', '\r', '\t', '\v', '\f':
			strings.write_byte(&b, ' ')
		case:
			strings.write_byte(&b, c)
		}
	}
	return latex_encode(t, strings.to_string(b))
}

// Code points of a string (Python ``len``).
rune_len :: proc(s: string) -> int {
	return utf8.rune_count_in_string(s)
}
