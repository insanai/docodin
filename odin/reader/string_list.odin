package reader

import "base:runtime"

// A port of ``docutils.statemachine.StringList`` (``ViewList``): lines of
// text with the source and offset of each line.  A slice is a child list (a
// "view") linked to its parent: inserting into or deleting from a child also
// changes the parent (and its parents), while changes to the parent do not
// reach existing children.  The builder relies on these exact semantics for
// ``include`` insertions, like docutils.
//
// Lists live in the reader's arena and are never freed individually; a
// child refers to its parent by pointer (each list is its own allocation).

// ``(source, offset)`` of a line.
Line_Info :: struct {
	source: string,
	offset: int,
}

String_List :: struct {
	data:          [dynamic]string,
	items:         [dynamic]Line_Info,
	parent:        ^String_List,
	parent_offset: int,
}

// ``StringList(lines, source)``: offsets 0, 1, 2, ... in ``source``.
sl_make :: proc(lines: []string, source: string, allocator: runtime.Allocator) -> ^String_List {
	l := new(String_List, allocator)
	l.data = make([dynamic]string, len(lines), max(len(lines), 4), allocator)
	l.items = make([dynamic]Line_Info, len(lines), max(len(lines), 4), allocator)
	for s, i in lines {
		l.data[i] = s
		l.items[i] = {source, i}
	}
	return l
}

// ``StringList(data, items=items)``: a list without parent.
sl_make_items :: proc(
	data: []string,
	items: []Line_Info,
	allocator: runtime.Allocator,
) -> ^String_List {
	l := new(String_List, allocator)
	l.data = make([dynamic]string, len(data), max(len(data), 4), allocator)
	l.items = make([dynamic]Line_Info, len(items), max(len(items), 4), allocator)
	copy(l.data[:], data)
	copy(l.items[:], items)
	return l
}

sl_len :: #force_inline proc "contextless" (l: ^String_List) -> int {
	return len(l.data)
}

// Python truthiness of a list (``if self.parent:``): not empty.
@(private = "file")
truthy :: #force_inline proc "contextless" (l: ^String_List) -> bool {
	return l != nil && len(l.data) > 0
}

// Clamp a Python slice bound.
@(private = "file")
bound :: proc "contextless" (i, n: int) -> int {
	j := i < 0 ? i + n : i
	return clamp(j, 0, n)
}

// ``l[start:end]``: a child list (``end`` < 0 counts from the end; use
// ``max(int)`` for "to the end").  ``parent_offset`` is ``start`` as given,
// like ``i.start or 0``.
sl_slice :: proc(l: ^String_List, start: int, end := max(int)) -> ^String_List {
	n := len(l.data)
	a, b := bound(start, n), bound(end, n)
	if b < a do b = a
	allocator := l.data.allocator
	c := sl_make_items(l.data[a:b], l.items[a:b], allocator)
	c.parent = l
	c.parent_offset = start
	return c
}

// ``a + b``: a new list without parent.
sl_concat :: proc(a, b: ^String_List) -> ^String_List {
	allocator := a.data.allocator
	c := sl_make_items(a.data[:], a.items[:], allocator)
	append(&c.data, ..b.data[:])
	append(&c.items, ..b.items[:])
	return c
}

// ``l.insert(i, text, source=source, offset=offset)``.
sl_insert_line :: proc(l: ^String_List, i: int, text: string, info: Line_Info) {
	j := bound(i, len(l.data))
	inject_at(&l.data, j, text)
	inject_at(&l.items, j, info)
	if truthy(l.parent) {
		index := (len(l.data) + i) %% len(l.data)
		sl_insert_line(l.parent, index + l.parent_offset, text, info)
	}
}

// ``l.insert(i, other)`` for a list ``other``.
sl_insert_list :: proc(l: ^String_List, i: int, other: ^String_List) {
	j := bound(i, len(l.data))
	inject_at(&l.data, j, ..other.data[:])
	inject_at(&l.items, j, ..other.items[:])
	if truthy(l.parent) && len(l.data) > 0 {
		index := (len(l.data) + i) %% len(l.data)
		sl_insert_list(l.parent, index + l.parent_offset, other)
	}
}

// ``del l[i]``.
sl_delete :: proc(l: ^String_List, i: int) {
	j := i < 0 ? i + len(l.data) : i
	if j < 0 || j >= len(l.data) do return
	ordered_remove(&l.data, j)
	ordered_remove(&l.items, j)
	if truthy(l.parent) do sl_delete(l.parent, i + l.parent_offset)
}

// ``l.trim_start(n)``.
sl_trim_start :: proc(l: ^String_List, n := 1) {
	k := min(n, len(l.data))
	remove_range(&l.data, 0, k)
	remove_range(&l.items, 0, k)
	if truthy(l.parent) do l.parent_offset += k
}

// ``l.trim_end(n)``.
sl_trim_end :: proc(l: ^String_List, n := 1) {
	k := min(n, len(l.data))
	resize(&l.data, len(l.data) - k)
	resize(&l.items, len(l.items) - k)
}

// ``l.info(i)``: ``ok`` is false for an index off the list; ``has_offset``
// is false just past the end (docutils returns ``(source, None)``).
sl_info :: proc(l: ^String_List, i: int) -> (info: Line_Info, has_offset: bool, ok: bool) {
	n := len(l.items)
	if i >= 0 && i < n do return l.items[i], true, true
	if i < 0 && i >= -n do return l.items[n + i], true, true
	if i == n && n > 0 do return {l.items[n - 1].source, 0}, false, true
	return {}, false, false
}

// ``StringList.trim_left(length, start, end)``: drop ``length`` code
// points of each line in ``[start, end)``.
sl_trim_left :: proc(l: ^String_List, length: int, start := 0, end := max(int)) {
	a, b := bound(start, len(l.data)), bound(end, len(l.data))
	for i in a ..< b do l.data[i] = cp_slice(l.data[i], length)
}

// ``'\n'.join(l)``.
sl_join :: proc(l: ^String_List, allocator: runtime.Allocator) -> string {
	return join_lines(l.data[:], allocator)
}
