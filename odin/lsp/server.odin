package lsp

// The language server: lifecycle, dispatch and the document requests.
//
// ``handle`` processes one JSON-RPC message; responses and notifications go
// to ``Server.send``.  ``run`` (main.odin) feeds it from standard input,
// with a reader thread for cancellation and a debounce of the diagnostics.
// Each message is handled in a scratch arena that is reset afterwards;
// documents live on the heap, their analyses in per-version arenas.

import "base:runtime"
import "core:encoding/json"
import "core:mem/virtual"
import "core:strings"
import "core:time"

VERSION :: "0.2.0"

// JSON-RPC and LSP error codes.
Error_Code :: enum int {
	Parse_Error            = -32700,
	Invalid_Request        = -32600,
	Method_Not_Found       = -32601,
	Invalid_Params         = -32602,
	Server_Not_Initialized = -32002,
	Request_Cancelled      = -32800,
}

State :: enum u8 {
	Uninitialized,
	Running,
	Shut_Down, // after ``shutdown``: only ``exit`` is accepted
}

Server :: struct {
	config:           Config,
	state:            State,
	encoding:         Encoding,
	pull_diagnostics: bool, // the client pulls diagnostics (else they are pushed)
	docs:             map[string]^Document,
	exit:             bool,
	exit_code:        int,
	// output: a complete JSON-RPC message
	send:             proc(data: rawptr, body: string),
	send_data:        rawptr,
	// whether the request with this id (JSON text) was cancelled
	cancelled:        proc(data: rawptr, id: string) -> bool,
	cancel_data:      rawptr,
	scratch:          virtual.Arena,
}

server_init :: proc(s: ^Server, send: proc(data: rawptr, body: string), send_data: rawptr) {
	s.config = DEFAULT_CONFIG
	s.send = send
	s.send_data = send_data
	s.docs = make(map[string]^Document)
	if virtual.arena_init_growing(&s.scratch) != nil do panic("docodin-lsp: cannot reserve arena")
}

server_destroy :: proc(s: ^Server) {
	for _, d in s.docs do document_destroy(d)
	delete(s.docs)
	config_destroy(&s.config)
	virtual.arena_destroy(&s.scratch)
}

// Handle one message (the body of a frame).
handle :: proc(s: ^Server, body: string) {
	scratch := virtual.arena_allocator(&s.scratch)
	defer virtual.arena_free_all(&s.scratch)
	context.temp_allocator = scratch
	msg, err := json.parse_string(body, .JSON, true, scratch)
	if err != nil {
		send_error(s, "null", .Parse_Error, "invalid JSON")
		return
	}
	method := get_string(msg, "method")
	id := id_text(get(msg, "id"), scratch)
	if method == "" do return // a response to a request of the server
	params := get(msg, "params")
	if id == "" {
		notification(s, method, params)
		return
	}
	if code, text, refused := refusal(s, method, id); refused {
		send_error(s, id, code, text)
		return
	}
	w := json_writer(scratch)
	context.allocator = scratch
	if code, text, ok := request(s, method, params, &w); !ok {
		send_error(s, id, code, text)
	} else {
		send_result(s, id, json_text(&w))
	}
}

// Why a request is not processed, if it is not.
@(private = "file")
refusal :: proc(
	s: ^Server,
	method, id: string,
) -> (
	code: Error_Code,
	text: string,
	refused: bool,
) {
	if s.cancelled != nil && s.cancelled(s.cancel_data, id) {
		return .Request_Cancelled, "request cancelled", true
	}
	switch s.state {
	case .Uninitialized:
		if method != "initialize" do return .Server_Not_Initialized, "server not initialized", true
	case .Running:
		if method == "initialize" do return .Invalid_Request, "server already initialized", true
	case .Shut_Down:
		return .Invalid_Request, "server is shut down", true
	}
	return
}

@(private = "file")
notification :: proc(s: ^Server, method: string, params: json.Value) {
	if method == "exit" {
		s.exit = true
		s.exit_code = 0 if s.state == .Shut_Down else 1
		return
	}
	if s.state != .Running do return
	switch method {
	case "textDocument/didOpen":
		did_open(s, params)
	case "textDocument/didChange":
		did_change(s, params)
	case "textDocument/didClose":
		did_close(s, params)
	case "workspace/didChangeConfiguration":
		configure(s, get_path(params, "settings", "docodin"))
	}
	// "initialized", "$/cancelRequest" (see ``run``), "textDocument/didSave",
	// "$/setTrace": nothing to do
}

// Write the result of a request into ``w``; ``ok`` false: an error.
@(private = "file")
request :: proc(
	s: ^Server,
	method: string,
	params: json.Value,
	w: ^Json_Writer,
) -> (
	code: Error_Code,
	text: string,
	ok: bool,
) {
	switch method {
	case "initialize":
		initialize(s, params, w)
		return .Invalid_Request, "", true
	case "shutdown":
		s.state = .Shut_Down
		null_value(w)
		return .Invalid_Request, "", true
	}
	h, known := document_request(method)
	if !known do return .Method_Not_Found, strings.concatenate({"unknown method: ", method}), false
	d := s.docs[get_path_string(params, "textDocument", "uri")]
	if d == nil do return .Invalid_Params, "unknown document", false
	h(s, d, params, w)
	return .Invalid_Request, "", true
}

@(private = "file")
get_path_string :: proc(v: json.Value, outer, inner: string) -> string {
	return get_string(get(v, outer), inner)
}

@(private = "file")
Document_Request :: proc(s: ^Server, d: ^Document, params: json.Value, w: ^Json_Writer)

@(private = "file")
document_request :: proc(method: string) -> (Document_Request, bool) {
	switch method {
	case "textDocument/documentSymbol":
		return proc(s: ^Server, d: ^Document, _: json.Value, w: ^Json_Writer) {
			document_symbols(w, snapshot(d), s.encoding)
		}, true
	case "textDocument/foldingRange":
		return proc(_: ^Server, d: ^Document, _: json.Value, w: ^Json_Writer) {
			folding_ranges(w, snapshot(d))
		}, true
	case "textDocument/semanticTokens/full":
		return semantic_tokens, true
	case "textDocument/definition":
		return proc(s: ^Server, d: ^Document, params: json.Value, w: ^Json_Writer) {
			snap := snapshot(d)
			definition(w, snap, d.uri, request_pos(snap, params, s.encoding), s.encoding)
		}, true
	case "textDocument/references":
		return proc(s: ^Server, d: ^Document, params: json.Value, w: ^Json_Writer) {
			snap := snapshot(d)
			decl := get_bool(get(params, "context"), "includeDeclaration")
			p := request_pos(snap, params, s.encoding)
			references(w, snap, d.uri, p, decl, s.encoding)
		}, true
	case "textDocument/hover":
		return proc(s: ^Server, d: ^Document, params: json.Value, w: ^Json_Writer) {
			snap := snapshot(d)
			hover(w, snap, request_pos(snap, params, s.encoding), s.encoding)
		}, true
	case "textDocument/completion":
		return proc(s: ^Server, d: ^Document, params: json.Value, w: ^Json_Writer) {
			snap := snapshot(d)
			completion(w, snap, request_pos(snap, params, s.encoding), s.encoding)
		}, true
	case "textDocument/codeAction":
		return proc(s: ^Server, d: ^Document, params: json.Value, w: ^Json_Writer) {
			code_actions(w, snapshot(d), d.uri, params, &s.config, s.encoding)
		}, true
	case "textDocument/diagnostic":
		return pull_diagnostics, true
	}
	return nil, false
}

@(private = "file")
semantic_tokens :: proc(s: ^Server, d: ^Document, _: json.Value, w: ^Json_Writer) {
	snap := snapshot(d)
	obj_begin(w)
	key(w, "data")
	encode_tokens(w, &snap.ix, sorted_tokens(&snap.analysis), s.encoding)
	obj_end(w)
}

@(private = "file")
pull_diagnostics :: proc(s: ^Server, d: ^Document, _: json.Value, w: ^Json_Writer) {
	snap := snapshot(d)
	obj_begin(w)
	key_str(w, "kind", "full")
	key(w, "items")
	write_diagnostics(w, &snap.ix, snapshot_diagnostics(snap, &s.config), s.encoding)
	obj_end(w)
}

// --- lifecycle -------------------------------------------------------------------------

@(private = "file")
initialize :: proc(s: ^Server, params: json.Value, w: ^Json_Writer) {
	caps := get(params, "capabilities")
	s.encoding = .Utf16
	for e in get_array(get(caps, "general"), "positionEncodings") {
		if name, _ := e.(json.String); name == "utf-8" do s.encoding = .Utf8
	}
	s.pull_diagnostics = has(get(caps, "textDocument"), "diagnostic")
	configure(s, get(params, "initializationOptions"))
	s.state = .Running
	obj_begin(w)
	key(w, "capabilities")
	write_capabilities(s, w)
	key(w, "serverInfo")
	obj_begin(w)
	key_str(w, "name", "docodin-lsp")
	key_str(w, "version", VERSION)
	obj_end(w)
	obj_end(w)
}

@(private = "file")
write_capabilities :: proc(s: ^Server, w: ^Json_Writer) {
	obj_begin(w)
	key_str(w, "positionEncoding", "utf-8" if s.encoding == .Utf8 else "utf-16")
	key(w, "textDocumentSync")
	obj_begin(w)
	key_bool(w, "openClose", true)
	key_int(w, "change", 2) // incremental
	obj_end(w)
	key_bool(w, "documentSymbolProvider", true)
	key_bool(w, "foldingRangeProvider", true)
	key_bool(w, "definitionProvider", true)
	key_bool(w, "referencesProvider", true)
	key_bool(w, "hoverProvider", true)
	key(w, "semanticTokensProvider")
	obj_begin(w)
	key(w, "legend")
	write_legend(w)
	key_bool(w, "full", true)
	obj_end(w)
	key(w, "completionProvider")
	obj_begin(w)
	key(w, "triggerCharacters")
	raw_value(w, `[".", ":", "|", "` + "`" + `", "["]`)
	obj_end(w)
	key(w, "codeActionProvider")
	obj_begin(w)
	key(w, "codeActionKinds")
	raw_value(w, `["quickfix"]`)
	obj_end(w)
	if s.pull_diagnostics {
		key(w, "diagnosticProvider")
		obj_begin(w)
		key_bool(w, "interFileDependencies", false)
		key_bool(w, "workspaceDiagnostics", false)
		obj_end(w)
	}
	obj_end(w)
}

// Settings from ``initializationOptions`` or ``didChangeConfiguration``
// (see config.odin); the diagnostics are computed again.
@(private = "file")
configure :: proc(s: ^Server, options: json.Value) {
	configure_from(&s.config, options)
	for _, d in s.docs {
		if d.snapshot != nil do d.snapshot.diagnosed = false
		schedule(s, d, 0)
	}
}

// --- text synchronisation --------------------------------------------------------------

@(private = "file")
did_open :: proc(s: ^Server, params: json.Value) {
	td := get(params, "textDocument")
	uri := get_string(td, "uri")
	if old, ok := s.docs[uri]; ok {
		delete_key(&s.docs, uri)
		document_destroy(old)
	}
	d := document_make(uri, get_int(td, "version"), get_string(td, "text"))
	s.docs[d.uri] = d
	schedule(s, d, 0)
}

@(private = "file")
did_change :: proc(s: ^Server, params: json.Value) {
	td := get(params, "textDocument")
	d := s.docs[get_string(td, "uri")]
	if d == nil do return
	apply_changes(d, get_array(params, "contentChanges"), s.encoding)
	d.version = get_int(td, "version", d.version)
	schedule(s, d, s.config.debounce)
}

@(private = "file")
did_close :: proc(s: ^Server, params: json.Value) {
	uri := get_path_string(params, "textDocument", "uri")
	d, ok := s.docs[uri]
	if !ok do return
	delete_key(&s.docs, uri)
	if !s.pull_diagnostics do send_diagnostics(s, d.uri, -1, nil, nil)
	document_destroy(d)
}

// Push the document's diagnostics after ``delay``.
@(private = "file")
schedule :: proc(s: ^Server, d: ^Document, delay: time.Duration) {
	if s.pull_diagnostics do return
	d.dirty = true
	d.publish_at = time.tick_add(time.tick_now(), delay)
}

// The time until the next pushed diagnostics are due (``ok`` false: none).
next_deadline :: proc(s: ^Server) -> (wait: time.Duration, ok: bool) {
	now := time.tick_now()
	for _, d in s.docs {
		if !d.dirty do continue
		left := max(time.tick_diff(now, d.publish_at), 0)
		if !ok || left < wait do wait = left
		ok = true
	}
	return
}

// Push the diagnostics that are due (all of them with ``force``).
publish_due :: proc(s: ^Server, force := false) {
	now := time.tick_now()
	for _, d in s.docs {
		if !d.dirty || (!force && time.tick_diff(now, d.publish_at) > 0) do continue
		d.dirty = false
		snap := snapshot(d)
		diags := snapshot_diagnostics(snap, &s.config)
		send_diagnostics(s, d.uri, d.version, &snap.ix, diags)
	}
}

@(private = "file")
send_diagnostics :: proc(
	s: ^Server,
	uri: string,
	version: int,
	ix: ^Line_Index,
	diags: []Diagnostic,
) {
	// not the scratch arena: this runs while a message is handled, too
	w := json_writer(runtime.heap_allocator())
	defer strings.builder_destroy(&w.b)
	obj_begin(&w)
	key_str(&w, "jsonrpc", "2.0")
	key_str(&w, "method", "textDocument/publishDiagnostics")
	key(&w, "params")
	obj_begin(&w)
	key_str(&w, "uri", uri)
	if version >= 0 do key_int(&w, "version", version)
	key(&w, "diagnostics")
	if ix == nil {
		raw_value(&w, "[]")
	} else {
		write_diagnostics(&w, ix, diags, s.encoding)
	}
	obj_end(&w)
	obj_end(&w)
	s.send(s.send_data, json_text(&w))
}

// --- responses -------------------------------------------------------------------------

@(private = "file")
send_result :: proc(s: ^Server, id, result: string) {
	body := strings.concatenate({`{"jsonrpc":"2.0","id":`, id, `,"result":`, result, "}"})
	s.send(s.send_data, body)
}

@(private = "file")
send_error :: proc(s: ^Server, id: string, code: Error_Code, message: string) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	strings.write_string(&b, id)
	strings.write_string(&b, `,"error":{"code":`)
	strings.write_int(&b, int(code))
	strings.write_string(&b, `,"message":`)
	write_json_string(&b, message)
	strings.write_string(&b, "}}")
	s.send(s.send_data, strings.to_string(b))
}
