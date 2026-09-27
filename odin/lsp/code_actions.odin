package lsp

// Diagnostics on the wire, and their quick fixes as code actions.
//
// Fixes are computed with the diagnostics of the snapshot; a
// ``codeAction`` request answers with the fixes of the snapshot's
// diagnostics that overlap its range.  Each diagnostic also carries its
// fix's title in ``data`` (as ruff carries its fixes), so clients that
// resolve actions by diagnostic can tell which have one, and docutils'
// level and line of the message.

import "core:encoding/json"

write_diagnostic :: proc(w: ^Json_Writer, ix: ^Line_Index, d: Diagnostic, enc: Encoding) {
	obj_begin(w)
	key(w, "range")
	write_range(w, ix, d.span, enc)
	key_int(w, "severity", severity(d.level))
	if d.code != "" do key_str(w, "code", d.code)
	key_str(w, "source", "docutils")
	key_str(w, "message", d.message)
	// docutils' own report: its level and line (the range can be more precise)
	key(w, "data")
	obj_begin(w)
	key_int(w, "level", d.level)
	key_int(w, "line", d.line)
	if d.fix.kind != .None do key_str(w, "fix", d.fix.title)
	obj_end(w)
	obj_end(w)
}

write_diagnostics :: proc(w: ^Json_Writer, ix: ^Line_Index, diags: []Diagnostic, enc: Encoding) {
	arr_begin(w)
	for d in diags do write_diagnostic(w, ix, d, enc)
	arr_end(w)
}

// ``textDocument/codeAction``: the quick fixes of the diagnostics in the
// requested range.
code_actions :: proc(
	w: ^Json_Writer,
	s: ^Snapshot,
	uri: string,
	params: json.Value,
	cfg: ^Config,
	enc: Encoding,
) {
	r := get(params, "range")
	first := from_lsp(&s.ix, lsp_pos(get(r, "start")), enc)
	last := from_lsp(&s.ix, lsp_pos(get(r, "end")), enc)
	only := get_array(get(params, "context"), "only")
	arr_begin(w)
	if wants_quickfix(only) {
		for d in snapshot_diagnostics(s, cfg) {
			if d.fix.kind == .None || pos_less(d.span.end, first) || pos_less(last, d.span.start) {
				continue
			}
			write_action(w, s, uri, d, enc)
		}
	}
	arr_end(w)
}

@(private = "file")
wants_quickfix :: proc(only: json.Array) -> bool {
	if len(only) == 0 do return true
	for kind in only {
		k, _ := kind.(json.String)
		if k == "quickfix" do return true
	}
	return false
}

@(private = "file")
write_action :: proc(w: ^Json_Writer, s: ^Snapshot, uri: string, d: Diagnostic, enc: Encoding) {
	obj_begin(w)
	key_str(w, "title", d.fix.title)
	key_str(w, "kind", "quickfix")
	key_bool(w, "isPreferred", true)
	key(w, "diagnostics")
	arr_begin(w)
	write_diagnostic(w, &s.ix, d, enc)
	arr_end(w)
	key(w, "edit")
	obj_begin(w)
	key(w, "changes")
	obj_begin(w)
	key(w, uri)
	arr_begin(w)
	edits := d.fix.edits
	for e in edits[:d.fix.count] {
		obj_begin(w)
		key(w, "range")
		write_range(w, &s.ix, e.span, enc)
		key_str(w, "newText", e.text)
		obj_end(w)
	}
	arr_end(w)
	obj_end(w)
	obj_end(w)
	obj_end(w)
}
