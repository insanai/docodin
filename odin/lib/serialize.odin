package docodin

import "base:runtime"

import rst "../rst"

// Serialization of the parse tree for the Python host in CPython ``marshal``
// format: ``marshal.loads`` turns it into tuples/lists/str/int at C speed.
// Only the stable, version-independent type codes are used.
//
// Wire layout (K = int(Node_Kind); children = list):
//   Text                          str
//   Emphasis/Strong/Literal/Inline_Target
//                                 (K, raw, text)
//   Substitution_Reference        (K, raw, text, underscores)
//   Reference                     (K, ref_kind, raw, text, x, y)
//                                   Simple: x=anonymous(bool)
//                                   Phrase: x=alias_type, y=(alias, target_raw)
//                                   Uri/Pep/Rfc: x=refuri or number
//   Footnote/Citation_Reference   (K, label)
//   Interpreted                   (K, raw, text, role)
//   Problematic                   (K, text, level, message)
//   System_Message                (K, line, level, message, children, cur,
//                                  source_line: map the line through the
//                                  parse's input lines, see rst.mark_source_line)
//   Section_Title                 (K, line, style, source, title_raw, title_children,
//                                  messages, cur_line)
//   Directive                     (K, line, name, block_text, lines, line_offset,
//                                  end_offset, blank_finish, reporter_line,
//                                  inserted: the include hook inserted its lines)
//   Target                        (K, line, raw, name, type, data, cur)
//   Footnote, Citation            (K, line, label, raw, children, cur)
//   Comment                       (K, line, text, cur)
//   Option_List_Item, Line_Block  (K, line, children, cur)
//   Table                         (K, line, children, cur, cell_line_delta)
//   <other block elements>        see ``write_node``
//
// ``cur`` values are docutils' ``document.current_line`` (rst.Parser.cur_line):
// a line number, 0 (None), -1 (None, and no current source), or at most -2:
// line None past the end of an input whose last line is ``-cur - 1`` (the
// current source is that line's).

MARSHAL_NONE  :: 'N'
MARSHAL_TRUE  :: 'T'
MARSHAL_FALSE :: 'F'
MARSHAL_INT   :: 'i'
MARSHAL_LIST  :: '['
MARSHAL_TUPLE :: '('
MARSHAL_SMALL_TUPLE :: ')'
MARSHAL_SHORT_ASCII :: 'z'
MARSHAL_ASCII :: 'a'
MARSHAL_UNICODE :: 'u'

// Wire format version, bumped whenever the layout changes.
WIRE_VERSION :: 3

Writer :: struct {
	buf: [dynamic]u8,
}

writer_make :: proc(capacity: int) -> Writer {
	return Writer{buf = make([dynamic]u8, 0, max(capacity, 256), runtime.heap_allocator())}
}

@(private = "file")
w_byte :: #force_inline proc(w: ^Writer, b: u8) {
	append(&w.buf, b)
}

@(private = "file")
w_u32 :: #force_inline proc(w: ^Writer, v: u32) {
	bytes := transmute([4]u8)u32le(v)
	append(&w.buf, ..bytes[:])
}

w_int :: proc(w: ^Writer, v: int) {
	w_byte(w, MARSHAL_INT)
	w_u32(w, u32(i32(clamp(v, int(min(i32)), int(max(i32))))))
}

w_bool :: proc(w: ^Writer, v: bool) {
	w_byte(w, MARSHAL_TRUE if v else MARSHAL_FALSE)
}

w_none :: proc(w: ^Writer) {
	w_byte(w, MARSHAL_NONE)
}

w_str :: proc(w: ^Writer, s: string) {
	ascii := true
	for i in 0 ..< len(s) {
		if s[i] >= 0x80 {
			ascii = false
			break
		}
	}
	if ascii && len(s) < 256 {
		w_byte(w, MARSHAL_SHORT_ASCII)
		w_byte(w, u8(len(s)))
	} else {
		w_byte(w, MARSHAL_ASCII if ascii else MARSHAL_UNICODE)
		w_u32(w, u32(len(s)))
	}
	append(&w.buf, s)
}

w_tuple :: proc(w: ^Writer, n: int) {
	if n < 256 {
		w_byte(w, MARSHAL_SMALL_TUPLE)
		w_byte(w, u8(n))
	} else {
		w_byte(w, MARSHAL_TUPLE)
		w_u32(w, u32(n))
	}
}

w_list :: proc(w: ^Writer, n: int) {
	w_byte(w, MARSHAL_LIST)
	w_u32(w, u32(n))
}

write_children :: proc(w: ^Writer, t: ^rst.Tree, n: rst.Node) {
	write_chain(w, t, rst.first_child(t, n))
}

write_chain :: proc(w: ^Writer, t: ^rst.Tree, first: rst.Node) {
	count := 0
	for c := first; c != rst.NO_NODE; c = t.nodes[c].next do count += 1
	w_list(w, count)
	for c := first; c != rst.NO_NODE; c = t.nodes[c].next do write_node(w, t, c)
}

write_node :: proc(w: ^Writer, t: ^rst.Tree, n: rst.Node) {
	d := rst.node_data(t, n)
	#partial switch d.kind {
	case .Text, .Emphasis, .Strong, .Literal, .Inline_Target, .Substitution_Reference, .Reference,
	     .Footnote_Reference, .Citation_Reference, .Interpreted, .Problematic:
		write_inline_node(w, t, n, d)
	case .System_Message, .Section_Title, .Directive, .Target:
		write_parser_node(w, t, n, d)
	case:
		write_block_node(w, t, n, d)
	}
}

// Inline nodes (see the wire layout above).
@(private = "file")
write_inline_node :: proc(w: ^Writer, t: ^rst.Tree, n: rst.Node, d: rst.Node_Data) {
	k := int(d.kind)
	#partial switch d.kind {
	case .Text:
		w_str(w, d.text)

	case .Emphasis, .Strong, .Literal, .Inline_Target:
		w_tuple(w, 3); w_int(w, k); w_str(w, d.raw); w_str(w, d.text)

	case .Substitution_Reference:
		w_tuple(w, 4); w_int(w, k); w_str(w, d.raw); w_str(w, d.text)
		w_int(w, int(d.num[0]))

	case .Reference:
		w_tuple(w, 6); w_int(w, k); w_int(w, int(d.num[0])); w_str(w, d.raw); w_str(w, d.text)
		write_reference_target(w, t, n, d)

	case .Footnote_Reference, .Citation_Reference:
		w_tuple(w, 2); w_int(w, k); w_str(w, d.text)

	case .Interpreted:
		w_tuple(w, 4); w_int(w, k); w_str(w, d.raw); w_str(w, d.text); w_str(w, d.name)

	case .Problematic:
		w_tuple(w, 4); w_int(w, k); w_str(w, d.text); w_int(w, int(d.num[0])); w_str(w, d.name)
	}
}

// The ``x, y`` fields of a Reference.
@(private = "file")
write_reference_target :: proc(w: ^Writer, t: ^rst.Tree, n: rst.Node, d: rst.Node_Data) {
	switch rst.Ref_Kind(d.num[0]) {
	case .Simple:
		w_bool(w, d.num[1] != 0); w_none(w)
	case .Phrase:
		if info, ok := rst.phrase_info(t, n); ok {
			w_int(w, int(info.alias_type))
			w_tuple(w, 2); w_str(w, info.alias); w_str(w, info.target_raw)
		} else {
			w_int(w, 0); w_none(w)
		}
	case .Uri, .Pep, .Rfc:
		w_str(w, d.name); w_none(w)
	}
}

// Messages, titles, directives and targets: records the host finishes.
@(private = "file")
write_parser_node :: proc(w: ^Writer, t: ^rst.Tree, n: rst.Node, d: rst.Node_Data) {
	k := int(d.kind)
	line := int(d.line)
	#partial switch d.kind {
	case .System_Message:
		w_tuple(w, 7); w_int(w, k); w_int(w, line); w_int(w, int(d.num[0])); w_str(w, d.text)
		write_children(w, t, n)
		w_int(w, int(d.cur_line)); w_bool(w, d.num[1] != 0)

	case .Section_Title:
		w_tuple(w, 8); w_int(w, k); w_int(w, line)
		w_str(w, d.name); w_str(w, d.text); w_str(w, d.raw)
		if title := d.first; title != rst.NO_NODE {
			write_children(w, t, title)
			write_chain(w, t, rst.next_sibling(t, title))
			w_int(w, int(rst.node_num(t, title)[1]))
		} else {
			w_list(w, 0); w_list(w, 0); w_int(w, 0)
		}

	case .Directive:
		info, _ := rst.directive_info(t, n)
		w_tuple(w, 10); w_int(w, k); w_int(w, line); w_str(w, d.name); w_str(w, d.raw)
		w_list(w, len(info.lines))
		for l in info.lines do w_str(w, l)
		w_int(w, info.line_offset); w_int(w, info.end_offset); w_bool(w, info.blank_finish)
		w_int(w, int(d.num[1])); w_bool(w, d.num[0] != 0)

	case .Target:
		w_tuple(w, 7); w_int(w, k); w_int(w, line); w_str(w, d.raw); w_str(w, d.name)
		w_int(w, int(d.num[0])); w_str(w, d.text); w_int(w, int(d.cur_line))
	}
}

// Body elements (see the wire layout above).
@(private = "file")
write_block_node :: proc(w: ^Writer, t: ^rst.Tree, n: rst.Node, d: rst.Node_Data) {
	k := int(d.kind)
	line := int(d.line)
	#partial switch d.kind {
	case .Paragraph, .Term, .Field_Name, .Line, .Attribution:
		// num[1]: reporter's current line while the inline text was parsed
		w_tuple(w, 6); w_int(w, k); w_int(w, line); w_str(w, d.raw); write_children(w, t, n)
		w_int(w, int(d.num[1])); w_int(w, int(d.cur_line))

	case .Classifier, .Option, .Title:
		w_tuple(w, 4); w_int(w, k); w_int(w, line); w_str(w, d.raw); write_children(w, t, n)

	case .Literal_Block, .Doctest_Block, .Label, .Option_String:
		w_tuple(w, 3); w_int(w, k); w_int(w, line); w_str(w, d.text)

	case .Comment:
		w_tuple(w, 4); w_int(w, k); w_int(w, line); w_str(w, d.text); w_int(w, int(d.cur_line))

	case .Option_List_Item, .Line_Block:
		// cur_line: docutils ``document.current_line`` when the node is attached
		w_tuple(w, 4); w_int(w, k); w_int(w, line); write_children(w, t, n)
		w_int(w, int(d.cur_line))

	case .Table:
		// num[0]: line delta of the cells (see rst.build_table)
		w_tuple(w, 5); w_int(w, k); w_int(w, line); write_children(w, t, n)
		w_int(w, int(d.cur_line)); w_int(w, int(d.num[0]))

	case .Transition:
		w_tuple(w, 3); w_int(w, k); w_int(w, line); w_str(w, d.raw)

	case .Include_End:
		w_tuple(w, 2); w_int(w, k); w_int(w, line)

	case .Option_Argument:
		w_tuple(w, 4); w_int(w, k); w_int(w, line); w_str(w, d.text); w_str(w, d.name)

	case .Bullet_List, .Field_List:
		w_tuple(w, 4); w_int(w, k); w_int(w, line); w_str(w, d.name); write_children(w, t, n)

	case .Footnote, .Citation:
		w_tuple(w, 6); w_int(w, k); w_int(w, line); w_str(w, d.name); w_str(w, d.raw)
		write_children(w, t, n)
		w_int(w, int(d.cur_line))

	case .List_Item, .Field_Body, .Description, .Definition_List_Item:
		w_tuple(w, 4); w_int(w, k); w_int(w, line); w_str(w, d.raw); write_children(w, t, n)

	case .Block_Quote:
		w_tuple(w, 5); w_int(w, k); w_int(w, line); w_str(w, d.raw); write_children(w, t, n)
		w_int(w, int(d.cur_line))

	case .Substitution_Definition:
		// num[0]: source-line minus absolute-line offset inside the definition
		w_tuple(w, 7); w_int(w, k); w_int(w, line); w_str(w, d.raw); w_str(w, d.name)
		write_children(w, t, n)
		w_int(w, int(d.num[0])); w_int(w, int(d.cur_line))

	case .Enumerated_List:
		w_tuple(w, 7); w_int(w, k); w_int(w, line)
		w_str(w, d.name); w_str(w, d.text); w_str(w, d.raw)
		if d.num[1] != 0 {
			w_int(w, int(d.num[0]))
		} else {
			w_none(w)
		}
		write_children(w, t, n)

	case .TGroup, .Colspec:
		w_tuple(w, 4); w_int(w, k); w_int(w, line); w_int(w, int(d.num[0]))
		write_children(w, t, n)

	case .Entry:
		w_tuple(w, 5); w_int(w, k); w_int(w, line)
		w_int(w, int(d.num[0])); w_int(w, int(d.num[1])); write_children(w, t, n)

	case:
		// structural elements without payload (the parser only produces
		// kinds listed above; others use this generic layout)
		w_tuple(w, 3); w_int(w, k); w_int(w, line); write_children(w, t, n)
	}
}

// Top-level result: (WIRE_VERSION, children, line_count, final_offset,
// cur_line), ``cur_line`` being docutils' ``document.current_line`` at the
// end of the parse (``rst.Parser.cur_line``).
serialize_document :: proc(
	t: ^rst.Tree,
	doc: rst.Node,
	line_count: int,
	final_offset: int,
	cur_line: int,
	size_hint: int,
) -> Writer {
	w := writer_make(size_hint)
	w_tuple(&w, 5)
	w_int(&w, WIRE_VERSION)
	write_children(&w, t, doc)
	w_int(&w, line_count)
	w_int(&w, final_offset)
	w_int(&w, cur_line)
	return w
}

serialize_inline :: proc(t: ^rst.Tree, nodes: rst.Node_List, size_hint: int) -> Writer {
	w := writer_make(size_hint)
	w_tuple(&w, 2)
	w_int(&w, WIRE_VERSION)
	write_chain(&w, t, nodes.first)
	return w
}
