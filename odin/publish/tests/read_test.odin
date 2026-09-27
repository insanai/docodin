package publish_tests

import "core:mem/virtual"
import "core:strings"
import "core:testing"

import dt "../../doctree"
import pb "../"
import rst "../../rst"

// ``read_document``: the messages of the reader and the transforms, as
// ``publish`` writes them, and the parse tree kept on request.

@(test)
read_document_messages :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	text := "Title\n=====\n\nSee `missing`_ and *oops.\n\n.. unknown:: x\n"
	overrides := []pb.Override{{"report_level", 1}, {"halt_level", 5}}
	r := pb.read_document(text, "doc.rst", "pseudoxml", overrides, {keep_tree = true}, a)
	defer dt.destroy(r.doc)
	testing.expect(t, r.err == nil)
	_, _, written, _, _, _ := pb.publish(text, "doc.rst", "pseudoxml", overrides,
		allocator = context.temp_allocator)
	testing.expect_value(t, len(r.messages), len(written))
	for m, i in r.messages {
		if i >= len(written) do break
		// ``publish`` writes "source:line: (LEVEL/n) " and the same text
		testing.expect_value(t, m.level, written[i].level)
		testing.expect(t, strings.has_suffix(strings.trim_space(written[i].text), m.text))
		testing.expect_value(t, m.source, "doc.rst")
		testing.expect(t, m.node != 0)
	}
	last := r.messages[len(r.messages) - 1]
	testing.expect_value(t, last.text, `Unknown target name: "missing".`)
	testing.expect_value(t, last.line, 4)
	// the parse tree: the document node with the section title first
	testing.expect(t, r.tree.root != rst.NO_NODE)
	first := rst.first_child(&r.tree.parser.tree, r.tree.root)
	testing.expect_value(t, rst.node_kind(&r.tree.parser.tree, first), rst.Node_Kind.Section_Title)
}

@(test)
read_document_halts_and_rejects_settings :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	r := pb.read_document("*x\n\n`y\n", "", "pseudoxml", {{"halt_level", 2}})
	defer dt.destroy(r.doc)
	halt, halted := r.err.(pb.System_Message)
	testing.expect(t, halted && halt.level == 2)
	testing.expect_value(t, len(r.messages), 1) // up to the halting message
	testing.expect(t, r.tree.root == rst.NO_NODE) // not requested
	bad := pb.read_document("x\n", "", "pseudoxml", {{"report_level", "loud"}})
	_, is_settings := bad.err.(pb.Settings_Error)
	testing.expect(t, is_settings && bad.doc == nil)
}
