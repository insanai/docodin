package doctree

import "core:strings"

// Where docutils would use a Python library.  The native pipeline works as
// docutils does without the library (Pygments, PIL) or cannot do what the
// library does (URLs, codecs, external programs); at each place docutils
// would use it, the stage records a ``Python_Need``.  A document with needs
// is published with docutils instead (``odin/publish``, the hosts).

Python_Feature :: enum u8 {
	Pygments, // code highlighted with Pygments (``utils.code_analyzer.Lexer``)
	Pil, // an image's size read with PIL
	Url, // a URL fetched with ``urllib`` (other than a local ``file:`` URL)
	Codec, // a codec or error handler of Python's ``codecs`` the native code lacks
	Parser, // a parser module (the include directive's ``:parser:``)
	Mathml_Converter, // an external LaTeX to MathML converter (``math_output``)
	Writer, // a writer module other than the native writers
	Option, // a command-line option of the Python front end
}

// The names of the features in the C ABI (``docodin_publish``).
PYTHON_FEATURE_NAMES := [Python_Feature]string {
	.Pygments         = "pygments",
	.Pil              = "pil",
	.Url              = "url",
	.Codec            = "codec",
	.Parser           = "parser",
	.Mathml_Converter = "mathml-converter",
	.Writer           = "writer",
	.Option           = "option",
}

Python_Need :: struct {
	feature: Python_Feature,
	// the language, the image URI, the URL, the codec or error handler, the
	// parser, the converter, the writer or the option
	detail:  string,
	source:  string, // "" if none
	line:    int, // 0 if none
}

// Record a need (once for each feature, detail and place).
note_python_need :: proc(doc: ^Doc, need: Python_Need) {
	for n in doc.python_needs do if n == need do return
	append(&doc.python_needs, Python_Need {
		feature = need.feature,
		detail = strings.clone(need.detail, doc.allocator),
		source = strings.clone(need.source, doc.allocator),
		line = need.line,
	})
}

// Record a need at node ``n`` (the source and line of ``n`` or of its
// closest ancestor that has either).
note_python_need_at :: proc(doc: ^Doc, n: Node, feature: Python_Feature, detail: string) {
	src, ln := get_source_line(doc, n)
	need := Python_Need{feature, detail, src.? or_else "", ln.? or_else 0}
	note_python_need(doc, need)
}
