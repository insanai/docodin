package lsp

// Document analysis: one parse of the document with the native parser
// (odin/rst), walked once into flat tables:
//
// * ``items``: definitions (sections, targets, substitution definitions,
//   footnotes, citations) and their uses (references), resolved by
//   ``resolve`` with docutils' name normalisation;
// * ``tokens``: semantic tokens;
// * ``folds``: folding ranges.
//
// The reST content of standard directives (admonitions, topics, tables,
// figures, ...) is parsed as docutils' directives parse it
// (``check.parse_directive_block``), so the constructs inside them are
// found too.  Everything is allocated in the snapshot's arena.

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
	kind:      Item_Kind,
	span:      Span,   // definitions: the name; uses: the whole markup
	name:      string, // normalised reference name or label ("" when anonymous)
	label:     string, // as written: title text, target name, footnote label
	value:     string, // URI, reference name (``indirect``) or definition text
	indirect:  bool,   // ``value`` is a reference name
	target:    i32,    // uses: the definition
	parent:    i32,    // the enclosing section
	level:     i32,    // sections: 1 for the top level
	last_line: i32,    // the last line of the construct
}

Fold_Kind :: enum u8 {
	Region,
	Comment,
}

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
	items:    [dynamic]Item,
	tokens:   [dynamic]Token,
	folds:    [dynamic]Fold,
	problems: [dynamic]Problem,
}

// Analyse the document of ``ix``, from the reader's parse ``tree`` if it
// kept one (else the document is parsed here).  The tree grows: the content
// of directives is parsed into it.
analyze :: proc(
	ix: ^Line_Index,
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
	if doc == rst.NO_NODE {
		p = rst.Parser {
			allocator = allocator,
			settings  = rst.settings_from_flags({.Match_Titles}, ix.tab_width, 0),
		}
		doc, _, _ = rst.parse_text(&p, ix.text, 0, true)
	}
	b := Builder {
		ix       = ix,
		p        = &p,
		t        = &p.tree,
		a        = &a,
		section  = NO_ITEM,
		sections = make([dynamic]i32, 0, 16),
	}
	last := trim_blank_end(ix, line_count(ix) - 1, 0)
	walk_children(&b, doc, Walk{end = last})
	finish_sections(&b, last)
	resolve(&a)
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
	ix:            ^Line_Index,
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
	delta: int, // source line minus the tree's line (table cells, substitutions)
	subst: bool, // inside a substitution definition
	end:   int, // the last line of the node (0-based)
}

@(private = "file")
FOLDED_KINDS :: bit_set[rst.Node_Kind] {
	.Bullet_List, .Enumerated_List, .Definition_List, .Field_List, .Option_List,
	.Literal_Block, .Doctest_Block, .Line_Block, .Table, .Block_Quote,
}

// Kinds of the parse tree that are inline markup.
@(private = "file")
INLINE_KINDS :: bit_set[rst.Node_Kind] {
	.Text, .Emphasis, .Strong, .Literal, .Inline_Target, .Substitution_Reference, .Reference,
	.Footnote_Reference, .Citation_Reference, .Interpreted, .Problematic,
}

// Walk the children of ``n`` (``w``: their context, ``w.end`` the last
// line of ``n``).  A child ends where the next one starts.
@(private = "file")
walk_children :: proc(b: ^Builder, n: rst.Node, w: Walk) {
	c := next_block(b.t, rst.first_child(b.t, n))
	for c != rst.NO_NODE {
		next := next_block(b.t, rst.next_sibling(b.t, c))
		cw := w
		start := start_line(b, c, w.delta)
		if next != rst.NO_NODE {
			if s := start_line(b, next, w.delta); s > start {
				cw.end = trim_blank_end(b.ix, s - 1, max(start, 0))
			}
		}
		walk(b, c, cw)
		c = next
	}
}

// ``n`` or the first sibling after it that is a block (messages are
// reported apart and may carry other lines).
@(private = "file")
next_block :: proc(t: ^rst.Tree, n: rst.Node) -> rst.Node {
	n := n
	for n != rst.NO_NODE {
		#partial switch rst.node_kind(t, n) {
		case .System_Message, .Include_End:
		case:
			return n
		}
		n = rst.next_sibling(t, n)
	}
	return n
}

// The first line of ``n`` (0-based), -1 if unknown.
@(private = "file")
start_line :: proc(b: ^Builder, n: rst.Node, delta: int) -> int {
	d := rst.node_data(b.t, n)
	if d.line <= 0 {
		first := next_block(b.t, d.first)
		return start_line(b, first, delta) if first != rst.NO_NODE else -1
	}
	line := int(d.line) - 1 + delta
	if d.kind == .Section_Title && len(d.name) == 2 do line -= 1 // the overline
	return line
}

@(private = "file")
walk :: proc(b: ^Builder, n: rst.Node, w: Walk) {
	d := rst.node_data(b.t, n)
	if construct(b, n, d, w) do return
	if d.kind in FOLDED_KINDS do add_fold(b, start_line(b, n, w.delta), w.end, .Region)
	first := rst.first_child(b.t, n)
	if first != rst.NO_NODE && rst.node_kind(b.t, first) in INLINE_KINDS {
		line := int(d.line) - 1 + w.delta
		text_type: Token_Type = .Property if d.kind == .Field_Name else .None
		last := line + strings.count(d.raw, "\n")
		inline_chain(b, first, {i32(max(line, 0)), 0}, last, text_type)
		return
	}
	cw := w
	if d.kind == .Entry do cw.delta -= 1 // cells are nested-parsed with a 1-based offset
	walk_children(b, n, cw)
}

// Sections, transitions and explicit markup: true when ``n`` is done.
@(private = "file")
construct :: proc(b: ^Builder, n: rst.Node, d: rst.Node_Data, w: Walk) -> bool {
	line := int(d.line) - 1 + w.delta
	#partial switch d.kind {
	case .Section_Title:
		section_title(b, n, w)
	case .Directive:
		directive(b, n, w)
	case .Target:
		target(b, n, line)
	case .Substitution_Definition:
		substitution_definition(b, n, w)
	case .Comment:
		comment(b, line, w.end)
	case .Footnote, .Citation:
		footnote(b, n, line, w.end)
		return false // the body is walked
	case .Transition:
		add_token(b, line_content_span(b.ix, line), .Operator)
	case:
		return false
	}
	return true
}

@(private = "file")
add_token :: proc(b: ^Builder, span: Span, type: Token_Type, mods := Token_Modifiers{}) {
	add_token_span(b.a, b.ix, span, type, mods)
}

@(private = "file")
add_fold :: proc(b: ^Builder, start, end: int, kind: Fold_Kind) {
	if start < 0 || end <= start do return
	append(&b.a.folds, Fold{i32(start), i32(end), kind})
}

@(private = "file")
add_item :: proc(b: ^Builder, item: Item) -> i32 {
	it := item
	it.target = NO_ITEM
	if it.kind != .Section do it.parent = b.section
	append(&b.a.items, it)
	return i32(len(b.a.items) - 1)
}

// --- sections --------------------------------------------------------------------------

// ``RSTState.check_subsection``: the level of the title style; a title
// that skips a level makes no section.
@(private = "file")
section_title :: proc(b: ^Builder, n: rst.Node, w: Walk) {
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
	line := int(d.line) - 1 + w.delta
	add_token(b, line_content_span(b.ix, line + 1), .Operator)
	if style.n == 2 do add_token(b, line_content_span(b.ix, line - 1), .Operator)
	if level > b.section_level + 1 do return
	b.section_level = level
	if level > len(b.title_styles) do append(&b.title_styles, style)

	title := rst.first_child(b.t, n)
	label := title_text(b, title)
	parent := NO_ITEM
	for i := len(b.sections) - 1; i >= 0; i -= 1 {
		if b.a.items[b.sections[i]].level < i32(level) {
			parent = b.sections[i]
			break
		}
	}
	item := Item {
		kind   = .Section,
		span   = line_content_span(b.ix, line),
		name   = dt.fully_normalize_name(label),
		label  = label,
		parent = parent,
		level  = i32(level),
	}
	b.section = add_item(b, item)
	append(&b.sections, b.section)
	if title != rst.NO_NODE {
		first := rst.first_child(b.t, title)
		inline_chain(b, first, {i32(line), 0}, line, .Namespace)
	}
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
finish_sections :: proc(b: ^Builder, last: int) {
	items := b.a.items[:]
	for s, k in b.sections {
		end := last
		for j in k + 1 ..< len(b.sections) {
			next := &items[b.sections[j]]
			if next.level > items[s].level do continue
			start := int(next.span.start.line)
			if is_overline(b, start) do start -= 1
			end = trim_blank_end(b.ix, start - 1, int(items[s].span.start.line))
			break
		}
		items[s].last_line = i32(end)
		first := int(items[s].span.start.line)
		if is_overline(b, first) do first -= 1
		add_fold(b, first, end, .Region)
	}
}

// Line ``line`` is a title with an overline above it.
@(private = "file")
is_overline :: proc(b: ^Builder, line: int) -> bool {
	if line < 1 do return false
	above := expanded(b.ix, line - 1)
	below := expanded(b.ix, line + 1)
	return is_adornment(above) && is_adornment(below) && len(above) > 0 && above[0] == below[0]
}

// A line of one repeated punctuation character.
is_adornment :: proc(line: string) -> bool {
	return rst.match_line(line)
}

// --- explicit markup -------------------------------------------------------------------

@(private = "file")
target :: proc(b: ^Builder, n: rst.Node, line: int) {
	d := rst.node_data(b.t, n)
	indirect := rst.Target_Type(d.num[0]) == .Refname
	last := i32(line + strings.count(d.raw, "\n"))
	if d.num[1] == 1 {
		span, ok := locate_text(b.ix, {i32(line), 0}, line, "__")
		if !ok do span = line_content_span(b.ix, line)
		item := Item {
			kind      = .Anonymous_Target,
			span      = span,
			value     = d.text,
			indirect  = indirect,
			last_line = last,
		}
		add_item(b, item)
		add_token(b, span, .Decorator, {.Declaration})
		return
	}
	span := name_span(b, line, "_", d.name)
	item := Item {
		kind      = .Target,
		span      = span,
		name      = dt.fully_normalize_name(d.name),
		label     = d.name,
		value     = d.text,
		indirect  = indirect,
		last_line = last,
	}
	add_item(b, item)
	add_token(b, span, .Decorator, {.Declaration})
}

// The span of ``name`` after ``marker`` on ``line`` (the line's content
// if it cannot be found).
@(private = "file")
name_span :: proc(b: ^Builder, line: int, marker, name: string) -> Span {
	from := Pos{i32(line), 0}
	if m, ok := locate_text(b.ix, from, line, marker); ok do from = m.end
	if name != "" {
		if s, ok := locate_text(b.ix, from, line, name); ok do return s
	}
	return line_content_span(b.ix, line)
}

@(private = "file")
substitution_definition :: proc(b: ^Builder, n: rst.Node, w: Walk) {
	d := rst.node_data(b.t, n)
	line := int(d.line) - 1 + w.delta
	span := name_span(b, line, "|", d.name)
	item := Item {
		kind      = .Substitution_Definition,
		span      = span,
		name      = dt.whitespace_normalize_name(d.name),
		label     = d.name,
		value     = strings.trim_right_space(d.raw),
		last_line = i32(w.end),
	}
	add_item(b, item)
	add_token(b, widen(span), .Variable, {.Declaration})
	cw := w
	cw.delta += int(d.num[0])
	cw.subst = true
	walk_children(b, n, cw)
}

// A name span with its delimiters ("|name|", "[label]").
@(private = "file")
widen :: proc(span: Span) -> Span {
	s := span
	s.start.col = max(s.start.col - 1, 0)
	s.end.col += 1
	return s
}

@(private = "file")
footnote :: proc(b: ^Builder, n: rst.Node, line, end: int) {
	d := rst.node_data(b.t, n)
	label := d.name
	span := name_span(b, line, "[", label)
	item := Item {
		kind      = .Footnote if d.kind == .Footnote else .Citation,
		span      = span,
		name      = footnote_name(label, d.kind == .Citation),
		label     = label,
		value     = strings.trim_right_space(d.raw),
		last_line = i32(end),
	}
	add_item(b, item)
	add_token(b, widen(span), .Enum_Member, {.Declaration})
	add_fold(b, line, end, .Region)
}

// The reference name of a footnote or citation label: "" for the
// auto-numbered ("#") and auto-symbol ("*") footnotes.
footnote_name :: proc(label: string, citation: bool) -> string {
	if citation do return dt.fully_normalize_name(label)
	if label == "#" || label == "*" do return ""
	if strings.has_prefix(label, "#") do return dt.fully_normalize_name(label[1:])
	return label
}

@(private = "file")
comment :: proc(b: ^Builder, line, end: int) {
	if line < 0 do return
	for l in line ..= max(line, end) {
		if !is_blank(expanded(b.ix, l)) do add_token(b, line_content_span(b.ix, l), .Comment)
	}
	add_fold(b, line, end, .Comment)
}

// --- directives ------------------------------------------------------------------------

@(private = "file")
directive :: proc(b: ^Builder, n: rst.Node, w: Walk) {
	d := rst.node_data(b.t, n)
	line := int(d.line) - 1 + w.delta
	span, found := locate_text(b.ix, {i32(line), 0}, line, strings.concatenate({d.name, "::"}))
	if found {
		span.end.col -= 2
		add_token(b, span, .Function)
	} else {
		span = line_content_span(b.ix, line)
	}
	item := Item {
		kind  = .Directive,
		span  = span,
		name  = strings.to_lower(d.name),
		label = d.name,
	}
	add_item(b, item)
	info, has_info := rst.directive_info(b.t, n)
	if !has_info do return
	end := min(w.end, trim_blank_end(b.ix, info.end_offset + w.delta, line))
	if !w.subst do add_fold(b, line, end, .Region)
	arguments_and_options(b, d.name, info, w.delta, span.end)
	cw := w
	cw.end = end
	directive_content(b, d.name, info, line, cw)
}

// Tokens of the arguments and options (the first block of lines).
@(private = "file")
arguments_and_options :: proc(
	b: ^Builder,
	name: string,
	info: rst.Directive_Info,
	delta: int,
	name_end: Pos,
) {
	entry, known := find_directive(name)
	takes_args := known && entry.spec.required_arguments + entry.spec.optional_arguments > 0
	for text, i in info.lines {
		if is_blank(text) {
			if i > 0 do break
			continue
		}
		line := info.line_offset + i + delta
		from := Pos{i32(line), 0} if i > 0 else Pos{i32(line), name_end.col}
		span, ok := locate_text(b.ix, from, line, rst.strip(text))
		if !ok do continue
		fname, fend, is_field := rst.match_field_marker(rst.strip(text))
		if !is_field {
			if takes_args do add_token(b, span, .Parameter)
			continue
		}
		marker := Span{span.start, {span.start.line, span.start.col + i32(len(fname) + 2)}}
		add_token(b, marker, .Property)
		value := rst.strip(rst.strip(text)[fend:])
		if strings.to_lower(fname) == "name" && value != "" {
			vspan, vok := locate_text(b.ix, marker.end, line, value)
			if !vok do continue
			item := Item {
				kind  = .Name_Option,
				span  = vspan,
				name  = dt.fully_normalize_name(value),
				label = value,
			}
			add_item(b, item)
			add_token(b, vspan, .Decorator, {.Declaration})
		}
	}
}

// Parse the reST parts of a standard directive as the directive does.
@(private = "file")
directive_content :: proc(
	b: ^Builder,
	name: string,
	info: rst.Directive_Info,
	line: int,
	w: Walk,
) {
	spec, known := check.directive_spec(name)
	if !known do return
	blk, ok := check.parse_directive_block(info, spec)
	if !ok do return
	switch spec.kind {
	case .Generic_Admonition, .Topic, .Sidebar, .Rubric, .Table:
		if len(blk.arguments) > 0 do inline_text(b, blk.arguments[0], line, line)
	case .Contents:
		if len(blk.arguments) > 0 do inline_text(b, blk.arguments[0], line, line)
		return
	case .Parsed_Literal:
		start := blk.content_offset + w.delta
		inline_text(b, strings.join(blk.content, "\n"), start, w.end)
		return
	case .Admonition, .Block_Quote, .Body, .Class, .Figure, .Replace:
	}
	if spec.kind == .Rubric || len(blk.content) == 0 do return
	if spec.kind == .Replace && !w.subst do return
	container := rst.new_node(b.t, .Block_Quote, 0)
	sm := rst.make_state_machine(b.p, nil, 0, container)
	sm.line_delta = w.delta
	rst.nested_parse(&sm, blk.content, blk.content_offset, container)
	walk_children(b, container, w)
}

// Inline markup of a directive argument or content (``inline_text``).
@(private = "file")
inline_text :: proc(b: ^Builder, text: string, line, last: int) {
	nodes := rst.parse_inline(b.p, text, line + 1)
	inline_chain(b, nodes.first, {i32(line), 0}, last, .None)
}

// --- inline markup ---------------------------------------------------------------------

// Locate the inline nodes of the chain ``first`` in order from ``from``.
// Text nodes get ``text_type`` tokens (titles, field names).
@(private = "file")
inline_chain :: proc(b: ^Builder, first: rst.Node, from: Pos, last: int, text_type: Token_Type) {
	cur := from
	for c := first; c != rst.NO_NODE; c = rst.next_sibling(b.t, c) {
		d := rst.node_data(b.t, c)
		needle := source_form(d)
		if needle == "" do continue
		span, ok := locate_text(b.ix, cur, last, needle)
		if !ok do continue
		cur = span.end
		inline_item(b, d, c, span, text_type)
	}
}

// The source text of an inline node.
@(private = "file")
source_form :: proc(d: rst.Node_Data) -> string {
	#partial switch d.kind {
	case .Text:
		// backslash escapes are NUL-escaped in the text
		out, _ := strings.replace_all(d.text, "\x00", "\\")
		return out
	case .Footnote_Reference, .Citation_Reference:
		return strings.concatenate({"[", d.text, "]_"})
	}
	out, _ := strings.replace_all(d.raw, "\x00", "\\")
	return out
}

@(private = "file")
inline_item :: proc(
	b: ^Builder,
	d: rst.Node_Data,
	n: rst.Node,
	span: Span,
	text_type: Token_Type,
) {
	#partial switch d.kind {
	case .Text:
		if text_type != .None do add_token(b, span, text_type, {.Declaration})
	case .Emphasis:
		add_token(b, span, .Emphasis)
	case .Strong:
		add_token(b, span, .Strong)
	case .Literal:
		add_token(b, span, .String)
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
		role.end = {span.start.line, span.start.col + width}
	} else {
		role.start = {span.end.line, span.end.col - width}
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
