package docodin

import "base:runtime"

import "core:strings"

import publish "../publish"
import rst "../rst"
import text "../text"

// C ABI of the shared library.
//
// * Buffers are passed with explicit lengths (NUL bytes are legal input).
// * Each call works in the calling thread's arena, which is emptied before
//   the call returns (its block goes to a small shared cache, see bump.odin):
//   nothing leaks between calls or when a thread exits, and the library is
//   safe to use from multiple threads.
// * Results are heap buffers owned by the caller; release with
//   ``docodin_free``.

ABI_VERSION :: 6
VERSION :: "0.2.0"

@(thread_local, private = "file")
tl_arena: Bump_Arena

// Calls in progress on this thread: a host callback (the include hook of
// ``docodin_parse``) may call back into the library, and the arena is only
// reset when the outermost call returns.
@(thread_local, private = "file")
tl_depth: int

@(private = "file")
call_context :: proc "contextless" () -> runtime.Context {
	tl_depth += 1
	if tl_depth == 1 do bump_unpark(&tl_arena)
	ctx := runtime.default_context()
	a := bump_allocator(&tl_arena)
	ctx.allocator = a
	ctx.temp_allocator = a
	return ctx
}

@(private = "file")
leave_call :: proc "contextless" () {
	tl_depth -= 1
	if tl_depth == 0 do bump_park(&tl_arena)
}

@(private = "file")
finish :: proc "contextless" (w: Writer, out_len: ^int) -> [^]u8 {
	if out_len != nil do out_len^ = len(w.buf)
	return raw_data(w.buf)
}

// Library initializer (registered with the linker's ``-init``): runs the
// Odin runtime start-up (global initializers, ``@(init)`` procedures).  Needed
// because the object is linked by the system toolchain, see
// scripts/build_odin.sh.  Hosts call it too, as not every linker honours
// ``-init`` (macOS's ld-prime ignores it): only the first call runs.
@(export)
docodin_init :: proc "c" () {
	if initialized do return
	initialized = true
	context = runtime.default_context()
	runtime._startup_runtime()
}

@(private = "file")
initialized: bool

@(export)
docodin_abi_version :: proc "c" () -> i32 {
	return ABI_VERSION
}

@(export)
docodin_version :: proc "c" () -> cstring {
	return VERSION
}

// Parse a (nested) block of reStructuredText; the result is laid out as
// ``serialize_document`` describes (nil if it would exceed 2 GiB).
//   input_offset:      absolute line offset of the first line
//   raw_line_count:    >= 0: input holds that many '\n'-joined lines
//                      (StringList); < 0: apply ``string2lines``
//   root_line:         host's current reporter line for nested parses (0: none)
//   include_hook:      nil, or called with each directive (its wire tuple);
//                      it returns true and '\n'-joined lines to insert
//                      after the directive (``insert_input``), which the
//                      parser then parses in place
@(export)
docodin_parse :: proc "c" (
	input: [^]u8,
	input_len: int,
	input_offset: int,
	raw_line_count: int,
	flags: rst.Parse_Flags,
	tab_width: i32,
	line_length_limit: i32,
	root_line: i32,
	include_hook: Include_Callback,
	hook_data: rawptr,
	out_len: ^int,
) -> [^]u8 {
	context = call_context()
	defer leave_call()
	p := rst.Parser {
		allocator = context.allocator,
		settings  = rst.settings_from_flags(flags, int(tab_width), int(line_length_limit)),
		root_line = int(root_line),
	}
	hook := C_Hook{include_hook, hook_data}
	if include_hook != nil {
		p.include_hook = c_include_hook
		p.hook_data = &hook
	}
	text := string(input[:max(input_len, 0)])
	match_titles := .Match_Titles in flags
	doc, line_count, final_offset := rst.parse_text(
		&p, text, input_offset, match_titles, raw_line_count,
	)
	capacity := input_len * 3 + 256
	w := serialize_document(&p.tree, doc, line_count, final_offset, p.cur_line, capacity)
	if len(w.buf) > int(max(i32)) {
		// the item offsets are marshal ints
		delete(w.buf)
		return nil
	}
	return finish(w, out_len)
}

// The host's include hook: ``item`` is the wire tuple of the directive; on
// true, ``out`` holds the lines to insert (``'\n'``-joined), valid until
// the next call.
Include_Callback :: proc "c" (
	data: rawptr,
	item: [^]u8,
	item_len: int,
	out: ^[^]u8,
	out_len: ^int,
) -> b32

@(private = "file")
C_Hook :: struct {
	callback: Include_Callback,
	data:     rawptr,
}

@(private = "file")
c_include_hook :: proc(
	data: rawptr,
	p: ^rst.Parser,
	sm: ^rst.State_Machine,
	d: rst.Node,
) -> (
	lines: []string,
	insert: bool,
) {
	hook := (^C_Hook)(data)
	w := writer_make(256)
	defer delete(w.buf)
	write_node(&w, &p.tree, d)
	out: [^]u8
	out_len: int
	if !hook.callback(hook.data, raw_data(w.buf), len(w.buf), &out, &out_len) do return nil, false
	text := strings.clone(string(out[:max(out_len, 0)]), p.allocator)
	return strings.split(text, "\n", p.allocator), true
}

// Parse inline markup only (``Inliner.parse`` / ``RSTState.inline_text``).
@(export)
docodin_parse_inline :: proc "c" (
	input: [^]u8,
	input_len: int,
	lineno: int,
	flags: rst.Parse_Flags,
	out_len: ^int,
) -> [^]u8 {
	context = call_context()
	defer leave_call()
	p := rst.Parser {
		allocator = context.allocator,
		settings  = rst.settings_from_flags(flags, 8, 0),
	}
	nodes := rst.parse_inline(&p, string(input[:max(input_len, 0)]), lineno)
	return finish(serialize_inline(&p.tree, nodes, input_len * 2 + 64), out_len)
}

// ``docutils.statemachine.string2lines``: (WIRE_VERSION, [lines]).
@(export)
docodin_split_lines :: proc "c" (
	input: [^]u8,
	input_len: int,
	tab_width: i32,
	out_len: ^int,
) -> [^]u8 {
	context = call_context()
	defer leave_call()
	lines := rst.split_lines(string(input[:max(input_len, 0)]), int(tab_width), context.allocator)
	w := writer_make(input_len + len(lines) * 6 + 16)
	w_tuple(&w, 2)
	w_int(&w, WIRE_VERSION)
	w_list(&w, len(lines))
	for l in lines do w_str(&w, l)
	return finish(w, out_len)
}

// ``publish_string`` / ``publish_parts`` natively (``odin/publish``): the
// standalone reader, the rST parser and a writer (pseudoxml, xml, html5,
// latex, xetex).  The request is length-prefixed (N: a native-endian
// ``int``; a field: N length, UTF-8 bytes):
//   field text, N has_source_path, field source_path, field writer,
//   field docutils_dir ("": the default), N count, count x override:
//     field name, N kind (0 None, 1 False, 2 True, 3 int, 4 str, 5 list),
//     then N value (int), a field (str) or N items and the fields (list).
// Result: (WIRE_VERSION, output, [(name, value)] parts, [(level, text)]
// messages, exit_status, error, needs), error: None or (kind, text, report,
// level, encoding, start, end, characters) with kind "settings",
// "system_message", "exception" or "unicode_encode"; needs: [(feature,
// detail, source, line, text)], where docutils would use a Python library
// (feature "pygments", "pil", "url", "codec", "parser", "mathml-converter"
// or "writer"; source "" and line 0 when unknown).  With needs, the other
// results are those of docutils without the libraries: publish the
// document with docutils.  nil for a malformed request.
@(export)
docodin_publish :: proc "c" (request: [^]u8, request_len: int, out_len: ^int) -> [^]u8 {
	context = call_context()
	defer leave_call()
	r := Request {
		buf = string(request[:max(request_len, 0)]),
		ok  = true,
	}
	text := read_bytes(&r)
	has_source := read_int(&r) != 0
	source_path := read_bytes(&r)
	writer := read_bytes(&r)
	docutils_dir := read_bytes(&r)
	overrides := read_overrides(&r)
	if !r.ok do return nil
	if !has_source do source_path = ""
	output, parts, messages, status, err, needs := publish.publish(text, source_path, writer,
		overrides, {docutils_dir = docutils_dir})
	w := writer_make(len(output) * 2 + 256)
	w_tuple(&w, 7)
	w_int(&w, WIRE_VERSION)
	w_str(&w, output)
	w_list(&w, len(parts.items))
	for p in parts.items {
		w_tuple(&w, 2)
		w_str(&w, p.name)
		w_str(&w, p.value)
	}
	w_list(&w, len(messages))
	for m in messages {
		w_tuple(&w, 2)
		w_int(&w, m.level)
		w_str(&w, m.text)
	}
	w_int(&w, status)
	write_publish_error(&w, err)
	write_python_needs(&w, needs)
	return finish(w, out_len)
}

@(private = "file")
write_python_needs :: proc(w: ^Writer, needs: []publish.Python_Need) {
	w_list(w, len(needs))
	for n in needs {
		w_tuple(w, 5)
		w_str(w, publish.python_feature_name(n.feature))
		w_str(w, n.detail)
		w_str(w, n.source)
		w_int(w, n.line)
		w_str(w, publish.python_need_text(n))
	}
}

@(private = "file")
read_overrides :: proc(r: ^Request) -> []publish.Override {
	count := read_int(r)
	if !r.ok || count < 0 || count > len(r.buf) {
		r.ok = false
		return nil
	}
	out := make([]publish.Override, count)
	for &o in out {
		o.name = read_bytes(r)
		switch kind := read_int(r); kind {
		case 0:
			o.value = publish.None{}
		case 1, 2:
			o.value = kind == 2
		case 3:
			o.value = read_int(r)
		case 4:
			o.value = read_bytes(r)
		case 5:
			o.value = read_list(r)
		case:
			r.ok = false
		}
	}
	return out
}

@(private = "file")
read_list :: proc(r: ^Request) -> []string {
	n := read_int(r)
	if !r.ok || n < 0 || n > len(r.buf) {
		r.ok = false
		return nil
	}
	items := make([]string, n)
	for &item in items do item = read_bytes(r)
	return items
}

@(private = "file")
write_publish_error :: proc(w: ^Writer, err: publish.Error) {
	if err == nil {
		w_none(w)
		return
	}
	kind, text, level := "", "", 0
	encoding, start, end, chars := "", 0, 0, ""
	switch e in err {
	case publish.Settings_Error:
		kind, text = "settings", e.message
	case publish.System_Message:
		kind, text, level = "system_message", e.text, e.level
	case publish.Exception:
		kind, text = "exception", e.text
	case publish.Unicode_Error:
		kind, text = "unicode_encode", publish.encode_error_text(e.encode)
		encoding, start, end, chars = publish.CODEC_NAMES[e.codec], e.start, e.end, e.chars
	}
	w_tuple(w, 8)
	w_str(w, kind)
	w_str(w, text)
	w_str(w, publish.error_report(err))
	w_int(w, level)
	w_str(w, encoding)
	w_int(w, start)
	w_int(w, end)
	w_str(w, chars)
}

// Release a result buffer.  Results are allocated with
// ``runtime.heap_allocator()`` (which keeps an alignment header), so they
// must be released through the same allocator.
@(export)
docodin_free :: proc "c" (ptr: rawptr) {
	if ptr == nil do return
	context = runtime.default_context()
	free(ptr, runtime.heap_allocator())
}

// ``docutils.utils.smartquotes.educate_tokens`` over the tokens of one text
// block: (WIRE_VERSION, [educated token, ...]), or nil for a malformed
// request.  The request is length-prefixed (N: a native-endian ``int``):
//   N attr_len, attr, N language_len, language,
//   N has_quotes (0: the language's quotes; 1: followed by 4 x (N len, mark):
//                 open/close primary, open/close secondary),
//   N count, count x N token length in code points,
//   count x u8 text.Token_Kind (0 text, 1 literal, 2 tag),
//   the tokens' text, concatenated (UTF-8).
@(export)
docodin_educate :: proc "c" (request: [^]u8, request_len: int, out_len: ^int) -> [^]u8 {
	context = call_context()
	defer leave_call()
	r := Request {
		buf = string(request[:max(request_len, 0)]),
		ok  = true,
	}
	attr, lang := read_bytes(&r), read_bytes(&r)
	marks := text.quotes_for(lang)
	if read_int(&r) != 0 {
		marks = {read_bytes(&r), read_bytes(&r), read_bytes(&r), read_bytes(&r)}
	}
	count := read_int(&r)
	lengths := read_raw(&r, count * size_of(int) if count <= len(r.buf) else -1)
	kinds := read_raw(&r, count)
	if !r.ok do return nil
	src := r.buf[r.pos:]
	e := text.educator_make(attr, lang, marks)
	w := writer_make(len(src) + len(src) / 4 + count * 5 + 16)
	w_tuple(&w, 2)
	w_int(&w, WIRE_VERSION)
	w_list(&w, count)
	pos := 0
	for i in 0 ..< count {
		end := advance_chars(src, pos, load_int(lengths[i * size_of(int):]))
		kind := text.Token_Kind(min(kinds[i], u8(text.Token_Kind.Tag)))
		w_str(&w, text.educate_token(&e, kind, src[pos:end]))
		pos = end
	}
	return finish(w, out_len)
}

// Reader of a length-prefixed request; `ok` turns false on reading past the end.
@(private = "file")
Request :: struct {
	buf: string,
	pos: int,
	ok:  bool,
}

@(private = "file")
read_raw :: proc(r: ^Request, n: int) -> string {
	if n < 0 || n > len(r.buf) - r.pos {
		r.ok = false
		r.pos = len(r.buf)
		return ""
	}
	r.pos += n
	return r.buf[r.pos - n:r.pos]
}

@(private = "file")
load_int :: #force_inline proc(b: string) -> (v: int) {
	runtime.mem_copy_non_overlapping(&v, raw_data(b), size_of(int))
	return
}

@(private = "file")
read_int :: proc(r: ^Request) -> int {
	b := read_raw(r, size_of(int))
	return load_int(b) if r.ok else 0
}

@(private = "file")
read_bytes :: proc(r: ^Request) -> string {
	return read_raw(r, read_int(r))
}

// Byte offset `chars` code points after `pos`.
@(private = "file")
advance_chars :: proc(s: string, pos: int, chars: int) -> int {
	i, left := pos, chars
	for i < len(s) && left > 0 {
		i += 1
		for i < len(s) && s[i] & 0xC0 == 0x80 do i += 1
		left -= 1
	}
	return i
}
