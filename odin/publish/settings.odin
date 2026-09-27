package publish

import "core:encoding/json"
import "core:reflect"
import "core:strconv"
import "core:strings"

import dt "../doctree"
import wr "../writers"

// The runtime settings of a run (``optparse.Values`` of docutils): every
// setting of the standalone reader, the rST parser and the writer, by its
// docutils name, with docutils' Python value.  The transforms and writers
// read them as the settings of a document loaded from the doctree
// interchange (``Doc.interchange.settings``), which keeps Python's
// distinctions (``None`` versus ``False``, a string versus a list); the
// reader reads the ``doctree.Settings`` converted from them.

// Python ``None``.
None :: struct {}

// A setting's value: ``None``, ``bool``, ``int``, ``str`` or a list of
// ``str``.  (A ``smartquotes_locales`` item is "language:quotes".)
Value :: union {
	None,
	bool,
	int,
	string,
	[]string,
}

// A setting given by the caller: ``settings_overrides[name] = value``.
// A string value of a setting with a docutils validator is converted as
// the validator converts command-line and configuration-file values; other
// values are taken as they are, as docutils takes programmatic overrides.
Override :: struct {
	name:  string,
	value: Value,
}

Settings :: map[string]Value

@(private = "file")
Writers :: bit_set[wr.Writer_Name]

@(private = "file")
ALL :: Writers{.Pseudoxml, .Xml, .Html5, .Latex, .Xetex}
@(private = "file")
HTML :: Writers{.Html5}
@(private = "file")
LATEX :: Writers{.Latex, .Xetex}
@(private = "file")
HTML_LATEX :: Writers{.Html5, .Latex, .Xetex}

// A docutils default: the setting of ``writers`` (``frontend
// .get_default_settings(Parser, Reader, Writer)`` with ``_disable_config``).
@(private = "file")
Default :: struct {
	name:    string,
	writers: Writers,
	value:   Default_Value,
}

// A default value; a list is written as its comma-separated items.
@(private = "file")
Default_Value :: union {
	None,
	bool,
	int,
	string,
	List_Text,
}

@(private = "file")
List_Text :: struct {
	items: string,
}

@(private = "file")
LATEX_PREAMBLE_XETEX :: `% Linux Libertine (free, wide coverage, not only for Linux)
\setmainfont{Linux Libertine O}
\setsansfont{Linux Biolinum O}
\setmonofont[HyphenChar=None,Scale=MatchLowercase]{DejaVu Sans Mono}`

@(private = "file", rodata)
DEFAULTS := [?]Default {
	// general (``frontend.OptionParser``)
	{"_disable_config", ALL, true},
	{"_destination", ALL, None{}},
	{"_source", ALL, None{}},
	{"auto_id_prefix", ALL, "%"},
	{"config", ALL, None{}},
	{"datestamp", ALL, None{}},
	{"debug", ALL, None{}},
	{"dump_internals", ALL, None{}},
	{"dump_pseudo_xml", ALL, None{}},
	{"dump_settings", ALL, None{}},
	{"dump_transforms", ALL, None{}},
	{"error_encoding", ALL, "utf-8"},
	{"error_encoding_error_handler", ALL, "backslashreplace"},
	{"exit_status_level", ALL, 5},
	{"expose_internals", ALL, None{}},
	{"footnote_backlinks", ALL, true},
	{"generator", ALL, None{}},
	{"halt_level", ALL, 4},
	{"id_prefix", ALL, ""},
	{"input_encoding", ALL, "utf-8"},
	{"input_encoding_error_handler", ALL, "strict"},
	{"language_code", ALL, "en"},
	{"output_encoding", ALL, "utf-8"},
	{"output_encoding_error_handler", {.Pseudoxml, .Latex, .Xetex}, "strict"},
	{"output_encoding_error_handler", {.Xml, .Html5}, "xmlcharrefreplace"},
	{"output_path", ALL, None{}},
	{"report_level", ALL, 2},
	{"root_prefix", ALL, ""},
	{"sectnum_xform", ALL, true},
	{"source_link", ALL, None{}},
	{"source_url", ALL, None{}},
	{"strict_visitor", ALL, None{}},
	{"strip_classes", ALL, None{}},
	{"strip_comments", ALL, None{}},
	{"strip_elements_with_classes", ALL, None{}},
	{"title", ALL, None{}},
	{"toc_backlinks", ALL, "entry"},
	{"traceback", ALL, None{}},
	// rST parser
	{"character_level_inline_markup", ALL, false},
	{"file_insertion_enabled", ALL, true},
	{"line_length_limit", ALL, 10000},
	{"pep_base_url", ALL, "https://peps.python.org/"},
	{"pep_file_url_template", ALL, "pep-%04d"},
	{"pep_references", ALL, None{}},
	{"raw_enabled", ALL, true},
	{"rfc_base_url", ALL, "https://tools.ietf.org/html/"},
	{"rfc_references", ALL, None{}},
	{"smart_quotes", ALL, false},
	{"smartquotes_locales", ALL, None{}},
	{"syntax_highlight", ALL, "long"},
	{"tab_width", ALL, 8},
	{"trim_footnote_reference_space", ALL, None{}},
	{"validate", ALL, None{}},
	// standalone reader
	{"docinfo_xform", ALL, true},
	{"doctitle_xform", ALL, true},
	{"sectsubtitle_xform", ALL, false},
	// pseudoxml, xml
	{"detailed", {.Pseudoxml}, None{}},
	{"doctype_declaration", {.Xml}, 1},
	{"indents", {.Xml}, None{}},
	{"newlines", {.Xml}, None{}},
	{"xml_declaration", {.Xml}, 1},
	// html5 and latex
	{"attribution", HTML_LATEX, "dash"},
	{"embed_stylesheet", HTML, true},
	{"embed_stylesheet", LATEX, false},
	{"footnote_references", HTML, "brackets"},
	{"footnote_references", LATEX, "superscript"},
	{"stylesheet", HTML, None{}},
	{"stylesheet", LATEX, ""},
	{"stylesheet_dirs", LATEX, List_Text{"."}},
	{"stylesheet_path", HTML, List_Text{"minimal.css,plain.css"}},
	{"stylesheet_path", LATEX, None{}},
	{"table_style", HTML, ""},
	{"table_style", LATEX, List_Text{"standard"}},
	// html5 (``stylesheet_dirs`` and ``template`` depend on the docutils
	// directory: see ``default_settings``)
	{"cloak_email_addresses", HTML, None{}},
	{"compact_field_lists", HTML, true},
	{"compact_lists", HTML, true},
	{"embed_images", HTML, None{}},
	{"image_loading", HTML, None{}},
	{"initial_header_level", HTML, "2"},
	{"math_output", HTML, "MathML"},
	{"section_self_link", HTML, false},
	{"xml_declaration", HTML, false},
	// latex2e, xetex
	{"compound_enumerators", LATEX, false},
	{"documentclass", LATEX, "article"},
	{"documentoptions", LATEX, "a4paper"},
	{"docutils_footnotes", LATEX, true},
	{"font_encoding", {.Latex}, "T1"},
	{"fontencoding", {.Xetex}, ""},
	{"graphicx_option", LATEX, ""},
	{"hyperlink_color", LATEX, "blue"},
	{"hyperref_options", LATEX, ""},
	{"latex_preamble", {.Latex}, dt.LATEX_PREAMBLE},
	{"latex_preamble", {.Xetex}, LATEX_PREAMBLE_XETEX},
	{"legacy_class_functions", LATEX, false},
	{"legacy_column_widths", LATEX, None{}},
	{"literal_block_env", LATEX, ""},
	{"reference_label", LATEX, ""},
	{"section_enumerator_separator", LATEX, "-"},
	{"section_prefix_for_enumerators", LATEX, None{}},
	{"template", {.Latex}, "default.tex"},
	{"template", {.Xetex}, "xelatex.tex"},
	{"use_bibtex", LATEX, ""},
	{"use_latex_abstract", LATEX, false},
	{"use_latex_citations", LATEX, None{}},
	{"use_latex_docinfo", LATEX, false},
	{"use_latex_toc", LATEX, true},
	{"use_part_section", LATEX, false},
	{"use_verbatim_when_possible", LATEX, None{}},
}

// The directory of the docutils package as the settings name it (the
// html5 ``stylesheet_dirs``): the writers find their data files by the
// writer directory's name under it.
DEFAULT_DOCUTILS_DIR :: "<docutils>"

// The docutils defaults of ``writer`` (allocated with ``allocator``).
default_settings :: proc(
	writer: wr.Writer_Name,
	docutils_dir := DEFAULT_DOCUTILS_DIR,
	allocator := context.allocator,
) -> Settings {
	s := make(Settings, 128, allocator)
	for d in DEFAULTS {
		if writer not_in d.writers do continue
		switch v in d.value {
		case None:
			s[d.name] = v
		case bool:
			s[d.name] = v
		case int:
			s[d.name] = v
		case string:
			s[d.name] = v
		case List_Text:
			s[d.name] = strings.split(v.items, ",", allocator)
		}
	}
	if writer == .Html5 {
		html_dir := strings.concatenate({docutils_dir, "/writers/html5_polyglot"}, allocator)
		dirs := make([]string, 2, allocator)
		dirs[0], dirs[1] = ".", html_dir
		s["stylesheet_dirs"] = dirs
	}
	return s
}

// Is ``name`` a setting of the writer (or a general one)?
is_setting :: proc(writer: wr.Writer_Name, name: string) -> bool {
	for d in DEFAULTS {
		if d.name == name && writer in d.writers do return true
	}
	return false
}

// ``settings_overrides``: each override replaces the setting (validated
// if it is a string of a setting with a validator).  ``err`` is the
// validator's error, ``bad`` the override.
apply_overrides :: proc(
	s: ^Settings,
	writer: wr.Writer_Name,
	overrides: []Override,
	allocator := context.allocator,
) -> (
	err: string,
	bad: Override,
) {
	for o in overrides {
		text, is_text := o.value.(string)
		if is_text && validator_of(o.name, writer) != .None {
			if e := set_validated(s, writer, o.name, text, allocator); e != "" do return e, o
			continue
		}
		s[o.name] = o.value
	}
	return "", {}
}

// --- conversions ---------------------------------------------------------------------

// Python truthiness.
truthy :: proc(v: Value) -> bool {
	switch x in v {
	case None:
		return false
	case bool:
		return x
	case int:
		return x != 0
	case string:
		return x != ""
	case []string:
		return len(x) > 0
	}
	return false
}

// The settings as a JSON object (``Doc.interchange.settings``).
to_json :: proc(s: Settings, allocator := context.allocator) -> json.Object {
	obj := make(json.Object, len(s) + 8, allocator)
	for name, v in s {
		obj[name] = json_value(v, allocator)
	}
	return obj
}

@(private = "file")
json_value :: proc(v: Value, allocator := context.allocator) -> json.Value {
	switch x in v {
	case None:
		return json.Null{}
	case bool:
		return json.Boolean(x)
	case int:
		return json.Integer(x)
	case string:
		return json.String(x)
	case []string:
		arr := make(json.Array, len(x), allocator)
		for item, i in x do arr[i] = json.String(item)
		return arr
	}
	return json.Null{}
}

// The ``doctree.Settings`` of the settings: ``None`` and ``False`` become
// "", 0, false or an empty list (as ``doctree.load_json`` converts a dump).
to_doctree :: proc(s: Settings, allocator := context.allocator) -> dt.Settings {
	out := dt.default_settings()
	for f in reflect.struct_fields_zipped(dt.Settings) {
		v, present := s[f.name]
		if !present do continue
		ptr := rawptr(uintptr(&out) + f.offset)
		switch f.type.id {
		case int:
			(^int)(ptr)^ = as_int(v)
		case bool:
			(^bool)(ptr)^ = truthy(v)
		case string:
			(^string)(ptr)^ = as_string(v, allocator)
		case []string:
			(^[]string)(ptr)^ = as_list(v, allocator)
		}
	}
	if q, ok := s["smart_quotes"].(string); ok {
		out.smart_quotes_alt = strings.has_prefix(q, "alt")
	}
	out.warning_stream = .Collect
	return out
}

as_int :: proc(v: Value) -> int {
	#partial switch x in v {
	case int:
		return x
	case bool:
		return 1 if x else 0
	case string:
		n, _ := strconv.parse_int(x, 10) // "auto" (``initial_header_level``): 0
		return n
	}
	return 0
}

as_string :: proc(v: Value, allocator := context.allocator) -> string {
	#partial switch x in v {
	case string:
		return x
	case int:
		return int_text(x, allocator)
	case bool:
		return "True" if x else ""
	case []string:
		return strings.join(x, ",", allocator)
	}
	return ""
}

@(private = "file")
as_list :: proc(v: Value, allocator := context.allocator) -> []string {
	#partial switch x in v {
	case []string:
		return x
	case string:
		if x == "" do return nil
		out := make([]string, 1, allocator)
		out[0] = x
		return out
	}
	return nil
}

int_text :: proc(n: int, allocator := context.allocator) -> string {
	buf: [32]u8
	return strings.clone(strconv.write_int(buf[:], i64(n), 10), allocator)
}
