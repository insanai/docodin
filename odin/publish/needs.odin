package publish

import "core:fmt"

import dt "../doctree"

// The explanation of a Python need (``python_need_text``) and how to do
// without the library (``python_need_hint``), for reports.

// The name of a feature in the C ABI ("pygments", "pil", ...).
python_feature_name :: proc(feature: Python_Feature) -> string {
	return dt.PYTHON_FEATURE_NAMES[feature]
}

// What needs Python, as a sentence.
python_need_text :: proc(need: Python_Need, allocator := context.allocator) -> string {
	format: string
	switch need.feature {
	case .Pygments:
		format = `Highlighting "%s" code needs Pygments.`
	case .Pil:
		format = `Reading the size of the image "%s" needs PIL (Pillow).`
	case .Url:
		format = `Fetching "%s" needs Python's urllib (docodin reads local file: URLs only).`
	case .Codec:
		format = `The codec or error handler "%s" needs Python's codecs.`
	case .Parser:
		format = `Including a file with the parser "%s" needs Python.`
	case .Mathml_Converter:
		format = `Converting math with the external MathML converter "%s" needs Python.`
	case .Writer:
		format = `The writer "%s" is a Python module (docodin's native writers are html5, ` +
			`latex, xetex, xml and pseudoxml).`
	case .Option:
		format = `The option "%s" needs docutils' Python front end.`
	}
	return fmt.aprintf(format, need.detail, allocator = allocator)
}

// How to publish the document without Python.
python_need_hint :: proc(need: Python_Need) -> string {
	switch need.feature {
	case .Pygments:
		return "or write `--syntax-highlight=none` to publish the code without highlighting."
	case .Pil:
		return "or give the image both a `:width:` and a `:height:` (and a figure a " +
			"`:figwidth:` other than `image`)."
	case .Url:
		return "or download the file and name it with the `:file:` option."
	case .Codec:
		return "or convert the files to UTF-8 (the native codecs are UTF-8, UTF-8-sig, " +
			"Latin-1 and ASCII, and UTF-16 and UTF-32 for the output)."
	case .Parser:
		return "or include reStructuredText without the `:parser:` option."
	case .Mathml_Converter:
		return "or write `--math-output=MathML` for the built-in converter."
	case .Writer:
		return "or choose a native writer, for example `--writer=html5`."
	case .Option:
		return "or leave the option out (the native docodin reads no configuration files)."
	}
	return ""
}
