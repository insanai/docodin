package doctree

import "core:fmt"
import "core:strconv"
import "core:strings"

// ``nodes.ATTRIBUTE_VALIDATORS``: convert and check attribute values.
// ``validate_value`` returns the normalized value or the text of the
// exception docutils raises (``ValueError``/``TypeError``).

@(private = "file")
Validator :: enum u8 {
	Str,
	Int,
	Yesorno,
	Identifier,
	Identifier_List,
	Nmtoken,
	Refname_List,
	Name,
	Measure,
	Colwidth,
	Keyword,
}

@(private = "file")
validator_of :: proc(key: string) -> (Validator, []string) {
	switch key {
	case "alt", "align", "auto", "bullet", "char", "content", "delimiter", "format",
	     "http-equiv", "lang", "media", "prefix", "refuri", "scheme", "source", "suffix",
	     "title", "uri":
		return .Str, nil
	case "anonymous", "colsep", "ltrim", "pgwide", "rowsep", "rtrim", "stub":
		return .Yesorno, nil
	case "backrefs", "classes", "ids":
		return .Identifier_List, nil
	case "charoff", "colname", "namest", "nameend", "type":
		return .Nmtoken, nil
	case "colnum", "cols", "level", "line", "morecols", "morerows", "scale", "start":
		return .Int, nil
	case "dupnames", "names":
		return .Refname_List, nil
	case "height", "width":
		return .Measure, nil
	case "name", "refname":
		return .Name, nil
	case "refid":
		return .Identifier, nil
	case "colwidth":
		return .Colwidth, nil
	}
	return .Keyword, keywords_of(key)
}

@(private = "file")
KW_DIR := [?]string{"ltr", "rtl", "auto"}
@(private = "file")
KW_ENUMTYPE := [?]string{"arabic", "loweralpha", "lowerroman", "upperalpha", "upperroman"}
@(private = "file")
KW_FRAME := [?]string{"top", "bottom", "topbot", "all", "sides", "none"}
@(private = "file")
KW_LOADING := [?]string{"embed", "link", "lazy"}
@(private = "file")
KW_VALIGN := [?]string{"top", "middle", "bottom"}
@(private = "file")
KW_XML_SPACE := [?]string{"default", "preserve"}

@(private = "file")
keywords_of :: proc(key: string) -> []string {
	switch key {
	case "dir":
		return KW_DIR[:]
	case "enumtype":
		return KW_ENUMTYPE[:]
	case "frame":
		return KW_FRAME[:]
	case "loading":
		return KW_LOADING[:]
	case "valign":
		return KW_VALIGN[:]
	case "xml:space":
		return KW_XML_SPACE[:]
	}
	return nil
}

@(private = "file")
py_type_name :: proc(v: Attr_Value) -> string {
	switch _ in v {
	case string:
		return "str"
	case int:
		return "int"
	case bool:
		return "bool"
	case List:
		return "list"
	case Attr_None:
		return "NoneType"
	}
	return "NoneType"
}

// The ``TypeError`` of ``re`` functions called with a non-string.
@(private = "file")
not_a_string :: proc(v: Attr_Value) -> string {
	return fmt.tprintf("expected string or bytes-like object, got '%s'", py_type_name(v))
}

@(private = "file")
py_str :: proc(doc: ^Doc, v: Attr_Value) -> string {
	b := strings.builder_make(context.temp_allocator)
	write_py_str(&b, doc, v)
	return strings.to_string(b)
}

@(private = "file")
py_repr :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	write_py_repr(&b, s)
	return strings.to_string(b)
}

// Validate and normalize the value of attribute ``key``; ``err`` is the
// exception message, "" if the value is valid.
validate_value :: proc(doc: ^Doc, key: string, v: Attr_Value) -> (out: Attr_Value, err: string) {
	kind, keywords := validator_of(key)
	switch kind {
	case .Str:
		return clone(doc, py_str(doc, v)), ""
	case .Int:
		return to_int(doc, v)
	case .Yesorno:
		s, is_str := v.(string)
		return !(is_str && s == "0") && attr_truthy(doc, v), ""
	case .Identifier, .Name:
		return check_identifier(doc, kind, v)
	case .Identifier_List, .Refname_List:
		return check_name_list(doc, kind, v)
	case .Nmtoken:
		return check_nmtoken(v)
	case .Measure:
		return validate_measure(doc, v)
	case .Colwidth:
		return validate_colwidth(doc, v)
	case .Keyword:
		return check_keyword(doc, v, keywords)
	}
	return v, ""
}

// ``nodes.validate_NMTOKEN``.
@(private = "file")
check_nmtoken :: proc(v: Attr_Value) -> (Attr_Value, string) {
	s, is_str := v.(string)
	if !is_str do return v, not_a_string(v)
	if !is_nmtoken(s) do return v, fmt.tprintf("\"%s\" is no NMTOKEN.", s)
	return v, ""
}

// ``nodes.create_keyword_validator(*keywords)``.
@(private = "file")
check_keyword :: proc(doc: ^Doc, v: Attr_Value, keywords: []string) -> (Attr_Value, string) {
	if keywords == nil do return v, "" // no validator known
	s, _ := v.(string)
	if contains_string(keywords, s) do return v, ""
	allowed := strings.join(keywords, "\", \"", context.temp_allocator)
	return v, fmt.tprintf("\"%s\" is not one of \"%s\".", py_str(doc, v), allowed)
}

@(private = "file")
to_int :: proc(doc: ^Doc, v: Attr_Value) -> (Attr_Value, string) {
	switch x in v {
	case int:
		return x, ""
	case bool:
		return 1 if x else 0, ""
	case string:
		if i, ok := py_parse_int(x); ok do return i, ""
		return v, fmt.tprintf("invalid literal for int() with base 10: %s", py_repr(x))
	case List, Attr_None:
	}
	msg := "int() argument must be a string, a bytes-like object or a real number, not '%s'"
	return v, fmt.tprintf(msg, py_type_name(v))
}

// ``int(s)`` for ASCII digits (surrounding whitespace, a sign and
// underscores between digits allowed).
py_parse_int :: proc(s: string) -> (int, bool) {
	t := strings.trim_right_proc(strings.trim_left_proc(s, py_isspace), py_isspace)
	neg := strings.has_prefix(t, "-")
	if neg || strings.has_prefix(t, "+") do t = t[1:]
	if strings.has_prefix(t, "_") || strings.has_suffix(t, "_") || strings.contains(t, "__") {
		return 0, false
	}
	digits, _ := strings.remove_all(t, "_", context.temp_allocator)
	if len(digits) == 0 do return 0, false
	value := 0
	for c in transmute([]u8)digits {
		if c < '0' || c > '9' do return 0, false
		value = value * 10 + int(c - '0')
	}
	return -value if neg else value, true
}

@(private = "file")
check_identifier :: proc(doc: ^Doc, kind: Validator, v: Attr_Value) -> (Attr_Value, string) {
	s, is_str := v.(string)
	if !is_str do return v, "" // Python raises AttributeError (not a validation error)
	if kind == .Name do return clone(doc, whitespace_normalize_name(s)), ""
	if s != make_id(s) do return v, fmt.tprintf("\"%s\" is no valid id or class name.", s)
	return v, ""
}

@(private = "file")
check_name_list :: proc(doc: ^Doc, kind: Validator, v: Attr_Value) -> (Attr_Value, string) {
	items: []string
	switch x in v {
	case string:
		items = kind == .Identifier_List ? py_split(x) : split_name_list(x)
	case List:
		items = make([]string, len(doc.lists[x]), context.temp_allocator)
		for s, i in doc.lists[x] do items[i] = str(doc, s)
	case int, bool, Attr_None:
		return v, fmt.tprintf("'%s' object is not iterable", py_type_name(v))
	}
	for &s in items {
		if kind == .Refname_List {
			s = whitespace_normalize_name(s)
		} else if s != make_id(s) {
			return v, fmt.tprintf("\"%s\" is no valid id or class name.", s)
		}
	}
	if l, is_list := v.(List); is_list && kind == .Identifier_List do return l, ""
	return new_list(doc, ..items), ""
}

@(private = "file")
is_nmtoken :: proc(s: string) -> bool {
	if len(s) == 0 do return false
	for i in 0 ..< len(s) {
		c := s[i]
		ok := c == '-' || c == '.' || c == '_' || (c >= '0' && c <= '9')
		ok ||= (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
		if !ok do return false
	}
	return true
}

// ``nodes.parse_measure``: the number and unit of a measure; ``star_unit``
// selects the colwidth unit pattern ``[*]?``.
@(private = "file")
parse_measure :: proc(m: string, star_unit: bool) -> (num: Attr_Value, unit: string, ok: bool) {
	i := 0
	if i < len(m) && m[i] == '-' do i += 1
	for i < len(m) && ((m[i] >= '0' && m[i] <= '9') || m[i] == '.') do i += 1
	number := m[:i]
	for i < len(m) && m[i] == ' ' do i += 1
	unit = m[i:]
	if !valid_unit(unit, star_unit) || len(strings.trim_prefix(number, "-")) == 0 do return
	num = py_number(number) or_return
	return num, unit, true
}

@(private = "file")
valid_unit :: proc(unit: string, star_unit: bool) -> bool {
	if star_unit do return unit == "" || unit == "*"
	if unit == "%" do return true
	for r in unit {
		if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || r == 0xB5) do return false
	}
	return true
}

// ``int(s)``, else ``float(s)`` (as the string ``repr(float)``).
@(private = "file")
py_number :: proc(s: string) -> (Attr_Value, bool) {
	if !strings.contains_rune(s, '.') {
		i, ok := py_parse_int(s)
		return i, ok
	}
	if strings.count(s, ".") > 1 || s == "." || s == "-." do return nil, false
	f, ok := strconv.parse_f64(s)
	if !ok do return nil, false
	return py_float_repr(f), true
}

// ``repr(f)`` of a Python float.
py_float_repr :: proc(f: f64, allocator := context.temp_allocator) -> string {
	buf: [64]u8
	e := strconv.write_float(buf[:], f, 'e', -1, 64) // "+d.ddde+XX"
	neg := e[0] == '-'
	mant, _, exp_s := strings.partition(e[1:], "e")
	digits, _ := strings.remove_all(mant, ".", context.temp_allocator)
	exp, _ := strconv.parse_int(exp_s)
	b := strings.builder_make(allocator)
	if neg do strings.write_byte(&b, '-')
	if exp < -4 || exp >= 16 {
		strings.write_byte(&b, digits[0])
		if len(digits) > 1 do fmt.sbprintf(&b, ".%s", digits[1:])
		fmt.sbprintf(&b, "e%s%02d", "-" if exp < 0 else "+", abs(exp))
	} else if exp < 0 {
		strings.write_string(&b, "0.")
		for _ in 0 ..< -exp - 1 do strings.write_byte(&b, '0')
		strings.write_string(&b, digits)
	} else {
		for k in 0 ..= exp do strings.write_byte(&b, k < len(digits) ? digits[k] : '0')
		strings.write_byte(&b, '.')
		strings.write_string(&b, digits[exp + 1:] if exp + 1 < len(digits) else "0")
	}
	return strings.to_string(b)
}

// ``nodes.validate_measure``.
@(private = "file")
validate_measure :: proc(doc: ^Doc, v: Attr_Value) -> (Attr_Value, string) {
	s, is_str := v.(string)
	if !is_str do return v, not_a_string(v)
	num, unit, ok := parse_measure(s, false)
	if !ok do return v, fmt.tprintf("\"%s\" is no valid measure.", s)
	return clone(doc, fmt.tprintf("%s%s", py_str(doc, num), unit)), ""
}

// ``nodes.validate_colwidth``: a positive number (floats as their repr).
@(private = "file")
validate_colwidth :: proc(doc: ^Doc, v: Attr_Value) -> (Attr_Value, string) {
	value: Attr_Value = -1
	switch x in v {
	case int:
		value = x
	case bool:
		value = 1 if x else 0
	case string:
		if x == "*" || x == "" {
			value = 1
		} else if num, _, ok := parse_measure(x, true); ok {
			value = num
		}
	case List, Attr_None:
		msg := "'<=' not supported between instances of '%s' and 'int'"
		return v, fmt.tprintf(msg, py_type_name(v))
	}
	positive := false
	#partial switch x in value {
	case int:
		positive = x > 0
	case string:
		positive = !strings.has_prefix(x, "-") && strings.trim(x, "0.") != ""
		value = clone(doc, x)
	}
	if !positive do return v, fmt.tprintf("\"%s\" is no proportional measure.", py_str(doc, v))
	return value, ""
}
