package publish

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

import dt "../doctree"
import wr "../writers"

// The option validators of ``docutils.frontend``: they convert a string
// (from the command line or a configuration file) into the setting's value.

Validator :: enum u8 {
	None,
	Boolean, // ``validate_boolean``
	Ternary, // ``validate_ternary``
	Threshold, // ``validate_threshold``
	Nonnegative_Int, // ``validate_nonnegative_int``
	Encoding, // ``validate_encoding_and_error_handler``
	Error_Handler, // ``validate_encoding_error_handler``
	Comma_List, // ``validate_comma_separated_list``
	Colon_List, // ``validate_colon_separated_string_list``
	Strip_Class, // ``validate_strip_class``
	Smartquotes_Locales, // ``validate_smartquotes_locales``
	Url_Trailing_Slash, // ``validate_url_trailing_slash``
	Math_Output, // ``validate_math_output`` (the string is kept)
}

@(private = "file")
Validated :: struct {
	name:      string,
	validator: Validator,
}

@(private = "file")
VALIDATED := [?]Validated {
	{"report_level", .Threshold},
	{"halt_level", .Threshold},
	{"exit_status_level", .Threshold},
	{"tab_width", .Nonnegative_Int},
	{"line_length_limit", .Nonnegative_Int},
	{"input_encoding", .Encoding},
	{"output_encoding", .Encoding},
	{"error_encoding", .Encoding},
	{"input_encoding_error_handler", .Error_Handler},
	{"output_encoding_error_handler", .Error_Handler},
	{"error_encoding_error_handler", .Error_Handler},
	{"stylesheet", .Comma_List},
	{"stylesheet_path", .Comma_List},
	{"stylesheet_dirs", .Comma_List},
	{"use_bibtex", .Comma_List},
	{"expose_internals", .Colon_List},
	{"strip_elements_with_classes", .Strip_Class},
	{"strip_classes", .Strip_Class},
	{"smart_quotes", .Ternary},
	{"smartquotes_locales", .Smartquotes_Locales},
	{"pep_base_url", .Url_Trailing_Slash},
	{"rfc_base_url", .Url_Trailing_Slash},
	{"math_output", .Math_Output},
}

// The ``validate_boolean`` settings.
@(private = "file")
BOOLEANS := [?]string {
	"cloak_email_addresses", "compact_field_lists", "compact_lists", "compound_enumerators",
	"debug", "detailed", "docinfo_xform", "doctitle_xform", "doctype_declaration",
	"docutils_footnotes", "embed_images", "embed_stylesheet", "file_insertion_enabled",
	"footnote_backlinks", "generator", "indents", "legacy_class_functions",
	"legacy_column_widths", "newlines", "pep_references", "raw_enabled", "rfc_references",
	"section_prefix_for_enumerators", "sectnum_xform", "sectsubtitle_xform", "source_link",
	"strip_comments", "traceback", "trim_footnote_reference_space", "use_latex_abstract",
	"use_latex_citations", "use_latex_docinfo", "use_latex_toc", "use_part_section",
	"use_verbatim_when_possible", "validate", "xml_declaration",
}

// The validator of setting ``name`` of ``writer``.
validator_of :: proc(name: string, writer: wr.Writer_Name) -> Validator {
	// the html5 ``table_style`` is a plain string, the LaTeX one a list
	if name == "table_style" do return .Comma_List if writer in LATEX_WRITERS else .None
	for v in VALIDATED {
		if v.name == name do return v.validator
	}
	for b in BOOLEANS {
		if b == name do return .Boolean
	}
	return .None
}

LATEX_WRITERS :: bit_set[wr.Writer_Name]{.Latex, .Xetex}

// Set ``name`` to ``text`` converted by its validator; the error text of
// the validator on failure.  An error handler given with an encoding
// ("name:handler") also sets the ``<name>_error_handler`` setting.
set_validated :: proc(
	s: ^Settings,
	writer: wr.Writer_Name,
	name, text: string,
	allocator := context.allocator,
) -> string {
	v := validator_of(name, writer)
	if v == .Encoding {
		encoding, colon, handler := strings.partition(text, ":")
		if colon != "" {
			if strings.contains_rune(handler, ':') {
				return "ValueError: too many values to unpack (expected 2)"
			}
			if err := check_error_handler(handler); err != "" do return err
			key := strings.concatenate({name, "_error_handler"}, allocator)
			s[key] = handler
		}
		if err := check_encoding(encoding); err != "" do return err
		s[name] = encoding
		return ""
	}
	value, err := validate(v, text, allocator)
	if err == "" do s[name] = value
	return err
}

// ``validator(setting, text)``: the converted value, or the error text.
validate :: proc(v: Validator, text: string, allocator := context.allocator) -> (Value, string) {
	return VALIDATE[v](text, allocator)
}

@(private = "file")
Validate_Proc :: proc(text: string, allocator: runtime.Allocator) -> (Value, string)

@(private = "file", rodata)
VALIDATE := [Validator]Validate_Proc {
	.None                = proc(text: string, _: runtime.Allocator) -> (Value, string) {
		return text, ""
	},
	.Boolean             = validate_boolean,
	.Ternary             = proc(text: string, _: runtime.Allocator) -> (Value, string) {
		if b, ok := parse_boolean(text); ok do return b, ""
		return text, ""
	},
	.Threshold           = proc(text: string, _: runtime.Allocator) -> (Value, string) {
		return parse_threshold(text)
	},
	.Nonnegative_Int     = parse_nonnegative,
	.Encoding            = proc(text: string, _: runtime.Allocator) -> (Value, string) {
		return text, check_encoding(text)
	},
	.Error_Handler       = proc(text: string, _: runtime.Allocator) -> (Value, string) {
		return text, check_error_handler(text)
	},
	.Comma_List          = proc(text: string, a: runtime.Allocator) -> (Value, string) {
		return comma_list(text, a), ""
	},
	.Colon_List          = proc(text: string, a: runtime.Allocator) -> (Value, string) {
		return strings.split(text, ":", a), ""
	},
	.Strip_Class         = strip_classes,
	.Smartquotes_Locales = smartquotes_locales,
	.Url_Trailing_Slash  = url_trailing_slash,
	.Math_Output         = proc(text: string, _: runtime.Allocator) -> (Value, string) {
		return text, check_math_output(text)
	},
}

@(private = "file")
validate_boolean :: proc(text: string, _: runtime.Allocator) -> (Value, string) {
	b, ok := parse_boolean(text)
	if !ok do return nil, fmt.aprintf(`LookupError: unknown boolean value: "%s"`, text)
	return b, ""
}

@(private = "file")
url_trailing_slash :: proc(text: string, allocator: runtime.Allocator) -> (Value, string) {
	if text == "" do return "./", ""
	if strings.has_suffix(text, "/") do return text, ""
	return strings.concatenate({text, "/"}, allocator), ""
}

// ``OptionParser.booleans``.
parse_boolean :: proc(text: string) -> (bool, bool) {
	switch dt.py_lower(strings.trim_space(text)) {
	case "1", "on", "yes", "true":
		return true, true
	case "0", "off", "no", "false", "":
		return false, true
	}
	return false, false
}

// ``validate_threshold``: a number or a level name.
parse_threshold :: proc(text: string) -> (Value, string) {
	if n, ok := py_int(text); ok do return n, ""
	switch dt.py_lower(text) {
	case "info":
		return 1, ""
	case "warning":
		return 2, ""
	case "error":
		return 3, ""
	case "severe":
		return 4, ""
	case "none":
		return 5, ""
	}
	return nil, fmt.aprintf("LookupError: unknown threshold: %s.", py_repr(text))
}

@(private = "file")
parse_nonnegative :: proc(text: string, _: runtime.Allocator) -> (Value, string) {
	n, ok := py_int(text)
	if !ok {
		return nil, fmt.aprintf(
			"ValueError: invalid literal for int() with base 10: %s",
			py_repr(text),
		)
	}
	if n < 0 do return nil, "ValueError: negative value; must be positive or zero"
	return n, ""
}

// ``int(text)`` of a decimal string (surrounding whitespace, a sign and
// underscores between digits are allowed).
py_int :: proc(text: string) -> (int, bool) {
	t := strings.trim_space(text)
	if t == "" || strings.has_prefix(t, "_") || strings.has_suffix(t, "_") do return 0, false
	if strings.contains(t, "__") do return 0, false
	return strconv.parse_int(t, 10)
}

// ``repr(text)``.
py_repr :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	dt.write_py_repr(&b, text)
	return strings.to_string(b)
}

// ``validate_comma_separated_list``: items split at commas, stripped of
// spaces, tabs and newlines; empty items are dropped.
comma_list :: proc(text: string, allocator := context.allocator) -> []string {
	items := make([dynamic]string, 0, 4, allocator)
	rest := text
	for item in strings.split_iterator(&rest, ",") {
		s := strings.trim(item, " \t\n")
		if s != "" do append(&items, s)
	}
	return items[:]
}

@(private = "file")
strip_classes :: proc(text: string, allocator: runtime.Allocator) -> (Value, string) {
	items := comma_list(text, allocator)
	for cls in items {
		if normalized := dt.make_id(cls); normalized != cls {
			msg := "ValueError: Invalid class value %s (perhaps %s?)"
			return nil, fmt.aprintf(msg, py_repr(cls), py_repr(normalized))
		}
	}
	return items, ""
}

// ``validate_smartquotes_locales``: "language:quotes" items with four
// quote characters or four colon-separated quotes.
@(private = "file")
smartquotes_locales :: proc(text: string, allocator: runtime.Allocator) -> (Value, string) {
	items := comma_list(text, allocator)
	for &item in items {
		colon := strings.index_byte(item, ':')
		if colon < 0 {
			msg := `ValueError: Invalid value "%s". Format is "<language>:<quotes>".`
			return nil, fmt.aprintf(msg, item)
		}
		quotes := strings.trim_space(item[colon + 1:])
		if strings.count(quotes, ":") != 3 && utf8.rune_count_in_string(quotes) != 4 {
			msg := "ValueError: Invalid value \"%s\". Please specify 4 quotes\n" +
				"    (primary open/close; secondary open/close)."
			return nil, fmt.aprintf(msg, item)
		}
		item = strings.concatenate({item[:colon], ":", quotes}, allocator)
	}
	return items, ""
}

@(private = "file")
check_math_output :: proc(text: string) -> string {
	if strings.trim_space(text) == "" do return ""
	format, _, options := strings.partition(strings.trim_left_space(text), " ")
	switch dt.py_lower(format) {
	case "html", "latex", "mathjax":
		return ""
	case "mathml":
		switch dt.py_lower(strings.trim_space(options)) {
		case "", "latexml", "ttm", "blahtexml", "pandoc":
			return ""
		}
		msg := "LookupError: MathML converter \"%s\" not supported,\n" +
			"    choose from ('', 'latexml', 'ttm', 'blahtexml', 'pandoc')."
		return fmt.aprintf(msg, strings.trim_space(options))
	}
	msg := "LookupError: Unknown math output format: \"%s\",\n" +
		"    choose from ('html', 'latex', 'mathml', 'mathjax')."
	return fmt.aprintf(msg, text)
}

// ``codecs.lookup(encoding)`` for the codecs docodin can encode and
// decode.
check_encoding :: proc(encoding: string) -> string {
	// "unicode": no encoding (``Output.encode`` returns the text)
	if codec_of(encoding) != .Unknown || encoding == "unicode" do return ""
	msg := "LookupError: unknown encoding: \"%s\" (docodin supports utf-8, utf-8-sig, " +
		"utf-16, utf-32, ascii and latin-1)"
	return fmt.aprintf(msg, encoding)
}

// ``codecs.lookup_error(handler)``.
check_error_handler :: proc(handler: string) -> string {
	switch handler {
	case "strict", "ignore", "replace", "backslashreplace", "xmlcharrefreplace",
	     "namereplace", "surrogateescape", "surrogatepass":
		return ""
	}
	msg := "LookupError: unknown encoding error handler: \"%s\" (choices: \"strict\", " +
		"\"ignore\", \"replace\", \"backslashreplace\", \"xmlcharrefreplace\", and possibly " +
		"others; see documentation for the Python ``codecs`` module)"
	return fmt.aprintf(msg, handler)
}
