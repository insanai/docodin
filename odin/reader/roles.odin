package reader

import dt "../doctree"

// Interpreted text roles (``docutils.parsers.rst.roles``): the canonical
// registry, the English role names, the per-document local roles
// (``roles._roles``, where the ``role`` and ``default-role`` directives
// register), and the standard role functions.

Role_Kind :: enum u8 {
	Generic, // wraps the text in ``tag``
	Pep,
	Rfc,
	Raw,
	Code,
	Math,
	Unimplemented,
	Generic_Custom, // ``generic_custom_role``: an ``inline`` element
	Custom, // ``CustomRole``: ``base`` with supplied options and content
}

Role :: struct {
	kind:    Role_Kind,
	tag:     dt.Tag, // Generic
	name:    string,
	base:    ^Role, // Custom
	options: Options, // Custom: the supplied options
	content: []string, // Custom: the supplied content
	spec:    []Option_Spec, // ``role_fn.options``
}

@(private = "file")
CLASS_SPEC := [?]Option_Spec{{"class", class_option}}
@(private = "file")
RAW_SPEC := [?]Option_Spec{{"format", unchanged}, {"class", class_option}}
@(private = "file")
CODE_SPEC := [?]Option_Spec{{"language", unchanged}, {"class", class_option}}

// The canonical registry (``roles._role_registry``).
@(private = "file")
ROLE_REGISTRY := [?]Role {
	{kind = .Generic, tag = .abbreviation, name = "abbreviation"},
	{kind = .Generic, tag = .acronym, name = "acronym"},
	{kind = .Generic, tag = .emphasis, name = "emphasis"},
	{kind = .Generic, tag = .literal, name = "literal"},
	{kind = .Generic, tag = .strong, name = "strong"},
	{kind = .Generic, tag = .subscript, name = "subscript"},
	{kind = .Generic, tag = .superscript, name = "superscript"},
	{kind = .Generic, tag = .title_reference, name = "title-reference"},
	{kind = .Pep, name = "pep-reference"},
	{kind = .Rfc, name = "rfc-reference"},
	{kind = .Raw, name = "raw"},
	{kind = .Code, name = "code"},
	{kind = .Math, name = "math"},
	{kind = .Unimplemented, name = "index"},
	{kind = .Unimplemented, name = "named-reference"},
	{kind = .Unimplemented, name = "anonymous-reference"},
	{kind = .Unimplemented, name = "uri-reference"},
	{kind = .Unimplemented, name = "footnote-reference"},
	{kind = .Unimplemented, name = "citation-reference"},
	{kind = .Unimplemented, name = "substitution-reference"},
	{kind = .Unimplemented, name = "target"},
	{kind = .Unimplemented, name = "restructuredtext-unimplemented-role"},
}

// ``generic_custom_role``: the base of custom roles without one.
GENERIC_CUSTOM_ROLE := Role {
	kind = .Generic_Custom,
	name = "generic_custom_role",
}

DEFAULT_INTERPRETED_ROLE :: "title-reference"

// The options a role function accepts (``role_fn.options`` after
// ``set_implicit_options``).
role_option_spec :: proc(r: ^Role) -> []Option_Spec {
	switch r.kind {
	case .Raw:
		return RAW_SPEC[:]
	case .Code:
		return CODE_SPEC[:]
	case .Custom:
		return r.spec
	case .Generic, .Pep, .Rfc, .Math, .Unimplemented, .Generic_Custom:
	}
	return CLASS_SPEC[:]
}

@(private = "file")
canonical_role :: proc(name: string) -> ^Role {
	for &r in ROLE_REGISTRY do if r.name == name do return &r
	return nil
}

// ``roles.role(role_name, language, lineno, reporter)``: the role and the
// lookup messages.
lookup_role :: proc(c: ^Context, role_name: string, lineno: int) -> (^Role, [dynamic]dt.Node) {
	msgs := make([dynamic]dt.Node, c.allocator)
	normname := dt.py_lower(role_name, c.allocator)
	if r, ok := c.roles[normname]; ok do return r, msgs
	canonical := DEFAULT_INTERPRETED_ROLE
	if role_name != "" {
		text: string
		canonical, text = canonical_name(c, .Role, role_name, normname)
		if text != "" do append(&msgs, dt.info(c.doc, text, {line = lineno}))
	}
	r := canonical_role(canonical)
	if r == nil do return nil, msgs
	c.roles[dt.clone(c.doc, normname)] = r
	return r, msgs
}

// ``Inliner.interpreted(rawsource, text, role, lineno)``.
interpreted :: proc(
	c: ^Context,
	rawsource, text, role_name: string,
	lineno: int,
	out, msgs: Node_Out,
) {
	r, messages := lookup_role(c, role_name, lineno)
	append(msgs, ..messages[:])
	if r == nil {
		text_ := concat("Unknown interpreted text role \"", role_name, "\".")
		msg := dt.error(c.doc, text_, {line = lineno})
		append(out, problematic(c, rawsource, rawsource, msg))
		append(msgs, msg)
		return
	}
	call_role(c, r, role_name, rawsource, text, lineno, nil, nil, out, msgs)
}

// Call the role function of ``r`` (``role_fn(role, rawtext, text, lineno,
// inliner, options, content)``).
call_role :: proc(
	c: ^Context,
	r: ^Role,
	role_name, rawtext, text: string,
	lineno: int,
	options: ^Options,
	content: []string,
	out, msgs: Node_Out,
) {
	opts := normalize_options(c, options)
	switch r.kind {
	case .Generic:
		n := dt.new_element(c.doc, r.tag, rawtext, text)
		apply_options(c, n, &opts)
		append(out, n)
	case .Generic_Custom:
		n := dt.new_element(c.doc, .inline, rawtext, text)
		apply_options(c, n, &opts)
		append(out, n)
	case .Pep:
		pep_role(c, rawtext, text, lineno, &opts, out, msgs)
	case .Rfc:
		rfc_role(c, rawtext, text, lineno, &opts, out, msgs)
	case .Raw:
		raw_role(c, role_name, rawtext, text, lineno, &opts, out, msgs)
	case .Code:
		code_role(c, rawtext, text, lineno, &opts, out, msgs)
	case .Math:
		n := dt.new_element(c.doc, .math, rawtext, dt.unescape(text, true))
		apply_options(c, n, &opts)
		append(out, n)
	case .Unimplemented:
		msg_text := concat("Interpreted text role \"", role_name, "\" not implemented.")
		msg := dt.error(c.doc, msg_text, {line = lineno})
		append(out, problematic(c, rawtext, rawtext, msg))
		append(msgs, msg)
	case .Custom:
		custom_role(c, r, role_name, rawtext, text, lineno, options, content, out, msgs)
	}
}

// ``CustomRole.__call__``.
@(private = "file")
custom_role :: proc(
	c: ^Context,
	r: ^Role,
	role_name, rawtext, text: string,
	lineno: int,
	options: ^Options,
	content: []string,
	out, msgs: Node_Out,
) {
	opts := normalize_options(c, &r.options)
	if options != nil do for o in options do options_set(&opts, o.name, o.value)
	merged := make([dynamic]string, c.allocator)
	append(&merged, ..r.content)
	if len(r.content) > 0 && len(content) > 0 do append(&merged, "\n")
	append(&merged, ..content)
	call_role(c, r.base, role_name, rawtext, text, lineno, &opts, merged[:], out, msgs)
}

// ``roles.normalize_options``: a copy with "class" renamed "classes".
normalize_options :: proc(c: ^Context, options: ^Options) -> Options {
	out := make(Options, c.allocator)
	if options == nil do return out
	for o in options {
		if o.name == "class" {
			append(&out, Option{"classes", o.value})
		} else {
			append(&out, o)
		}
	}
	return out
}

// ``node_class(rawtext, text, **options)``: set the options as attributes.
apply_options :: proc(c: ^Context, n: dt.Node, opts: ^Options) {
	doc := c.doc
	for o in opts {
		switch v in o.value {
		case string:
			dt.set_attr(doc, n, o.name, v)
		case int:
			dt.set_attr(doc, n, o.name, v)
		case []string:
			l := dt.list_for_write(doc, n, o.name)
			for s in v do append(l, dt.intern(doc, s))
		case []int:
			l := dt.list_for_write(doc, n, o.name)
			for i in v do append(l, dt.intern(doc, itoa(i)))
		case Opt_None:
			dt.set_attr(doc, n, o.name, dt.Attr_None{})
		}
	}
}

@(private = "file")
pep_role :: proc(
	c: ^Context,
	rawtext, text: string,
	lineno: int,
	opts: ^Options,
	out, msgs: Node_Out,
) {
	pepnum, ok := dt.py_parse_int(dt.unescape(text))
	if !ok || pepnum < 0 || pepnum > 9999 {
		msg_text := concat(
			"PEP number must be a number from 0 to 9999; \"", text, "\" is invalid.",
		)
		role_error(c, rawtext, msg_text, lineno, out, msgs)
		return
	}
	s := &c.doc.settings
	uri := concat(s.pep_base_url, py_format_int(s.pep_file_url_template, pepnum))
	n := dt.new_element(c.doc, .reference, rawtext, concat("PEP ", text))
	dt.set_attr(c.doc, n, dt.K_REFURI, uri)
	apply_options(c, n, opts)
	append(out, n)
}

@(private = "file")
rfc_role :: proc(
	c: ^Context,
	rawtext, text: string,
	lineno: int,
	opts: ^Options,
	out, msgs: Node_Out,
) {
	num_text := dt.unescape(text)
	section := ""
	has_section := false
	for i in 0 ..< len(text) {
		if text[i] != '#' do continue
		u := dt.unescape(text)
		for j in 0 ..< len(u) {
			if u[j] == '#' {
				num_text, section, has_section = u[:j], u[j + 1:], true
				break
			}
		}
		break
	}
	rfcnum, ok := dt.py_parse_int(num_text)
	if !ok || rfcnum < 1 {
		msg_text := concat(
			"RFC number must be a number greater than or equal to 1; \"",
			text,
			"\" is invalid.",
		)
		role_error(c, rawtext, msg_text, lineno, out, msgs)
		return
	}
	uri := concat(c.doc.settings.rfc_base_url, "rfc", itoa(rfcnum), ".html")
	if has_section do uri = concat(uri, "#", section)
	n := dt.new_element(c.doc, .reference, rawtext, concat("RFC ", itoa(rfcnum)))
	dt.set_attr(c.doc, n, dt.K_REFURI, uri)
	apply_options(c, n, opts)
	append(out, n)
}

// An ERROR message at ``lineno`` with its problematic node.
@(private = "file")
role_error :: proc(c: ^Context, rawtext, text: string, lineno: int, out, msgs: Node_Out) {
	msg := dt.error(c.doc, text, {line = lineno})
	append(out, problematic(c, rawtext, rawtext, msg))
	append(msgs, msg)
}

@(private = "file")
raw_role :: proc(
	c: ^Context,
	role_name, rawtext, text: string,
	lineno: int,
	opts: ^Options,
	out, msgs: Node_Out,
) {
	doc := c.doc
	if !doc.settings.raw_enabled {
		msg := dt.warning(doc, "raw (and derived) roles disabled")
		append(out, problematic(c, rawtext, rawtext, msg))
		append(msgs, msg)
		return
	}
	if _, has_format := options_get(opts, "format"); !has_format {
		msg_text := concat(
			"No format (Writer name) is associated with this role: \"",
			role_name,
			"\".\nThe \"raw\" role cannot be used directly.\n",
			"Instead, use the \"role\" directive to create a new role with an ",
			"associated format.",
		)
		role_error(c, rawtext, msg_text, lineno, out, msgs)
		return
	}
	n := dt.new_element(doc, .raw, rawtext, dt.unescape(text, true))
	apply_options(c, n, opts)
	src, ln, _ := get_source_and_line(c, c.top, lineno)
	dt.set_source(doc, n, src)
	dt.set_line(doc, n, ln)
	append(out, n)
}

@(private = "file")
code_role :: proc(
	c: ^Context,
	rawtext, text: string,
	lineno: int,
	opts: ^Options,
	out, msgs: Node_Out,
) {
	doc := c.doc
	language := ""
	if v, ok := options_get(opts, "language"); ok do language, _ = v.(string)
	if uses_pygments(c, language) do note_need(c, c.top, lineno, .Pygments, language)
	classes := make([dynamic]string, c.allocator)
	append(&classes, "code")
	if v, ok := options_get(opts, "classes"); ok {
		if l, is_list := v.([]string); is_list do append(&classes, ..l)
	}
	if language != "" && !contains(classes[:], language) do append(&classes, language)
	if err := lexer_error(c, language); err != "" {
		msg := dt.warning(doc, err)
		append(out, problematic(c, rawtext, rawtext, msg))
		append(msgs, msg)
		return
	}
	n := dt.new_element(doc, .literal, rawtext)
	for cl in classes do dt.list_append(doc, n, dt.K_CLASSES, cl)
	dt.append_child(doc, n, dt.new_text(doc, dt.unescape(text, true)))
	append(out, n)
}

// ``code_analyzer.Lexer(code, language, syntax_highlight)`` analyzes the
// code with Pygments.
uses_pygments :: proc(c: ^Context, language: string) -> bool {
	if language == "" || language == "text" do return false
	return c.doc.settings.syntax_highlight != "none"
}

// ``code_analyzer.Lexer(code, language, syntax_highlight)`` without
// Pygments: the ``LexerError`` text, "" when the code is not analyzed.
lexer_error :: proc(c: ^Context, language: string) -> string {
	if !uses_pygments(c, language) do return ""
	return "Cannot analyze code. Pygments package not found."
}

contains :: proc(list: []string, s: string) -> bool {
	for x in list do if x == s do return true
	return false
}
