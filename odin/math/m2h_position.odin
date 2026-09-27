package texmath

// The parse position of `math2html` (``TextPosition``): a cursor over the formula
// with a stack of endings.  Nested constructs push the text that ends them
// (``}``, ``]``, ``\end{name}``, and the optional row and cell separators); the
// position is `finished` at the end of the text or at an ending reachable from the
// top of the stack past optional endings.  At the end of the text, pending endings
// are reported each time, as in docutils.
//
// Offsets are in bytes: Python's code point offsets only differ in the messages,
// which count characters (`identifier`).

import "core:strings"
import "core:unicode/utf8"

Ending :: struct {
	text:     string,
	optional: bool,
}

is_out :: #force_inline proc(m: ^M2h) -> bool {
	return m.pos >= len(m.text)
}

// ``Position.current()``: the character at the position (the caller checks `is_out`).
current :: proc(m: ^M2h) -> rune {
	r, _ := utf8.decode_rune_in_string(m.text[m.pos:])
	return r
}

// ``Position.checkfor(string)``.
check_for :: proc(m: ^M2h, s: string) -> bool {
	return m.pos + len(s) <= len(m.text) && m.text[m.pos:m.pos + len(s)] == s
}

// ``Position.checkskip(string)``.
check_skip :: proc(m: ^M2h, s: string) -> bool {
	if !check_for(m, s) {
		return false
	}
	m.pos += len(s)
	return true
}

// ``Globable.skipcurrent()``: the current character, skipped.  Past the end of
// the text, Python's indexing raises.
skip_current :: proc(m: ^M2h) -> string {
	if is_out(m) {
		raise(m, {.Index_Error, "string index out of range"})
		return ""
	}
	_, size := utf8.decode_rune_in_string(m.text[m.pos:])
	start := m.pos
	m.pos += size
	return m.text[start:m.pos]
}

// ``TextPosition.identifier()``: the next 30 characters between stars.
identifier :: proc(m: ^M2h) -> string {
	rest := m.text[min(m.pos, len(m.text)):]
	return strings.concatenate({"*", rest[:cp_offset(rest, 30)], "*"})
}

// ``Globable.finished()``; also true once an exception is raised, which ends
// every parse loop.
finished :: proc(m: ^M2h) -> bool {
	if m.err != nil {
		return true
	}
	if is_out(m) {
		if len(m.endings) > 0 {
			trace_error(m, "Pending ", endings_string(m), " left open")
		}
		return true
	}
	return find_ending(m) >= 0
}

@(private = "file")
endings_string :: proc(m: ^M2h) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "endings [")
	for ending, index in m.endings {
		if index > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, "Ending ")
		strings.write_string(&b, ending.text)
		if ending.optional {
			strings.write_string(&b, " (optional)")
		}
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

// ``EndingList.findending``: the index of the innermost ending found before the
// first non-optional one that is not; -1 if none.
find_ending :: proc(m: ^M2h) -> int {
	#reverse for ending, index in m.endings {
		if check_for(m, ending.text) {
			return index
		}
		if !ending.optional {
			return -1
		}
	}
	return -1
}

push_ending :: proc(m: ^M2h, text: string, optional := false) {
	append(&m.endings, Ending{text, optional})
}

// ``Globable.popending``: pop and skip the ending at the position ("" if none).
pop_ending :: proc(m: ^M2h, expected := "") -> string {
	ending := ""
	if is_out(m) {
		trace_error(m, "No ending out of bounds")
	} else if index := find_ending(m); index < 0 {
		char, _ := utf8.decode_rune_in_string(m.text[m.pos:])
		trace_error(m, "No ending at ", utf8.runes_to_string({char}))
	} else {
		ending = m.endings[index].text
		resize(&m.endings, index)
	}
	if len(expected) > 0 && expected != ending {
		trace_error(m, "Expected ending ", expected, ", got ", ending)
	}
	m.pos += len(ending)
	return ending
}

// ``Globable.nextending``: the ending found at the position, if any.
next_ending :: proc(m: ^M2h) -> (string, bool) {
	index := find_ending(m)
	if index < 0 {
		return "", false
	}
	return m.endings[index].text, true
}

// ``Globable.glob``: consume characters while not finished and `accept` holds.
glob :: proc(m: ^M2h, accept: proc "contextless" (r: rune) -> bool) -> string {
	start := m.pos
	for !finished(m) && accept(current(m)) {
		_, size := utf8.decode_rune_in_string(m.text[m.pos:])
		m.pos += size
	}
	return m.text[start:m.pos]
}

// ``Globable.isvalue``: neither space nor bracket (raises past the end).
is_value :: proc(m: ^M2h) -> bool {
	if is_out(m) {
		raise(m, {.Index_Error, "string index out of range"})
		return false
	}
	return is_value_char(current(m))
}

@(private = "file")
is_value_char :: proc "contextless" (r: rune) -> bool {
	return !is_space(r) && r != '{' && r != '}' && r != '(' && r != ')'
}

// ``Globable.globvalue``.
glob_value :: proc(m: ^M2h) -> string {
	return glob(m, is_value_char)
}

// ``Globable.globincluding(magicchar)``: up to and including `magic` (assumed if
// missing, and skipped even past the end).
glob_including :: proc(m: ^M2h, magic: rune) -> string {
	start := m.pos
	for !finished(m) && current(m) != magic {
		_, size := utf8.decode_rune_in_string(m.text[m.pos:])
		m.pos += size
	}
	text := m.text[start:m.pos]
	m.pos += utf8.rune_size(magic)
	return strings.concatenate({text, utf8.runes_to_string({magic})})
}
