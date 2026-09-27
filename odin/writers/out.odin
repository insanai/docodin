package writers

import "base:runtime"

// ``Out``: a translator's output collector.
//
// docutils' translators collect output in Python lists of strings and some
// methods work on the list items: ``body[-1] == "<code>"``, ``del
// body[start:]``, ``out.pop()``, ``out[0]``.  ``Out`` keeps the text in one
// growing byte buffer and records where each item ("chunk") starts, so these
// operations keep their list semantics without a string per item.
Out :: struct {
	buf:    [dynamic]u8,
	starts: [dynamic]int, // start offset of each chunk in ``buf``
}

out_make :: proc(allocator: runtime.Allocator, capacity := 256) -> Out {
	return Out {
		buf = make([dynamic]u8, 0, capacity, allocator),
		starts = make([dynamic]int, 0, capacity / 16 + 4, allocator),
	}
}

// A new chunk ``s`` (``out.append(s)``).
put :: proc(o: ^Out, s: string) {
	append(&o.starts, len(o.buf))
	append(&o.buf, s)
}

// Several chunks (``out += [a, b, ...]``).
put_all :: proc(o: ^Out, items: ..string) {
	for s in items do put(o, s)
}

// Start a new, empty chunk that ``w`` then extends.
begin :: proc(o: ^Out) {
	append(&o.starts, len(o.buf))
}

// Extend the current chunk (after ``begin`` or ``put``).
w :: proc(o: ^Out, s: string) {
	append(&o.buf, s)
}

wb :: proc(o: ^Out, c: u8) {
	append(&o.buf, c)
}

// Number of chunks (``len(out)``).
chunks :: proc(o: ^Out) -> int {
	return len(o.starts)
}

// Byte length of the text.
size :: proc(o: ^Out) -> int {
	return len(o.buf)
}

// The whole text (``"".join(out)``); a view into the buffer.
text_of :: proc(o: ^Out) -> string {
	return string(o.buf[:])
}

// The text of chunks ``[i:j]`` (``"".join(out[i:j])``); ``j`` < 0 counts
// from the end.  A view into the buffer.
text_range :: proc(o: ^Out, i: int, j := max(int)) -> string {
	n := len(o.starts)
	a := clamp(i, 0, n)
	b := j < 0 ? n + j : min(j, n)
	if b <= a do return ""
	end := b < n ? o.starts[b] : len(o.buf)
	return string(o.buf[o.starts[a]:end])
}

// The chunk at ``i`` (``out[i]``); ``i`` < 0 counts from the end.
chunk_at :: proc(o: ^Out, i: int) -> string {
	n := len(o.starts)
	k := i < 0 ? n + i : i
	if k < 0 || k >= n do return ""
	return text_range(o, k, k + 1)
}

// ``out[-1]``, "" for an empty collector.
last :: proc(o: ^Out) -> string {
	return chunk_at(o, -1)
}

// ``del out[i:]``.
truncate :: proc(o: ^Out, i: int) {
	if i >= len(o.starts) do return
	k := max(i, 0)
	resize(&o.buf, o.starts[k])
	resize(&o.starts, k)
}

// ``out.pop()``: remove the last chunk and return a copy of it.
pop_chunk :: proc(o: ^Out, allocator := context.temp_allocator) -> string {
	if len(o.starts) == 0 do return ""
	s := clone_string(last(o), allocator)
	truncate(o, len(o.starts) - 1)
	return s
}

// ``out[i] = s``.
replace_chunk :: proc(o: ^Out, i: int, s: string) {
	rest := clone_string(text_range(o, i + 1))
	tail := make([]int, max(len(o.starts) - i - 1, 0), context.temp_allocator)
	for k in 0 ..< len(tail) do tail[k] = o.starts[i + 1 + k] - o.starts[i + 1]
	truncate(o, i)
	put(o, s)
	base := len(o.buf)
	append(&o.buf, rest)
	for off in tail do append(&o.starts, base + off)
}

// ``out.clear()``.
reset :: proc(o: ^Out) {
	clear(&o.buf)
	clear(&o.starts)
}

// Append all chunks of ``src`` to ``dst`` (``dst.extend(src)``).
put_out :: proc(dst, src: ^Out) {
	put_range(dst, src, 0)
}

// Append the chunks ``[i:j]`` of ``src`` to ``dst``.
put_range :: proc(dst, src: ^Out, i: int, j := max(int)) {
	n := len(src.starts)
	a := clamp(i, 0, n)
	b := j < 0 ? n + j : min(j, n)
	for k in a ..< b {
		end := k + 1 < n ? src.starts[k + 1] : len(src.buf)
		append(&dst.starts, len(dst.buf))
		append(&dst.buf, ..src.buf[src.starts[k]:end])
	}
}

clone_string :: proc(s: string, allocator := context.temp_allocator) -> string {
	if len(s) == 0 do return ""
	b := make([]u8, len(s), allocator)
	copy(b, s)
	return string(b)
}
