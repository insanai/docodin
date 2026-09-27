package doctree

import "core:strings"

// Module-level helpers of ``docutils.nodes``: identifiers and names.

// ``_non_id_translate_digraphs``.
@(private = "file")
digraph :: proc(r: rune) -> string {
	switch r {
	case 0x00DF:
		return "sz" // ligature sz
	case 0x00E6:
		return "ae" // ae
	case 0x0153:
		return "oe" // ligature oe
	case 0x0238:
		return "db" // db digraph
	case 0x0239:
		return "qp" // qp digraph
	}
	return ""
}

// ``_non_id_translate``: letters with strokes, hooks, etc.
@(private = "file")
NON_ID_TRANSLATE := [?]struct {
	cp: rune,
	to: u8,
} {
	{0x00F8, 'o'}, {0x0111, 'd'}, {0x0127, 'h'}, {0x0131, 'i'}, {0x0142, 'l'}, {0x0167, 't'},
	{0x0180, 'b'}, {0x0183, 'b'}, {0x0188, 'c'}, {0x018C, 'd'}, {0x0192, 'f'}, {0x0199, 'k'},
	{0x019A, 'l'}, {0x019E, 'n'}, {0x01A5, 'p'}, {0x01AB, 't'}, {0x01AD, 't'}, {0x01B4, 'y'},
	{0x01B6, 'z'}, {0x01E5, 'g'}, {0x0225, 'z'}, {0x0234, 'l'}, {0x0235, 'n'}, {0x0236, 't'},
	{0x0237, 'j'}, {0x023C, 'c'}, {0x023F, 's'}, {0x0240, 'z'}, {0x0247, 'e'}, {0x0249, 'j'},
	{0x024B, 'q'}, {0x024D, 'r'}, {0x024F, 'y'},
}

@(private = "file")
non_id_translate :: proc(r: rune) -> (u8, bool) {
	if r < 0xF8 || r > 0x24F do return 0, false
	for t in NON_ID_TRANSLATE do if t.cp == r do return t.to, true
	return 0, false
}

// The ASCII characters of the NFKD decomposition of ``r``
// (``unicodedata.normalize('NFKD', r).encode('ascii', 'ignore')``).
nfkd_ascii :: proc(r: rune, buf: ^[4]u8) -> string {
	if r < 0x80 {
		buf[0] = u8(r)
		return string(buf[:1])
	}
	lo, hi := 0, len(NFKD_ASCII_RUNS)
	for lo < hi {
		mid := (lo + hi) / 2
		run := NFKD_ASCII_RUNS[mid]
		if r < run.lo {
			hi = mid
		} else if r > run.hi {
			lo = mid + 1
		} else {
			buf[0] = run.first + run.step * u8(r - run.lo)
			return string(buf[:1])
		}
	}
	lo, hi = 0, len(NFKD_ASCII_MULTI)
	for lo < hi {
		mid := (lo + hi) / 2
		m := NFKD_ASCII_MULTI[mid]
		if r < m.cp {
			hi = mid
		} else if r > m.cp {
			lo = mid + 1
		} else {
			return m.s
		}
	}
	return ""
}

// ``nodes.make_id(string)``: an identifier matching ``[a-z](-?[a-z0-9]+)*``.
make_id :: proc(s: string, allocator := context.temp_allocator) -> string {
	ascii := strings.builder_make(0, len(s), context.temp_allocator)
	buf: [4]u8
	for r in py_lower(s) {
		if d := digraph(r); d != "" {
			strings.write_string(&ascii, d)
		} else if t, ok := non_id_translate(r); ok {
			strings.write_byte(&ascii, t)
		} else {
			strings.write_string(&ascii, nfkd_ascii(r, &buf))
		}
	}
	return squash_non_id(strings.to_string(ascii), allocator)
}

// Replace runs of characters other than ``[a-z0-9]`` by one hyphen, then
// drop leading hyphens and digits and trailing hyphens (``_non_id_chars``,
// ``_non_id_at_ends``).  Whitespace needs no separate treatment: it is one
// of the replaced characters.
@(private = "file")
squash_non_id :: proc(id: string, allocator := context.temp_allocator) -> string {
	out := make([dynamic]u8, 0, len(id), allocator)
	in_run := false
	for i in 0 ..< len(id) {
		c := id[i]
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') {
			append(&out, c)
			in_run = false
		} else if !in_run {
			append(&out, '-')
			in_run = true
		}
	}
	start := 0
	for start < len(out) && (out[start] == '-' || (out[start] >= '0' && out[start] <= '9')) {
		start += 1
	}
	end := len(out)
	for end > start && out[end - 1] == '-' do end -= 1
	return string(out[start:end])
}

// ``nodes.fully_normalize_name``: case- and whitespace-normalized.
fully_normalize_name :: proc(name: string, allocator := context.temp_allocator) -> string {
	return py_normalize_space(py_lower(name), allocator)
}

// ``nodes.whitespace_normalize_name``.
whitespace_normalize_name :: proc(name: string, allocator := context.temp_allocator) -> string {
	return py_normalize_space(name, allocator)
}

// ``nodes.serial_escape``: escape list items for serialization.
serial_escape :: proc(value: string, allocator := context.temp_allocator) -> string {
	if strings.index_any(value, "\\ ") < 0 do return value
	b := strings.builder_make(0, len(value) + 4, allocator)
	for i in 0 ..< len(value) {
		c := value[i]
		if c == '\\' || c == ' ' do strings.write_byte(&b, '\\')
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

// ``nodes.pseudo_quoteattr``.
pseudo_quoteattr :: proc(value: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({"\"", value, "\""}, allocator)
}

// ``nodes.unescape(text, restore_backslashes)``: remove the null-escapes
// (``\x00``, and the escaped spaces and newlines), or turn them back into
// backslashes.
unescape :: proc(
	text: string,
	restore_backslashes := false,
	allocator := context.temp_allocator,
) -> string {
	if strings.index_byte(text, 0) < 0 do return text
	if restore_backslashes {
		s, _ := strings.replace_all(text, "\x00", "\\", allocator)
		return s
	}
	s := text
	for sep in ([]string{"\x00 ", "\x00\n", "\x00"}) {
		s, _ = strings.remove_all(s, sep, allocator)
	}
	return s
}

// ``nodes.split_name_list``: split at unescaped spaces, unescaping.
split_name_list :: proc(s: string, allocator := context.temp_allocator) -> []string {
	t, _ := strings.replace_all(s, "\\", "\x00", context.temp_allocator)
	t, _ = strings.replace_all(t, "\x00\x00", "\\", context.temp_allocator)
	t, _ = strings.replace_all(t, "\x00 ", "\x00\x00", context.temp_allocator)
	parts := strings.split(t, " ", allocator)
	for &p in parts {
		p, _ = strings.replace_all(p, "\x00\x00", " ", allocator)
		p, _ = strings.remove_all(p, "\x00", allocator)
	}
	return parts
}

// ``nodes.dupname(node, name)``: move ``name`` from ``names`` to
// ``dupnames`` and mark the node referenced.
dupname :: proc(doc: ^Doc, n: Node, name: Str) {
	list_append(doc, n, K_DUPNAMES, name)
	list_remove(doc, n, K_NAMES, name)
	doc.nodes[n].flags += {.Referenced}
}
