package lsp_tests

// Tests of the language features: resolution, symbols, folding, semantic
// tokens, hover, completion, diagnostics and quick fixes.

import "core:encoding/json"
import "core:strings"
import "core:testing"

import lsp ".."

@(private = "file")
DOC :: `Title
=====

See ` + "`Title`_, link_, `phrase <link_>`_, anon__, `anon2`__," + `
|sub|, [1]_, [#]_, [#note]_, [*]_, [CIT]_ and _` + "`inline`." + `

.. _link: http://example.com
__ http://first
.. __: http://second
.. |sub| replace:: text
.. [1] one
.. [#] auto
.. [#note] labelled
.. [*] symbol
.. [CIT] citation

Ref to inline_ and ` + "`Other Section`_ and `name-opt`_." + `

Other Section
-------------

.. note:: Note with *emph* and link_.
   :name: name-opt

- item

  ::

     literal
`

@(private = "file")
analyse :: proc(text: string) -> (lsp.Line_Index, lsp.Analysis) {
	ix := lsp.line_index_make(text, 8, context.temp_allocator)
	a := lsp.analyze(&ix, context.temp_allocator)
	return ix, a
}

// The column of the ``nth`` occurrence of ``needle`` on line ``line``.
@(private = "file")
col_of :: proc(ix: ^lsp.Line_Index, line: int, needle: string, nth := 0) -> int {
	text := ix.expanded[line]
	at := 0
	for _ in 0 ..= nth {
		i := strings.index(text[at:], needle)
		if i < 0 do return -1
		at += i + (1 if nth > 0 else 0)
	}
	return at - (1 if nth > 0 else 0)
}

// The line of the definition of the name at ``needle`` on ``line``.
@(private = "file")
definition_line :: proc(ix: ^lsp.Line_Index, a: ^lsp.Analysis, line: int, needle: string) -> int {
	col := col_of(ix, line, needle)
	if col < 0 do return -2
	def := lsp.definition_of(a, lsp.item_at(a, {i32(line), i32(col + 1)}))
	return -1 if def == lsp.NO_ITEM else int(a.items[def].span.start.line)
}

@(test)
test_resolution :: proc(t: ^testing.T) {
	ix, a := analyse(DOC)
	cases := []struct {
		line:   int,
		needle: string,
		want:   int,
	} {
		{3, "`Title`_", 0},
		{3, "link_,", 6},
		{3, "`phrase", 6},
		{3, "anon__", 7},
		{3, "`anon2`__", 8},
		{4, "|sub|", 9},
		{4, "[1]_", 10},
		{4, "[#]_", 11},
		{4, "[#note]_", 12},
		{4, "[*]_", 13},
		{4, "[CIT]_", 14},
		{16, "inline_", 4},
		{16, "`Other Section`_", 18},
		{16, "`name-opt`_", 22},
		{21, "link_", 6},
		{6, "link", 6}, // a definition is its own definition
	}
	for c in cases {
		testing.expectf(t, definition_line(&ix, &a, c.line, c.needle) == c.want, "%v", c)
	}
	link := lsp.definition_of(&a, lsp.item_at(&a, {6, 5}))
	refs := lsp.references_of(&a, link, context.temp_allocator)
	testing.expect_value(t, len(refs), 3)
}

@(test)
test_name_normalisation :: proc(t: ^testing.T) {
	ix, a := analyse("A `Mixed   CASE\nname`_.\n\n.. _mixed case NAME: http://x\n")
	testing.expect_value(t, definition_line(&ix, &a, 0, "`Mixed"), 3)
	idx := lsp.item_at(&a, {0, 3})
	testing.expect(t, idx != lsp.NO_ITEM)
	if idx != lsp.NO_ITEM do testing.expect_value(t, a.items[idx].span, lsp.Span{{0, 2}, {1, 6}})
}

@(test)
test_hover_texts :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	ix, a := analyse(DOC)
	hover :: proc(ix: ^lsp.Line_Index, a: ^lsp.Analysis, line: int, needle: string) -> string {
		return lsp.hover_text(a, lsp.item_at(a, {i32(line), i32(col_of(ix, line, needle) + 1)}))
	}
	testing.expect(t, strings.contains(hover(&ix, &a, 4, "|sub|"), "replace:: text"))
	testing.expect(t, strings.contains(hover(&ix, &a, 4, "[1]_"), "one"))
	testing.expect(t, strings.contains(hover(&ix, &a, 3, "link_"), "<http://example.com>"))
	testing.expect_value(t, hover(&ix, &a, 16, "`Other"), "**Section** Other Section")
	testing.expect(t, strings.contains(hover(&ix, &a, 21, "note"), "`:class:`"))
	_, b := analyse("A `x <http://y>`_ and `missing`_.\n")
	embedded := lsp.hover_text(&b, lsp.item_at(&b, {0, 3}))
	testing.expect_value(t, embedded, "**Hyperlink** → <http://y>")
	unknown := lsp.hover_text(&b, lsp.item_at(&b, {0, 23}))
	testing.expect(t, strings.contains(unknown, "Unknown target"))
}

@(test)
test_symbols :: proc(t: ^testing.T) {
	ss: Session
	session_start(&ss)
	defer session_end(&ss)
	open(&ss, "file:///s.rst", DOC)
	msg := request(&ss, 2, "textDocument/documentSymbol", doc_params("file:///s.rst"))
	top := lsp.get_array(msg, "result")
	testing.expect_value(t, len(top), 1)
	testing.expect_value(t, lsp.get_string(top[0], "name"), "Title")
	names := make([dynamic]string, context.temp_allocator)
	for c in lsp.get_array(top[0], "children") do append(&names, lsp.get_string(c, "name"))
	want := []string {
		"inline", "link", "|sub|", "[1]", "[#]", "[#note]", "[*]", "[CIT]", "Other Section",
	}
	testing.expect_value(t, len(names), len(want))
	for n, i in want do if i < len(names) do testing.expect_value(t, names[i], n)
	other := lsp.get_array(top[0], "children")[len(want) - 1]
	testing.expect_value(t, lsp.get_path(other, "range", "start", "line").(json.Integer), 18)
	nested := lsp.get_array(other, "children")
	testing.expect(t, len(nested) == 1 && lsp.get_string(nested[0], "name") == "name-opt")
}

@(test)
test_folding :: proc(t: ^testing.T) {
	_, a := analyse(DOC)
	has :: proc(a: ^lsp.Analysis, start, end: i32) -> bool {
		for f in a.folds do if f.start == start && f.end == end do return true
		return false
	}
	testing.expect(t, has(&a, 0, 28))  // the document's section
	testing.expect(t, has(&a, 18, 28)) // "Other Section"
	testing.expect(t, has(&a, 21, 22)) // the note
	testing.expect(t, has(&a, 24, 28)) // the list
	testing.expect(t, has(&a, 28, 28) == false)
}

// The semantic tokens of ``text`` as (line, character, length, type).
@(private = "file")
tokens :: proc(text: string) -> [][4]int {
	ss: Session
	session_start(&ss)
	defer session_end(&ss)
	open(&ss, "file:///t.rst", text)
	msg := request(&ss, 2, "textDocument/semanticTokens/full", doc_params("file:///t.rst"))
	data := lsp.get_array(lsp.get(msg, "result"), "data")
	out := make([dynamic][4]int, context.temp_allocator)
	line, char := 0, 0
	for i := 0; i + 4 < len(data); i += 5 {
		dl := int(data[i].(json.Integer))
		dc := int(data[i + 1].(json.Integer))
		char = dc if dl > 0 else char + dc
		line += dl
		length, type := int(data[i + 2].(json.Integer)), int(data[i + 3].(json.Integer))
		append(&out, [4]int{line, char, length, type})
	}
	return out[:]
}

@(test)
test_semantic_tokens :: proc(t: ^testing.T) {
	toks := tokens(
		"Title *x*\n=========\n\n:field: *e* **s** ``l`` :code:`c` |s|_ ref_\n\n" +
		".. note:: Arg\n   :class: c\n\n.. comment\n",
	)
	want := [][4]int {
		{0, 0, 6, int(lsp.Token_Type.Namespace)},
		{0, 6, 3, int(lsp.Token_Type.Emphasis)},
		{1, 0, 9, int(lsp.Token_Type.Operator)},
		{3, 1, 5, int(lsp.Token_Type.Property)},
		{3, 8, 3, int(lsp.Token_Type.Emphasis)},
		{3, 12, 5, int(lsp.Token_Type.Strong)},
		{3, 18, 5, int(lsp.Token_Type.String)},
		{3, 24, 6, int(lsp.Token_Type.Macro)},
		{3, 34, 4, int(lsp.Token_Type.Variable)},
		{3, 39, 4, int(lsp.Token_Type.Type)},
		{5, 3, 4, int(lsp.Token_Type.Function)},
		{6, 3, 7, int(lsp.Token_Type.Property)},
		{8, 0, 10, int(lsp.Token_Type.Comment)},
	}
	testing.expect_value(t, len(toks), len(want))
	for w, i in want do if i < len(toks) do testing.expect_value(t, toks[i], w)
}

@(test)
test_completion :: proc(t: ^testing.T) {
	ss: Session
	session_start(&ss)
	defer session_end(&ss)
	uri := "file:///c.rst"
	text := ".. no\n\n.. figure:: x.png\n   :wi\n\nSee `Ti and :em and |s\n\n" +
		".. |sub| replace:: x\n.. _Title: http://x\n"
	open(&ss, uri, text)
	labels :: proc(ss: ^Session, line, char: int) -> [dynamic]string {
		params := doc_params("file:///c.rst", position(line, char))
		msg := request(ss, 3, "textDocument/completion", params)
		out := make([dynamic]string, context.temp_allocator)
		for item in lsp.get_array(lsp.get(msg, "result"), "items") {
			append(&out, lsp.get_string(item, "label"))
		}
		return out
	}
	contains :: proc(list: [dynamic]string, s: string) -> bool {
		for x in list do if x == s do return true
		return false
	}
	testing.expect(t, contains(labels(&ss, 0, 5), "note"))
	testing.expect(t, contains(labels(&ss, 3, 6), ":width:"))
	testing.expect(t, contains(labels(&ss, 5, 7), "Title"))
	testing.expect(t, contains(labels(&ss, 5, 15), "emphasis"))
	testing.expect(t, contains(labels(&ss, 5, 22), "sub"))
	msg := request(&ss, 4, "textDocument/completion", doc_params(uri, position(0, 5)))
	edit := lsp.get(lsp.get_array(lsp.get(msg, "result"), "items")[0], "textEdit")
	testing.expect_value(t, lsp.get_path(edit, "range", "start", "character").(json.Integer), 3)
}

@(private = "file")
start_character :: proc(v: json.Value) -> int {
	return int(lsp.get_path(v, "range", "start", "character").(json.Integer) or_else -1)
}

@(test)
test_diagnostics_and_fixes :: proc(t: ^testing.T) {
	ss: Session
	session_start(&ss)
	defer session_end(&ss)
	uri := "file:///d.rst"
	open(&ss, uri, "Long title\n=====\n\nSee `missing`_ and *oops.\n")
	diags, ok := published(&ss, uri)
	testing.expect(t, ok)
	testing.expect_value(t, len(diags), 3)
	if len(diags) != 3 do return
	testing.expect_value(t, lsp.get_string(diags[0], "code"), "TITLE UNDERLINE TOO SHORT")
	first := lsp.get_string(diags[0], "message")
	testing.expect(t, strings.has_prefix(first, "Title underline too short."))
	testing.expect_value(t, lsp.get_int(diags[1], "severity"), 2)
	testing.expect_value(t, start_character(diags[1]), 19)
	testing.expect_value(t, lsp.get_string(diags[2], "message"), `Unknown target name: "missing".`)
	testing.expect_value(t, lsp.get_int(diags[2], "severity"), 1)
	testing.expect_value(t, start_character(diags[2]), 4)
	range := `"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":0}},` +
		`"context":{"diagnostics":[]}`
	msg := request(&ss, 5, "textDocument/codeAction", doc_params(uri, range))
	actions := lsp.get_array(msg, "result")
	testing.expect_value(t, len(actions), 1)
	if len(actions) != 1 do return
	edits := lsp.get_array(lsp.get_path(actions[0], "edit", "changes"), uri)
	testing.expect_value(t, lsp.get_string(edits[0], "newText"), "==========")
}

@(test)
test_pull_diagnostics :: proc(t: ^testing.T) {
	ss: Session
	session_start(&ss, `{"textDocument":{"diagnostic":{}}}`, `{"reportLevel":"info"}`)
	defer session_end(&ss)
	uri := "file:///p.rst"
	open(&ss, uri, "Title\n===\n")
	_, pushed := published(&ss, uri)
	testing.expect(t, !pushed)
	msg := request(&ss, 2, "textDocument/diagnostic", doc_params(uri))
	items := lsp.get_array(lsp.get(msg, "result"), "items")
	testing.expect_value(t, len(items), 1)
	if len(items) == 1 do testing.expect_value(t, lsp.get_int(items[0], "severity"), 3)
}

@(test)
test_known_elsewhere :: proc(t: ^testing.T) {
	c := lsp.DEFAULT_CONFIG
	defer lsp.config_destroy(&c)
	options := parse(`{"sphinx":true,"knownRoles":["Mine"],"reportLevel":"error","debounce":5}`)
	lsp.configure_from(&c, options)
	testing.expect_value(t, c.report_level, 3)
	testing.expect(t, lsp.known_elsewhere(&c, `Unknown interpreted text role "mine".`))
	testing.expect(t, lsp.known_elsewhere(&c, `Unknown interpreted text role "py:func".`))
	testing.expect(t, lsp.known_elsewhere(&c, `No directive entry for "toctree" in module "x".`))
	testing.expect(t, !lsp.known_elsewhere(&c, `Unknown directive type "other".`))
	testing.expect(t, !lsp.known_elsewhere(&c, `Unknown target name: "ref".`))
}
