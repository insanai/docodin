package lsp

// Document analysis: one walk of the parse tree (the reader's, which keeps
// it with source spans) into flat tables:
//
// * ``items``: definitions (sections, targets, substitution definitions,
//   footnotes, citations) and their uses (references), resolved by
//   ``resolve`` with docutils' name normalisation;
// * ``tokens``: semantic tokens;
// * ``folds``: folding ranges;
// * ``problems``: the inline markup the parser reports.
//
// Positions are the nodes' source spans.  The reST content of standard
// directives (admonitions, topics, tables, figures, ...) is parsed into the
// tree as docutils' directives parse it (``check.parse_directive_block``),
// so the constructs inside them are found too.  Everything is allocated in
// the snapshot's arena.

import "base:runtime"
import "core:strings"

import check "../check"
import dt "../doctree"
import rd "../reader"
import rst "../rst"

Item_Kind :: enum u8 {
	// definitions
	Section,
	Target,           // .. _name: URI / .. _name: other_ / .. _name:
	Anonymous_Target, // __ URI / .. __: URI
	Inline_Target,    // _`name`
	Embedded_Target,  // `text <URI>`_ defines "text"
	Name_Option,      // the :name: option of a directive
	Substitution_Definition,
	Footnote,
	Citation,
	// uses
	Reference,
	Anonymous_Reference,
	Substitution_Reference,
	Footnote_Reference,
	Citation_Reference,
	// other markup with a name
	Role,
	Directive,
}

Item_Kinds :: bit_set[Item_Kind]

DEFINITION_KINDS :: Item_Kinds {
	.Section, .Target, .Anonymous_Target, .Inline_Target, .Embedded_Target, .Name_Option,
	.Substitution_Definition, .Footnote, .Citation,
}

USE_KINDS :: Item_Kinds {
	.Reference, .Anonymous_Reference, .Substitution_Reference, .Footnote_Reference,
	.Citation_Reference,
}

NO_ITEM :: i32(-1)

Item :: struct {
	kind:     Item_Kind,
	span:     Span,   // definitions: the name; uses: the whole markup
	full:     Span,   // the whole construct (a section: its title to its end)
	name:     string, // normalised reference name or label ("" when anonymous)
	label:    string, // as written: title text, target name, footnote label
	value:    string, // URI, reference name (``indirect``) or definition text
	indirect: bool,   // ``value`` is a reference name
	target:   i32,    // uses: the definition
	parent:   i32,    // the enclosing section
	level:    i32,    // sections: 1 for the top level
}

Fold_Kind :: enum u8 {
	Region,
	Comment,
}

// Lines (LSP numbering) of a folding range.
Fold :: struct {
	start, end: i32,
	kind:       Fold_Kind,
}

// Inline markup the parser reports (a ``problematic`` node): the message's
// line (as the parse tree numbers it) and text, and the offending markup.
Problem :: struct {
	line:    i32,
	message: string,
	span:    Span,
}

Analysis :: struct {
	tree:     rst.Tree, // the parse, with the directive content parsed into it
	items:    [dynamic]Item,
	tokens:   [dynamic]Token,
	folds:    [dynamic]Fold,
	problems: [dynamic]Problem,
}

// Analyse ``text`` from the reader's parse ``tree`` if it kept one (else
// the text is parsed here).  The tree grows: the content of directives is
// parsed into it.
analyze :: proc(
	text: string,
	idx: ^rst.Line_Index,
	allocator: runtime.Allocator,
	tree := rd.Parse_Tree{},
) -> Analysis {
	context.allocator = allocator
	context.temp_allocator = allocator
	a := Analysis {
		items    = make([dynamic]Item, 0, 64),
		tokens   = make([dynamic]Token, 0, 256),
		folds    = make([dynamic]Fold, 0, 32),
		problems = make([dynamic]Problem, 0, 8),
	}
	p := tree.parser
	doc := tree.root
	if doc == rst.NO_NODE || !rst.has_spans(&p.tree) {
		flags := rst.Parse_Flags{.Match_Titles, .Spans}
		p = rst.Parser {
			allocator = allocator,
			settings  = rst.settings_from_flags(flags, TAB_WIDTH, 0),
		}
		doc, _, _ = rst.parse_text(&p, text, 0, true)
	}
	b := Builder {
		idx      = idx,
		p        = &p,
		t        = &p.tree,
		a        = &a,
		section  = NO_ITEM,
		sections = make([dynamic]i32, 0, 16),
	}
	walk_children(&b, doc, {})
	finish_sections(&b)
	resolve(&a)
	a.tree = p.tree
	return a
}

// --- the walk --------------------------------------------------------------------------

@(private = "file")
Title_Style :: struct {
	chars: [2]u8,
	n:     int, // 1: underline only, 2: overline and underline
}

@(private = "file")
Builder :: struct {
	idx:           ^rst.Line_Index,
	p:             ^rst.Parser,
	t:             ^rst.Tree,
	a:             ^Analysis,
	title_styles:  [dynamic]Title_Style,
	section_level: int,
	section:       i32, // the current section
	sections:      [dynamic]i32,
}

// Context of a node during the walk.
@(private = "file")
Walk :: struct {
	subst: bool, // inside a substitution definition
}

@(private = "file")
FOLDED_KINDS :: bit_set[rst.Node_Kind] {
	.Bullet_List, .Enumerated_List, .Definition_List, .Field_List, .Option_List,
	.Literal_Block, .Doctest_Block, .Line_Block, .Table, .Block_Quote,
}

@(private = "file")
walk_children :: proc(b: ^Builder, n: rst.Node, w: Walk) {
	it := rst.children(b.t, n)
	for c in rst.iterate(&it) do walk(b, c, w)
}

@(private = "file")
walk :: proc(b: ^Builder, n: rst.Node, w: Walk) {
	d := rst.node_data(b.t, n)
	span := node_span(b.t, n)
	#partial switch d.kind {
	case .Section_Title:
		section_title(b, n, span)
	case .Directive:
		directive(b, n, span, w)
	case .Target:
		target(b, d, span)
	case .Substitution_Definition:
		substitution_definition(b, n, span)
	case .Comment:
		add_token(b, span, .Comment)
		add_fold(b, span, .Comment)
	case .Transition:
		add_token(b, span, .Operator)
	case .System_Message, .Include_End:
	case:
		if d.kind == .Footnote || d.kind == .Citation do footnote(b, d, span)
		if d.kind in FOLDED_KINDS do add_fold(b, span, .Region)
		inline_item(b, d, n, span)
		walk_children(b, n, w)
	}
}

@(private = "file")
add_token :: proc(b: ^Builder, span: Span, type: Token_Type, mods := Token_Modifiers{}) {
	if type == .None || span.end <= span.start do return
	append(&b.a.tokens, Token{span, type, mods})
}

@(private = "file")
add_fold :: proc(b: ^Builder, span: Span, kind: Fold_Kind) {
	first := to_lsp(b.idx, span.start).line
	last := to_lsp(b.idx, span.end).line
	if last > first do append(&b.a.folds, Fold{i32(first), i32(last), kind})
}

@(private = "file")
add_item :: proc(b: ^Builder, item: Item) -> i32 {
	it := item
	it.target = NO_ITEM
	if it.kind != .Section do it.parent = b.section
	if it.full == {} do it.full = it.span
	append(&b.a.items, it)
	return i32(len(b.a.items) - 1)
}

// --- sections --------------------------------------------------------------------------

// ``RSTState.check_subsection``: the level of the title style; a title
// that skips a level makes no section.
@(private = "file")
section_title :: proc(b: ^Builder, n: rst.Node, span: Span) {
	d := rst.node_data(b.t, n)
	style := Title_Style {
		n = len(d.name),
	}
	for i in 0 ..< min(len(d.name), 2) do style.chars[i] = d.name[i]
	level := len(b.title_styles) + 1
	for s, i in b.title_styles {
		if s == style {
			level = i + 1
			break
		}
	}
	line := int(d.line)
	add_token(b, content_span(b.t, line + 1), .Operator)
	if style.n == 2 do add_token(b, content_span(b.t, line - 1), .Operator)
	if level > b.section_level + 1 do return
	b.section_level = level
	if level > len(b.title_styles) do append(&b.title_styles, style)

	title := rst.first_child(b.t, n)
	label := title_text(b, title)
	item := Item {
		kind   = .Section,
		span   = node_span(b.t, title) if title != rst.NO_NODE else span,
		full   = span,
		name   = dt.fully_normalize_name(label),
		label  = label,
		parent = section_parent(b, level),
		level  = i32(level),
	}
	b.section = add_item(b, item)
	append(&b.sections, b.section)
	if title != rst.NO_NODE do inline_children(b, title, .Namespace)
}

@(private = "file")
section_parent :: proc(b: ^Builder, level: int) -> i32 {
	for i := len(b.sections) - 1; i >= 0; i -= 1 {
		if b.a.items[b.sections[i]].level < i32(level) do return b.sections[i]
	}
	return NO_ITEM
}

// The text of a title (``title.astext()``).
@(private = "file")
title_text :: proc(b: ^Builder, title: rst.Node) -> string {
	if title == rst.NO_NODE do return ""
	sb := strings.builder_make()
	it := rst.children(b.t, title)
	for c in rst.iterate(&it) {
		d := rst.node_data(b.t, c)
		#partial switch d.kind {
		case .Footnote_Reference, .Citation_Reference, .Problematic, .Literal:
			strings.write_string(&sb, d.text)
		case:
			strings.write_string(&sb, rst.unescape(d.text, context.allocator))
		}
	}
	return strings.to_string(sb)
}

// A section ends before the next title of its level or a higher one.
@(private = "file")
finish_sections :: proc(b: ^Builder) {
	items := b.a.items[:]
	last := last_nonblank(b.t, rst.line_count(b.t), 0)
	for s, k in b.sections {
		end := last
		for j in k + 1 ..< len(b.sections) {
			next := items[b.sections[j]]
			if next.level > items[s].level do continue
			end = last_nonblank(b.t, line_of(b.t, next.full.start) - 1, 0)
			break
		}
		items[s].full.end = max(content_span(b.t, end).end, items[s].full.end)
		add_fold(b, items[s].full, .Region)
	}
}

// --- explicit markup -------------------------------------------------------------------

@(private = "file")
target :: proc(b: ^Builder, d: rst.Node_Data, span: Span) {
	item := Item {
		full     = span,
		value    = d.text,
		indirect = rst.Target_Type(d.num[0]) == .Refname,
	}
	if d.num[1] == 1 {
		item.kind = .Anonymous_Target
		item.span = find_in(b.t, span, "__") or_else first_line(b, span)
	} else {
		item.kind = .Target
		item.span = name_after(b, span, "_", d.name)
		item.name = dt.fully_normalize_name(d.name)
		item.label = d.name
	}
	add_item(b, item)
	add_token(b, item.span, .Decorator, {.Declaration})
}

// The span of ``name`` after ``marker`` on the first line of ``span`` (the
// line if it cannot be found).
@(private = "file")
name_after :: proc(b: ^Builder, span: Span, marker, name: string) -> Span {
	from := span
	if m, ok := find_in(b.t, span, marker); ok do from.start = m.end
	return find_in(b.t, from, name) or_else first_line(b, span)
}

@(private = "file")
first_line :: proc(b: ^Builder, span: Span) -> Span {
	return content_span(b.t, line_of(b.t, span.start))
}

@(private = "file")
substitution_definition :: proc(b: ^Builder, n: rst.Node, span: Span) {
	d := rst.node_data(b.t, n)
	name := name_after(b, span, "|", d.name)
	item := Item {
		kind  = .Substitution_Definition,
		span  = name,
		full  = span,
		name  = dt.whitespace_normalize_name(d.name),
		label = d.name,
		value = strings.trim_right_space(d.raw),
	}
	add_item(b, item)
	add_token(b, widen(name), .Variable, {.Declaration})
	walk_children(b, n, {subst = true})
}

// A name span with its delimiters ("|name|", "[label]").
@(private = "file")
widen :: proc(span: Span) -> Span {
	return {max(span.start - 1, 0), span.end + 1}
}

@(private = "file")
footnote :: proc(b: ^Builder, d: rst.Node_Data, span: Span) {
	label := name_after(b, span, "[", d.name)
	item := Item {
		kind  = .Footnote if d.kind == .Footnote else .Citation,
		span  = label,
		full  = span,
		name  = footnote_name(d.name, d.kind == .Citation),
		label = d.name,
		value = strings.trim_right_space(d.raw),
	}
	add_item(b, item)
	add_token(b, widen(label), .Enum_Member, {.Declaration})
	add_fold(b, span, .Region)
}

// The reference name of a footnote or citation label: "" for the
// auto-numbered ("#") and auto-symbol ("*") footnotes.
footnote_name :: proc(label: string, citation: bool) -> string {
	if citation do return dt.fully_normalize_name(label)
	if label == "#" || label == "*" do return ""
	if strings.has_prefix(label, "#") do return dt.fully_normalize_name(label[1:])
	return label
}

// --- directives ------------------------------------------------------------------------

@(private = "file")
directive :: proc(b: ^Builder, n: rst.Node, span: Span, w: Walk) {
	d := rst.node_data(b.t, n)
	name, found := find_in(b.t, span, strings.concatenate({d.name, "::"}))
	if found {
		name.end -= 2
		add_token(b, name, .Function)
	} else {
		name = first_line(b, span)
	}
	item := Item {
		kind  = .Directive,
		span  = name,
		full  = span,
		name  = strings.to_lower(d.name),
		label = d.name,
	}
	add_item(b, item)
	info, has_info := rst.directive_info(b.t, n)
	if !has_info do return
	if !w.subst do add_fold(b, span, .Region)
	_, inline_argument := check.directive_spec(d.name)
	arguments_and_options(b, d.name, info, !inline_argument)
	directive_content(b, d.name, info, w)
}

// Tokens of the arguments and options (the first block of lines).  The
// arguments of directives that parse them as inline text get their tokens
// from that parse (``directive_content``).
@(private = "file")
arguments_and_options :: proc(
	b: ^Builder,
	name: string,
	info: rst.Directive_Info,
	args: bool,
) {
	entry, known := find_directive(name)
	spec := entry.spec
	takes_args := args && known && spec.required_arguments + spec.optional_arguments > 0
	for text, i in info.lines {
		if is_blank(text) {
			if i > 0 do break
			continue
		}
		body := rst.strip(text)
		at := view_offset(b.t, body)
		if at < 0 do continue // a line whose tabs were expanded
		span := Span{i32(at), i32(at + len(body))}
		fname, fend, is_field := rst.match_field_marker(body)
		if !is_field {
			if takes_args do add_token(b, span, .Parameter)
			continue
		}
		add_token(b, {span.start, span.start + i32(len(fname) + 2)}, .Property)
		value := rst.strip(body[fend:])
		if strings.to_lower(fname) == "name" && value != "" {
			vat := view_offset(b.t, value)
			if vat < 0 do continue
			vspan := Span{i32(vat), i32(vat + len(value))}
			option := Item {
				kind  = .Name_Option,
				span  = vspan,
				name  = dt.fully_normalize_name(value),
				label = value,
			}
			add_item(b, option)
			add_token(b, vspan, .Decorator, {.Declaration})
		}
	}
}

// Parse the reST parts of a standard directive into the tree as the
// directive does.
@(private = "file")
directive_content :: proc(b: ^Builder, name: string, info: rst.Directive_Info, w: Walk) {
	spec, known := check.directive_spec(name)
	if !known do return
	blk, ok := check.parse_directive_block(info, spec)
	if !ok do return
	switch spec.kind {
	case .Generic_Admonition, .Topic, .Sidebar, .Rubric, .Table, .Contents:
		if len(blk.arguments) > 0 do inline_lines(b, argument_lines(info), .Parameter)
		if spec.kind == .Contents do return
	case .Parsed_Literal:
		inline_lines(b, blk.content, .None)
		return
	case .Admonition, .Block_Quote, .Body, .Class, .Figure, .Replace:
	}
	if spec.kind == .Rubric || len(blk.content) == 0 do return
	if spec.kind == .Replace && !w.subst do return
	container := rst.new_node(b.t, .Block_Quote, 0)
	sm := rst.make_state_machine(b.p, nil, 0, container)
	rst.nested_parse(&sm, blk.content, blk.content_offset, container)
	walk_children(b, container, w)
}

// The lines of a directive's arguments: its first block, up to the options.
@(private = "file")
argument_lines :: proc(info: rst.Directive_Info) -> []string {
	lines := info.lines
	if len(lines) > 0 && is_blank(lines[0]) do lines = lines[1:]
	n := 0
	for n < len(lines) && !is_blank(lines[n]) {
		if _, _, is_field := rst.match_field_marker(lines[n]); is_field do break
		n += 1
	}
	return lines[:n]
}

// Inline markup of lines of the source (``inline_text`` of a directive's
// argument or content): parsed into the tree, located through the lines;
// the text gets ``text_type`` tokens.
@(private = "file")
inline_lines :: proc(b: ^Builder, lines: []string, text_type: Token_Type) {
	if len(lines) == 0 do return
	// one line: the text is a view of the source; more: the lines map it
	text := lines[0]
	if len(lines) > 1 {
		if b.p.spans != nil do b.p.spans.inline_lines = lines
		text = strings.join(lines, "\n")
	}
	nodes := rst.parse_inline(b.p, text, 0)
	inline_chain(b, nodes.first, text_type)
}

// --- inline markup ---------------------------------------------------------------------

// The inline children of ``n``: their tokens and items; the text has
// ``text_type`` tokens (titles).
@(private = "file")
inline_children :: proc(b: ^Builder, n: rst.Node, text_type: Token_Type) {
	inline_chain(b, rst.first_child(b.t, n), text_type)
}

@(private = "file")
inline_chain :: proc(b: ^Builder, first: rst.Node, text_type: Token_Type) {
	for c := first; c != rst.NO_NODE; c = rst.next_sibling(b.t, c) {
		d := rst.node_data(b.t, c)
		span := node_span(b.t, c)
		if d.kind == .Text {
			add_token(b, span, text_type, {.Declaration})
		} else {
			inline_item(b, d, c, span)
		}
	}
}

@(private = "file")
inline_item :: proc(b: ^Builder, d: rst.Node_Data, n: rst.Node, span: Span) {
	#partial switch d.kind {
	case .Emphasis:
		add_token(b, span, .Emphasis)
	case .Strong:
		add_token(b, span, .Strong)
	case .Literal:
		add_token(b, span, .String)
	case .Field_Name:
		add_token(b, span, .Property)
	case .Interpreted:
		interpreted(b, d, span)
	case .Inline_Target:
		name := dt.fully_normalize_name(rst.unescape(d.text, context.allocator))
		add_item(b, Item{kind = .Inline_Target, span = span, name = name, label = d.text})
		add_token(b, span, .Decorator, {.Declaration})
	case .Substitution_Reference:
		name := dt.whitespace_normalize_name(rst.unescape(d.text, context.allocator))
		add_item(b, Item{kind = .Substitution_Reference, span = span, name = name, label = name})
		add_token(b, span, .Variable)
	case .Footnote_Reference, .Citation_Reference:
		citation := d.kind == .Citation_Reference
		kind: Item_Kind = .Citation_Reference if citation else .Footnote_Reference
		name := footnote_name(d.text, citation)
		add_item(b, Item{kind = kind, span = span, name = name, label = d.text})
		add_token(b, span, .Enum_Member)
	case .Reference:
		reference(b, d, n, span)
	case .Problematic:
		append(&b.a.problems, Problem{d.line, d.name, span})
	}
}

@(private = "file")
interpreted :: proc(b: ^Builder, d: rst.Node_Data, span: Span) {
	if d.name == "" do return
	role := span
	width := i32(len(d.name) + 2)
	if strings.has_prefix(d.raw, ":") {
		role.end = span.start + width
	} else {
		role.start = span.end - width
	}
	add_item(b, Item{kind = .Role, span = role, name = strings.to_lower(d.name), label = d.name})
	add_token(b, role, .Macro)
}

@(private = "file")
reference :: proc(b: ^Builder, d: rst.Node_Data, n: rst.Node, span: Span) {
	kind := rst.Ref_Kind(d.num[0])
	if kind != .Simple && kind != .Phrase do return // standalone URIs, PEP and RFC references
	add_token(b, span, .Type)
	anonymous := strings.has_suffix(d.raw, "__")
	text := rst.unescape(d.text, context.allocator)
	item := Item {
		kind  = .Anonymous_Reference if anonymous else .Reference,
		span  = span,
		name  = "" if anonymous else dt.fully_normalize_name(text),
		label = text,
	}
	if info, ok := rst.phrase_info(b.t, n); ok {
		switch info.alias_type {
		case .Name:
			item.kind = .Reference
			item.name = dt.fully_normalize_name(info.alias)
			item.value = info.alias
			item.indirect = true
		case .Uri:
			item.value = info.alias
			item.name = ""
			if !anonymous && text != "" {
				def := Item {
					kind  = .Embedded_Target,
					span  = span,
					name  = dt.fully_normalize_name(text),
					label = text,
					value = info.alias,
				}
				add_item(b, def)
			}
			item.kind = .Reference
		case .None:
		}
	}
	add_item(b, item)
}
