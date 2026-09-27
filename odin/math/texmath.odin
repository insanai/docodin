/*
Package texmath converts LaTeX math like docutils 0.22.4's ``docutils.utils.math``.

- `math2html`: TeX to HTML with the classes of ``math.css`` (``math2html.math2html``).
- `tex2mathml`: TeX to presentational MathML (``latex2mathml.tex2mathml``).
- `uni2tex` and `uni2tex_translate`: the ``unichar2tex.uni2tex_table`` of the LaTeX
  writer; the ``tex2unichar`` dictionaries are the ``TEX2UNICHAR_*`` tables.

The output is docutils' output character for character. Where docutils raises an
exception (a ``MathError`` for invalid input, or an ``AttributeError``, ``IndexError`` ...
from a bug that some input triggers), the procedures return an `Exception` with the
Python exception's type and message instead.

Strings are UTF-8. The converters work in a scratch arena and return their results in
the given allocator.
*/
package texmath

import "core:mem/virtual"
import "core:strings"

// The Python exception a conversion raises in docutils.
Exception_Kind :: enum u8 {
	None,
	Math_Error, // docutils.utils.math.MathError (a ValueError)
	Attribute_Error,
	Index_Error,
	Type_Error,
	Value_Error,
	Zero_Division_Error,
	Unbound_Local_Error,
	Recursion_Error, // the native nesting limit, `MAX_DEPTH`
}

// Python's names of the exception kinds.
@(rodata)
EXCEPTION_NAMES := [Exception_Kind]string {
	.None                = "",
	.Math_Error          = "MathError",
	.Attribute_Error     = "AttributeError",
	.Index_Error         = "IndexError",
	.Type_Error          = "TypeError",
	.Value_Error         = "ValueError",
	.Zero_Division_Error = "ZeroDivisionError",
	.Unbound_Local_Error = "UnboundLocalError",
	.Recursion_Error     = "RecursionError",
}

Exception :: struct {
	kind:    Exception_Kind,
	message: string, // ``str(exception)``
}

// nil, or the exception docutils raises.
Error :: Maybe(Exception)

// The deepest nesting the converters accept.  Deeper input raises a
// `.Recursion_Error`, like docutils (whose recursion ends earlier: at about 190
// nested groups in ``math2html`` with Python's default recursion limit).
MAX_DEPTH :: 1000

RECURSION_ERROR :: Exception{.Recursion_Error, "maximum recursion depth exceeded"}

// The message of ``getattr(None, name)``.
none_attribute :: proc(name: string) -> Exception {
	return {
		.Attribute_Error,
		strings.concatenate({"'NoneType' object has no attribute '", name, "'"}),
	}
}

// The message of ``setattr(None, name, value)`` (CPython 3.13 and later, the
// version the tables are generated from).
none_attribute_set :: proc(name: string) -> Exception {
	return {
		.Attribute_Error,
		strings.concatenate({
			"'NoneType' object has no attribute '", name,
			"' and no __dict__ for setting new attributes",
		}),
	}
}

// A growing arena for the temporary data of one conversion.
@(private)
Scratch :: struct {
	arena: virtual.Arena,
}

@(private)
scratch_begin :: proc(scratch: ^Scratch) -> bool {
	return virtual.arena_init_growing(&scratch.arena) == nil
}

@(private)
scratch_end :: proc(scratch: ^Scratch) {
	virtual.arena_destroy(&scratch.arena)
}

@(private)
clone_error :: proc(err: Error, allocator := context.allocator) -> Error {
	exception, raised := err.?
	if !raised {
		return nil
	}
	return Exception{exception.kind, strings.clone(exception.message, allocator)}
}
