package reader

import "core:strings"

import dt "../doctree"
import rst "../rst"

// Section nesting: ``RSTState.check_subsection`` and ``new_subsection``.
//
// A title style is the underline character, or the overline and underline
// characters (one or two code points, as the parse tree records them);
// ``memo.title_styles`` lists them in order of appearance.

// ``(K, line, style, source, title_raw, title_children, messages, cur_line)``
build_section_title :: proc(c: ^Context, t: ^rst.Tree, n: rst.Node, _: dt.Node, sm: ^Machine) {
	doc := c.doc
	d := rst.node_data(t, n)
	title := d.first
	messages := make([dynamic]dt.Node, c.allocator)
	title_items := rst.NO_NODE
	cur_line := 0
	if title != rst.NO_NODE {
		title_items = rst.first_child(t, title)
		cur_line = int(rst.node_num(t, title)[1])
		for m := rst.next_sibling(t, title); m != rst.NO_NODE; m = rst.next_sibling(t, m) {
			append(&messages, message(c, t, m))
		}
	}
	lineno := int(d.line)
	// docutils checks and creates the section while positioned on the underline
	set_current(c, sm, lineno + 1)
	if !check_subsection(c, sm, d.text, d.name, lineno) do return
	section := dt.new_element(doc, .section)
	dt.append_child(doc, sm.node, section)
	title_messages := make([dynamic]dt.Node, c.allocator)
	at_line(c, cur_line)
	textnodes := inline_nodes(c, t, title_items, lineno, sm.node, &title_messages)
	titlenode := element(c, .title, d.raw, textnodes)
	dt.list_append(doc, section, dt.K_NAMES, normalize_name(dt.astext(doc, titlenode)))
	dt.append_child(doc, section, titlenode)
	extend(c, section, messages[:])
	extend(c, section, title_messages[:])
	dt.note_implicit_target(doc, section, section)
	sm.node = section
	c.section_level += 1
}

// ``RSTState.check_subsection``: is the section valid here?  Moves
// ``sm.node`` up to the new section's parent.
check_subsection :: proc(c: ^Context, sm: ^Machine, source, style: string, lineno: int) -> bool {
	parent_sections := dt.section_hierarchy(c.doc, sm.node, c.allocator)
	oldlevel := len(parent_sections) + sm.section_level_offset
	newlevel := len(c.title_styles) + 1
	for s, i in c.title_styles {
		if s == style {
			newlevel = i + 1
			break
		}
	}
	if newlevel > oldlevel + 1 {
		text := concat(
			"Inconsistent title style: skip from level ",
			itoa(oldlevel),
			" to ",
			itoa(newlevel),
			".",
		)
		subsection_error(c, sm, text, source, lineno, "")
		return false
	}
	if newlevel <= oldlevel {
		// new section is sibling or higher up in the section hierarchy
		k := oldlevel - newlevel + 1 // parent_sections[newlevel - oldlevel - 1]
		if k > len(parent_sections) {
			details := concat(
				"The parent of level ",
				itoa(newlevel),
				" sections cannot be reached. The parser is at section level ",
				itoa(oldlevel),
				" but the current node has only ",
				itoa(len(parent_sections)),
				" parent section(s).\nOne reason may be a high level section used in a ",
				"directive that parses its content into a base node not attached to the ",
				"document\n(up to Docutils 0.21, these sections were silently dropped).",
			)
			text := concat("A level ", itoa(newlevel), " section cannot be used here.")
			subsection_error(c, sm, text, source, lineno, details)
			return false
		}
		sm.node = dt.parent(c.doc, parent_sections[len(parent_sections) - k])
		c.section_level = newlevel - 1
	}
	if newlevel > len(c.title_styles) do append(&c.title_styles, dt.clone(c.doc, style))
	return true
}

@(private = "file")
subsection_error :: proc(
	c: ^Context,
	sm: ^Machine,
	text, source: string,
	lineno: int,
	details: string,
) {
	doc := c.doc
	kids := make([dynamic]dt.Node, 0, 3, c.allocator)
	append(&kids, dt.new_element(doc, .literal_block, "", source))
	styles := concat("Established title styles: ", format_styles(c))
	append(&kids, dt.new_element(doc, .paragraph, "", styles))
	if details != "" do append(&kids, dt.new_element(doc, .paragraph, "", details))
	msg := dt.error(doc, text, {children = kids[:], line = lineno})
	dt.append_child(doc, sm.node, msg)
}

// ``' '.join('/'.join(style) for style in title_styles)``.
@(private = "file")
format_styles :: proc(c: ^Context) -> string {
	b := strings.builder_make(c.allocator)
	for s, i in c.title_styles {
		if i > 0 do strings.write_byte(&b, ' ')
		k := 0
		for r in s {
			if k > 0 do strings.write_byte(&b, '/')
			strings.write_rune(&b, r)
			k += 1
		}
	}
	return strings.to_string(b)
}
