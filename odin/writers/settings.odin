package writers

import "core:encoding/json"
import "core:strings"

import dt "../doctree"

// The runtime settings the writers read.  ``doctree.Settings`` holds the
// settings of the native pipeline, but a few writer settings keep Python
// semantics that it does not represent: ``None`` as a third state
// (``legacy_column_widths``, ``use_latex_citations``), strings versus lists
// (``stylesheet``), and settings of other writers or transforms
// (``newlines``, ``sectnum_depth``).  A document loaded from the doctree
// interchange carries every docutils setting (``Doc.interchange``), which
// ``settings_for`` reads with those semantics.

Settings :: struct {
	// general
	output_encoding:                string,
	output_encoding_error_handler:  string,
	language_code:                  string,
	report_level:                   int,
	tab_width:                      int,
	file_insertion_enabled:         bool,
	root_prefix:                    string,
	output_path:                    string, // "" for None
	toc_backlinks:                  string, // "" for False
	footnote_backlinks:             bool,
	sectnum_xform:                  bool,
	syntax_highlight:               string,
	// pseudoxml
	detailed:                       bool,
	// docutils_xml (``xml_declaration`` also html5)
	newlines:                       bool,
	indents:                        bool,
	xml_declaration:                bool,
	doctype_declaration:            bool,
	// html5 and latex
	template:                       string, // "" for the writer's default
	stylesheet:                     []string, // ``get_stylesheet_list`` items
	stylesheet_path:                []string,
	stylesheet_dirs:                []string,
	stylesheet_text:                Maybe(string), // ``stylesheet`` given as a string
	embed_stylesheet:               bool,
	footnote_references:            string,
	attribution:                    string,
	table_style:                    []string, // latex: the list
	table_style_text:               string, // html5: the string
	// html5
	initial_header_level:           string, // "1" … "6" or "auto"
	math_output:                    string,
	compact_lists:                  bool,
	compact_field_lists:            bool,
	cloak_email_addresses:          bool,
	embed_images:                   Maybe(bool),
	image_loading:                  string, // "" for None
	section_self_link:              bool,
	// latex
	documentclass:                  string,
	documentoptions:                string,
	use_latex_citations:            Maybe(bool),
	latex_preamble:                 string,
	use_latex_toc:                  bool,
	use_part_section:               bool,
	use_latex_docinfo:              bool,
	use_latex_abstract:             bool,
	hyperlink_color:                string,
	hyperref_options:               string,
	compound_enumerators:           bool,
	section_prefix_for_enumerators: bool,
	section_enumerator_separator:   string,
	literal_block_env:              string,
	use_verbatim_when_possible:     Maybe(bool),
	graphicx_option:                string,
	font_encoding:                  string,
	reference_label:                string,
	use_bibtex:                     []string,
	legacy_class_functions:         bool,
	legacy_column_widths:           Maybe(bool),
	docutils_footnotes:             bool,
	sectnum_depth:                  Maybe(int), // set by the ``SectNum`` transform
	sectnum_start:                  Maybe(int),
}

XETEX_PREAMBLE :: `% Linux Libertine (free, wide coverage, not only for Linux)
\setmainfont{Linux Libertine O}
\setsansfont{Linux Biolinum O}
\setmonofont[HyphenChar=None,Scale=MatchLowercase]{DejaVu Sans Mono}`

// The writer's settings for ``doc``: from the dumped docutils settings of an
// interchange document, else from ``doc.settings``.
settings_for :: proc(doc: ^dt.Doc, writer: Writer_Name) -> Settings {
	if obj, ok := doc.interchange.settings.(json.Object); ok {
		return settings_from_json(obj, writer)
	}
	return settings_from_doctree(&doc.settings, writer)
}

@(private = "file")
settings_from_doctree :: proc(s: ^dt.Settings, writer: Writer_Name) -> Settings {
	out := Settings {
		output_encoding                = s.output_encoding,
		output_encoding_error_handler  = s.output_encoding_error_handler,
		language_code                  = s.language_code,
		report_level                   = s.report_level,
		tab_width                      = s.tab_width,
		file_insertion_enabled         = s.file_insertion_enabled,
		root_prefix                    = s.root_prefix,
		toc_backlinks                  = s.toc_backlinks,
		footnote_backlinks             = s.footnote_backlinks,
		sectnum_xform                  = s.sectnum_xform,
		syntax_highlight               = s.syntax_highlight,
		detailed                       = s.detailed,
		newlines                       = false,
		indents                        = false,
		xml_declaration                = s.xml_declaration || writer == .Xml,
		doctype_declaration            = true,
		template                       = s.template,
		stylesheet                     = s.stylesheet,
		stylesheet_path                = s.stylesheet_path,
		stylesheet_dirs                = s.stylesheet_dirs,
		embed_stylesheet               = s.embed_stylesheet,
		footnote_references            = s.footnote_references,
		attribution                    = s.attribution,
		table_style                    = s.table_style,
		table_style_text               = strings.join(s.table_style, ",", context.temp_allocator),
	}
	html_from_doctree(&out, s)
	latex_from_doctree(&out, s)
	if s.embed_images do out.embed_images = true
	if s.use_bibtex != "" {
		out.use_bibtex = strings.split(s.use_bibtex, ",", context.temp_allocator)
	}
	if s.use_verbatim_when_possible do out.use_verbatim_when_possible = true
	if writer == .Xetex {
		out.font_encoding = ""
		if out.latex_preamble == dt.LATEX_PREAMBLE do out.latex_preamble = XETEX_PREAMBLE
	}
	if len(out.stylesheet_dirs) > 0 && writer == .Html5 {
		dirs := make([]string, len(out.stylesheet_dirs) + 1, context.temp_allocator)
		copy(dirs, out.stylesheet_dirs)
		dirs[len(dirs) - 1] = NATIVE_DIR_PREFIX + "writers/html5_polyglot"
		out.stylesheet_dirs = dirs
	}
	return out
}

@(private = "file")
html_from_doctree :: proc(out: ^Settings, s: ^dt.Settings) {
	out.initial_header_level = int_str(s.initial_header_level)
	out.math_output = s.math_output
	out.compact_lists = s.compact_lists
	out.compact_field_lists = s.compact_field_lists
	out.cloak_email_addresses = s.cloak_email_addresses
	out.image_loading = s.image_loading
	out.section_self_link = s.section_self_link
}

@(private = "file")
latex_from_doctree :: proc(out: ^Settings, s: ^dt.Settings) {
	out.documentclass = s.documentclass
	out.documentoptions = s.documentoptions
	// ``doctree.Settings`` represents None as false (the docutils default of
	// these settings, with its own meaning).
	if s.use_latex_citations do out.use_latex_citations = true
	out.latex_preamble = s.latex_preamble
	out.use_latex_toc = s.use_latex_toc
	out.use_part_section = s.use_part_section
	out.use_latex_docinfo = s.use_latex_docinfo
	out.use_latex_abstract = s.use_latex_abstract
	out.hyperlink_color = s.hyperlink_color
	out.hyperref_options = s.hyperref_options
	out.compound_enumerators = s.compound_enumerators
	out.section_prefix_for_enumerators = s.section_prefix_for_enumerators
	out.section_enumerator_separator = s.section_enumerator_separator
	out.literal_block_env = s.literal_block_env
	out.graphicx_option = s.graphicx_option
	out.font_encoding = s.font_encoding
	out.reference_label = s.reference_label
	out.legacy_class_functions = s.legacy_class_functions
	if s.legacy_column_widths do out.legacy_column_widths = true
	out.docutils_footnotes = s.docutils_footnotes
	out.sectnum_depth = 0
	out.sectnum_start = 1
}

// --- the interchange settings ------------------------------------------------------

@(private = "file")
py_bool :: proc(obj: json.Object, key: string, default := false) -> bool {
	v, ok := obj[key]
	if !ok do return default
	#partial switch x in v {
	case json.Boolean:
		return x
	case json.Integer:
		return x != 0
	case json.String:
		return x != ""
	case json.Array:
		return len(x) > 0
	case json.Float:
		return x != 0
	}
	return false
}

// A setting that may be None (missing or null: nil).
@(private = "file")
maybe_bool :: proc(obj: json.Object, key: string) -> Maybe(bool) {
	v, ok := obj[key]
	if !ok do return nil
	if _, is_null := v.(json.Null); is_null do return nil
	return py_bool(obj, key)
}

@(private = "file")
py_str :: proc(obj: json.Object, key: string, default := "") -> string {
	v, ok := obj[key]
	if !ok do return default
	#partial switch x in v {
	case json.String:
		return x
	case json.Integer:
		return int_str(int(x))
	}
	return ""
}

@(private = "file")
maybe_int :: proc(obj: json.Object, key: string) -> Maybe(int) {
	v, ok := obj[key]
	if !ok do return nil
	#partial switch x in v {
	case json.Integer:
		return int(x)
	case json.Boolean:
		return 1 if x else 0
	}
	return nil
}

// ``getattr(settings, key, default)`` of an int setting that may be None
// (nil); a string counts as ``default`` (values from config files).
@(private = "file")
getattr_int :: proc(obj: json.Object, key: string, default: int) -> Maybe(int) {
	v, ok := obj[key]
	if !ok do return default
	#partial switch x in v {
	case json.Null:
		return nil
	case json.Integer:
		return int(x)
	case json.Boolean:
		return 1 if x else 0
	}
	return default
}

// A list setting: a list as is, a non-empty string split at commas (as
// ``get_stylesheet_list`` does with a programmatically set string).
@(private = "file")
py_list :: proc(obj: json.Object, key: string) -> []string {
	v, ok := obj[key]
	if !ok do return nil
	#partial switch x in v {
	case json.Array:
		out := make([]string, len(x), context.temp_allocator)
		for e, i in x {
			s, _ := e.(json.String)
			out[i] = s
		}
		return out
	case json.String:
		if x == "" do return nil
		parts := strings.split(x, ",", context.temp_allocator)
		for &p in parts do p = strings.trim_space(p)
		return parts
	}
	return nil
}

@(private = "file")
settings_from_json :: proc(obj: json.Object, writer: Writer_Name) -> Settings {
	s := Settings {
		output_encoding               = py_str(obj, "output_encoding", "utf-8"),
		output_encoding_error_handler = py_str(obj, "output_encoding_error_handler", "strict"),
		language_code                 = py_str(obj, "language_code", "en"),
		report_level                  = maybe_int(obj, "report_level").? or_else 2,
		tab_width                     = maybe_int(obj, "tab_width").? or_else 8,
		file_insertion_enabled        = py_bool(obj, "file_insertion_enabled", true),
		root_prefix                   = py_str(obj, "root_prefix"),
		output_path                   = py_str(obj, "output_path"),
		toc_backlinks                 = py_str(obj, "toc_backlinks", "entry"),
		footnote_backlinks            = py_bool(obj, "footnote_backlinks", true),
		sectnum_xform                 = py_bool(obj, "sectnum_xform", true),
		syntax_highlight              = py_str(obj, "syntax_highlight", "long"),
		detailed                      = py_bool(obj, "detailed"),
		newlines                      = py_bool(obj, "newlines"),
		indents                       = py_bool(obj, "indents"),
		xml_declaration               = py_bool(obj, "xml_declaration"),
		doctype_declaration           = py_bool(obj, "doctype_declaration"),
		template                      = py_str(obj, "template"),
		stylesheet                    = py_list(obj, "stylesheet"),
		stylesheet_path               = py_list(obj, "stylesheet_path"),
		stylesheet_dirs               = py_list(obj, "stylesheet_dirs"),
		embed_stylesheet              = py_bool(obj, "embed_stylesheet"),
		footnote_references           = py_str(obj, "footnote_references"),
		attribution                   = py_str(obj, "attribution", "dash"),
		table_style                   = py_list(obj, "table_style"),
		table_style_text              = py_str(obj, "table_style"),
	}
	if v, ok := obj["stylesheet"].(json.String); ok do s.stylesheet_text = v
	if toc, ok := obj["toc_backlinks"].(json.Boolean); ok && !toc do s.toc_backlinks = ""
	html_from_json(&s, obj)
	latex_from_json(&s, obj, writer)
	return s
}

@(private = "file")
html_from_json :: proc(s: ^Settings, obj: json.Object) {
	s.initial_header_level = py_str(obj, "initial_header_level", "2")
	s.math_output = py_str(obj, "math_output", "MathML")
	s.compact_lists = py_bool(obj, "compact_lists", true)
	s.compact_field_lists = py_bool(obj, "compact_field_lists", true)
	s.cloak_email_addresses = py_bool(obj, "cloak_email_addresses")
	s.embed_images = maybe_bool(obj, "embed_images")
	s.image_loading = py_str(obj, "image_loading")
	s.section_self_link = py_bool(obj, "section_self_link")
}

@(private = "file")
latex_from_json :: proc(s: ^Settings, obj: json.Object, writer: Writer_Name) {
	s.documentclass = py_str(obj, "documentclass", "article")
	s.documentoptions = py_str(obj, "documentoptions", "a4paper")
	s.use_latex_citations = maybe_bool(obj, "use_latex_citations")
	default_preamble := XETEX_PREAMBLE if writer == .Xetex else dt.LATEX_PREAMBLE
	s.latex_preamble = py_str(obj, "latex_preamble", default_preamble)
	s.use_latex_toc = py_bool(obj, "use_latex_toc", true)
	s.use_part_section = py_bool(obj, "use_part_section")
	s.use_latex_docinfo = py_bool(obj, "use_latex_docinfo")
	s.use_latex_abstract = py_bool(obj, "use_latex_abstract")
	s.hyperlink_color = py_str(obj, "hyperlink_color", "blue")
	s.hyperref_options = py_str(obj, "hyperref_options")
	s.compound_enumerators = py_bool(obj, "compound_enumerators")
	s.section_prefix_for_enumerators = py_bool(obj, "section_prefix_for_enumerators")
	s.section_enumerator_separator = py_str(obj, "section_enumerator_separator", "-")
	s.literal_block_env = py_str(obj, "literal_block_env")
	s.use_verbatim_when_possible = maybe_bool(obj, "use_verbatim_when_possible")
	s.graphicx_option = py_str(obj, "graphicx_option")
	s.font_encoding = py_str(obj, "font_encoding", "" if writer == .Xetex else "T1")
	s.reference_label = py_str(obj, "reference_label")
	s.use_bibtex = py_list(obj, "use_bibtex")
	s.legacy_class_functions = py_bool(obj, "legacy_class_functions")
	s.legacy_column_widths = maybe_bool(obj, "legacy_column_widths")
	s.docutils_footnotes = py_bool(obj, "docutils_footnotes", true)
	s.sectnum_depth = getattr_int(obj, "sectnum_depth", 0)
	s.sectnum_start = getattr_int(obj, "sectnum_start", 1)
}
