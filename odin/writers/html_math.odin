package writers

import "core:strings"

import dt "../doctree"
import texmath "../math"

// The math conversions of the HTML5 writer: ``math_output`` "HTML"
// (``math2html``) and "MathML" (``latex2mathml``).  The converters are those
// of odin/math; the external MathML converters are Python needs.

// ``_math2html``: HTML of LaTeX math, with the math stylesheets set up.
math_to_html :: proc(t: ^Html, code: string, is_block: bool) -> string {
	if t.math_options != "" && chunks(&t.math_header) == 0 {
		rest := t.math_options
		for name in strings.split_iterator(&rest, ",") {
			path := find_file_in_dirs(name, t.s.stylesheet_dirs)
			stylesheet_call(t, &t.math_header, path, true)
		}
	}
	wrapped := wrap_math_code(code, is_block)
	html, err := texmath.math2html(wrapped, is_block, context.temp_allocator)
	if e, raised := err.?; raised do t.err = exception_text(e)
	return html
}

// ``_math2mathml``: MathML of LaTeX math and the format; on a conversion
// error the encoded source with the fallback format and a warning.
math_to_mathml :: proc(t: ^Html, n: dt.Node, code: string, is_block: bool) -> (string, string) {
	if t.math_options != "" {
		dt.note_python_need_at(t.doc, n, .Mathml_Converter, t.math_options)
		t.err = strings.concatenate(
			{"NotImplementedError: external MathML converter ", t.math_options},
			context.temp_allocator,
		)
		return "", "mathml"
	}
	mathml, err := texmath.tex2mathml(code, is_block, context.temp_allocator)
	e, raised := err.?
	if !raised do return mathml, "mathml"
	if e.kind != .Math_Error {
		t.err = exception_text(e)
		return "", "mathml"
	}
	append(&t.messages, dt.warning(t.doc, e.message, {base_node = n}))
	fallback := "problematic" if t.s.report_level <= 2 else "latex"
	return encoded(astext(t.doc, n)), fallback
}

// "Kind: message" of an exception that docutils does not catch.
@(private = "file")
exception_text :: proc(e: texmath.Exception) -> string {
	return cat(texmath.EXCEPTION_NAMES[e.kind], ": ", e.message)
}
