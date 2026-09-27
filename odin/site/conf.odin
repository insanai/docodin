package site

import "core:strconv"
import "core:strings"
import "core:time"

// The configuration of a Sphinx project: the module-level assignments of
// ``conf.py`` that are plain values.  ``conf.py`` is not run: statements
// that are not ``NAME = value`` (or ``A = B = value``) with a string,
// number, boolean, None, list, tuple, dict or a name assigned before are
// ignored, as are imports and function calls.  Strings may be adjacent
// literals or joined with ``+``; an f-string takes the values of the names
// it formats, and the current year for an expression mentioning ``year``.

Value :: union {
	string,
	f64,
	bool,
	[]Value, // list or tuple
	Dict,
}

// A ``dict`` literal, in insertion order.
Dict :: struct {
	keys:   []string,
	values: []Value,
}

Conf :: struct {
	values:           map[string]Value,
	project:          string,
	author:           string,
	copyright:        string,
	version:          string,
	release:          string,
	html_title:       string,
	language:         string,
	root_doc:         string,
	today_fmt:        string,
	tagline:          string, // ``docodin_tagline``
	pdf_filename:     string, // ``docodin_pdf_filename``
	latex_engine:     string,
	latex_toplevel:   string, // ``latex_toplevel_sectioning``
	exclude_patterns: []string,
	html_static_path: []string,
	html_logo:        string, // relative to the source directory; "" for docodin's
	templates_path:   []string,
	numfig:           bool,
	part_labels:      bool, // ``docodin_part_labels``
}

// Parse ``conf.py`` text into a ``Conf`` (allocated with ``allocator``).
parse_conf :: proc(text: string, allocator := context.allocator) -> Conf {
	context.allocator = allocator
	p := Conf_Parser {
		text   = text,
		values = make(map[string]Value),
	}
	for p.pos < len(p.text) do parse_statement(&p)
	return conf_from_values(p.values)
}

// The ``Conf`` fields of the values, with Sphinx's defaults.
@(private = "file")
conf_from_values :: proc(values: map[string]Value) -> Conf {
	c := Conf {
		values = values,
	}
	c.project = conf_string(values, "project", "Project name not set")
	c.author = conf_string(values, "author", "")
	c.copyright = conf_string(values, "copyright", "")
	c.version = conf_string(values, "version", "")
	c.release = conf_string(values, "release", c.version)
	c.language = conf_string(values, "language", "en")
	c.root_doc = conf_string(values, "root_doc", conf_string(values, "master_doc", "index"))
	c.today_fmt = conf_string(values, "today_fmt", "%B %d, %Y")
	c.tagline = conf_string(values, "docodin_tagline", "")
	c.latex_engine = conf_string(values, "latex_engine", "lualatex")
	c.latex_toplevel = conf_string(values, "latex_toplevel_sectioning", "")
	default_title := c.project
	if c.release != "" do default_title = strings.concatenate({c.project, " ", c.release})
	c.html_title = conf_string(values, "html_title", default_title)
	c.pdf_filename = conf_string(values, "docodin_pdf_filename", "")
	c.exclude_patterns = conf_strings(values, "exclude_patterns")
	c.html_static_path = conf_strings(values, "html_static_path")
	c.html_logo = conf_string(values, "html_logo", "")
	c.templates_path = conf_strings(values, "templates_path")
	c.numfig = conf_bool(values, "numfig", false)
	c.part_labels = conf_bool(values, "docodin_part_labels", false)
	return c
}

conf_string :: proc(values: map[string]Value, name, default: string) -> string {
	if s, ok := values[name].(string); ok do return s
	return default
}

conf_bool :: proc(values: map[string]Value, name: string, default: bool) -> bool {
	#partial switch v in values[name] {
	case bool:
		return v
	case f64:
		return v != 0
	case string:
		return v != ""
	}
	return default
}

// A list of strings (the strings of a list or tuple value).
conf_strings :: proc(values: map[string]Value, name: string) -> []string {
	list, ok := values[name].([]Value)
	if !ok do return nil
	out := make([dynamic]string, 0, len(list))
	for v in list do if s, is_str := v.(string); is_str do append(&out, s)
	return out[:]
}

// --- the parser ----------------------------------------------------------------------------

@(private = "file")
Conf_Parser :: struct {
	text:   string,
	pos:    int,
	depth:  int, // of brackets around the current expression
	values: map[string]Value,
}

// One logical line: an assignment is recorded, anything else skipped.
@(private = "file")
parse_statement :: proc(p: ^Conf_Parser) {
	skip_blank(p)
	if p.pos >= len(p.text) do return
	start := p.pos
	names := assignment_targets(p)
	if len(names) > 0 {
		if v, ok := parse_expr(p); ok && at_line_end(p) {
			for n in names do p.values[strings.clone(n)] = v
			skip_line(p)
			return
		}
	}
	p.pos = start
	skip_line(p)
}

// The names of ``A = B = ...``, leaving ``p`` at the value.
@(private = "file")
assignment_targets :: proc(p: ^Conf_Parser) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for {
		name := scan_name(p)
		skip_space(p)
		if name == "" || !at(p, '=') || at_str(p, "==") do break
		p.pos += 1
		skip_space(p)
		append(&names, name)
		save := p.pos
		next := scan_name(p)
		skip_space(p)
		chained := next != "" && at(p, '=') && !at_str(p, "==")
		p.pos = save
		if !chained do break
	}
	return names[:]
}

// Skip to the end of the logical line (brackets, strings and backslash
// continuations included).
@(private = "file")
skip_line :: proc(p: ^Conf_Parser) {
	depth := 0
	for p.pos < len(p.text) {
		c := p.text[p.pos]
		switch c {
		case '#':
			for p.pos < len(p.text) && p.text[p.pos] != '\n' do p.pos += 1
			continue
		case '\'', '"':
			scan_string_literal(p)
			continue
		case '(', '[', '{':
			depth += 1
		case ')', ']', '}':
			depth = max(depth - 1, 0)
		case '\\':
			p.pos += 2
			continue
		case '\n':
			p.pos += 1
			if depth == 0 do return
			continue
		}
		p.pos += 1
	}
}

@(private = "file")
parse_expr :: proc(p: ^Conf_Parser) -> (Value, bool) {
	v, ok := parse_atom(p)
	if !ok do return nil, false
	for {
		skip_space(p)
		if !at(p, '+') do return v, true
		p.pos += 1
		skip_space(p)
		w, ok2 := parse_atom(p)
		a, is_str := v.(string)
		b, is_str2 := w.(string)
		if !ok2 || !is_str || !is_str2 do return nil, false
		v = strings.concatenate({a, b})
	}
}

@(private = "file")
parse_atom :: proc(p: ^Conf_Parser) -> (Value, bool) {
	if p.pos >= len(p.text) do return nil, false
	c := p.text[p.pos]
	switch {
	case c == '[' || c == '(':
		return parse_list(p, ']' if c == '[' else ')')
	case c == '{':
		return parse_dict(p)
	case c == '"' || c == '\'' || is_string_prefix(p):
		return parse_strings(p)
	case c == '-' || (c >= '0' && c <= '9'):
		return parse_number(p)
	}
	return parse_name_value(p)
}

// ``True``, ``False``, ``None`` or a name assigned before (not a call or
// an attribute).
@(private = "file")
parse_name_value :: proc(p: ^Conf_Parser) -> (Value, bool) {
	name := scan_name(p)
	switch name {
	case "True":
		return true, true
	case "False":
		return false, true
	case "None":
		return "", true
	case "":
		return nil, false
	}
	skip_space(p)
	if at(p, '(') || at(p, '.') || at(p, '[') do return nil, false
	v, known := p.values[name]
	return v, known
}

@(private = "file")
parse_list :: proc(p: ^Conf_Parser, close: u8) -> (Value, bool) {
	p.pos += 1
	p.depth += 1
	defer p.depth -= 1
	items := make([dynamic]Value)
	comma := false
	for {
		skip_blank(p)
		if at(p, close) {
			p.pos += 1
			// "(x)" is x, not a tuple
			if close == ')' && len(items) == 1 && !comma do return items[0], true
			return items[:], true
		}
		v, ok := parse_expr(p)
		if !ok do return nil, false
		append(&items, v)
		skip_blank(p)
		comma = at(p, ',')
		if comma do p.pos += 1
		else if !at(p, close) do return nil, false
	}
}

@(private = "file")
parse_dict :: proc(p: ^Conf_Parser) -> (Value, bool) {
	p.pos += 1
	p.depth += 1
	defer p.depth -= 1
	keys := make([dynamic]string)
	values := make([dynamic]Value)
	for {
		skip_blank(p)
		if at(p, '}') {
			p.pos += 1
			return Dict{keys[:], values[:]}, true
		}
		k, ok := parse_expr(p)
		key, is_str := k.(string)
		skip_blank(p)
		if !ok || !is_str || !at(p, ':') do return nil, false
		p.pos += 1
		skip_blank(p)
		v, ok2 := parse_expr(p)
		if !ok2 do return nil, false
		append(&keys, key)
		append(&values, v)
		skip_blank(p)
		if at(p, ',') do p.pos += 1
		else if !at(p, '}') do return nil, false
	}
}

@(private = "file")
parse_number :: proc(p: ^Conf_Parser) -> (Value, bool) {
	start := p.pos
	if at(p, '-') do p.pos += 1
	for p.pos < len(p.text) {
		c := p.text[p.pos]
		if !((c >= '0' && c <= '9') || c == '.' || c == '_' || c == 'e') do break
		p.pos += 1
	}
	text, _ := strings.remove_all(p.text[start:p.pos], "_", context.temp_allocator)
	f, ok := strconv.parse_f64(text)
	return f, ok
}

// Adjacent string literals, concatenated.
@(private = "file")
parse_strings :: proc(p: ^Conf_Parser) -> (Value, bool) {
	b := strings.builder_make()
	for {
		if !(at(p, '"') || at(p, '\'') || is_string_prefix(p)) do break
		s, ok := parse_string(p)
		if !ok do return nil, false
		strings.write_string(&b, s)
		skip_blank_inside(p)
	}
	return strings.to_string(b), true
}

// A string prefix (r, f, b, u and their pairs) followed by a quote.
@(private = "file")
is_string_prefix :: proc(p: ^Conf_Parser) -> bool {
	i := p.pos
	for i < len(p.text) && i - p.pos < 2 && strings.index_byte("rRfFbBuU", p.text[i]) >= 0 {
		i += 1
	}
	return i > p.pos && i < len(p.text) && (p.text[i] == '"' || p.text[i] == '\'')
}

@(private = "file")
parse_string :: proc(p: ^Conf_Parser) -> (string, bool) {
	raw, fmt_string := false, false
	for strings.index_byte("rRfFbBuU", p.text[p.pos]) >= 0 {
		c := p.text[p.pos] | 0x20
		raw |= c == 'r'
		fmt_string |= c == 'f'
		p.pos += 1
	}
	start := p.pos
	if !scan_string_literal(p) do return "", false
	quote_len := 3 if strings.has_prefix(p.text[start:], `"""`) ||
		strings.has_prefix(p.text[start:], `'''`) else 1
	body := p.text[start + quote_len:p.pos - quote_len]
	s := body if raw else unescape_python(body)
	if fmt_string do s = format_fstring(p, s)
	return s, true
}

// Advance past a quoted literal at ``p.pos`` (single or triple quotes).
@(private = "file")
scan_string_literal :: proc(p: ^Conf_Parser) -> bool {
	q := p.text[p.pos]
	triple := strings.has_prefix(p.text[p.pos:], q == '"' ? `"""` : `'''`)
	delim := p.text[p.pos:p.pos + (3 if triple else 1)]
	p.pos += len(delim)
	for p.pos < len(p.text) {
		c := p.text[p.pos]
		if c == '\\' {
			p.pos += 2
			continue
		}
		if !triple && c == '\n' do return false
		if strings.has_prefix(p.text[p.pos:], delim) {
			p.pos += len(delim)
			return true
		}
		p.pos += 1
	}
	return false
}

@(private = "file")
unescape_python :: proc(s: string) -> string {
	if strings.index_byte(s, '\\') < 0 do return s
	b := strings.builder_make()
	for i := 0; i < len(s); i += 1 {
		if s[i] != '\\' || i + 1 >= len(s) {
			strings.write_byte(&b, s[i])
			continue
		}
		i += 1
		switch s[i] {
		case 'n':
			strings.write_byte(&b, '\n')
		case 't':
			strings.write_byte(&b, '\t')
		case '\n':
		case '\\', '\'', '"':
			strings.write_byte(&b, s[i])
		case:
			strings.write_byte(&b, '\\')
			strings.write_byte(&b, s[i])
		}
	}
	return strings.to_string(b)
}

// ``{name}`` of an f-string: a known string value, the current year for an
// expression about the year, else the expression text.
@(private = "file")
format_fstring :: proc(p: ^Conf_Parser, s: string) -> string {
	b := strings.builder_make()
	for i := 0; i < len(s); i += 1 {
		if s[i] == '{' && i + 1 < len(s) && s[i + 1] == '{' {
			strings.write_byte(&b, '{')
			i += 1
			continue
		}
		if s[i] == '}' && i + 1 < len(s) && s[i + 1] == '}' {
			strings.write_byte(&b, '}')
			i += 1
			continue
		}
		end := strings.index_byte(s[i:], '}')
		if s[i] != '{' || end < 0 {
			strings.write_byte(&b, s[i])
			continue
		}
		expr := strings.trim_space(s[i + 1:i + end])
		strings.write_string(&b, fstring_field(p, expr))
		i += end
	}
	return strings.to_string(b)
}

@(private = "file")
fstring_field :: proc(p: ^Conf_Parser, expr: string) -> string {
	if v, ok := p.values[expr].(string); ok do return v
	if strings.contains(expr, "year") {
		y, _, _ := time.date(time.now())
		buf: [8]u8
		return strings.clone(strconv.write_int(buf[:], i64(y), 10))
	}
	return expr
}

// --- lexing helpers --------------------------------------------------------------------------

@(private = "file")
at :: proc(p: ^Conf_Parser, c: u8) -> bool {
	return p.pos < len(p.text) && p.text[p.pos] == c
}

@(private = "file")
at_str :: proc(p: ^Conf_Parser, s: string) -> bool {
	return strings.has_prefix(p.text[p.pos:], s)
}

// Only blanks and a comment remain on the line.
@(private = "file")
at_line_end :: proc(p: ^Conf_Parser) -> bool {
	skip_space(p)
	return p.pos >= len(p.text) || p.text[p.pos] == '\n' || p.text[p.pos] == '#' ||
		p.text[p.pos] == ';'
}

@(private = "file")
scan_name :: proc(p: ^Conf_Parser) -> string {
	start := p.pos
	for p.pos < len(p.text) {
		c := p.text[p.pos]
		alpha := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
		if !(alpha || (p.pos > start && c >= '0' && c <= '9')) do break
		p.pos += 1
	}
	return p.text[start:p.pos]
}

// Spaces and tabs (and backslash continuations).
@(private = "file")
skip_space :: proc(p: ^Conf_Parser) {
	for p.pos < len(p.text) {
		c := p.text[p.pos]
		if c == '\\' && p.pos + 1 < len(p.text) && p.text[p.pos + 1] == '\n' {
			p.pos += 2
			continue
		}
		if c != ' ' && c != '\t' && c != '\r' do return
		p.pos += 1
	}
}

// Whitespace, newlines and comments (inside brackets, or between
// statements).
@(private = "file")
skip_blank :: proc(p: ^Conf_Parser) {
	for p.pos < len(p.text) {
		c := p.text[p.pos]
		if c == '#' {
			for p.pos < len(p.text) && p.text[p.pos] != '\n' do p.pos += 1
			continue
		}
		if c != ' ' && c != '\t' && c != '\r' && c != '\n' do return
		p.pos += 1
	}
}

// Between adjacent string literals: blanks, and newlines only inside
// brackets.
@(private = "file")
skip_blank_inside :: proc(p: ^Conf_Parser) {
	if p.depth == 0 {
		skip_space(p)
		return
	}
	save := p.pos
	skip_blank(p)
	if p.pos < len(p.text) && (at(p, '"') || at(p, '\'') || is_string_prefix(p)) do return
	p.pos = save
	skip_space(p)
}
