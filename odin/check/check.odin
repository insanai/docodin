package check

// Native reStructuredText checking: parse a document and collect the markup
// errors (the docutils system messages raised while parsing), including those
// in the reStructuredText parts of standard directives (see directives.odin).
//
// Directives, interpreted text roles and reference resolution are processed
// by the docutils host (the ``docodin`` Python front end), so their
// diagnostics are not reported here.

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

import rst "../rst"

Options :: struct {
	flags:      rst.Parse_Flags,
	tab_width:  int,
	line_limit: int,
}

DEFAULT_OPTIONS :: Options {
	flags      = {.Match_Titles},
	tab_width  = 8,
	line_limit = 10000,
}

// A diagnostic: a docutils system message, kept in parts for rendering.
Message :: struct {
	line:    int, // 1-based; 0: none
	level:   int, // rst.INFO ... rst.SEVERE
	text:    string, // the message proper
	details: []string, // further paragraphs
	literal: string, // source excerpt carried by the message (literal block)
	span:    Span, // inline markup problems: the offending text
}

// Offending inline text: ``row`` lines below the message line, ending
// ``from_line_end`` bytes before the end of that (de-indented) line.
Span :: struct {
	text:          string,
	row:           int,
	from_line_end: int,
}

LEVEL_NAMES := [?]string{"DEBUG", "INFO", "WARNING", "ERROR", "SEVERE"}

level_name :: proc(level: int) -> string {
	return LEVEL_NAMES[clamp(level, 0, len(LEVEL_NAMES) - 1)]
}

// Position of the first invalid UTF-8 byte of ``data``, or -1.  docutils
// decodes input as strict UTF-8 (a BOM is kept as U+FEFF).
invalid_utf8_offset :: proc(data: []byte) -> int {
	for i := 0; i < len(data); {
		if data[i] < 0x80 {
			i += 1
			continue
		}
		r, size := utf8.decode_rune(data[i:])
		if r == utf8.RUNE_ERROR && size <= 1 do return i
		i += size
	}
	return -1
}

// Parse ``text`` and return its diagnostics in source order.  Everything is
// allocated with ``context.allocator``.
check_text :: proc(text: string, opts: Options) -> []Message {
	p := rst.Parser {
		allocator = context.allocator,
		settings  = rst.settings_from_flags(opts.flags, opts.tab_width, opts.line_limit),
	}
	doc, line_count, final_offset := rst.parse_text(&p, text, 0, true)
	c := Collector {
		p        = &p,
		messages = make([dynamic]Message, 0, 16),
	}
	collect_document(&c, doc)
	if final_offset >= 0 {
		// docutils resolves a line number <= 0 with ``input_lines.info(line - 1)``:
		// a negative index, counted from the end of the input
		for &m in c.messages do if m.line <= 0 && line_count + m.line > 0 do m.line += line_count
	}
	// docutils reports messages as they are created, which is source order
	// except for inline messages; report them by line
	slice.stable_sort_by(c.messages[:], proc(a, b: Message) -> bool {return a.line < b.line})
	return c.messages[:]
}

// --- message collection ------------------------------------------------------------

@(private = "file")
Style :: struct {
	chars: [2]u8,
	n:     int, // 1: underline only, 2: overline and underline
}

@(private = "file")
Collector :: struct {
	p:             ^rst.Parser,
	messages:      [dynamic]Message,
	title_styles:  [dynamic]Style,
	section_level: int,
}

// Context of a node's children during the walk.
@(private = "file")
Walk :: struct {
	line:  int, // nearest enclosing line: docutils passes it to the inliner
	delta: int, // source line minus absolute line (table cells, substitutions)
	ctx:   Context, // ``state_machine.node`` of directives among the children
	subst: bool, // inside a substitution definition
}

@(private = "file")
collect_document :: proc(c: ^Collector, doc: ^rst.Node) {
	c.title_styles = make([dynamic]Style, 0, 8)
	w := Walk {
		ctx = .Root,
	}
	for n := doc.first; n != nil; n = n.next {
		if n.kind == .Section_Title {
			section_title(c, n)
		} else {
			collect(c, n, w)
		}
	}
}

@(private = "file")
collect :: proc(c: ^Collector, n: ^rst.Node, w: Walk) {
	line := int(n.line) if n.line > 0 else w.line
	#partial switch n.kind {
	case .System_Message:
		add_message(c, n)
		return
	case .Problematic:
		row, from_end := rst.inline_position_unpack(n.num[1])
		append(&c.messages, Message{line = line, level = int(n.num[0]), text = n.name,
			span = {n.text, row, from_end}})
		return
	case .Directive:
		run_directive(c, n, w)
		return
	case .Text:
		return
	}
	cw := Walk{line, w.delta, .Other, w.subst}
	#partial switch n.kind {
	case .Entry:
		cw.delta -= 1 // cells are nested-parsed with a 1-based offset
	case .Substitution_Definition:
		cw.delta += int(n.num[0])
		cw.subst = true
	}
	collect_children(c, n, cw)
}

@(private = "file")
collect_children :: proc(c: ^Collector, n: ^rst.Node, w: Walk) {
	for ch := n.first; ch != nil; ch = ch.next do collect(c, ch, w)
}

@(private = "file")
add_message :: proc(c: ^Collector, n: ^rst.Node) {
	m := Message{line = int(n.line), level = int(n.num[0]), text = n.text}
	details := make([dynamic]string, 0, 1)
	for ch := n.first; ch != nil; ch = ch.next {
		if ch.kind == .Literal_Block && m.literal == "" {
			m.literal = ch.text
		} else {
			append(&details, ch.text if len(ch.text) > 0 else ch.raw)
		}
	}
	m.details = details[:]
	append(&c.messages, m)
}

// ``RSTState.check_subsection`` at document level: title messages are
// reported first; an inconsistent title is dropped with an error.
@(private = "file")
section_title :: proc(c: ^Collector, n: ^rst.Node) {
	w := Walk {
		line = int(n.line),
		ctx  = .Other,
	}
	title := n.first
	if title != nil {
		for m := title.next; m != nil; m = m.next do collect(c, m, w)
	}
	style := Style {
		n = len(n.name),
	}
	for i in 0 ..< min(len(n.name), 2) do style.chars[i] = n.name[i]

	newlevel := len(c.title_styles) + 1
	for s, i in c.title_styles {
		if s == style {
			newlevel = i + 1
			break
		}
	}
	if newlevel > c.section_level + 1 {
		inconsistent_title(c, n, newlevel)
		return
	}
	c.section_level = newlevel
	if newlevel > len(c.title_styles) do append(&c.title_styles, style)
	if title != nil do collect(c, title, w)
}

@(private = "file")
inconsistent_title :: proc(c: ^Collector, n: ^rst.Node, newlevel: int) {
	b := strings.builder_make()
	strings.write_string(&b, "Established title styles:")
	for s in c.title_styles {
		strings.write_byte(&b, ' ')
		strings.write_byte(&b, s.chars[0])
		if s.n == 2 {
			strings.write_byte(&b, '/')
			strings.write_byte(&b, s.chars[1])
		}
	}
	details := make([]string, 1)
	details[0] = strings.to_string(b)
	text := fmt.aprintf("Inconsistent title style: skip from level %d to %d.", c.section_level, newlevel)
	append(&c.messages, Message{line = int(n.line), level = rst.ERROR, text = text, details = details,
		literal = n.text})
}

// --- directives ----------------------------------------------------------------------

// Run the reStructuredText parts of a standard directive (see directives.odin).
@(private = "file")
run_directive :: proc(c: ^Collector, n: ^rst.Node, w: Walk) {
	spec, known := directive_spec(n.name)
	if !known do return
	info, has_info := n.extra.(^rst.Directive_Info)
	if !has_info || info == nil do return
	b, ok := parse_directive_block(info, spec)
	if !ok do return

	// the reporter's current line is the outermost machine's, which docutils
	// leaves at the end of the directive block while the directive runs
	saved_root_line := c.p.root_line
	if c.p.root_line == 0 do c.p.root_line = info.end_offset + 1
	defer c.p.root_line = saved_root_line
	directive_parts(c, &b, spec, int(n.line), w)
}

@(private = "file")
directive_parts :: proc(c: ^Collector, b: ^Directive_Block, spec: Directive_Spec, lineno: int, w: Walk) {
	has_content := len(b.content) > 0
	switch spec.kind {
	case .Admonition, .Figure:
		if has_content do parse_content(c, b, w, .Other if spec.kind == .Admonition else .Anonymous)
	case .Generic_Admonition:
		if !has_content do return
		parse_title(c, b.arguments[0], lineno)
		parse_content(c, b, w, .Other)
	case .Topic, .Sidebar:
		if w.ctx == .Other || !has_content do return
		if len(b.arguments) > 0 {
			parse_title(c, b.arguments[0], lineno)
			if subtitle, given := option_value(b, "subtitle"); given do parse_title(c, subtitle, lineno)
		}
		parse_content(c, b, w, .Sidebar if spec.kind == .Sidebar else .Other)
	case .Rubric:
		parse_title(c, b.arguments[0], lineno)
	case .Block_Quote:
		if has_content do parse_block_quote(c, b, lineno, w)
	case .Body:
		if !has_content do return
		if len(b.arguments) > 0 && !valid_class_value(b.arguments[0]) do return
		parse_content(c, b, w, .Other)
	case .Parsed_Literal:
		if has_content do parse_title(c, strings.join(b.content, "\n"), lineno)
	case .Class:
		if valid_class_value(b.arguments[0]) && has_content do parse_content(c, b, w, .Anonymous)
	case .Replace:
		if w.subst && has_content do parse_content(c, b, w, .Anonymous)
	case .Table:
		if !has_content do return
		if len(b.arguments) > 0 do parse_title(c, b.arguments[0], lineno)
		parse_content(c, b, w, .Anonymous)
	case .Contents:
		if w.ctx != .Other && len(b.arguments) > 0 do parse_title(c, b.arguments[0], lineno)
	}
}

// ``state.nested_parse(content, content_offset, node)``
@(private = "file")
parse_content :: proc(c: ^Collector, b: ^Directive_Block, w: Walk, ctx: Context) {
	node := rst.new_node(.Block_Quote, 0, c.p.allocator) // anonymous container
	sm := rst.make_state_machine(c.p, nil, 0, node)
	sm.line_delta = w.delta
	rst.nested_parse(&sm, b.content, b.content_offset, node)
	collect_children(c, node, Walk{b.content_offset + 1, w.delta, ctx, false})
}

// epigraph, highlights, pull-quote: ``state.block_quote(content, content_offset)``
@(private = "file")
parse_block_quote :: proc(c: ^Collector, b: ^Directive_Block, lineno: int, w: Walk) {
	out := rst.new_node(.Block_Quote, 0, c.p.allocator)
	sm := rst.make_state_machine(c.p, nil, 0, out)
	sm.line_delta = w.delta
	rst.block_quote(&sm, b.content, b.content_offset, out)
	collect_children(c, out, Walk{lineno, w.delta, .Other, false})
}

// ``state.inline_text(text, lineno)``
@(private = "file")
parse_title :: proc(c: ^Collector, text: string, lineno: int) {
	nodes := rst.parse_inline(c.p, text, lineno)
	w := Walk {
		line = lineno,
		ctx  = .Other,
	}
	for n := nodes.first; n != nil; n = n.next do collect(c, n, w)
}
