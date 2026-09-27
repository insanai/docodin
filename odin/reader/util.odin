package reader

import "core:strings"

import dt "../doctree"
import rst "../rst"

// Small helpers shared by the reader.

cp_slice :: rst.cp_slice
cp_len :: rst.cp_len
join_lines :: rst.join_lines
strip :: rst.strip
rstrip :: rst.rstrip
lstrip :: rst.lstrip
has_prefix :: strings.has_prefix
has_suffix :: strings.has_suffix

concat :: proc(parts: ..string, allocator := context.temp_allocator) -> string {
	return strings.concatenate(parts, allocator)
}

// Python ``str(n)``.
itoa :: proc(n: int, allocator := context.temp_allocator) -> string {
	return rst.int_str(n, allocator)
}

// ``normalize_name`` (``nodes.fully_normalize_name``).
normalize_name :: proc(name: string) -> string {
	return dt.fully_normalize_name(name)
}

// ``Element.extend``.
extend :: proc(c: ^Context, parent: dt.Node, nodes: []dt.Node) {
	for n in nodes do dt.append_child(c.doc, parent, n)
}

// A new element holding ``children`` (``cls(rawsource, *children)``).
element :: proc(c: ^Context, tag: dt.Tag, rawsource: string, children: []dt.Node) -> dt.Node {
	n := dt.new_element(c.doc, tag, rawsource)
	extend(c, n, children)
	return n
}

// Python truthiness of a string list attribute value etc.: a string is
// "blank" when ``not s.strip()``.
is_blank :: #force_inline proc "contextless" (s: string) -> bool {
	return len(rst.strip(s)) == 0
}

// Python ``str.split()`` with at most ``maxsplit`` splits (-1: no limit):
// the remainder keeps its trailing whitespace.
py_split_max :: proc(s: string, maxsplit: int, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, 4, allocator)
	i := 0
	for {
		// skip whitespace
		for i < len(s) {
			r, w := rst.rune_at(s, i)
			if !dt.py_isspace(r) do break
			i += w
		}
		if i >= len(s) do break
		if maxsplit >= 0 && len(out) == maxsplit {
			append(&out, s[i:])
			break
		}
		j := i
		for j < len(s) {
			r, w := rst.rune_at(s, j)
			if dt.py_isspace(r) do break
			j += w
		}
		append(&out, s[i:j])
		i = j
	}
	return out[:]
}

// ``repr()`` of a Python ``str``.
py_repr :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	dt.write_py_repr(&b, s)
	return strings.to_string(b)
}
