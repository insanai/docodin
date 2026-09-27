package reader

import "core:strings"

import dt "../doctree"
import rst "../rst"

// The directive framework: lookup by (English) name, ``Body.run_directive``
// with ``parse_directive_block`` (arguments, options, content), the option
// field parsing of the ``ExtensionOptions`` state, and the ``Directive``
// run protocol (``DirectiveError`` levels, ``nested_parse``,
// ``inline_text``).

// The nodes a directive (or role) returns.
Nodes :: [dynamic]dt.Node

// A list that nodes (or messages) are appended to.
Node_Out :: ^[dynamic]dt.Node

// A ``DirectiveError`` raised by ``run``, if any.
Failure :: Maybe(Directive_Error)

// ``DirectiveError``: a message of ``level`` with the directive block.
Directive_Error :: struct {
	level: dt.Level,
	msg:   string,
}

Directive_Run :: proc(c: ^Context, d: ^Directive) -> (nodes: Nodes, err: Failure)

// A directive class (``Directive`` subclass attributes and ``run``).
Directive_Spec :: struct {
	required_arguments:        int,
	optional_arguments:        int,
	final_argument_whitespace: bool,
	option_spec:               []Option_Spec, // empty: None
	has_content:               bool,
	run:                       Directive_Run,
	parsed_literal:            bool, // ``ParsedLiteral`` (line renumbering)
	tag:                       dt.Tag, // ``node_class`` (admonitions, topic, sidebar)
	classes:                   []string, // ``BlockQuote.classes``
}

// A directive instance.
Directive :: struct {
	name:           string,
	arguments:      []string,
	options:        Options,
	content:        ^String_List,
	lineno:         int,
	content_offset: int,
	block_text:     string,
	sm:             ^Machine, // ``state_machine``
	subst:          bool, // ``state`` is a ``SubstitutionDef`` state
	spec:           ^Directive_Spec,
}

// ``Directive.error(message)`` etc.
directive_error :: proc(level: dt.Level, parts: ..string) -> Directive_Error {
	return {level, strings.concatenate(parts, context.temp_allocator)}
}

// ``(K, line, name, block_text, lines, line_offset, end_offset, blank_finish)``:
// run a directive; true when it inserted input lines.
build_directive :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	parent: dt.Node,
	sm_in: ^Machine,
	subst: bool,
	alt: string,
) -> bool {
	doc := c.doc
	d := rst.node_data(t, n)
	info, _ := rst.directive_info(t, n)
	ctx_sm: Machine
	sm := sm_in
	if parent != sm.node {
		ctx_sm = context_machine(sm, parent)
		sm = &ctx_sm
	}
	lineno := int(d.line)
	spec, messages := lookup_directive(c, d.name)
	extend(c, parent, messages[:])
	// docutils consumes the directive block before running (or rejecting)
	// the directive: the document's current line is the block's last line
	set_current(c, sm, info.end_offset + 1)
	if spec == nil {
		text := concat("Unknown directive type \"", d.name, "\".")
		lit := dt.new_element(doc, .literal_block, d.raw, d.raw)
		dt.append_child(doc, parent, dt.error(doc, text, {children = {lit}, line = lineno}))
		return false
	}
	sm.line_offset = info.end_offset - sm.input_offset
	at_line(c, int(d.num[1])) // docutils' root machine (the reporter's line)
	before := sl_len(sm.lines) if sm.lines != nil else c.line_count
	indented := block_lines(c, sm, info.lines, info.line_offset)
	dir := Directive {
		name       = d.name,
		lineno     = lineno,
		block_text = d.raw,
		sm         = sm,
		subst      = subst,
		spec       = spec,
	}
	dir.options = make(Options, c.allocator)
	if subst do append(&dir.options, Option{"alt", alt})
	if err := parse_directive_block(c, &dir, indented, info.line_offset); err != "" {
		text := concat("Error in \"", d.name, "\" directive:\n", err, ".")
		lit := dt.new_element(doc, .literal_block, d.raw, d.raw)
		dt.append_child(doc, parent, dt.error(doc, text, {children = {lit}, line = lineno}))
		return false
	}
	if d.num[0] != 0 do c.insert_mode = .Skip // the parser inserted the lines
	removed := c.removed_lines // before the directive's nested parses
	result := run_directive(c, &dir)
	c.insert_mode = .Insert
	extend(c, parent, result[:])
	if removed > 0 do note_directive_lines(c, result[:], spec, dir.content_offset, removed)
	if sm.lines != nil && sl_len(sm.lines) != before {
		process_inserted_input(c, sm, before)
		return true
	}
	return false
}

// ``directive.run()``, turning a ``DirectiveError`` into its message.
run_directive :: proc(c: ^Context, d: ^Directive) -> [dynamic]dt.Node {
	nodes, err := d.spec.run(c, d)
	e, failed := err.?
	if !failed do return nodes
	msg := dt.system_message(c.doc, e.level, e.msg, {line = d.lineno})
	dt.append_child(c.doc, msg, dt.new_element(c.doc, .literal_block, d.block_text, d.block_text))
	out := make([dynamic]dt.Node, c.allocator)
	append(&out, msg)
	return out
}

// Directive nodes without a source carry an absolute line, and so does
// ``parsed-literal``'s block (``content_offset + 1``).
@(private = "file")
note_directive_lines :: proc(
	c: ^Context,
	result: []dt.Node,
	spec: ^Directive_Spec,
	content_offset: int,
	removed: int,
) {
	doc := c.doc
	for node in result {
		for n in dt.traverse(doc, node, dt.tags_of(.Element)) {
			_, has_src := dt.source(doc, n)
			_, has_line := dt.line(doc, n)
			if !has_src && has_line do note_absolute_line(c, n, removed)
		}
	}
	if spec.parsed_literal && len(result) > 0 && dt.is(doc, result[0], {.literal_block}) {
		if ln, ok := dt.line(doc, result[0]); ok && ln == content_offset + 1 {
			note_absolute_line(c, result[0], removed)
		}
	}
}

// The directive block as a slice of the input lines (so that nested
// parses and insertions reach the enclosing input), with the parser's
// de-indented text.
block_lines :: proc(c: ^Context, sm: ^Machine, lines: []string, line_offset: int) -> ^String_List {
	il := input_lines(c, sm)
	// views (table cells, substitution definitions) number their lines
	// ``line_delta`` away from the shared input lines
	start := line_offset + sm.line_delta - sm.input_offset
	end := start + len(lines)
	if 0 <= start && end <= sl_len(il) {
		block := sl_slice(il, start, end)
		copy(block.data[:], lines)
		if sm.disconnected do block.parent = nil // insertions stay in the block
		return block
	}
	return sl_make(lines, c.source, c.allocator)
}

// --- parse_directive_block ------------------------------------------------------------

// ``Body.parse_directive_block``: fills the arguments, options, content
// and content offset of ``d``; returns the ``MarkupError`` text, if any.
parse_directive_block :: proc(
	c: ^Context,
	d: ^Directive,
	indented: ^String_List,
	line_offset_in: int,
) -> string {
	spec := d.spec
	line_offset := line_offset_in
	if sl_len(indented) > 0 && is_blank(indented.data[0]) {
		sl_trim_start(indented)
		line_offset += 1
	}
	for sl_len(indented) > 0 && is_blank(indented.data[sl_len(indented) - 1]) {
		sl_trim_end(indented)
	}
	has_args := spec.required_arguments > 0 || spec.optional_arguments > 0
	b := split_directive_block(indented, line_offset, has_args || len(spec.option_spec) > 0)
	if len(spec.option_spec) > 0 {
		err: string
		b.arg_block, err = parse_directive_options(c, d, b.arg_block)
		if err != "" do return err
	} else {
		clear(&d.options) // the presets only apply to directives with options
	}
	return finish_directive_block(c, d, &b, indented, line_offset)
}

// The rest of ``parse_directive_block``: content and arguments.
@(private = "file")
finish_directive_block :: proc(
	c: ^Context,
	d: ^Directive,
	b: ^Directive_Block,
	indented: ^String_List,
	line_offset: int,
) -> string {
	spec := d.spec
	has_args := spec.required_arguments > 0 || spec.optional_arguments > 0
	if sl_len(b.arg_block) > 0 && !has_args {
		b.content = sl_concat(b.arg_block, sl_slice(indented, b.split))
		b.content_offset = line_offset
		b.arg_block = sl_slice(indented, 0, 0)
	}
	for sl_len(b.content) > 0 && is_blank(b.content.data[0]) {
		sl_trim_start(b.content)
		b.content_offset += 1
	}
	d.arguments = nil
	if has_args {
		err: string
		d.arguments, err = parse_directive_arguments(c, spec, b.arg_block)
		if err != "" do return err
	}
	if sl_len(b.content) > 0 && !spec.has_content do return "no content permitted"
	d.content = b.content
	d.content_offset = b.content_offset
	return ""
}

// A directive block split into arguments (and options) and content.
@(private = "file")
Directive_Block :: struct {
	arg_block:      ^String_List,
	content:        ^String_List,
	content_offset: int,
	split:          int, // index of the first line after the argument block
}

// With arguments or options, the argument block ends at the first blank
// line; else everything is content.
@(private = "file")
split_directive_block :: proc(
	indented: ^String_List,
	line_offset: int,
	has_arg_block: bool,
) -> Directive_Block {
	if sl_len(indented) == 0 || !has_arg_block {
		return {sl_slice(indented, 0, 0), indented, line_offset, 0}
	}
	i := 0
	for i < sl_len(indented) && !is_blank(indented.data[i]) do i += 1
	return {sl_slice(indented, 0, i), sl_slice(indented, i + 1), line_offset + i + 1, i}
}

// ``Body.parse_directive_options``: the option block is the argument block
// from the first field marker on.
@(private = "file")
parse_directive_options :: proc(
	c: ^Context,
	d: ^Directive,
	arg_block_in: ^String_List,
) -> (
	arg_block: ^String_List,
	err: string,
) {
	arg_block = arg_block_in
	for line, i in arg_block_in.data {
		if _, _, ok := rst.match_field_marker(line); !ok do continue
		opt_block := sl_slice(arg_block_in, i)
		arg_block = sl_slice(arg_block_in, 0, i)
		err = parse_extension_options(c, d, opt_block)
		return
	}
	return
}

@(private = "file")
parse_directive_arguments :: proc(
	c: ^Context,
	spec: ^Directive_Spec,
	arg_block: ^String_List,
) -> (
	arguments: []string,
	err: string,
) {
	required := spec.required_arguments
	optional := spec.optional_arguments
	arg_text := sl_join(arg_block, c.allocator)
	arguments = dt.py_split(arg_text, c.allocator)
	if len(arguments) < required {
		err = concat(itoa(required), " argument(s) required, ", itoa(len(arguments)), " supplied")
	} else if len(arguments) > required + optional {
		if spec.final_argument_whitespace {
			arguments = py_split_max(arg_text, required + optional - 1, c.allocator)
		} else {
			err = concat(
				"maximum ", itoa(required + optional), " argument(s) allowed, ",
				itoa(len(arguments)), " supplied",
			)
		}
	}
	return
}

// --- extension options ---------------------------------------------------------------

// A field of the ``ExtensionOptions`` state.
@(private = "file")
Option_Field :: struct {
	name:       string, // ``field[0].astext()``
	paragraphs: [dynamic]string,
	messages:   bool, // the name's inline markup reported messages
}

// ``Body.parse_extension_options``: the options of ``datalines`` into
// ``d.options``; returns the error text, if any.
@(private = "file")
parse_extension_options :: proc(c: ^Context, d: ^Directive, datalines: ^String_List) -> string {
	fields, complete, blank_finish, stop := parse_option_fields(c, datalines)
	// docutils parses the block in a nested state machine: it runs to the
	// end of its input (the document's current line becomes undefined) or
	// steps back from the first line that is not an option
	if n := len(datalines.items); n > 0 {
		if complete {
			c.doc.current_source, c.doc.current_line = datalines.items[n - 1].source, nil
		} else {
			info, _, _ := sl_info(datalines, stop - 1)
			c.doc.current_source, c.doc.current_line = info.source, info.offset + 1
		}
	}
	if !complete do return "invalid option block"
	if err := extract_extension_options(c, d, fields[:]); err != "" do return err
	if !blank_finish do return "option data incompletely parsed"
	return ""
}

// Run the ``ExtensionOptions`` state over directive option lines: the
// fields, whether the block parsed completely, ``blank_finish`` and the
// index of the first line not in the field list.
@(private = "file")
parse_option_fields :: proc(
	c: ^Context,
	datalines: ^String_List,
) -> (
	fields: [dynamic]Option_Field,
	complete: bool,
	blank_finish: bool,
	stop: int,
) {
	fields = make([dynamic]Option_Field, c.allocator)
	lines := datalines.data[:]
	blank_finish = true
	container := dt.new_element(c.doc, .field_list)
	i := 0
	for i < len(lines) {
		line := lines[i]
		if is_blank(line) {
			i += 1
			continue
		}
		name, end, ok := rst.match_field_marker(line)
		if line[0] == ' ' || !ok do return fields, false, blank_finish, i
		block_end, indent, bf := indented_block(lines, i + 1)
		blank_finish = bf
		body := make([dynamic]string, c.allocator)
		append(&body, line[end:])
		for ln in lines[i + 1:block_end] {
			append(&body, cp_slice(ln, indent) if indent > 0 else ln)
		}
		append(&fields, option_field(c, name, body[:], i + 1, container))
		i = block_end
	}
	return fields, true, blank_finish, len(lines)
}

// ``get_first_known_indented``: (end index, common indent, blank_finish).
@(private = "file")
indented_block :: proc(
	lines: []string,
	start: int,
) -> (end: int, indent: int, blank_finish: bool) {
	end = start
	indent = -1
	for end < len(lines) {
		ln := lines[end]
		if len(ln) > 0 && ln[0] != ' ' do return end, max(indent, 0), is_blank(lines[end - 1])
		stripped := lstrip(ln)
		if stripped != "" {
			li := cp_len(ln) - cp_len(stripped)
			indent = li if indent < 0 else min(indent, li)
		}
		end += 1
	}
	return end, max(indent, 0), true
}

// A field whose body paragraphs hold the plain option text.  Names other
// than plain words are inline-parsed as docutils does (``alt_`` is a
// reference); their messages make the body invalid.
@(private = "file")
option_field :: proc(
	c: ^Context,
	name: string,
	body_in: []string,
	lineno: int,
	container: dt.Node,
) -> Option_Field {
	f := Option_Field {
		name       = name,
		paragraphs = make([dynamic]string, c.allocator),
	}
	if !is_simple_option_name(name) && c.dry_run {
		c.dry_run_failed = true // inline markup has side effects
	} else if !is_simple_option_name(name) {
		nodes, msgs := inline_text(c, name, lineno, container)
		field_name := element(c, .field_name, name, nodes[:])
		f.name = dt.astext(c.doc, field_name, c.allocator)
		f.messages = len(msgs) > 0
		// ``field_body(..., *messages)``: the messages have a parent (they
		// are not loose parse messages)
		element(c, .field_body, "", msgs[:])
	}
	body := body_in
	for len(body) > 0 && is_blank(body[0]) do body = body[1:]
	para := make([dynamic]string, c.allocator)
	for k in 0 ..= len(body) {
		ln := body[k] if k < len(body) else ""
		if !is_blank(ln) {
			append(&para, ln)
		} else if len(para) > 0 {
			append(&f.paragraphs, join_lines(para[:], c.allocator))
			clear(&para)
		}
	}
	return f
}

// Option names that are plain text when inline-parsed.
@(private = "file")
is_simple_option_name :: proc(name: string) -> bool {
	if name == "" do return false
	for i in 0 ..< len(name) {
		ch := name[i]
		ok := (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')
		if !(ok || ch == '.' || ch == '+' || ch == '-') do return false
	}
	return true
}

// ``utils.extract_extension_options``: convert the fields with the
// directive's option spec into ``d.options``.
@(private = "file")
extract_extension_options :: proc(c: ^Context, d: ^Directive, fields: []Option_Field) -> string {
	// extract_options
	names := make([dynamic]string, 0, len(fields), c.allocator)
	values := make([dynamic]Maybe(string), 0, len(fields), c.allocator)
	for f in fields {
		if len(dt.py_split(f.name)) != 1 {
			return concat(
				"invalid option data: extension option field name ",
				"may not contain multiple words",
			)
		}
		name := dt.py_lower(f.name, c.allocator)
		if f.messages || len(f.paragraphs) > 1 {
			return concat(
				"invalid option data: extension option field body may contain\n",
				"a single paragraph only (option \"", name, "\")",
			)
		}
		append(&names, name)
		value: Maybe(string)
		if len(f.paragraphs) == 1 do value = f.paragraphs[0]
		append(&values, value)
	}
	// assemble_option_dict
	options := make(Options, c.allocator)
	for name, i in names {
		conv := find_converter(d.spec.option_spec, name)
		if conv == nil do return concat("unknown option: \"", name, "\"")
		if options_has(&options, name) {
			return concat("invalid option data: duplicate option \"", name, "\"")
		}
		value, err := conv(c, values[i])
		if err != "" {
			return concat(
				"invalid option value: (option: \"", name, "\"; value: ",
				maybe_repr(values[i]), ")\n", err,
			)
		}
		append(&options, Option{name, value})
	}
	for o in options do options_set(&d.options, o.name, o.value)
	return ""
}

@(private = "file")
find_converter :: proc(spec: []Option_Spec, name: string) -> Converter {
	for s in spec do if s.name == name do return s.convert
	return nil
}

@(private = "file")
maybe_repr :: proc(v: Maybe(string)) -> string {
	s, ok := v.?
	return py_repr(s) if ok else "None"
}

// --- directive helpers --------------------------------------------------------------------

// ``self.state.inline_text(text, lineno)``.
d_inline_text :: proc(
	c: ^Context,
	d: ^Directive,
	text: string,
	lineno: int,
) -> ([dynamic]dt.Node, [dynamic]dt.Node) {
	return inline_text(c, text, lineno, d.sm.node)
}

// ``self.state.nested_parse(self.content, self.content_offset, node)``.
d_nested_parse :: proc(c: ^Context, d: ^Directive, node: dt.Node) -> int {
	return nested_parse(c, d.sm, d.content, d.content_offset, node)
}

// ``self.state_machine.get_source_and_line(self.lineno)`` into ``n``.
d_set_source_line :: proc(c: ^Context, d: ^Directive, n: dt.Node, lineno: Maybe(int)) {
	src, ln, _ := get_source_and_line(c, d.sm, lineno)
	dt.set_source(c.doc, n, src)
	dt.set_line(c.doc, n, ln)
}

// ``Directive.add_name(node)``.
add_name :: proc(c: ^Context, d: ^Directive, n: dt.Node) {
	v, ok := options_pop(&d.options, "name")
	if !ok do return
	s, _ := v.(string)
	name := normalize_name(s)
	if dt.has_attr(c.doc, n, "name") do dt.delete_attr(c.doc, n, "name")
	dt.list_append(c.doc, n, dt.K_NAMES, name)
	dt.note_explicit_target(c.doc, n, n)
}

// ``Directive.assert_has_content()``.
assert_has_content :: proc(d: ^Directive) -> Maybe(Directive_Error) {
	if d.content != nil && sl_len(d.content) > 0 do return nil
	return directive_error(
		.ERROR, "Content block expected for the \"", d.name, "\" directive; none found.",
	)
}

// A result list.
result_of :: proc(c: ^Context, nodes: ..dt.Node) -> [dynamic]dt.Node {
	out := make([dynamic]dt.Node, 0, max(len(nodes), 2), c.allocator)
	append(&out, ..nodes)
	return out
}

// ``'\n'.join(self.content)``.
content_text :: proc(c: ^Context, d: ^Directive) -> string {
	if d.content == nil do return ""
	return sl_join(d.content, c.allocator)
}
