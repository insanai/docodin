package reader

import "core:c/libc"
import "core:strings"

import dt "../doctree"
import rst "../rst"

// Miscellaneous directives (``directives.misc``): class, replace, unicode,
// date, title, role, default-role, raw and the test directive.

@(private = "file")
UNICODE_OPTIONS := [?]Option_Spec{{"trim", flag}, {"ltrim", flag}, {"rtrim", flag}}
@(private = "file")
RAW_OPTIONS := [?]Option_Spec {
	{"file", path},
	{"url", uri},
	{"encoding", encoding},
	{"class", class_option},
}
@(private = "file")
TEST_OPTIONS := [?]Option_Spec{{"option", unchanged_required}}

CLASS := Directive_Spec {
	required_arguments        = 1,
	final_argument_whitespace = true,
	has_content               = true,
	run                       = run_class,
}
REPLACE := Directive_Spec {
	has_content = true,
	run         = run_replace,
}
UNICODE := Directive_Spec {
	required_arguments        = 1,
	final_argument_whitespace = true,
	option_spec               = UNICODE_OPTIONS[:],
	run                       = run_unicode,
}
DATE := Directive_Spec {
	has_content = true,
	run         = run_date,
}
TITLE := Directive_Spec {
	required_arguments        = 1,
	final_argument_whitespace = true,
	run                       = run_title,
}
ROLE := Directive_Spec {
	has_content = true,
	run         = run_role,
}
DEFAULT_ROLE := Directive_Spec {
	optional_arguments = 1,
	run                = run_default_role,
}
RAW := Directive_Spec {
	required_arguments        = 1,
	final_argument_whitespace = true,
	option_spec               = RAW_OPTIONS[:],
	has_content               = true,
	run                       = run_raw,
}
TEST_DIRECTIVE := Directive_Spec {
	optional_arguments        = 1,
	final_argument_whitespace = true,
	option_spec               = TEST_OPTIONS[:],
	has_content               = true,
	run                       = run_test_directive,
}

@(private = "file")
invalid_context :: proc(d: ^Directive) -> Directive_Error {
	msg := "\" directive can only be used within a substitution definition."
	return directive_error(.ERROR, "Invalid context: the \"", d.name, msg)
}

@(private = "file")
run_class :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	doc := c.doc
	v, err := class_option(c, d.arguments[0])
	if err != "" {
		msg := "\" directive: \""
		return nil, directive_error(
			.ERROR, "Invalid class attribute value for \"", d.name, msg, d.arguments[0], "\".",
		)
	}
	class_value := v.([]string)
	node_list := make([dynamic]dt.Node, c.allocator)
	if sl_len(d.content) > 0 {
		container := dt.new_element(doc, .Element)
		d_nested_parse(c, d, container)
		for n in dt.children(doc, container, c.allocator) {
			for cl in class_value do dt.list_append(doc, n, dt.K_CLASSES, cl)
			append(&node_list, n)
		}
		return node_list, nil
	}
	details := [?]dt.Detail{{"class", class_value}, {"directive", d.name}}
	pending := dt.new_pending(
		doc, "docutils.transforms.misc.ClassAttribute", 210, details[:], d.block_text,
	)
	dt.note_pending(doc, pending)
	append(&node_list, pending)
	return node_list, nil
}

@(private = "file")
run_replace :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	doc := c.doc
	if !d.subst do return nil, invalid_context(d)
	if err := assert_has_content(d); err != nil do return nil, err
	element := dt.new_element(doc, .Element, content_text(c, d))
	d_nested_parse(c, d, element)
	node: dt.Node
	messages := make([dynamic]dt.Node, c.allocator)
	for elem in dt.children(doc, element, c.allocator) {
		if node == 0 && dt.is(doc, elem, {.paragraph}) {
			node = elem
		} else if dt.is(doc, elem, {.system_message}) {
			dt.set_list(doc, elem, dt.K_BACKREFS)
			append(&messages, elem)
		} else {
			msg := concat(
				"Error in \"", d.name, "\" directive: may contain a single paragraph only.",
			)
			return result_of(c, dt.error(doc, msg, {line = d.lineno})), nil
		}
	}
	if node != 0 do append(&messages, ..dt.children(doc, node, c.allocator))
	return messages, nil
}

@(private = "file")
run_unicode :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	doc := c.doc
	if !d.subst do return nil, invalid_context(d)
	subdef := d.sm.node
	if options_has(&d.options, "trim") {
		dt.set_attr(doc, subdef, "ltrim", 1)
		dt.set_attr(doc, subdef, "rtrim", 1)
	}
	if options_has(&d.options, "ltrim") do dt.set_attr(doc, subdef, "ltrim", 1)
	if options_has(&d.options, "rtrim") do dt.set_attr(doc, subdef, "rtrim", 1)
	out := make([dynamic]dt.Node, c.allocator)
	for code in dt.py_split(strip_unicode_comment(d.arguments[0]), c.allocator) {
		decoded, err := unicode_code(c, code)
		if err != "" {
			return nil, directive_error(.ERROR, "Invalid character code: ", code, "\n", err)
		}
		append(&out, dt.new_text(doc, decoded))
	}
	return out, nil
}

// ``Unicode.comment_pattern.split(text)[0]``: the text before ``( |\n|^)\.\. ``.
@(private = "file")
strip_unicode_comment :: proc(text: string) -> string {
	if has_prefix(text, ".. ") do return ""
	for i in 0 ..< len(text) {
		at_space := text[i] == ' ' || text[i] == '\n'
		if at_space && has_prefix(text[i + 1:], ".. ") do return text[:i]
	}
	return text
}

// ``directives.unicode_code(code)``: the character, or the error text
// (``io.error_string``) of the ``ValueError``.
unicode_code :: proc(c: ^Context, code: string) -> (string, string) {
	digits := ""
	base := 10
	if is_ascii_digits(code) {
		digits = code
	} else if hex, ok := unicode_hex(code); ok {
		digits, base = hex, 16
	} else {
		return code, ""
	}
	value := 0
	for ch in transmute([]u8)digits {
		d := int(ch - '0') if ch <= '9' else int((ch | 0x20) - 'a') + 10
		value = value * base + d
		if value > 0x7FFF_FFFF {
			return "", "ValueError: code too large (Python int too large to convert to C int)"
		}
	}
	if value > 0x10FFFF do return "", "ValueError: chr() arg not in range(0x110000)"
	b := strings.builder_make(c.allocator)
	strings.write_rune(&b, rune(value))
	return strings.to_string(b), ""
}

@(private = "file")
is_ascii_digits :: proc(s: string) -> bool {
	if s == "" do return false
	for i in 0 ..< len(s) do if s[i] < '0' || s[i] > '9' do return false
	return true
}

// ``(?:0x|x|\\x|U\+?|\\u)([0-9a-f]+)$|&#x([0-9a-f]+);$`` (ignoring case).
@(private = "file")
unicode_hex :: proc(code: string) -> (string, bool) {
	lower := strings.to_lower(code, context.temp_allocator)
	for prefix in ([]string{"0x", "x", "\\x", "u+", "u", "\\u"}) {
		digits := code[len(prefix):] if len(code) >= len(prefix) else ""
		if has_prefix(lower, prefix) && is_hex(digits) do return digits, true
	}
	if has_prefix(lower, "&#x") && has_suffix(code, ";") && len(code) > 4 {
		inner := code[3:len(code) - 1]
		if is_hex(inner) do return inner, true
	}
	return "", false
}

@(private = "file")
is_hex :: proc(s: string) -> bool {
	if s == "" do return false
	for i in 0 ..< len(s) {
		ch := s[i] | 0x20
		if !((s[i] >= '0' && s[i] <= '9') || (ch >= 'a' && ch <= 'f')) do return false
	}
	return true
}

@(private = "file")
run_date :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	if !d.subst do return nil, invalid_context(d)
	format := content_text(c, d)
	if format == "" do format = "%Y-%m-%d"
	return result_of(c, dt.new_text(c.doc, strftime(c, format))), nil
}

// ``time.strftime(format)`` (local time).
@(private = "file")
strftime :: proc(c: ^Context, format: string) -> string {
	now := libc.time(nil)
	tm := libc.localtime(&now)
	cformat := strings.clone_to_cstring(format, c.allocator)
	size := 256 + 4 * len(format)
	for _ in 0 ..< 8 {
		buf := make([]u8, size, c.allocator)
		n := libc.strftime(raw_data(buf), uint(size), cformat, tm)
		if n > 0 || format == "" do return string(buf[:n])
		size *= 4
	}
	return ""
}

@(private = "file")
run_title :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	dt.set_attr(c.doc, c.doc.root, dt.K_TITLE, d.arguments[0])
	return nil, nil
}

@(private = "file")
run_default_role :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	if len(d.arguments) == 0 {
		delete_key(&c.roles, "") // restore the "default" default role
		return nil, nil
	}
	role_name := d.arguments[0]
	role, messages := lookup_role(c, role_name, d.lineno)
	if role == nil {
		append(&messages, unknown_role_error(c, d, role_name))
		return messages, nil
	}
	c.roles[""] = role
	return messages, nil
}

@(private = "file")
unknown_role_error :: proc(c: ^Context, d: ^Directive, role_name: string) -> dt.Node {
	text := concat("Unknown interpreted text role \"", role_name, "\".")
	lit := dt.new_element(c.doc, .literal_block, d.block_text, d.block_text)
	return dt.error(c.doc, text, {children = {lit}, line = d.lineno})
}

// ``Role.run``: create and register a custom interpreted text role.
@(private = "file")
run_role :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	if d.content_offset > d.lineno || sl_len(d.content) == 0 {
		return nil, directive_error(
			.ERROR, "\"", d.name, "\" directive requires arguments on the first line.",
		)
	}
	args := d.content.data[0]
	new_name, base_name, ok := match_role_arguments(args)
	if !ok {
		return nil, directive_error(
			.ERROR, "\"", d.name, "\" directive arguments not valid role names: \"", args, "\".",
		)
	}
	messages := make([dynamic]dt.Node, c.allocator)
	base := &GENERIC_CUSTOM_ROLE
	if base_name != "" {
		base, messages = lookup_role(c, base_name, d.lineno)
		if base == nil {
			append(&messages, unknown_role_error(c, d, base_name))
			return messages, nil
		}
	}
	role, err := custom_role_of(c, d, new_name, base)
	if err != 0 {
		append(&messages, err)
		return messages, nil
	}
	c.roles[dt.py_lower(new_name, c.allocator)] = role
	return messages, nil
}

// ``roles.CustomRole(new_role_name, base_role, options, content)`` with
// the options and content of the directive's remaining lines, or the error.
@(private = "file")
custom_role_of :: proc(
	c: ^Context,
	d: ^Directive,
	new_name: string,
	base: ^Role,
) -> (^Role, dt.Node) {
	converted := Directive_Spec {
		option_spec = role_option_spec(base),
	}
	role_dir := Directive {
		name    = d.name,
		sm      = d.sm,
		spec    = &converted,
		options = make(Options, c.allocator),
	}
	block := sl_slice(d.content, 1)
	if err := parse_directive_block(c, &role_dir, block, d.content_offset); err != "" {
		text := concat("Error in \"", d.name, "\" directive:\n", err, ".")
		return nil, role_directive_error(c, d, text)
	}
	if !options_has(&role_dir.options, "class") {
		v, err := class_option(c, new_name)
		if err != "" {
			text := concat("Invalid argument for \"", d.name, "\" directive:\n", err, ".")
			return nil, role_directive_error(c, d, text)
		}
		options_set(&role_dir.options, "class", v)
	}
	role := new(Role, c.allocator)
	role^ = Role {
		kind    = .Custom,
		name    = new_name,
		base    = base,
		options = role_dir.options,
		content = role_dir.content.data[:],
		spec    = role_option_spec(base),
	}
	return role, 0
}

@(private = "file")
role_directive_error :: proc(c: ^Context, d: ^Directive, text: string) -> dt.Node {
	lit := dt.new_element(c.doc, .literal_block, d.block_text, d.block_text)
	return dt.error(c.doc, text, {children = {lit}, line = d.lineno})
}

// ``Role.argument_pattern``: ``(simplename)\s*(\(\s*(simplename)\s*\)\s*)?$``.
@(private = "file")
match_role_arguments :: proc(s: string) -> (new_name, base_name: string, ok: bool) {
	end := rst.simplename_end(s, 0)
	if end == 0 do return
	new_name = s[:end]
	i := skip_space(s, end)
	if i == len(s) do return new_name, "", true
	if s[i] != '(' do return
	i = skip_space(s, i + 1)
	base_end := rst.simplename_end(s, i)
	if base_end == i do return
	base_name = s[i:base_end]
	i = skip_space(s, base_end)
	if i >= len(s) || s[i] != ')' do return
	i = skip_space(s, i + 1)
	return new_name, base_name, i == len(s)
}

@(private = "file")
skip_space :: proc(s: string, i_in: int) -> int {
	i := i_in
	for i < len(s) {
		r, w := rst.rune_at(s, i)
		if !dt.py_isspace(r) do break
		i += w
	}
	return i
}

@(private = "file")
run_raw :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	doc := c.doc
	s := &doc.settings
	has_file := options_has(&d.options, "file")
	has_url := options_has(&d.options, "url")
	if !s.raw_enabled || (!s.file_insertion_enabled && (has_file || has_url)) {
		return nil, directive_error(.WARNING, "\"", d.name, "\" directive disabled.")
	}
	format := strings.join(dt.py_split(dt.py_lower(d.arguments[0], c.allocator)), " ", c.allocator)
	text, source, err := raw_text(c, d, has_file, has_url)
	if e, failed := err.?; failed do return nil, e
	node := dt.new_element(doc, .raw, "", text)
	for cl in options_list(&d.options, "class") do dt.list_append(doc, node, dt.K_CLASSES, cl)
	dt.set_attr(doc, node, "format", format)
	if source != "" do dt.set_attr(doc, node, dt.K_SOURCE, source)
	d_set_source_line(c, d, node, d.lineno)
	return result_of(c, node), nil
}

// The text of a ``raw`` directive (content, file or URL) and its source.
@(private = "file")
raw_text :: proc(
	c: ^Context,
	d: ^Directive,
	has_file, has_url: bool,
) -> (
	text, source: string,
	err: Maybe(Directive_Error),
) {
	switch {
	case sl_len(d.content) > 0:
		if has_file || has_url {
			msg := "\" directive may not both specify an external file and have content."
			return "", "", directive_error(.ERROR, "\"", d.name, msg)
		}
		return content_text(c, d), "", nil
	case has_file:
		if has_url {
			msg := "The \"file\" and \"url\" options may not be simultaneously specified "
			return "", "", directive_error(.ERROR, msg, "for the \"", d.name, "\" directive.")
		}
		file := options_string(&d.options, "file")
		source = adapt_path(c, file, c.doc.settings.root_prefix)
		text, err = read_file(c, d, source)
		return
	case has_url:
		url := options_string(&d.options, "url")
		content, class, fetch_err := read_url(c, d, url)
		if class == "UnicodeError" {
			return "", "", directive_error(
				.SEVERE, "Problem with \"", d.name, "\" directive:\n", fetch_err,
			)
		}
		if class != "" {
			return "", "", directive_error(
				.SEVERE, "Problems with \"", d.name, "\" directive URL \"", url, "\":\n",
				class, ": ",
				fetch_err, ".",
			)
		}
		return content, url, nil
	}
	return "", "", assert_has_content(d)
}

@(private = "file")
run_test_directive :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	b := strings.builder_make(c.allocator)
	strings.write_string(&b, "Directive processed. Type=\"")
	strings.write_string(&b, d.name)
	strings.write_string(&b, "\", arguments=[")
	for a, i in d.arguments {
		if i > 0 do strings.write_string(&b, ", ")
		dt.write_py_repr(&b, a)
	}
	strings.write_string(&b, "], options={")
	for o, i in d.options {
		if i > 0 do strings.write_string(&b, ", ")
		dt.write_py_repr(&b, o.name)
		strings.write_string(&b, ": ")
		write_option_repr(&b, o.value)
	}
	strings.write_string(&b, "}, content:")
	opts := dt.Message_Options {
		line = d.lineno,
	}
	if sl_len(d.content) > 0 {
		text := content_text(c, d)
		opts.children = {dt.new_element(c.doc, .literal_block, text, text)}
	} else {
		strings.write_string(&b, " None")
	}
	return result_of(c, dt.info(c.doc, strings.to_string(b), opts)), nil
}
