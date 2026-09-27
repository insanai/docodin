package reader

import dt "../doctree"
import rst "../rst"

// Builders of line blocks, tables and explicit markup: footnotes,
// citations, hyperlink targets, substitution definitions and comments.

// ``Target_Type`` of the parse tree (``num[0]`` of a ``Target``).
TARGET_REFNAME :: 1

build_line_block :: proc(c: ^Context, t: ^rst.Tree, n: rst.Node, parent: dt.Node, sm: ^Machine) {
	block := dt.new_element(c.doc, .line_block)
	set_srcline(c, sm, block, rst.node_line(t, n))
	dt.append_child(c.doc, parent, block)
	// the first line is parsed in the enclosing state, later ones in
	// LineBlock (whose node is the block)
	containers := [2]dt.Node{parent, block}
	line_block_children(c, t, n, block, sm, parent, &containers, rst.node_cur_line(t, n), true)
}

@(private = "file")
line_block_children :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	block: dt.Node,
	sm: ^Machine,
	outer: dt.Node,
	containers: ^[2]dt.Node,
	cur: int,
	has_cur: bool,
) {
	doc := c.doc
	for ch := rst.first_child(t, n); ch != rst.NO_NODE; ch = rst.next_sibling(t, ch) {
		d := rst.node_data(t, ch)
		if d.kind == .Line {
			at_line(c, int(d.num[1]))
			set_current_line(c, sm, int(d.cur_line))
			msgs := make([dynamic]dt.Node, c.allocator)
			kids := inline_nodes(c, t, d.first, int(d.line), containers[0], &msgs)
			line := element(c, .line, d.raw, kids)
			containers[0] = containers[1]
			set_srcline(c, sm, line, int(d.line))
			dt.append_child(doc, block, line)
			extend(c, outer, msgs[:]) // each line's messages go to the enclosing element
			continue
		}
		// ``nest_line_block_segment`` builds the nested blocks after parsing:
		// the outermost ones are attached at the block's end line, deeper
		// ones inside detached blocks (no source/line)
		sub := dt.new_element(doc, .line_block)
		if has_cur {
			set_current_line(c, sm, cur)
			dt.append_child(doc, block, sub)
		} else {
			link_child(c, block, sub)
		}
		line_block_children(c, t, ch, sub, sm, outer, containers, 0, false)
	}
}

// Append ``child`` without ``setup_child`` (Python's
// ``parent.children.append(child)``): no source or line.
link_child :: proc(c: ^Context, parent, child: dt.Node) {
	src, has_src := dt.source(c.doc, child)
	ln, has_line := dt.line(c.doc, child)
	dt.append_child(c.doc, parent, child)
	dt.set_source(c.doc, child, src if has_src else nil)
	dt.set_line(c.doc, child, ln if has_line else nil)
}

build_table :: proc(c: ^Context, t: ^rst.Tree, n: rst.Node, parent: dt.Node, sm: ^Machine) {
	doc := c.doc
	d := rst.node_data(t, n)
	table := dt.new_element(doc, .table)
	// docutils nests the cells with a 1-based ``input_offset``: absolute
	// lines run ahead of the source (see rst.build_table)
	cell_sm := context_machine(sm, sm.node)
	cell_sm.line_delta = sm.line_delta + int(d.num[0])
	for tg := d.first; tg != rst.NO_NODE; tg = rst.next_sibling(t, tg) {
		tgroup := dt.new_element(doc, .tgroup)
		dt.set_attr(doc, tgroup, "cols", int(rst.node_num(t, tg)[0]))
		dt.append_child(doc, table, tgroup)
		for part := rst.first_child(t, tg); part != rst.NO_NODE; part = rst.next_sibling(t, part) {
			kind := rst.node_kind(t, part)
			if kind == .Colspec {
				colspec := dt.new_element(doc, .colspec)
				dt.set_attr(doc, colspec, "colwidth", int(rst.node_num(t, part)[0]))
				dt.append_child(doc, tgroup, colspec)
				continue
			}
			section := dt.new_element(doc, .thead if kind == .THead else .tbody)
			dt.append_child(doc, tgroup, section)
			for row_item := rst.first_child(t, part); row_item != rst.NO_NODE; {
				dt.append_child(doc, section, table_row(c, t, row_item, &cell_sm))
				row_item = rst.next_sibling(t, row_item)
			}
		}
	}
	set_current_line(c, sm, int(d.cur_line))
	dt.append_child(doc, parent, table)
}

@(private = "file")
table_row :: proc(c: ^Context, t: ^rst.Tree, n: rst.Node, cell_sm: ^Machine) -> dt.Node {
	doc := c.doc
	row := dt.new_element(doc, .row)
	for e := rst.first_child(t, n); e != rst.NO_NODE; e = rst.next_sibling(t, e) {
		num := rst.node_num(t, e)
		entry := dt.new_element(doc, .entry)
		if num[0] != 0 do dt.set_attr(doc, entry, "morerows", int(num[0]))
		if num[1] != 0 do dt.set_attr(doc, entry, "morecols", int(num[1]))
		dt.append_child(doc, row, entry)
		build_items(c, t, rst.first_child(t, e), entry, cell_sm, false)
	}
	return row
}

// --- footnotes, citations, targets ------------------------------------------------

// The label child (if any) of a footnote or citation, and the first body item.
@(private = "file")
append_label :: proc(c: ^Context, t: ^rst.Tree, n: rst.Node, node: dt.Node) -> rst.Node {
	first := rst.first_child(t, n)
	if first != rst.NO_NODE && rst.node_kind(t, first) == .Label {
		dt.append_child(c.doc, node, dt.new_element(c.doc, .label, "", rst.node_text(t, first)))
		return rst.next_sibling(t, first)
	}
	return first
}

build_footnote :: proc(c: ^Context, t: ^rst.Tree, n: rst.Node, parent: dt.Node, sm: ^Machine) {
	doc := c.doc
	name := normalize_name(rst.node_name(t, n))
	footnote := dt.new_element(doc, .footnote, rst.node_raw(t, n))
	set_srcline(c, sm, footnote, rst.node_line(t, n))
	body := append_label(c, t, n, footnote)
	if has_prefix(name, "#") {
		name = name[1:]
		dt.set_attr(doc, footnote, "auto", 1)
		if name != "" do dt.list_append(doc, footnote, dt.K_NAMES, name)
		dt.note_autofootnote(doc, footnote)
	} else if name == "*" {
		name = ""
		dt.set_attr(doc, footnote, "auto", "*")
		dt.note_symbol_footnote(doc, footnote)
	} else {
		dt.list_append(doc, footnote, dt.K_NAMES, name)
		dt.note_footnote(doc, footnote)
	}
	if name != "" {
		dt.note_explicit_target(doc, footnote, footnote)
	} else {
		dt.set_id(doc, footnote, footnote)
	}
	build_items(c, t, body, footnote, sm, false)
	dt.append_child(doc, parent, footnote)
}

build_citation :: proc(c: ^Context, t: ^rst.Tree, n: rst.Node, parent: dt.Node, sm: ^Machine) {
	doc := c.doc
	citation := dt.new_element(doc, .citation, rst.node_raw(t, n))
	set_srcline(c, sm, citation, rst.node_line(t, n))
	body := append_label(c, t, n, citation)
	dt.list_append(doc, citation, dt.K_NAMES, normalize_name(rst.node_name(t, n)))
	dt.note_citation(doc, citation)
	dt.note_explicit_target(doc, citation, citation)
	build_items(c, t, body, citation, sm, false)
	dt.append_child(doc, parent, citation)
}

build_target :: proc(c: ^Context, t: ^rst.Tree, n: rst.Node, parent: dt.Node, sm: ^Machine) {
	d := rst.node_data(t, n)
	doc := c.doc
	set_current_line(c, sm, int(d.cur_line)) // registry messages are attached here
	target := dt.new_element(doc, .target, d.raw)
	if d.num[0] == TARGET_REFNAME {
		dt.set_attr(doc, target, dt.K_REFNAME, normalize_name(d.text))
		set_indirect_reference_name(c, target, d.text)
		add_target(c, d.name, "", target, int(d.line), parent)
		dt.note_indirect_target(doc, target)
	} else {
		add_target(c, d.name, d.text, target, int(d.line), parent)
	}
	dt.append_child(doc, parent, target)
}

// ``target.indirect_reference_name = name``.
set_indirect_reference_name :: proc(c: ^Context, n: dt.Node, name: string) {
	internals := dt_internals(c, n)
	internals.indirect_reference_name = dt.clone(c.doc, name)
}

// The Python instance state of ``n`` (``Doc.internals``).
dt_internals :: proc(c: ^Context, n: dt.Node) -> ^dt.Node_Internals {
	if n not_in c.doc.internals do c.doc.internals[n] = {}
	return &c.doc.internals[n]
}

// ``Body.add_target``.
add_target :: proc(
	c: ^Context,
	targetname, refuri: string,
	target: dt.Node,
	lineno: int,
	parent: dt.Node,
) {
	doc := c.doc
	dt.set_line(doc, target, lineno)
	note_absolute_line(c, target)
	if targetname != "" {
		name := normalize_name(dt.unescape(targetname))
		dt.list_append(doc, target, dt.K_NAMES, name)
		if refuri != "" {
			uri := adjust_uri(c, refuri)
			if uri != "" do dt.set_attr(doc, target, dt.K_REFURI, uri)
		}
		dt.note_explicit_target(doc, target, parent)
	} else {
		if refuri != "" do dt.set_attr(doc, target, dt.K_REFURI, refuri)
		dt.set_attr(doc, target, "anonymous", true)
		dt.note_anonymous_target(doc, target)
	}
}

// ``Inliner.adjust_uri``.
adjust_uri :: proc(c: ^Context, uri: string) -> string {
	charlevel := .Character_Level_Inline_Markup in c.flags
	return rst.adjust_uri_text(uri, charlevel, c.allocator)
}

build_comment :: proc(c: ^Context, t: ^rst.Tree, n: rst.Node, parent: dt.Node, sm: ^Machine) {
	s := rst.node_text(t, n)
	set_current_line(c, sm, rst.node_cur_line(t, n))
	dt.append_child(c.doc, parent, dt.new_element(c.doc, .comment, s, s))
}

// --- substitution definitions ------------------------------------------------------

build_substitution_definition :: proc(
	c: ^Context,
	t: ^rst.Tree,
	n: rst.Node,
	parent: dt.Node,
	sm: ^Machine,
) {
	doc := c.doc
	d := rst.node_data(t, n)
	src, ln := srcline(c, sm, int(d.line))
	node := dt.new_element(doc, .substitution_definition, d.raw)
	dt.set_source(doc, node, src)
	dt.set_line(doc, node, ln)
	alt := dt.whitespace_normalize_name(d.name)
	dt.list_append(doc, node, dt.K_NAMES, alt)
	sub_sm := context_machine(sm, node)
	sub_sm.line_delta = sm.line_delta + int(d.num[0])
	// where the SubstitutionDef state stopped (an embedded directive moves
	// on from there while it runs)
	set_current_line(c, sm, int(d.cur_line))
	for ch := d.first; ch != rst.NO_NODE; ch = rst.next_sibling(t, ch) {
		// the SubstitutionDef state machine's current line (note_source)
		set_current(c, &sub_sm, rst.node_line(t, ch))
		if rst.node_kind(t, ch) == .Directive {
			build_directive(c, t, ch, node, &sub_sm, true, alt)
		} else {
			build_block(c, t, ch, node, &sub_sm)
		}
	}
	finish_substitution_definition(c, node, d, parent, src, ln)
}

// ``Body.substitution_def`` post-processing: body elements move out,
// the contents are checked and the definition is registered.
@(private = "file")
finish_substitution_definition :: proc(
	c: ^Context,
	node: dt.Node,
	d: rst.Node_Data,
	parent: dt.Node,
	src: Maybe(string),
	ln: Maybe(int),
) {
	doc := c.doc
	for ch in dt.children(doc, node, c.allocator) {
		if !dt.is(doc, ch, dt.tags_of(.Inline) + {.Text}) do dt.append_child(doc, parent, ch)
	}
	opts := dt.Message_Options {
		source = src,
		line   = ln,
	}
	for elem in dt.traverse(doc, node, dt.tags_of(.Element), include_self = false) {
		if dt.tag(doc, elem) == .problematic {
			opts.children = {dt.new_element(doc, .literal_block, "", d.raw)}
			msg := dt.error(doc, "Problematic content in substitution definition", opts)
			para := element(c, .paragraph, "", dt.children(doc, node, c.allocator))
			dt.append_child(doc, msg, element(c, .block_quote, "", {para}))
			dt.append_child(doc, parent, msg)
			return
		}
		if illegal := disallowed_in_substitution(c, elem); illegal != "" {
			opts.children = {dt.new_element(doc, .literal_block, "", d.raw)}
			text := concat(illegal, " are not supported in a substitution definition.")
			dt.append_child(doc, parent, dt.error(doc, text, opts))
			return
		}
	}
	if dt.child_count(doc, node) == 0 {
		opts.children = {dt.new_element(doc, .literal_block, d.raw, d.raw)}
		text := concat("Substitution definition \"", d.name, "\" empty or invalid.")
		dt.append_child(doc, parent, dt.warning(doc, text, opts))
		return
	}
	dt.note_substitution_def(doc, node, d.name, parent)
	dt.append_child(doc, parent, node)
}

// ``Body.disallowed_inside_substitution_definitions``.
@(private = "file")
disallowed_in_substitution :: proc(c: ^Context, n: dt.Node) -> string {
	doc := c.doc
	anonymous, _ := dt.get_attr(doc, n, "anonymous")
	if dt.tag(doc, n) == .reference && truthy(doc, anonymous) do return "Anonymous references"
	auto, _ := dt.get_attr(doc, n, "auto")
	if dt.tag(doc, n) == .footnote_reference && truthy(doc, auto) {
		return "References to auto-numbered and auto-symbol footnotes"
	}
	if len(dt.attr_list(doc, n, dt.K_NAMES)) > 0 || len(dt.attr_list(doc, n, dt.K_IDS)) > 0 {
		return "Targets (names and identifiers)"
	}
	return ""
}

// Python truthiness of an attribute value (missing: false).
truthy :: proc(doc: ^dt.Doc, v: dt.Attr_Value) -> bool {
	switch x in v {
	case string:
		return x != ""
	case int:
		return x != 0
	case bool:
		return x
	case dt.List:
		return len(dt.list_items(doc, x)) > 0
	case dt.Attr_None:
		return false
	}
	return false
}
