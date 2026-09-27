package docodin

import "base:runtime"

import rst "../rst"

// C ABI of the shared library.
//
// * Buffers are passed with explicit lengths (NUL bytes are legal input).
// * Each call works in the calling thread's arena, which is reset before the
//   call returns: nothing leaks between calls and no global state is shared,
//   so the library is safe to use from multiple threads.
// * Results are heap buffers owned by the caller; release with
//   ``docodin_free``.

ABI_VERSION :: 2
VERSION :: "0.2.0"

@(thread_local, private = "file")
tl_arena: Bump_Arena

@(private = "file")
call_context :: proc "contextless" () -> runtime.Context {
	ctx := runtime.default_context()
	a := bump_allocator(&tl_arena)
	ctx.allocator = a
	ctx.temp_allocator = a
	return ctx
}

@(private = "file")
finish :: proc "contextless" (w: Writer, out_len: ^int) -> [^]u8 {
	if out_len != nil do out_len^ = len(w.buf)
	return raw_data(w.buf)
}

// Library initializer (registered with the linker's ``-init``): runs the
// Odin runtime start-up (global initializers, ``@(init)`` procedures).  Needed
// because the object is linked by the system toolchain, see
// scripts/build_odin.sh.
@(export)
docodin_init :: proc "c" () {
	context = runtime.default_context()
	runtime._startup_runtime()
}

@(export)
docodin_abi_version :: proc "c" () -> i32 {
	return ABI_VERSION
}

@(export)
docodin_version :: proc "c" () -> cstring {
	return VERSION
}

// Parse a (nested) block of reStructuredText.
//   input_offset:      absolute line offset of the first line
//   raw_line_count:    >= 0: input holds that many '\n'-joined lines
//                      (StringList); < 0: apply ``string2lines``
//   root_line:         host's current reporter line for nested parses (0: none)
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
	out_len: ^int,
) -> [^]u8 {
	context = call_context()
	defer bump_reset(&tl_arena)
	p := rst.Parser {
		allocator = context.allocator,
		settings  = rst.settings_from_flags(flags, int(tab_width), int(line_length_limit)),
		root_line = int(root_line),
	}
	text := string(input[:max(input_len, 0)])
	match_titles := .Match_Titles in flags
	doc, line_count, final_offset := rst.parse_text(
		&p, text, input_offset, match_titles, raw_line_count,
	)
	capacity := input_len + input_len / 2
	w := serialize_document(&p.tree, doc, line_count, final_offset, p.cur_line, capacity)
	return finish(w, out_len)
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
	defer bump_reset(&tl_arena)
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
	defer bump_reset(&tl_arena)
	lines := rst.split_lines(string(input[:max(input_len, 0)]), int(tab_width), context.allocator)
	w := writer_make(input_len + len(lines) * 6 + 16)
	w_tuple(&w, 2)
	w_int(&w, WIRE_VERSION)
	w_list(&w, len(lines))
	for l in lines do w_str(&w, l)
	return finish(w, out_len)
}

// Render reST directly to semantic HTML5 using the native Odin emitter.
@(export)
docodin_render_html :: proc "c" (
	input: [^]u8,
	input_len: int,
	title: [^]u8,
	title_len: int,
	author: [^]u8,
	author_len: int,
	standalone: bool,
	embed_css: bool,
	out_len: ^int,
) -> [^]u8 {
	context = call_context()
	defer bump_reset(&tl_arena)
	p := rst.Parser {
		allocator = context.allocator,
		settings  = rst.DEFAULT_SETTINGS,
	}
	text := string(input[:max(input_len, 0)])
	doc, _, _ := rst.parse_text(&p, text, 0, true, -1)
	cfg := rst.Html_Config {
		title      = string(title[:max(title_len, 0)]) if title != nil else "",
		author     = string(author[:max(author_len, 0)]) if author != nil else "",
		standalone = standalone,
		embed_css  = embed_css,
	}
	html_str := rst.write_html(doc, &p, cfg)

	buf := make([]u8, len(html_str), runtime.heap_allocator())
	copy(buf, html_str)
	if out_len != nil do out_len^ = len(buf)
	return raw_data(buf)
}

// Render reST directly to LaTeX 2e using the native Odin emitter.
@(export)
docodin_render_latex :: proc "c" (
	input: [^]u8,
	input_len: int,
	title: [^]u8,
	title_len: int,
	author: [^]u8,
	author_len: int,
	date: [^]u8,
	date_len: int,
	standalone: bool,
	out_len: ^int,
) -> [^]u8 {
	context = call_context()
	defer bump_reset(&tl_arena)
	p := rst.Parser {
		allocator = context.allocator,
		settings  = rst.DEFAULT_SETTINGS,
	}
	text := string(input[:max(input_len, 0)])
	doc, _, _ := rst.parse_text(&p, text, 0, true, -1)
	cfg := rst.Latex_Config {
		title      = string(title[:max(title_len, 0)]) if title != nil else "",
		author     = string(author[:max(author_len, 0)]) if author != nil else "",
		date       = string(date[:max(date_len, 0)]) if date != nil else "",
		standalone = standalone,
	}
	latex_str := rst.write_latex(doc, &p, cfg)

	buf := make([]u8, len(latex_str), runtime.heap_allocator())
	copy(buf, latex_str)
	if out_len != nil do out_len^ = len(buf)
	return raw_data(buf)
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
