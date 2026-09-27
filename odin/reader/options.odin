package reader

import "core:strings"

import dt "../doctree"
import rst "../rst"

// Directive options: the values and the conversion functions of
// ``docutils.parsers.rst.directives``.  A converter returns the value, or
// the text of the ``ValueError``/``TypeError`` docutils raises.

// Python ``None`` (a flag option).
Opt_None :: struct {}

Option_Value :: union {
	string,
	int,
	[]string,
	Opt_None,
}

Option :: struct {
	name:  string,
	value: Option_Value,
}

// An ordered option dictionary.
Options :: [dynamic]Option

// ``argument`` is nil for an option without value (Python ``None``).
Converter :: proc(c: ^Context, argument: Maybe(string)) -> (value: Option_Value, err: string)

Option_Spec :: struct {
	name:    string,
	convert: Converter,
}

options_get :: proc(opts: ^Options, name: string) -> (Option_Value, bool) {
	if opts == nil do return nil, false
	for o in opts do if o.name == name do return o.value, true
	return nil, false
}

options_has :: proc(opts: ^Options, name: string) -> bool {
	_, ok := options_get(opts, name)
	return ok
}

// ``options[name] = value`` (keeps the position of an existing key).
options_set :: proc(opts: ^Options, name: string, value: Option_Value) {
	for &o in opts {
		if o.name == name {
			o.value = value
			return
		}
	}
	append(opts, Option{name, value})
}

// ``options.pop(name)``.
options_pop :: proc(opts: ^Options, name: string) -> (Option_Value, bool) {
	for o, i in opts {
		if o.name == name {
			ordered_remove(opts, i)
			return o.value, true
		}
	}
	return nil, false
}

// The string value of an option ("" if missing or not a string).
options_string :: proc(opts: ^Options, name: string) -> string {
	v, _ := options_get(opts, name)
	s, _ := v.(string)
	return s
}

// The list value of an option (``options.get(name, [])``).
options_list :: proc(opts: ^Options, name: string) -> []string {
	v, _ := options_get(opts, name)
	l, _ := v.([]string)
	return l
}

// Python ``repr`` of an option value.
write_option_repr :: proc(b: ^strings.Builder, v: Option_Value) {
	switch x in v {
	case string:
		dt.write_py_repr(b, x)
	case int:
		dt.write_int(b, x)
	case []string:
		strings.write_byte(b, '[')
		for s, i in x {
			if i > 0 do strings.write_string(b, ", ")
			dt.write_py_repr(b, s)
		}
		strings.write_byte(b, ']')
	case Opt_None:
		strings.write_string(b, "None")
	case:
		strings.write_string(b, "None")
	}
}

// --- converters ---------------------------------------------------------------------

REQUIRED :: "argument required but none supplied"

flag :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	if a, ok := argument.?; ok && !is_blank(a) {
		return nil, concat("no argument is allowed; \"", a, "\" supplied")
	}
	return Opt_None{}, ""
}

unchanged_required :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	a, ok := argument.?
	if !ok do return nil, REQUIRED
	return a, ""
}

unchanged :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	return argument.? or_else "", ""
}

// ``directives.path``: the lines stripped and joined.
path :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	a, ok := argument.?
	if !ok do return nil, REQUIRED
	b := strings.builder_make(c.allocator)
	for l in dt.py_splitlines(a) do strings.write_string(&b, strip(l))
	return strings.to_string(b), ""
}

// ``directives.uri``: unescaped whitespace removed.
uri :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	a, ok := argument.?
	if !ok do return nil, REQUIRED
	parts := rst.split_escaped_whitespace(rst.escape2null(a, c.allocator), c.allocator)
	b := strings.builder_make(c.allocator)
	for part, i in parts {
		if i > 0 do strings.write_byte(&b, ' ')
		for w in dt.py_split(dt.unescape(part)) do strings.write_string(&b, w)
	}
	return strings.to_string(b), ""
}

// Python ``int(argument)``.
py_int_arg :: proc(argument: Maybe(string)) -> (int, string) {
	a, ok := argument.?
	if !ok {
		return 0, concat(
			"int() argument must be a string, a bytes-like object or a real number, ",
			"not 'NoneType'",
		)
	}
	v, valid := dt.py_parse_int(a)
	if !valid do return 0, concat("invalid literal for int() with base 10: ", py_repr(a))
	return v, ""
}

int_option :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	v, err := py_int_arg(argument)
	if err != "" do return nil, err
	return v, ""
}

nonnegative_int :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	v, err := py_int_arg(argument)
	if err != "" do return nil, err
	if v < 0 do return nil, "negative value; must be positive or zero"
	return v, ""
}

class_option :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	a, ok := argument.?
	if !ok do return nil, REQUIRED
	names := dt.py_split(a, c.allocator)
	classes := make([dynamic]string, 0, len(names), c.allocator)
	for name in names {
		class_name := dt.make_id(name, c.allocator)
		if class_name == "" do return nil, concat("cannot make \"", name, "\" into a class name")
		append(&classes, class_name)
	}
	return classes[:], ""
}

// ``directives.encoding``: known to Python's codecs.
encoding :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	a, ok := argument.?
	if !ok do return nil, "lookup() argument must be str, not None"
	if normalize_encoding(a) == "" do return nil, concat("unknown encoding: \"", a, "\"")
	return a, ""
}

// ``directives.value_or((None,), int)`` (``include``'s "number-lines").
none_or_int :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	if argument == nil do return Opt_None{}, ""
	return int_option(c, argument)
}

// ``directives.parser_name``: only the reStructuredText parser is native.
parser_name :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	a := argument.? or_else ""
	if a == "" do return Opt_None{}, ""
	switch dt.py_lower(a, c.allocator) {
	case "rst", "restructuredtext", "rest", "restx", "rtxt", "rstx":
		return "rst", ""
	}
	return nil, concat("Parser \"", a, "\" not found. No module named '", a, "'")
}

// ``Contents.backlinks``: ``choice(arg, ('top', 'entry', 'none'))``.
backlinks :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	values := "\"top\", \"entry\", or \"none\""
	a, ok := argument.?
	if !ok do return nil, concat("must supply an argument; choose from ", values)
	value := strip(dt.py_lower(a, c.allocator))
	switch value {
	case "top", "entry":
		return value, ""
	case "none":
		return Opt_None{}, ""
	}
	return nil, concat("\"", a, "\" unknown; choose from ", values)
}

// The codec name of a Python encoding name ("" if unknown): the encodings
// the native reader decodes.
normalize_encoding :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in dt.py_lower(name) {
		strings.write_rune(&b, '_' if r == ' ' || r == '-' else r)
	}
	switch strings.to_string(b) {
	case "utf_8", "utf8", "u8", "utf", "utf8_ucs2", "utf8_ucs4", "cp65001":
		return "utf-8"
	case "utf_8_sig", "utf8_sig":
		return "utf-8-sig"
	case "latin_1", "latin1", "latin", "l1", "iso_8859_1", "iso8859_1", "8859", "cp819",
	     "iso_ir_100", "iso_8859_1:1987", "csisolatin1":
		return "latin-1"
	case "ascii", "us_ascii", "646", "us", "ansi_x3.4_1968", "cp367", "csascii", "ibm367",
	     "iso646_us", "iso_646.irv:1991", "iso_ir_6":
		return "ascii"
	}
	return ""
}
