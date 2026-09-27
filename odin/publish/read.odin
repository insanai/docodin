package publish

import "core:strings"

import dt "../doctree"
import rd "../reader"

// Reading without writing: ``Publisher.publish`` up to the transforms, for
// tools that report a document's system messages (the language server).
//
//     arena: virtual.Arena
//     r := publish.read_document(text, "doc.rst", "pseudoxml",
//         {{"report_level", 1}, {"halt_level", 5}}, {keep_tree = true},
//         virtual.arena_allocator(&arena))
//     defer dt.destroy(r.doc)
//     for m in r.messages do ...
//
// The settings, reader, transforms, reporter and halting are ``publish``'s.

// A system message written to the warning stream.
Document_Message :: struct {
	level:  int,
	source: string, // "" for none
	line:   int, // 0 for none
	// ``Element.astext()`` of the message: its paragraphs and source excerpt,
	// separated by blank lines (``msg.astext()`` without the
	// "source:line: (LEVEL/n) " head)
	text:   string,
	// the ``system_message`` element in ``Read_Result.doc`` (0 for a
	// message of a nested document's reporter)
	node:   dt.Node,
}

Read_Options :: struct {
	using options: Options,
	// keep the native parse tree of the document (``Read_Result.tree``)
	keep_tree:     bool,
}

Read_Result :: struct {
	// The transformed document (nil after a settings error); the caller
	// destroys it (``dt.destroy``).
	doc:      ^dt.Doc,
	// The messages written to the warning stream (``report_level``), up to
	// the one that halted the run or the exception.
	messages: []Document_Message,
	err:      Error, // Settings_Error, System_Message (``halt_level``) or Exception
	needs:    []Python_Need,
	tree:     rd.Parse_Tree, // with ``keep_tree``
}

// ``publish`` without the writer: read ``text`` and apply the transforms of
// ``writer`` with the settings ``overrides``.  Everything is allocated with
// ``allocator`` (an arena: nothing is freed piecemeal), except the document,
// which owns its memory.
read_document :: proc(
	text, source_path, writer: string,
	overrides: []Override,
	options := Read_Options{},
	allocator := context.allocator,
) -> (
	result: Read_Result,
) {
	context.allocator = allocator
	context.temp_allocator = allocator
	p := Pipeline {
		source_path  = source_path,
		options      = options.options,
		docutils_dir = options.docutils_dir,
		allocator    = allocator,
	}
	if p.docutils_dir == "" do p.docutils_dir = DEFAULT_DOCUTILS_DIR
	if options.keep_tree do p.tree_allocator = allocator
	if prepare(&p, writer, overrides) && read(&p, text) do transform(&p)
	return {p.doc, document_messages(&p), p.err, collect_needs(&p), p.tree}
}

@(private = "file")
document_messages :: proc(p: ^Pipeline) -> []Document_Message {
	if p.doc == nil do return nil
	doc := p.doc
	r := &doc.reporter
	written := r.written[:r.halt_written] if r.halted else r.written[:]
	if n, raised := p.written.?; raised do written = r.written[:n]
	out := make([]Document_Message, len(written))
	for w, i in written {
		m := Document_Message {
			level = int(w.level),
			node  = w.node,
			text  = strings.trim_right(w.text, "\n"),
		}
		if w.node != 0 {
			m.source = strings.clone(dt.get_string(doc, w.node, dt.K_SOURCE))
			m.line = dt.get_int(doc, w.node, dt.K_LINE)
			m.text = message_text(doc, w.node)
		} else if _, _, rest := strings.partition(m.text, ") "); rest != "" {
			m.text = rest // "source:line: (LEVEL/n) text"
		}
		m.text = strings.clone(m.text)
		out[i] = m
	}
	return out
}

// The children of a ``system_message`` as ``Element.astext`` joins them.
@(private = "file")
message_text :: proc(doc: ^dt.Doc, msg: dt.Node) -> string {
	b := strings.builder_make()
	for c := doc.nodes[msg].first; c != 0; c = doc.nodes[c].next {
		if c != doc.nodes[msg].first do strings.write_string(&b, "\n\n")
		dt.write_astext(&b, doc, c)
	}
	return strings.to_string(b)
}
