package rst

import "base:runtime"
import "core:strings"

// ``docutils.utils.escape2null``: backslash escapes become NUL + char.
// Zero-copy when ``text`` contains no backslash.
escape2null :: proc(text: string, allocator: runtime.Allocator) -> string {
	if strings.index_byte(text, '\\') < 0 do return text
	buf := make([]byte, len(text), allocator)
	i := 0
	for i < len(text) {
		b := text[i]
		if b == '\\' {
			buf[i] = 0
			i += 1
			if i < len(text) {
				// keep the escaped character verbatim (skip escape processing)
				_, w := rune_at(text, i)
				copy(buf[i:], text[i:i + w])
				i += w
			}
		} else {
			buf[i] = b
			i += 1
		}
	}
	return string(buf)
}

// ``docutils.nodes.unescape``: remove NUL escape markers (and escaped
// whitespace), or restore them to backslashes.
unescape :: proc(text: string, allocator: runtime.Allocator, restore_backslashes := false) -> string {
	if strings.index_byte(text, 0) < 0 do return text
	if restore_backslashes {
		buf := make([]byte, len(text), allocator)
		for i in 0 ..< len(text) do buf[i] = '\\' if text[i] == 0 else text[i]
		return string(buf)
	}
	// Three sequential global removals, exactly like docutils:
	// '\x00 ', then '\x00\n', then '\x00'.
	s := remove_all(text, "\x00 ", allocator)
	s = remove_all(s, "\x00\n", allocator)
	return remove_all(s, "\x00", allocator)
}

@(private = "file")
remove_all :: proc(s: string, sep: string, allocator: runtime.Allocator) -> string {
	if strings.index(s, sep) < 0 do return s
	b := strings.builder_make_len_cap(0, len(s), allocator)
	rest := s
	for {
		i := strings.index(rest, sep)
		if i < 0 {
			strings.write_string(&b, rest)
			break
		}
		strings.write_string(&b, rest[:i])
		rest = rest[i + len(sep):]
	}
	return strings.to_string(b)
}

// Python ``str.split()`` (runs of Unicode whitespace).
split_whitespace :: proc(s: string, allocator: runtime.Allocator) -> []string {
	parts := make([dynamic]string, 0, 4, allocator)
	i := 0
	for i < len(s) {
		for i < len(s) {
			r, w := rune_at(s, i)
			if !is_space(r) do break
			i += w
		}
		if i >= len(s) do break
		start := i
		for i < len(s) {
			r, w := rune_at(s, i)
			if is_space(r) do break
			i += w
		}
		append(&parts, s[start:i])
	}
	return parts[:]
}

// ``' '.join(s.split())`` — docutils ``whitespace_normalize_name``.
whitespace_normalize :: proc(s: string, allocator: runtime.Allocator) -> string {
	parts := split_whitespace(s, allocator)
	if len(parts) == 1 do return parts[0]
	return strings.join(parts, " ", allocator)
}

// ``docutils.utils.split_escaped_whitespace``: split at NUL+space / NUL+newline.
split_escaped_whitespace :: proc(text: string, allocator: runtime.Allocator) -> []string {
	parts := make([dynamic]string, 0, 2, allocator)
	start := 0
	i := 0
	for i + 1 < len(text) {
		if text[i] == 0 && (text[i + 1] == ' ' || text[i + 1] == '\n') {
			append(&parts, text[start:i])
			i += 2
			start = i
		} else {
			i += 1
		}
	}
	append(&parts, text[start:])
	return parts[:]
}

// Remove all whitespace: ``''.join(s.split())``.
remove_whitespace :: proc(s: string, allocator: runtime.Allocator) -> string {
	parts := split_whitespace(s, allocator)
	if len(parts) == 1 do return parts[0]
	return strings.concatenate(parts, allocator)
}

// ``refuri`` normalisation used by hyperlink targets and embedded URIs:
// ``' '.join(''.join(unescape(part).split()) for part in split_escaped_whitespace(text))``
normalize_uri :: proc(text: string, allocator: runtime.Allocator) -> string {
	parts := split_escaped_whitespace(text, allocator)
	cleaned := make([]string, len(parts), allocator)
	for part, i in parts do cleaned[i] = remove_whitespace(unescape(part, allocator), allocator)
	if len(cleaned) == 1 do return cleaned[0]
	return strings.join(cleaned, " ", allocator)
}
