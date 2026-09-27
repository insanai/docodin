package lsp_tests

// Tests of the protocol layer: framing, lifecycle, errors, cancellation,
// text synchronisation and position conversion.

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "core:testing"

import lsp ".."
import rst "../../rst"

// --- a client session over ``lsp.handle`` ----------------------------------------------

Session :: struct {
	server:    lsp.Server,
	out:       [dynamic]string, // messages sent by the server
	cancel:    string, // id of a cancelled request
	allocator: runtime.Allocator, // of ``out`` (the server runs on a scratch arena)
}

@(private = "file")
collect :: proc(data: rawptr, body: string) {
	ss := (^Session)(data)
	append(&ss.out, strings.clone(body, ss.allocator))
}

@(private = "file")
cancelled :: proc(data: rawptr, id: string) -> bool {
	return (^Session)(data).cancel == id
}

session_start :: proc(ss: ^Session, capabilities := `{}`, options := `{}`) {
	session_init(ss)
	ss.server.cancelled = cancelled
	ss.server.cancel_data = ss
	params := strings.concatenate(
		{`{"capabilities":`, capabilities, `,"initializationOptions":`, options, "}"},
		context.temp_allocator,
	)
	request(ss, 1, "initialize", params)
	notify(ss, "initialized", `{}`)
}

session_init :: proc(ss: ^Session) {
	ss.allocator = context.allocator
	ss.out = make([dynamic]string, ss.allocator)
	lsp.server_init(&ss.server, collect, ss)
}

session_end :: proc(ss: ^Session) {
	lsp.server_destroy(&ss.server)
	for m in ss.out do delete(m, ss.allocator)
	delete(ss.out)
}

notify :: proc(ss: ^Session, method, params: string) {
	body := strings.concatenate(
		{`{"jsonrpc":"2.0","method":"`, method, `","params":`, params, "}"},
		context.temp_allocator,
	)
	lsp.handle(&ss.server, body)
}

// Send a request; the response (parsed with the temporary allocator).
request :: proc(ss: ^Session, id: int, method, params: string) -> json.Value {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	strings.write_int(&b, id)
	strings.write_string(&b, `,"method":"`)
	strings.write_string(&b, method)
	strings.write_string(&b, `","params":`)
	strings.write_string(&b, params)
	strings.write_string(&b, "}")
	lsp.handle(&ss.server, strings.to_string(b))
	for i := len(ss.out) - 1; i >= 0; i -= 1 {
		msg := parse(ss.out[i])
		if lsp.get_int(msg, "id", -1) == id do return msg
	}
	return nil
}

parse :: proc(body: string) -> json.Value {
	v, err := json.parse_string(body, .JSON, true, context.temp_allocator)
	if err != nil do return nil
	return v
}

// ``{"textDocument": {"uri": ...}}`` with ``extra`` members.
doc_params :: proc(uri: string, extra := "") -> string {
	sep := "," if extra != "" else ""
	parts := []string{`{"textDocument":{"uri":"`, uri, `"}`, sep, extra, "}"}
	return strings.concatenate(parts, context.temp_allocator)
}

position :: proc(line, character: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `"position":{"line":`)
	strings.write_int(&b, line)
	strings.write_string(&b, `,"character":`)
	strings.write_int(&b, character)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

open :: proc(ss: ^Session, uri, text: string) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"textDocument":{"uri":"`)
	strings.write_string(&b, uri)
	strings.write_string(&b, `","languageId":"rst","version":1,"text":`)
	lsp.write_json_string(&b, text)
	strings.write_string(&b, "}}")
	notify(ss, "textDocument/didOpen", strings.to_string(b))
}

error_code :: proc(msg: json.Value) -> int {
	return lsp.get_int(lsp.get(msg, "error"), "code")
}

// The last published diagnostics of ``uri``.
published :: proc(ss: ^Session, uri: string) -> (json.Array, bool) {
	lsp.publish_due(&ss.server, true)
	for i := len(ss.out) - 1; i >= 0; i -= 1 {
		msg := parse(ss.out[i])
		if lsp.get_string(msg, "method") != "textDocument/publishDiagnostics" do continue
		params := lsp.get(msg, "params")
		if lsp.get_string(params, "uri") != uri do continue
		return lsp.get_array(params, "diagnostics"), true
	}
	return nil, false
}

// --- framing ---------------------------------------------------------------------------

@(private = "file")
Chunks :: struct {
	parts: []string,
	next:  int,
}

@(private = "file")
chunk_read :: proc(data: rawptr, buf: []byte) -> int {
	c := (^Chunks)(data)
	if c.next >= len(c.parts) do return 0
	n := copy(buf, c.parts[c.next])
	c.next += 1
	return n
}

@(test)
test_framing :: proc(t: ^testing.T) {
	// two frames split across reads, header names in any case, extra headers
	input := []string {
		"Content-Length: 2\r\n\r\n{}conTENT-length:  7\r",
		"\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n[1,",
		"2,3]",
	}
	c := Chunks{input, 0}
	r: lsp.Frame_Reader
	lsp.frame_reader_init(&r, chunk_read, &c)
	defer lsp.frame_reader_destroy(&r)
	body, ok := lsp.read_frame(&r, context.temp_allocator)
	testing.expect(t, ok && body == "{}")
	body, ok = lsp.read_frame(&r, context.temp_allocator)
	testing.expect_value(t, body, "[1,2,3]")
	_, ok = lsp.read_frame(&r, context.temp_allocator)
	testing.expect(t, !ok)
	testing.expect_value(t, lsp.frame("{}", context.temp_allocator), "Content-Length: 2\r\n\r\n{}")
}

@(test)
test_json_writer :: proc(t: ^testing.T) {
	w := lsp.json_writer(context.temp_allocator)
	lsp.obj_begin(&w)
	lsp.key_str(&w, "a", "q\"\\\n\x01é")
	lsp.key(&w, "b")
	lsp.arr_begin(&w)
	lsp.int_value(&w, 1)
	lsp.null_value(&w)
	lsp.obj_begin(&w)
	lsp.obj_end(&w)
	lsp.arr_end(&w)
	lsp.key_bool(&w, "c", true)
	lsp.obj_end(&w)
	testing.expect_value(t, lsp.json_text(&w), `{"a":"q\"\\\n\u0001é","b":[1,null,{}],"c":true}`)
}

// --- lifecycle -------------------------------------------------------------------------

@(test)
test_lifecycle :: proc(t: ^testing.T) {
	ss: Session
	session_init(&ss)
	defer session_end(&ss)
	testing.expect_value(t, error_code(request(&ss, 1, "shutdown", "null")), -32002)
	init := request(&ss, 2, "initialize", `{"capabilities":{}}`)
	caps := lsp.get_path(init, "result", "capabilities")
	testing.expect_value(t, lsp.get_string(caps, "positionEncoding"), "utf-16")
	testing.expect_value(t, lsp.get_int(lsp.get(caps, "textDocumentSync"), "change"), 2)
	testing.expect(t, lsp.get_bool(caps, "definitionProvider"))
	legend := lsp.get_path(caps, "semanticTokensProvider", "legend")
	testing.expect_value(t, len(lsp.get_array(legend, "tokenTypes")), 14)
	testing.expect(t, !lsp.has(caps, "diagnosticProvider"))
	again := request(&ss, 3, "initialize", `{"capabilities":{}}`)
	testing.expect_value(t, error_code(again), -32600)
	testing.expect_value(t, error_code(request(&ss, 4, "no/such", `{}`)), -32601)
	unknown := request(&ss, 5, "textDocument/hover", doc_params("file:///x.rst", position(0, 0)))
	testing.expect_value(t, error_code(unknown), -32602)
	shutdown := request(&ss, 6, "shutdown", "null")
	testing.expect(t, lsp.has(shutdown, "result"))
	testing.expect_value(t, error_code(request(&ss, 7, "textDocument/hover", `{}`)), -32600)
	notify(&ss, "exit", "null")
	testing.expect(t, ss.server.exit)
	testing.expect_value(t, ss.server.exit_code, 0)
}

@(test)
test_exit_without_shutdown :: proc(t: ^testing.T) {
	ss: Session
	session_start(&ss)
	defer session_end(&ss)
	notify(&ss, "exit", "null")
	testing.expect(t, ss.server.exit)
	testing.expect_value(t, ss.server.exit_code, 1)
}

@(test)
test_invalid_json_and_cancellation :: proc(t: ^testing.T) {
	ss: Session
	session_start(&ss)
	defer session_end(&ss)
	lsp.handle(&ss.server, "{not json")
	testing.expect_value(t, error_code(parse(ss.out[len(ss.out) - 1])), -32700)
	open(&ss, "file:///c.rst", "Text\n")
	ss.cancel = "9"
	msg := request(&ss, 9, "textDocument/documentSymbol", doc_params("file:///c.rst"))
	testing.expect_value(t, error_code(msg), -32800)
	msg = request(&ss, 10, "textDocument/documentSymbol", doc_params("file:///c.rst"))
	testing.expect(t, lsp.has(msg, "result"))
}

@(test)
test_utf8_negotiation :: proc(t: ^testing.T) {
	ss: Session
	session_start(&ss, `{"general":{"positionEncodings":["utf-8","utf-16"]}}`)
	defer session_end(&ss)
	testing.expect_value(t, ss.server.encoding, lsp.Encoding.UTF8)
}

// --- text synchronisation --------------------------------------------------------------

@(test)
test_incremental_changes :: proc(t: ^testing.T) {
	ss: Session
	session_start(&ss)
	defer session_end(&ss)
	uri := "file:///sync.rst"
	open(&ss, uri, "Héllo 😀 world\nsecond line\n")
	// UTF-16: the emoji is two code units; replace "world" (line 0, 9..14)
	changes := []string {
		`{"textDocument":{"uri":"file:///sync.rst","version":2},"contentChanges":[`,
		edit(0, 9, 0, 14, "there"), ",", edit(1, 0, 1, 6, "2nd"), ",",
		edit(2, 0, 2, 0, `third\n`), "]}",
	}
	change := strings.concatenate(changes, context.temp_allocator)
	notify(&ss, "textDocument/didChange", change)
	d := ss.server.docs[uri]
	testing.expect_value(t, d.text, "Héllo 😀 there\n2nd line\nthird\n")
	testing.expect_value(t, d.version, 2)
	full := `{"textDocument":{"uri":"file:///sync.rst","version":3},` +
		`"contentChanges":[{"text":"New\n"}]}`
	notify(&ss, "textDocument/didChange", full)
	testing.expect_value(t, ss.server.docs[uri].text, "New\n")
	notify(&ss, "textDocument/didClose", doc_params(uri))
	testing.expect(t, uri not_in ss.server.docs)
}

// A ``TextDocumentContentChangeEvent`` with a range.
@(private = "file")
edit :: proc(l0, c0, l1, c1: int, text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for part, i in ([?]int{l0, c0, l1, c1}) {
		strings.write_string(&b, EDIT_PARTS[i])
		strings.write_int(&b, part)
	}
	strings.write_string(&b, `}},"text":"`)
	strings.write_string(&b, text)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

@(private = "file")
EDIT_PARTS := [4]string {
	`{"range":{"start":{"line":`, `,"character":`, `},"end":{"line":`, `,"character":`,
}

@(test)
test_uri_to_path :: proc(t: ^testing.T) {
	path := lsp.uri_to_path("file:///home/me/My%20Docs/a%2Bb.rst", context.temp_allocator)
	testing.expect_value(t, path, "/home/me/My Docs/a+b.rst")
	windows := lsp.uri_to_path("file:///C:/x.rst", context.temp_allocator)
	testing.expect_value(t, windows, "C:/x.rst")
	testing.expect_value(t, lsp.uri_to_path("untitled:1", context.temp_allocator), "untitled:1")
}

// --- positions -------------------------------------------------------------------------

@(test)
test_positions :: proc(t: ^testing.T) {
	text := "a\tb😀c\r\nx\ry\n"
	utf16 := rst.line_index_make(text, .UTF16, context.temp_allocator)
	utf8 := rst.line_index_make(text, .UTF8, context.temp_allocator)
	c := i32(strings.index(text, "c"))
	testing.expect_value(t, lsp.to_lsp(&utf16, c), lsp.Lsp_Pos{0, 5})
	testing.expect_value(t, lsp.to_lsp(&utf8, c), lsp.Lsp_Pos{0, 7})
	testing.expect_value(t, lsp.from_lsp(&utf16, {0, 5}), c)
	testing.expect_value(t, lsp.from_lsp(&utf16, {1, 1}), 11)
	testing.expect_value(t, lsp.from_lsp(&utf16, {9, 0}), i32(len(text)))
	testing.expect_value(t, lsp.line_end(&utf16, 0), i32(8))
}

@(test)
test_spans_of_the_parse :: proc(t: ^testing.T) {
	text := "Title\n=====\n\nA `phrase\nreference`_ here.\n"
	idx := rst.line_index_make(text, .UTF16, context.temp_allocator)
	a := lsp.analyze(text, &idx, context.temp_allocator)
	ref := lsp.item_at(&a, i32(strings.index(text, "`phrase")) + 1)
	testing.expect(t, ref != lsp.NO_ITEM)
	if ref == lsp.NO_ITEM do return
	span := a.items[ref].span
	testing.expect_value(t, text[span.start:span.end], "`phrase\nreference`_")
	testing.expect_value(t, lsp.content_span(&a.tree, 2), lsp.Span{6, 11})
	testing.expect_value(t, lsp.last_nonblank(&a.tree, 3, 0), 2)
}
