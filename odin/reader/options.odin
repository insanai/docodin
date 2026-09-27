package reader

import "core:strconv"
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
	[]int,
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
	case []int:
		strings.write_byte(b, '[')
		for n, i in x {
			if i > 0 do strings.write_string(b, ", ")
			dt.write_int(b, n)
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

// ``directives.choice(argument, values)``: the lower-cased value.
choice :: proc(c: ^Context, argument: Maybe(string), values: []string) -> (Option_Value, string) {
	b := strings.builder_make(c.allocator)
	for v, i in values {
		switch {
		case i == 0:
		case i == len(values) - 1:
			strings.write_string(&b, ", or ")
		case:
			strings.write_string(&b, ", ")
		}
		strings.write_byte(&b, '"')
		strings.write_string(&b, v)
		strings.write_byte(&b, '"')
	}
	formatted := strings.to_string(b)
	a, ok := argument.?
	if !ok do return nil, concat("must supply an argument; choose from ", formatted)
	value := strip(dt.py_lower(a, c.allocator))
	if contains(values, value) do return value, ""
	return nil, concat("\"", a, "\" unknown; choose from ", formatted)
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

// --- measures -------------------------------------------------------------------------

@(private = "file")
CSS3_UNITS := [?]string {
	"em", "ex", "ch", "rem", "vw", "vh", "vmin", "vmax", "cm", "mm", "Q", "in", "pt", "pc", "px",
}

// ``nodes.parse_measure``: ``(-?[0-9.]+) *([a-zA-Zµ]*|%?)`` fully matched;
// the value as Python ``str()`` of the int or float.
parse_measure :: proc(measure: string) -> (value: string, negative: bool, unit: string, ok: bool) {
	number: string
	number, unit = split_measure(measure)
	if strings.trim_prefix(number, "-") == "" || !measure_unit(unit) do return
	if n, is_int := dt.py_parse_int(number); is_int && strings.index_byte(number, '.') < 0 {
		return itoa(n), n < 0, unit, true
	}
	f, is_float := strconv.parse_f64(number)
	if !is_float || strings.count(number, ".") != 1 do return
	return dt.py_float_repr(f), f < 0, unit, true
}

// ``-?[0-9.]+`` and the rest after spaces.
@(private = "file")
split_measure :: proc(measure: string) -> (number, unit: string) {
	i := 0
	if i < len(measure) && measure[i] == '-' do i += 1
	for i < len(measure) && (is_digit(measure[i]) || measure[i] == '.') do i += 1
	j := i
	for j < len(measure) && measure[j] == ' ' do j += 1
	return measure[:i], measure[j:]
}

@(private = "file")
is_digit :: #force_inline proc "contextless" (b: u8) -> bool {
	return b >= '0' && b <= '9'
}

@(private = "file")
measure_unit :: proc(unit: string) -> bool {
	if unit == "%" do return true
	for r in unit {
		if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || r == 0xB5) do return false
	}
	return true
}

// ``directives.get_measure(argument, units)``.
get_measure :: proc(argument: string, units: []string) -> (string, string) {
	value, negative, unit, ok := parse_measure(argument)
	if !ok do return "", concat("\"", argument, "\" is no valid measure.")
	if negative || !contains(units, unit) {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(
			&b, "not a positive number or measure of one of the following units:\n",
		)
		k := 0
		for u in units {
			if u == "" do continue
			if k > 0 do strings.write_string(&b, ", ")
			strings.write_string(&b, u)
			k += 1
		}
		return "", strings.to_string(b)
	}
	return concat(value, unit), ""
}

@(private = "file")
NONE_TYPE_ERROR :: "expected string or bytes-like object, got 'NoneType'"

length_or_unitless :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	a, ok := argument.?
	if !ok do return nil, NONE_TYPE_ERROR
	units := make([dynamic]string, c.allocator)
	append(&units, ..CSS3_UNITS[:])
	append(&units, "")
	v, err := get_measure(a, units[:])
	if err != "" do return nil, err
	return v, ""
}

// ``directives.length_or_percentage_or_unitless(argument, default)``.
length_or_percentage :: proc(argument: Maybe(string), default := "") -> (Option_Value, string) {
	a, ok := argument.?
	if !ok do return nil, NONE_TYPE_ERROR
	units := make([dynamic]string, context.temp_allocator)
	append(&units, ..CSS3_UNITS[:])
	append(&units, "%")
	v, err := get_measure(a, units[:])
	if err == "" do return v, ""
	if unitless, err2 := get_measure(a, {""}); err2 == "" do return concat(unitless, default), ""
	return nil, err
}

length_or_percentage_or_unitless :: proc(
	c: ^Context,
	argument: Maybe(string),
) -> (Option_Value, string) {
	return length_or_percentage(argument)
}

// ``directives.percentage``.
percentage :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	a, ok := argument.?
	if !ok do return nonnegative_int(c, nil)
	return nonnegative_int(c, strings.trim_right(a, " %"))
}

// ``directives.value_or(('auto', ...), directives.positive_int_list)``.
widths_option :: proc(
	c: ^Context,
	argument: Maybe(string),
	values: []string,
) -> (Option_Value, string) {
	a, ok := argument.?
	if ok && contains(values, a) do return a, ""
	if !ok do return nil, "argument of type 'NoneType' is not iterable"
	entries: []string
	if strings.index_byte(a, ',') >= 0 {
		entries = strings.split(a, ",", c.allocator)
	} else {
		entries = dt.py_split(a, c.allocator)
	}
	out := make([dynamic]int, 0, len(entries), c.allocator)
	for e in entries {
		v, err := py_int_arg(e)
		if err != "" do return nil, err
		if v < 1 do return nil, "negative or zero value; must be positive"
		append(&out, v)
	}
	return out[:], ""
}

// ``directives.single_char_or_unicode``.
single_char_or_unicode :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	a, given := argument.?
	if !given {
		// ``unicode_code(None)``: not a conversion error (docutils raises)
		raise_exception(c, "AttributeError: 'NoneType' object has no attribute 'isdigit'")
		return Opt_None{}, ""
	}
	char, err := unicode_code(c, a)
	if err != "" do return nil, strings.trim_prefix(err, "ValueError: ")
	if cp_len(char) > 1 do return nil, concat(
		py_repr(char), " invalid; must be a single character or a Unicode code",
	)
	return char, ""
}

// ``directives.single_char_or_whitespace_or_unicode``.
single_char_or_whitespace_or_unicode :: proc(
	c: ^Context,
	argument: Maybe(string),
) -> (Option_Value, string) {
	switch argument.? or_else "" {
	case "tab":
		return "\t", ""
	case "space":
		return " ", ""
	}
	return single_char_or_unicode(c, argument)
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
