package reader

import "core:strings"

import dt "../doctree"

// Body element directives (``directives.admonitions`` and
// ``directives.body``).

@(private = "file")
CLASS_NAME := [?]Option_Spec{{"class", class_option}, {"name", unchanged}}
@(private = "file")
SIDEBAR_OPTIONS := [?]Option_Spec {
	{"class", class_option},
	{"name", unchanged},
	{"subtitle", unchanged_required},
}
@(private = "file")
CODE_OPTIONS := [?]Option_Spec {
	{"class", class_option},
	{"name", unchanged},
	{"number-lines", unchanged},
}
@(private = "file")
NAME_ONLY := [?]Option_Spec{{"name", unchanged}}

@(private = "file")
admonition_spec :: proc "contextless" (tag: dt.Tag) -> Directive_Spec {
	return {
		final_argument_whitespace = true,
		option_spec = CLASS_NAME[:],
		has_content = true,
		run = run_admonition,
		tag = tag,
	}
}

ATTENTION := admonition_spec(.attention)
CAUTION := admonition_spec(.caution)
DANGER := admonition_spec(.danger)
ERROR := admonition_spec(.error)
HINT := admonition_spec(.hint)
IMPORTANT := admonition_spec(.important)
NOTE := admonition_spec(.note)
TIP := admonition_spec(.tip)
WARNING := admonition_spec(.warning)
ADMONITION := Directive_Spec {
	required_arguments        = 1,
	final_argument_whitespace = true,
	option_spec               = CLASS_NAME[:],
	has_content               = true,
	run                       = run_admonition,
	tag                       = .admonition,
}

TOPIC := Directive_Spec {
	required_arguments        = 1,
	final_argument_whitespace = true,
	option_spec               = CLASS_NAME[:],
	has_content               = true,
	run                       = run_pseudo_section,
	tag                       = .topic,
}
SIDEBAR := Directive_Spec {
	optional_arguments        = 1,
	final_argument_whitespace = true,
	option_spec               = SIDEBAR_OPTIONS[:],
	has_content               = true,
	run                       = run_sidebar,
	tag                       = .sidebar,
}
LINE_BLOCK := Directive_Spec {
	option_spec = CLASS_NAME[:],
	has_content = true,
	run         = run_line_block,
}
PARSED_LITERAL := Directive_Spec {
	option_spec    = CLASS_NAME[:],
	has_content    = true,
	run            = run_parsed_literal,
	parsed_literal = true,
}
CODE_BLOCK := Directive_Spec {
	optional_arguments = 1,
	option_spec        = CODE_OPTIONS[:],
	has_content        = true,
	run                = run_code_block,
}
MATH_BLOCK := Directive_Spec {
	option_spec = CLASS_NAME[:],
	has_content = true,
	run         = run_math_block,
}
RUBRIC := Directive_Spec {
	required_arguments        = 1,
	final_argument_whitespace = true,
	option_spec               = CLASS_NAME[:],
	run                       = run_rubric,
}
@(private = "file")
EPIGRAPH_CLASSES := [?]string{"epigraph"}
@(private = "file")
HIGHLIGHTS_CLASSES := [?]string{"highlights"}
@(private = "file")
PULL_QUOTE_CLASSES := [?]string{"pull-quote"}
EPIGRAPH := Directive_Spec {
	has_content = true,
	run         = run_block_quote,
	classes     = EPIGRAPH_CLASSES[:],
}
HIGHLIGHTS := Directive_Spec {
	has_content = true,
	run         = run_block_quote,
	classes     = HIGHLIGHTS_CLASSES[:],
}
PULL_QUOTE := Directive_Spec {
	has_content = true,
	run         = run_block_quote,
	classes     = PULL_QUOTE_CLASSES[:],
}
COMPOUND := Directive_Spec {
	option_spec = CLASS_NAME[:],
	has_content = true,
	run         = run_compound,
}
CONTAINER := Directive_Spec {
	optional_arguments        = 1,
	final_argument_whitespace = true,
	option_spec               = NAME_ONLY[:],
	has_content               = true,
	run                       = run_container,
}

// ``BaseAdmonition.run``.
@(private = "file")
run_admonition :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	doc := c.doc
	options := normalize_options(c, &d.options)
	if err := assert_has_content(d); err != nil do return nil, err
	node := dt.new_element(doc, d.spec.tag, content_text(c, d))
	apply_options(c, node, &options)
	add_name(c, d, node)
	d_set_source_line(c, d, node, d.lineno)
	if d.spec.tag == .admonition {
		title_text := d.arguments[0]
		textnodes, messages := d_inline_text(c, d, title_text, d.lineno)
		title := element(c, .title, title_text, textnodes[:])
		d_set_source_line(c, d, title, d.lineno)
		dt.append_child(doc, node, title)
		extend(c, node, messages[:])
		if !options_has(&options, "classes") {
			class := concat("admonition-", dt.make_id(title_text))
			dt.list_append(doc, node, dt.K_CLASSES, class)
		}
	}
	d_nested_parse(c, d, node)
	return result_of(c, node), nil
}

// ``BasePseudoSection.run`` (topic and sidebar).
@(private = "file")
run_pseudo_section :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	doc := c.doc
	if pseudo_section_invalid(c, d.sm.node) {
		msg := "\" directive may not be used within topics or body elements."
		return nil, directive_error(.ERROR, "The \"", d.name, msg)
	}
	if err := assert_has_content(d); err != nil do return nil, err
	titles := make([dynamic]dt.Node, c.allocator)
	messages := make([dynamic]dt.Node, c.allocator)
	if len(d.arguments) > 0 {
		title_text := d.arguments[0]
		textnodes, msgs := d_inline_text(c, d, title_text, d.lineno)
		append(&titles, element(c, .title, title_text, textnodes[:]))
		append(&messages, ..msgs[:])
		if v, ok := options_get(&d.options, "subtitle"); ok {
			subtitle, _ := v.(string)
			textnodes2, more := d_inline_text(c, d, subtitle, d.lineno)
			append(&titles, element(c, .subtitle, subtitle, textnodes2[:]))
			append(&messages, ..more[:])
		}
	}
	text := content_text(c, d)
	node := element(c, d.spec.tag, text, titles[:])
	extend(c, node, messages[:])
	for cl in options_list(&d.options, "class") do dt.list_append(doc, node, dt.K_CLASSES, cl)
	d_set_source_line(c, d, node, d.lineno)
	add_name(c, d, node)
	if text != "" do d_nested_parse(c, d, node)
	return result_of(c, node), nil
}

// ``not isinstance(node, (Root, section, sidebar)) and isinstance(node,
// BasePseudoSection.invalid_parents)``.
pseudo_section_invalid :: proc(c: ^Context, node: dt.Node) -> bool {
	doc := c.doc
	if dt.is(doc, node, {.document, .section, .sidebar}) do return false
	invalid := dt.tags_of(.SubStructural) + dt.tags_of(.Bibliographic) + dt.tags_of(.Decorative)
	invalid += dt.tags_of(.Body) + dt.tags_of(.Part) + {.topic}
	return dt.is(doc, node, invalid)
}

@(private = "file")
run_sidebar :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	if dt.is(c.doc, d.sm.node, {.sidebar}) {
		return nil, directive_error(
			.ERROR, "The \"", d.name, "\" directive may not be used within a sidebar element.",
		)
	}
	if options_has(&d.options, "subtitle") && len(d.arguments) == 0 {
		return nil, directive_error(
			.ERROR, "The \"subtitle\" option may not be used without a title.",
		)
	}
	return run_pseudo_section(c, d)
}

// ``LineBlock.run`` (the legacy ``line-block`` directive).
@(private = "file")
run_line_block :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	doc := c.doc
	if err := assert_has_content(d); err != nil do return nil, err
	block := dt.new_element(doc, .line_block)
	for cl in options_list(&d.options, "class") do dt.list_append(doc, block, dt.K_CLASSES, cl)
	d_set_source_line(c, d, block, d.lineno)
	add_name(c, d, block)
	node_list := result_of(c, block)
	src, has_src := dt.source(doc, block)
	block_line, _ := dt.line(doc, block)
	for line_text, i in d.content.data {
		stripped := strip(line_text)
		text_nodes, messages := d_inline_text(c, d, stripped, d.lineno + d.content_offset)
		line := element(c, .line, line_text, text_nodes[:])
		dt.set_source(doc, line, src if has_src else nil)
		dt.set_line(doc, line, block_line + i)
		if stripped != "" {
			dt_internals(c, line).indent = cp_len(line_text) - cp_len(lstrip(line_text))
		}
		dt.append_child(doc, block, line)
		append(&node_list, ..messages[:])
		d.content_offset += 1
	}
	nest_line_block_lines(c, block)
	return node_list, nil
}

// ``Body.nest_line_block_lines``.
nest_line_block_lines :: proc(c: ^Context, block: dt.Node) {
	items := dt.children(c.doc, block, c.allocator)
	for i in 1 ..< len(items) {
		if line_indent(c, items[i]) == nil do dt_internals(c, items[i]).indent = line_indent(
			c, items[i - 1],
		)
	}
	nest_line_block_segment(c, block)
}

@(private = "file")
line_indent :: proc(c: ^Context, n: dt.Node) -> Maybe(int) {
	if internals, ok := c.doc.internals[n]; ok do return internals.indent
	return nil
}

// ``Body.nest_line_block_segment``.
@(private = "file")
nest_line_block_segment :: proc(c: ^Context, block: dt.Node) {
	doc := c.doc
	items := dt.children(doc, block, c.allocator)
	least := max(int)
	for item in items do least = min(least, line_indent(c, item).? or_else 0)
	new_items := make([dynamic]dt.Node, c.allocator)
	new_block := dt.new_element(doc, .line_block)
	for item in items {
		if (line_indent(c, item).? or_else 0) > least {
			dt.append_child(doc, new_block, item)
			continue
		}
		if dt.child_count(doc, new_block) > 0 {
			nest_line_block_segment(c, new_block)
			append(&new_items, new_block)
			new_block = dt.new_element(doc, .line_block)
		}
		append(&new_items, item)
	}
	if dt.child_count(doc, new_block) > 0 {
		nest_line_block_segment(c, new_block)
		append(&new_items, new_block)
	}
	dt.clear_children(doc, block)
	extend(c, block, new_items[:])
}

@(private = "file")
run_parsed_literal :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	options := normalize_options(c, &d.options)
	if err := assert_has_content(d); err != nil do return nil, err
	text := content_text(c, d)
	text_nodes, messages := d_inline_text(c, d, text, d.lineno)
	node := element(c, .literal_block, text, text_nodes[:])
	apply_options(c, node, &options)
	dt.set_line(c.doc, node, d.content_offset + 1)
	add_name(c, d, node)
	out := result_of(c, node)
	append(&out, ..messages[:])
	return out, nil
}

// ``CodeBlock.run`` without Pygments (``syntax_highlight`` "none"); a
// language to highlight is a Python need.
run_code_block :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	doc := c.doc
	if err := assert_has_content(d); err != nil do return nil, err
	language := d.arguments[0] if len(d.arguments) > 0 else ""
	if uses_pygments(c, language) do note_directive_need(c, d, .Pygments, language)
	options := normalize_options(c, &d.options)
	classes := make([dynamic]string, c.allocator)
	append(&classes, "code")
	if language != "" do append(&classes, language)
	append(&classes, ..options_list(&options, "classes"))
	if err := lexer_error(c, language); err != "" && doc.settings.report_level <= 2 {
		return nil, directive_error(.WARNING, err)
	}
	code := content_text(c, d)
	node := dt.new_element(doc, .literal_block, code)
	for cl in classes do dt.list_append(doc, node, dt.K_CLASSES, cl)
	add_name(c, d, node)
	if v, ok := options_get(&options, "source"); ok {
		if s, is_str := v.(string); is_str do dt.set_attr(doc, node, dt.K_SOURCE, s)
	}
	if v, ok := options_get(&options, "number-lines"); ok {
		startline, valid := number_lines_start(v)
		if !valid do return nil, directive_error(
			.ERROR, ":number-lines: with non-integer start value",
		)
		endline := startline + sl_len(d.content)
		add_numbered_lines(c, node, code, startline, endline, false)
	} else {
		dt.append_child(doc, node, dt.new_text(doc, code))
	}
	return result_of(c, node), nil
}

// ``int(options['number-lines'] or 1)``.
@(private = "file")
number_lines_start :: proc(v: Option_Value) -> (int, bool) {
	switch x in v {
	case string:
		if x == "" do return 1, true
		return dt.py_parse_int(x)
	case int:
		return x if x != 0 else 1, true
	case Opt_None, []string, []int:
	}
	return 1, true
}

// The tokens of ``NumberLines([([], code)], startline, endline)``: an
// ``inline`` (class "ln") with the number before each line.  ``raw``:
// ``include``'s ``inline('', value)`` (no rawsource) instead of
// ``inline(value, value)``.
add_numbered_lines :: proc(
	c: ^Context,
	node: dt.Node,
	code: string,
	startline,
	endline: int,
	raw: bool,
) {
	doc := c.doc
	width := len(itoa(endline))
	number :: proc(n, width: int) -> string {
		digits := itoa(n)
		b := strings.builder_make(context.temp_allocator)
		for _ in len(digits) ..< width do strings.write_byte(&b, ' ')
		strings.write_string(&b, digits)
		strings.write_byte(&b, ' ')
		return strings.to_string(b)
	}
	add_ln :: proc(c: ^Context, node: dt.Node, value: string, raw: bool) {
		ln := dt.new_element(c.doc, .inline, "" if raw else value, value)
		dt.list_append(c.doc, ln, dt.K_CLASSES, "ln")
		dt.append_child(c.doc, node, ln)
	}
	lineno := startline
	add_ln(c, node, number(lineno, width), raw)
	lines := strings.split(code, "\n", c.allocator)
	for line in lines[:len(lines) - 1] {
		dt.append_child(doc, node, dt.new_text(doc, concat(line, "\n")))
		lineno += 1
		add_ln(c, node, number(lineno, width), raw)
	}
	dt.append_child(doc, node, dt.new_text(doc, lines[len(lines) - 1]))
}

@(private = "file")
run_math_block :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	options := normalize_options(c, &d.options)
	if err := assert_has_content(d); err != nil do return nil, err
	out := make([dynamic]dt.Node, c.allocator)
	for block in split_string(content_text(c, d), "\n\n", c.allocator) {
		if block == "" do continue
		node := dt.new_element(c.doc, .math_block, d.block_text, block)
		apply_options(c, node, &options)
		d_set_source_line(c, d, node, d.lineno)
		add_name(c, d, node)
		append(&out, node)
	}
	return out, nil
}

// Python ``str.split(sep)``.
split_string :: proc(s, sep: string, allocator := context.temp_allocator) -> []string {
	return strings.split(s, sep, allocator)
}

@(private = "file")
run_rubric :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	options := normalize_options(c, &d.options)
	rubric_text := d.arguments[0]
	textnodes, messages := d_inline_text(c, d, rubric_text, d.lineno)
	rubric := element(c, .rubric, rubric_text, textnodes[:])
	apply_options(c, rubric, &options)
	add_name(c, d, rubric)
	out := result_of(c, rubric)
	append(&out, ..messages[:])
	return out, nil
}

// ``BlockQuote.run`` (epigraph, highlights, pull-quote).
@(private = "file")
run_block_quote :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	if err := assert_has_content(d); err != nil do return nil, err
	elements := block_quote(c, d.sm, d.content, d.content_offset)
	for e in elements {
		if !dt.is(c.doc, e, {.block_quote}) do continue
		for cl in d.spec.classes do dt.list_append(c.doc, e, dt.K_CLASSES, cl)
	}
	return elements, nil
}

@(private = "file")
run_compound :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	if err := assert_has_content(d); err != nil do return nil, err
	node := dt.new_element(c.doc, .compound, content_text(c, d))
	for cl in options_list(&d.options, "class") do dt.list_append(c.doc, node, dt.K_CLASSES, cl)
	d_set_source_line(c, d, node, d.lineno)
	add_name(c, d, node)
	d_nested_parse(c, d, node)
	return result_of(c, node), nil
}

@(private = "file")
run_container :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	if err := assert_has_content(d); err != nil do return nil, err
	text := content_text(c, d)
	classes: []string
	if len(d.arguments) > 0 {
		v, err := class_option(c, d.arguments[0])
		if err != "" {
			msg := "\" directive: \""
			return nil, directive_error(
				.ERROR, "Invalid class attribute value for \"", d.name, msg, d.arguments[0], "\".",
			)
		}
		classes = v.([]string)
	}
	node := dt.new_element(c.doc, .container, text)
	for cl in classes do dt.list_append(c.doc, node, dt.K_CLASSES, cl)
	d_set_source_line(c, d, node, d.lineno)
	add_name(c, d, node)
	d_nested_parse(c, d, node)
	return result_of(c, node), nil
}
