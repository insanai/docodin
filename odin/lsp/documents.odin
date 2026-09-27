package lsp

// Open documents and their snapshots.
//
// A document keeps its text (edited in place by ``didChange``); its
// snapshot is the analysis of one version, built on first use in an arena
// of its own and freed as a whole when the text changes.

import "base:runtime"
import "core:encoding/json"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "core:time"

import rst "../rst"

TAB_WIDTH :: 8

Document :: struct {
	uri:        string,
	path:       string, // the source path of messages and includes
	version:    int,
	text:       string,
	snapshot:   ^Snapshot, // nil until needed after a change
	// diagnostics are due at ``publish_at`` (pushed diagnostics)
	dirty:      bool,
	publish_at: time.Tick,
}

Snapshot :: struct {
	arena:       virtual.Arena,
	allocator:   runtime.Allocator,
	version:     int,
	path:        string,
	text:        string,
	idx:         rst.Line_Index, // LSP positions (the server's encoding)
	reading:     Reading, // docutils' messages
	analysis:    Analysis,
	diagnostics: [dynamic]Diagnostic,
	diagnosed:   bool,
}

// Documents and their texts are on the heap: requests run with a scratch
// arena as the context allocator.
document_make :: proc(uri: string, version: int, text: string) -> ^Document {
	heap := runtime.heap_allocator()
	d := new(Document, heap)
	d.uri = strings.clone(uri, heap)
	d.path = uri_to_path(uri, heap)
	d.version = version
	d.text = strings.clone(text, heap)
	return d
}

document_destroy :: proc(d: ^Document) {
	heap := runtime.heap_allocator()
	snapshot_destroy(d.snapshot)
	delete(d.uri, heap)
	delete(d.path, heap)
	delete(d.text, heap)
	free(d, heap)
}

// The snapshot of the document's current text (positions in ``enc``).
snapshot :: proc(d: ^Document, enc: Encoding) -> ^Snapshot {
	if d.snapshot != nil do return d.snapshot
	s := new(Snapshot, runtime.heap_allocator())
	if virtual.arena_init_growing(&s.arena) != nil do panic("docodin-lsp: cannot reserve arena")
	s.allocator = virtual.arena_allocator(&s.arena)
	s.version = d.version
	s.path = strings.clone(d.path, s.allocator)
	s.text = strings.clone(d.text, s.allocator)
	s.idx = rst.line_index_make(s.text, enc, s.allocator)
	// one parse: the reader's tree is analysed
	s.reading = read_with_docutils(s.text, s.path, s.allocator)
	s.analysis = analyze(s.text, &s.idx, s.allocator, s.reading.tree)
	d.snapshot = s
	return s
}

// The diagnostics of a snapshot (computed once).
snapshot_diagnostics :: proc(s: ^Snapshot, cfg: ^Config) -> []Diagnostic {
	if !s.diagnosed {
		s.diagnostics = build_diagnostics(s, cfg)
		s.diagnosed = true
	}
	return s.diagnostics[:]
}

snapshot_destroy :: proc(s: ^Snapshot) {
	if s == nil do return
	virtual.arena_destroy(&s.arena)
	free(s, runtime.heap_allocator())
}

// Replace the text (allocated on the heap); the snapshot is dropped.
set_text :: proc(d: ^Document, text: string) {
	old := d.text
	d.text = text
	delete(old, runtime.heap_allocator())
	snapshot_destroy(d.snapshot)
	d.snapshot = nil
}

// Apply the ``contentChanges`` of ``didChange`` in order: a change with a
// range replaces that range, one without replaces the whole text.
apply_changes :: proc(d: ^Document, changes: json.Array, enc: Encoding) {
	for change in changes {
		text := get_string(change, "text")
		if !has(change, "range") {
			set_text(d, strings.clone(text, runtime.heap_allocator()))
			continue
		}
		idx := rst.line_index_make(d.text, enc, context.temp_allocator)
		r := get(change, "range")
		a := int(from_lsp(&idx, lsp_pos(get(r, "start"))))
		b := int(from_lsp(&idx, lsp_pos(get(r, "end"))))
		if b < a do a, b = b, a
		set_text(d, strings.concatenate({d.text[:a], text, d.text[b:]}, runtime.heap_allocator()))
	}
}

lsp_pos :: proc(v: json.Value) -> Lsp_Pos {
	return {get_int(v, "line"), get_int(v, "character")}
}

// The file path of a ``file:`` URI (percent-decoded); other URIs are used
// as they are.
uri_to_path :: proc(uri: string, allocator := context.allocator) -> string {
	if !strings.has_prefix(uri, "file://") do return strings.clone(uri, allocator)
	rest := uri[len("file://"):]
	// file:///C:/x on Windows
	if len(rest) >= 3 && rest[0] == '/' && rest[2] == ':' do rest = rest[1:]
	b := strings.builder_make(0, len(rest), allocator)
	for i := 0; i < len(rest); i += 1 {
		if rest[i] == '%' && i + 2 < len(rest) {
			if v, ok := strconv.parse_int(rest[i + 1:i + 3], 16); ok {
				strings.write_byte(&b, u8(v))
				i += 2
				continue
			}
		}
		strings.write_byte(&b, rest[i])
	}
	return strings.to_string(b)
}
