package reader

import dt "../doctree"
import rst "../rst"

// The tree builder (``TreeBuilder`` of the Python host): docutils nodes for
// the items of a native parse tree, with docutils' registration and its
// ``document.current_line`` bookkeeping.

// The message after explicit markup that ends without a blank line; a
// directive that inserted input lines swallows it (see ``build_items``).
EXPLICIT_UNINDENT :: "Explicit markup ends without a blank line; unexpected unindent."

// The state of a walk over sibling items (``build_items``).
@(private = "file")
Item_Walk :: struct {
	linear:        bool, // the machine's lines map 1:1 to the source
	skip_unindent: bool, // a directive inserted input lines
	early:         dt.Node, // a message created before the current construct
}

// Build the items of the chain ``first`` (up to ``stop``).  ``top``: the
// items of a (nested) parse, appended to ``sm.node`` (which section titles
// may move); else the items nested inside ``parent``.
build_items :: proc(
	c: ^Context,
	t: ^rst.Tree,
	first: rst.Node,
	parent: dt.Node,
	sm: ^Machine,
	top: bool,
	stop := rst.NO_NODE,
) {
	w := Item_Walk {
		linear = is_linear(c, sm),
	}
	for item := first; item != stop; item = rst.next_sibling(t, item) {
		target := sm.node if top else parent
		if skip_item(c, t, item, target, &w) do continue
		set_item_line(c, t, item, sm, w.linear)
		kind := rst.node_kind(t, item)
		if kind == .Paragraph || kind == .Enumerated_List || kind == .Table {
			w.early = early_message(c, t, item, sm, stop)
		}
		#partial switch kind {
		case .Paragraph:
			build_paragraph(c, t, item, target, sm, w.linear)
		case .Directive:
			w.skip_unindent = build_directive(c, t, item, target, sm, false, "")
			w.linear = is_linear(c, sm)
			if w.linear do c.doc.current_source = c.source
		case:
			build_block(c, t, item, target, sm)
		}
	}
}

// Items already handled: the unindent warning after a directive that
// inserted input lines, and a message ``early_message`` created.
@(private = "file")
skip_item :: proc(
	c: ^Context,
	t: ^rst.Tree,
	item: rst.Node,
	target: dt.Node,
	w: ^Item_Walk,
) -> bool {
	if w.skip_unindent {
		w.skip_unindent = false
		kind := rst.node_kind(t, item)
		if kind == .System_Message && rst.node_text(t, item) == EXPLICIT_UNINDENT do return true
	}
	if w.early == 0 do return false
	// created before the construct (and its content)
	if dt.parent(c.doc, w.early) == 0 do dt.append_child(c.doc, target, w.early)
	w.early = 0
	return true
}

// ``document.current_source``/``current_line`` at the start of an item.
@(private = "file")
set_item_line :: proc(c: ^Context, t: ^rst.Tree, item: rst.Node, sm: ^Machine, linear: bool) {
	if linear {
		c.doc.current_source = c.source
		c.doc.current_line = rst.node_line(t, item) + sm.line_delta
	} else {
		set_current(c, sm, rst.node_line(t, item))
	}
}

// A builder of a block item: appends the nodes of ``n`` to ``parent``.
Block_Builder :: proc(c: ^Context, t: ^rst.Tree, n: rst.Node, parent: dt.Node, sm: ^Machine)

@(private = "file")
BLOCK_BUILDERS := #partial [rst.Node_Kind]Block_Builder {
	.Section_Title           = build_section_title,
	.Paragraph               = build_paragraph_item,
	.Bullet_List             = build_bullet_list,
	.Enumerated_List         = build_enumerated_list,
	.Definition_List         = build_definition_list,
	.Field_List              = build_field_list,
	.Option_List             = build_option_list,
	.Literal_Block           = build_literal_block,
	.Doctest_Block           = build_doctest_block,
	.Line_Block              = build_line_block,
	.Block_Quote             = build_block_quote,
	.Transition              = build_transition,
	.Table                   = build_table,
	.Footnote                = build_footnote,
	.Citation                = build_citation,
	.Target                  = build_target,
	.Substitution_Definition = build_substitution_definition,
	.Comment                 = build_comment,
	.Directive               = build_directive_item,
	.Include_End             = build_include_end,
	.System_Message          = build_system_message,
}

// Dispatch a block item by kind.
build_block :: proc(c: ^Context, t: ^rst.Tree, n: rst.Node, parent: dt.Node, sm: ^Machine) {
	builder := BLOCK_BUILDERS[rst.node_kind(t, n)]
	if builder == nil do panic("reader: unexpected block item kind")
	builder(c, t, n, parent, sm)
}

@(private = "file")
build_paragraph_item :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	parent: dt.Node,
	sm: ^Machine,
) {
	build_paragraph(c, t, n, parent, sm, false)
}

@(private = "file")
build_directive_item :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	parent: dt.Node,
	sm: ^Machine,
) {
	build_directive(c, t, n, parent, sm, false, "")
}

// A message docutils reports before the construct ``n`` is parsed, but
// attaches after it: created first, so messages reach the reporter in
// docutils' order.
@(private = "file")
early_message :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	sm: ^Machine,
	stop: rst.Node,
) -> dt.Node {
	following := rst.next_sibling(t, n)
	if following == stop || rst.node_kind(t, following) != .System_Message do return 0
	if !reported_early(t, n, following, sm.line_delta) do return 0
	set_current_line(c, sm, rst.node_cur_line(t, following))
	msg := message(c, t, following)
	if rst.node_kind(t, n) == .Enumerated_List do c.start_message = msg
	return msg
}

// Is the message ``following`` the construct ``n`` one that docutils
// reports before parsing the construct's content?
@(private = "file")
reported_early :: proc(t: ^rst.Tree, n, following: rst.Node, line_delta: int) -> bool {
	text := rst.node_text(t, following)
	#partial switch rst.node_kind(t, n) {
	case .Paragraph:
		// ``Text.text``: an indented line right after the paragraph (the
		// message has the source line, the paragraph the absolute line)
		want := rst.node_line(t, n) + count_newlines(rst.node_raw(t, n)) + 1 + line_delta
		return text == "Unexpected indentation." && rst.node_line(t, following) == want
	case .Enumerated_List:
		// ``Body.enumerator`` reports the start before the items
		return has_prefix(text, "Enumerated list start value not ordinal-1")
	case .Table:
		// ``isolate_grid_table`` reports an indented line right after the
		// table before the cells are parsed; ``table_top`` then reports
		// the missing blank line (a table that failed has its "Malformed
		// table." message in between)
		if text != "Unexpected indentation." do return false
		after := rst.next_sibling(t, following)
		if after == rst.NO_NODE || rst.node_kind(t, after) != .System_Message do return false
		same_line := rst.node_line(t, after) == rst.node_line(t, following)
		return same_line && rst.node_text(t, after) == "Blank line required after table."
	}
	return false
}

@(private = "file")
count_newlines :: proc(s: string) -> int {
	k := 0
	for i in 0 ..< len(s) do if s[i] == '\n' do k += 1
	return k
}

// Set ``document.current_source``/``current_line`` from a native ``cur``
// value (docutils ``note_source`` of the last cursor move): a line, 0
// (None) or -1 (None, and no source).
set_current_line :: proc(c: ^Context, sm: ^Machine, cur: int) {
	doc := c.doc
	switch {
	case cur > 0:
		if is_linear(c, sm) {
			doc.current_source, doc.current_line = c.source, cur
		} else {
			set_current(c, sm, cur - sm.line_delta)
		}
	case cur == 0:
		// just past the end of the input: the source of its last line
		doc.current_source, doc.current_line = last_line_source(c, sm), nil
	case:
		doc.current_source, doc.current_line = nil, nil
	}
}

// The source of the last input line of ``sm`` (``info(len(lines))``).
@(private = "file")
last_line_source :: proc(c: ^Context, sm: ^Machine) -> Maybe(string) {
	if is_linear(c, sm) do return c.source
	lines := input_lines(c, sm)
	if sl_len(lines) == 0 do return nil
	return lines.items[sl_len(lines) - 1].source
}

// Position the reporter's state machine like docutils' root machine
// (messages without an explicit line use its line).
at_line :: proc(c: ^Context, cur_line: int) {
	if cur_line != 0 do c.root_line = cur_line
}

// The inline nodes of the chain ``first`` (``TreeBuilder.inline``).
inline_nodes :: proc(
	c: ^Context,
	t: ^rst.Tree,
	first: rst.Node,
	lineno: int,
	container: dt.Node,
	msgs: ^[dynamic]dt.Node,
) -> []dt.Node {
	out := make([dynamic]dt.Node, 0, 4, c.allocator)
	build_inline(c, t, first, lineno, container, &out, msgs)
	return out[:]
}

// --- system messages -----------------------------------------------------------------

// The ``system_message`` of a parse tree message.
message :: proc(c: ^Context, t: ^rst.Tree, n: rst.Node) -> dt.Node {
	d := rst.node_data(t, n)
	kids := make([dynamic]dt.Node, 0, 2, c.allocator)
	for ch := d.first; ch != rst.NO_NODE; ch = rst.next_sibling(t, ch) {
		#partial switch rst.node_kind(t, ch) {
		case .Literal_Block:
			s := rst.node_text(t, ch)
			append(&kids, dt.new_element(c.doc, .literal_block, s, s))
		case .Paragraph:
			s := rst.node_raw(t, ch)
			append(&kids, dt.new_element(c.doc, .paragraph, s, s))
		case:
			panic("reader: unexpected message child")
		}
	}
	opts := dt.Message_Options {
		children = kids[:],
	}
	if d.line != 0 do opts.line = int(d.line)
	return dt.system_message(c.doc, dt.Level(d.num[0]), d.text, opts)
}

@(private = "file")
build_system_message :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	parent: dt.Node,
	sm: ^Machine,
) {
	set_current_line(c, sm, rst.node_cur_line(t, n))
	dt.append_child(c.doc, parent, message(c, t, n))
}

// --- body elements ------------------------------------------------------------------

// A paragraph (the most frequent block element).
@(private = "file")
build_paragraph :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	parent: dt.Node,
	sm: ^Machine,
	linear: bool,
) {
	d := rst.node_data(t, n)
	at_line(c, int(d.num[1]))
	if linear && d.cur_line > 0 {
		c.doc.current_line = int(d.cur_line)
	} else {
		set_current_line(c, sm, int(d.cur_line))
	}
	msgs := make([dynamic]dt.Node, c.allocator)
	p := element(c, .paragraph, d.raw, inline_nodes(c, t, d.first, int(d.line), parent, &msgs))
	set_srcline(c, sm, p, int(d.line))
	dt.append_child(c.doc, parent, p)
	extend(c, parent, msgs[:])
}

@(private = "file")
build_bullet_list :: proc(c: ^Context, t: ^rst.Tree, n: rst.Node, parent: dt.Node, sm: ^Machine) {
	d := rst.node_data(t, n)
	ul := dt.new_element(c.doc, .bullet_list)
	set_srcline(c, sm, ul, int(d.line))
	dt.append_child(c.doc, parent, ul)
	dt.set_attr(c.doc, ul, "bullet", d.name)
	for li := d.first; li != rst.NO_NODE; li = rst.next_sibling(t, li) {
		dt.append_child(c.doc, ul, list_item(c, t, li, sm))
	}
}

@(private = "file")
list_item :: proc(c: ^Context, t: ^rst.Tree, n: rst.Node, sm: ^Machine) -> dt.Node {
	li := dt.new_element(c.doc, .list_item, rst.node_raw(t, n))
	set_srcline(c, sm, li, rst.node_line(t, n))
	build_items(c, t, rst.first_child(t, n), li, sm, false)
	return li
}

@(private = "file")
build_enumerated_list :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	parent: dt.Node,
	sm: ^Machine,
) {
	d := rst.node_data(t, n)
	doc := c.doc
	el := dt.new_element(doc, .enumerated_list)
	set_srcline(c, sm, el, int(d.line))
	dt.append_child(doc, parent, el)
	dt.set_attr(doc, el, "enumtype", d.name)
	dt.set_attr(doc, el, "prefix", d.text)
	dt.set_attr(doc, el, "suffix", d.raw)
	if d.num[1] != 0 do dt.set_attr(doc, el, "start", int(d.num[0]))
	if c.start_message != 0 {
		// ``Body.enumerator`` attaches its message before parsing the items
		dt.append_child(doc, parent, c.start_message)
		c.start_message = 0
	}
	for li := d.first; li != rst.NO_NODE; li = rst.next_sibling(t, li) {
		dt.append_child(doc, el, list_item(c, t, li, sm))
	}
}

@(private = "file")
build_definition_list :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	parent: dt.Node,
	sm: ^Machine,
) {
	dl := dt.new_element(c.doc, .definition_list)
	set_srcline(c, sm, dl, rst.node_line(t, n))
	first := true
	for dli := rst.first_child(t, n); dli != rst.NO_NODE; dli = rst.next_sibling(t, dli) {
		item := definition_list_item(c, t, dli, sm, parent if first else dl)
		dt.append_child(c.doc, dl, item)
		if first {
			dt.append_child(c.doc, parent, dl)
			first = false
		}
	}
	if first do dt.append_child(c.doc, parent, dl)
}

@(private = "file")
definition_list_item :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	sm: ^Machine,
	container: dt.Node,
) -> dt.Node {
	doc := c.doc
	dli := dt.new_element(doc, .definition_list_item, rst.node_raw(t, n))
	set_srcline(c, sm, dli, rst.node_line(t, n))
	msgs := make([dynamic]dt.Node, c.allocator)
	definition := rst.NO_NODE
	for ch := rst.first_child(t, n); ch != rst.NO_NODE; ch = rst.next_sibling(t, ch) {
		d := rst.node_data(t, ch)
		#partial switch d.kind {
		case .Term:
			at_line(c, int(d.num[1]))
			set_current_line(c, sm, int(d.cur_line))
			term := element(
				c, .term, d.raw, inline_nodes(c, t, d.first, int(d.line), container, &msgs),
			)
			set_srcline(c, sm, term, int(d.line))
			dt.append_child(doc, dli, term)
		case .Classifier:
			kids := inline_nodes(c, t, d.first, int(d.line), container, &msgs)
			dt.append_child(doc, dli, element(c, .classifier, d.raw, kids))
		case:
			definition = ch
		}
	}
	dd := element(c, .definition, "", msgs[:])
	if definition != rst.NO_NODE {
		set_srcline(c, sm, dd, rst.node_line(t, definition))
		dt.append_child(doc, dli, dd)
		build_items(c, t, rst.first_child(t, definition), dd, sm, false)
	}
	return dli
}

@(private = "file")
build_field_list :: proc(c: ^Context, t: ^rst.Tree, n: rst.Node, parent: dt.Node, sm: ^Machine) {
	fl := dt.new_element(c.doc, .field_list)
	if name := rst.node_name(t, n); name != "" do dt.list_append(c.doc, fl, dt.K_CLASSES, name)
	dt.append_child(c.doc, parent, fl)
	container := parent
	for f := rst.first_child(t, n); f != rst.NO_NODE; f = rst.next_sibling(t, f) {
		dt.append_child(c.doc, fl, field(c, t, f, sm, container))
		container = fl // FieldList state: the node is the field_list
	}
}

@(private = "file")
field :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	sm: ^Machine,
	container: dt.Node,
) -> dt.Node {
	doc := c.doc
	lineno := rst.node_line(t, n)
	name_item := rst.first_child(t, n)
	body_item := rst.next_sibling(t, name_item)
	f := dt.new_element(doc, .field)
	set_srcline(c, sm, f, lineno)
	msgs := make([dynamic]dt.Node, c.allocator)
	nd := rst.node_data(t, name_item)
	at_line(c, int(nd.num[1]))
	set_current_line(c, sm, int(nd.cur_line))
	kids := inline_nodes(c, t, nd.first, lineno, container, &msgs)
	dt.append_child(doc, f, element(c, .field_name, nd.raw, kids))
	body := element(c, .field_body, rst.node_raw(t, body_item), msgs[:])
	dt.append_child(doc, f, body)
	build_items(c, t, rst.first_child(t, body_item), body, sm, false)
	return f
}

@(private = "file")
build_option_list :: proc(c: ^Context, t: ^rst.Tree, n: rst.Node, parent: dt.Node, sm: ^Machine) {
	doc := c.doc
	ol := dt.new_element(doc, .option_list)
	set_srcline(c, sm, ol, rst.node_line(t, n))
	first := true
	for oli := rst.first_child(t, n); oli != rst.NO_NODE; oli = rst.next_sibling(t, oli) {
		built := option_list_item(c, t, oli, sm)
		if first {
			dt.append_child(doc, parent, ol)
			first = false
		}
		set_current_line(c, sm, rst.node_cur_line(t, oli))
		dt.append_child(doc, ol, built)
	}
	if first do dt.append_child(doc, parent, ol)
}

@(private = "file")
option_list_item :: proc(c: ^Context, t: ^rst.Tree, n: rst.Node, sm: ^Machine) -> dt.Node {
	doc := c.doc
	group_item := rst.first_child(t, n)
	desc_item := rst.next_sibling(t, group_item)
	group := dt.new_element(doc, .option_group)
	for opt := rst.first_child(t, group_item); opt != rst.NO_NODE; opt = rst.next_sibling(t, opt) {
		option := dt.new_element(doc, .option, rst.node_raw(t, opt))
		for part := rst.first_child(t, opt); part != rst.NO_NODE; part = rst.next_sibling(
			t, part,
		) {
			s := rst.node_text(t, part)
			if rst.node_kind(t, part) == .Option_String {
				dt.append_child(doc, option, dt.new_element(doc, .option_string, s, s))
			} else {
				arg := dt.new_element(doc, .option_argument, s, s)
				dt.set_attr(doc, arg, dt.K_DELIMITER, rst.node_name(t, part))
				dt.append_child(doc, option, arg)
			}
		}
		dt.append_child(doc, group, option)
	}
	description := dt.new_element(doc, .description, rst.node_raw(t, desc_item))
	oli := element(c, .option_list_item, "", {group, description})
	build_items(c, t, rst.first_child(t, desc_item), description, sm, false)
	return oli
}

@(private = "file")
build_literal_block :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	parent: dt.Node,
	sm: ^Machine,
) {
	s := rst.node_text(t, n)
	lb := dt.new_element(c.doc, .literal_block, s, s)
	set_srcline(c, sm, lb, rst.node_line(t, n))
	dt.append_child(c.doc, parent, lb)
}

@(private = "file")
build_doctest_block :: proc(c: ^Context, t: ^rst.Tree, n: rst.Node, parent: dt.Node, _: ^Machine) {
	s := rst.node_text(t, n)
	db := dt.new_element(c.doc, .doctest_block, s, s)
	dt.set_line(c.doc, db, c.doc.current_line) // docutils: the line where it starts
	dt.append_child(c.doc, parent, db)
}

@(private = "file")
build_transition :: proc(c: ^Context, t: ^rst.Tree, n: rst.Node, parent: dt.Node, sm: ^Machine) {
	tr := dt.new_element(c.doc, .transition, rst.node_raw(t, n))
	set_srcline(c, sm, tr, rst.node_line(t, n))
	dt.append_child(c.doc, parent, tr)
}

@(private = "file")
build_block_quote :: proc(c: ^Context, t: ^rst.Tree, n: rst.Node, parent: dt.Node, sm: ^Machine) {
	doc := c.doc
	d := rst.node_data(t, n)
	bq := dt.new_element(doc, .block_quote, d.raw)
	set_srcline(c, sm, bq, int(d.line))
	attribution := rst.NO_NODE
	if d.last != rst.NO_NODE && rst.node_kind(t, d.last) == .Attribution do attribution = d.last
	msgs := make([dynamic]dt.Node, c.allocator)
	build_items(c, t, d.first, bq, sm, false, attribution)
	if attribution != rst.NO_NODE {
		a := rst.node_data(t, attribution)
		at_line(c, int(a.num[1]))
		set_current_line(c, sm, int(a.cur_line))
		kids := inline_nodes(c, t, a.first, int(a.line), sm.node, &msgs)
		node := element(c, .attribution, a.raw, kids)
		set_srcline(c, sm, node, int(a.line))
		dt.append_child(doc, bq, node)
	}
	dt.append_child(doc, parent, bq)
	if len(msgs) > 0 {
		set_current_line(c, sm, int(d.cur_line))
		extend(c, parent, msgs[:])
	}
}

// The comment that ends an inclusion: ``document.include_log.pop()``.
@(private = "file")
build_include_end :: proc(c: ^Context, _: ^rst.Tree, _: rst.Node, _: dt.Node, _: ^Machine) {
	if len(c.include_log) > 0 do pop(&c.include_log)
}
