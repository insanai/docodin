package doctree

import "base:runtime"
import "core:encoding/json"
import "core:mem/virtual"
import "core:reflect"
import "core:slice"
import "core:strings"

// ``dump_json``: the interchange JSON of a ``Doc`` (see json.odin), as
// Python's ``json.dumps(dump, sort_keys=True, indent=1, ensure_ascii=False)``
// writes it, plus a newline.  A document loaded with ``load_json`` dumps
// byte-identically to its dump.
//
// Nodes outside the document tree are numbered in the order of their first
// reference, as scripts/doctree_json.py does: the tree records (in
// preorder; per node its ``internal`` maps, then ``pending`` details by
// key), the registry (``ids``, ``substitution_defs``, ``decoration``, the
// name -> nodes maps, then the node lists), the transformer queue, the
// written messages, then the detached records in turn (a record's parent
// first).  A node is numbered with its subtree, after its parent.

@(private = "file")
Dumper :: struct {
	doc:      ^Doc,
	a:        runtime.Allocator, // scratch
	index:    []i32, // record index of each node, -1: not numbered
	count:    int,
	detached: [dynamic]Node,
}

// The JSON dump of ``doc``.  ``stage``, ``input``, ``settings`` and
// ``expected`` are those loaded by ``load_json``; for another document the
// stage and input are empty, the settings are the fields of ``Settings``
// and ``expected`` holds the ``pformat`` of the document.
dump_json :: proc(doc: ^Doc, allocator := context.allocator) -> string {
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do panic("doctree: cannot reserve arena")
	defer virtual.arena_destroy(&scratch)
	a := virtual.arena_allocator(&scratch)
	context.temp_allocator = a
	d := Dumper {
		doc      = doc,
		a        = a,
		index    = make([]i32, len(doc.nodes), a),
		detached = make([dynamic]Node, a),
	}
	slice.fill(d.index, -1)
	number(&d, doc.root)
	ic := &doc.interchange
	out := make(json.Object, 16, a)
	out["format"] = json.String(INTERCHANGE_FORMAT)
	out["stage"] = json.String(ic.stage)
	out["input"] = ic.input if ic.input != nil else make(json.Object, 0, a)
	out["tree"] = record(&d, doc.root)
	out["registry"] = dump_registry(&d)
	out["transformer"] = dump_transformer(&d)
	out["reporter"] = dump_reporter(&d)
	out["settings"] = ic.settings if ic.settings != nil else settings_value(&d)
	out["expected"] = ic.expected if ic.expected != nil else expected_value(&d)
	out["detached"] = dump_detached(&d)
	b := strings.builder_make(a)
	write_json(&b, out, 0)
	strings.write_byte(&b, '\n')
	return strings.clone(strings.to_string(b), allocator)
}

// --- numbering -------------------------------------------------------------------

@(private = "file")
number :: proc(d: ^Dumper, n: Node) {
	d.index[n] = i32(d.count)
	d.count += 1
	for c := d.doc.nodes[n].first; c != 0; c = d.doc.nodes[c].next do number(d, c)
}

// The record index of ``n`` (null for 0); a node outside the numbered trees
// becomes, with its subtree, a detached record.
@(private = "file")
ref :: proc(d: ^Dumper, n: Node) -> json.Value {
	if n == 0 do return json.Null{}
	if d.index[n] < 0 {
		if p := d.doc.nodes[n].parent; p != 0 do ref(d, p)
		if d.index[n] < 0 {
			number(d, n)
			append(&d.detached, n)
		}
	}
	return json.Integer(d.index[n])
}

@(private = "file")
refs :: proc(d: ^Dumper, nodes: []Node) -> json.Value {
	out := make(json.Array, 0, len(nodes), d.a)
	for n in nodes do append(&out, ref(d, n))
	return out
}

@(private = "file")
dump_detached :: proc(d: ^Dumper) -> json.Value {
	out := make(json.Array, 0, len(d.detached), d.a)
	for i := 0; i < len(d.detached); i += 1 { 	// records may add detached nodes
		n := d.detached[i]
		rec := make(json.Object, 2, d.a)
		rec["parent"] = ref(d, d.doc.nodes[n].parent)
		rec["node"] = record(d, n)
		append(&out, rec)
	}
	return out
}

// --- node records ------------------------------------------------------------------

@(private = "file")
record :: proc(d: ^Dumper, n: Node) -> json.Value {
	doc := d.doc
	e := doc.nodes[n]
	out := make(json.Object, 8, d.a)
	out["tag"] = json.String(TAG_NAMES[e.tag])
	if .Has_Source in e.flags do out["source"] = json.String(doc.strings[e.source])
	if .Has_Line in e.flags do out["line"] = json.Integer(e.line)
	if .Has_Document in e.flags do out["document"] = true
	if e.tag == .Text {
		out["text"] = json.String(e.text)
		return out
	}
	element_record(d, n, &out)
	if e.first != 0 {
		children := make(json.Array, 0, 4, d.a)
		for c := e.first; c != 0; c = doc.nodes[c].next do append(&children, record(d, c))
		out["children"] = children
	}
	return out
}

@(private = "file")
element_record :: proc(d: ^Dumper, n: Node, out: ^json.Object) {
	doc := d.doc
	e := doc.nodes[n]
	if e.text != "" do out["rawsource"] = json.String(e.text)
	if attrs := attribute_values(d, n); len(attrs) > 0 do out["attributes"] = attrs
	deleted := make(json.Array, 0, 0, d.a)
	for b in Basic_List {
		if b in TAG_LIST_ATTRS[e.tag] && b in e.deleted {
			append(&deleted, json.String(str(doc, basic_key(b))))
		}
	}
	if len(deleted) > 0 do out["deleted"] = deleted
	if .Referenced in e.flags do out["referenced"] = true
	if .Resolved in e.flags do out["resolved"] = true
	if internal, ok := internals_value(d, n); ok do out["internal"] = internal
	if e.tag == .pending {
		p := pending_of(doc, n)
		pending := make(json.Object, 3, d.a)
		pending["transform"] = json.String(p.transform)
		pending["default_priority"] = json.Integer(p.default_priority)
		pending["details"] = details_value(d, p.details[:])
		out["pending"] = pending
	}
}

// The attributes, without the class's list attributes that are empty.
@(private = "file")
attribute_values :: proc(d: ^Dumper, n: Node) -> json.Object {
	doc := d.doc
	listed := TAG_LIST_ATTRS[doc.nodes[n].tag]
	out := make(json.Object, 8, d.a)
	for item in attributes(doc, n, d.a) {
		l, is_list := item.value.(List)
		k, _ := lookup(doc, item.key)
		b, basic := basic_of(k)
		if is_list && basic && b in listed && len(doc.lists[l]) == 0 do continue
		out[item.key] = attr_json(d, item.value)
	}
	return out
}

@(private = "file")
attr_json :: proc(d: ^Dumper, v: Attr_Value) -> json.Value {
	switch x in v {
	case string:
		return json.String(x)
	case int:
		return json.Integer(x)
	case bool:
		return json.Boolean(x)
	case List:
		items := make(json.Array, 0, len(d.doc.lists[x]), d.a)
		for s in d.doc.lists[x] do append(&items, json.String(str(d.doc, s)))
		return items
	case Attr_None:
		return json.Null{}
	}
	return json.Null{}
}

@(private = "file")
internals_value :: proc(d: ^Dumper, n: Node) -> (json.Value, bool) {
	ni, ok := d.doc.internals[n]
	if !ok do return nil, false
	out := make(json.Object, 4, d.a)
	if indent, has := ni.indent.?; has do out["indent"] = json.Integer(indent)
	if name, has := ni.indirect_reference_name.?; has {
		out["indirect_reference_name"] = json.String(name)
	}
	if len(ni.expect_referenced_by_id) > 0 {
		out["expect_referenced_by_id"] = name_refs_value(d, ni.expect_referenced_by_id[:])
	}
	if len(ni.expect_referenced_by_name) > 0 {
		out["expect_referenced_by_name"] = name_refs_value(d, ni.expect_referenced_by_name[:])
	}
	return out, len(out) > 0
}

@(private = "file")
name_refs_value :: proc(d: ^Dumper, list: []Name_Ref) -> json.Value {
	out := make(json.Array, 0, len(list), d.a)
	for r in list do append(&out, pair_value(d, json.String(str(d.doc, r.name)), ref(d, r.node)))
	return out
}

@(private = "file")
pair_value :: proc(d: ^Dumper, a, b: json.Value) -> json.Value {
	out := make(json.Array, 2, d.a)
	out[0], out[1] = a, b
	return out
}

// ``pending.details`` or transform kwargs; nodes are referenced by key order.
@(private = "file")
details_value :: proc(d: ^Dumper, details: []Detail) -> json.Value {
	sorted := slice.clone(details, d.a)
	slice.sort_by(sorted, proc(a, b: Detail) -> bool {return a.key < b.key})
	out := make(json.Object, len(details), d.a)
	for detail in sorted do out[detail.key] = detail_json(d, detail.value)
	return out
}

@(private = "file")
detail_json :: proc(d: ^Dumper, v: Detail_Value) -> json.Value {
	switch x in v {
	case string:
		return json.String(x)
	case int:
		return json.Integer(x)
	case bool:
		return json.Boolean(x)
	case Node:
		out := make(json.Object, 1, d.a)
		out["node"] = ref(d, x)
		return out
	case []Node:
		out := make(json.Object, 1, d.a)
		out["nodes"] = refs(d, x)
		return out
	case []string:
		items := make(json.Array, 0, len(x), d.a)
		for s in x do append(&items, json.String(s))
		return items
	case Detail_None:
		return json.Null{}
	}
	return json.Null{}
}

// --- document state ----------------------------------------------------------------

@(private = "file")
node_pairs :: proc(d: ^Dumper, m: ^Ordered_Map(Node)) -> json.Value {
	out := make(json.Array, 0, len(m.keys), d.a)
	for k, i in m.keys {
		if k == TOMBSTONE do continue
		append(&out, pair_value(d, json.String(str(d.doc, k)), ref(d, m.values[i])))
	}
	return out
}

@(private = "file")
str_pairs :: proc(d: ^Dumper, m: ^Ordered_Map(Str)) -> json.Value {
	out := make(json.Array, 0, len(m.keys), d.a)
	for k, i in m.keys {
		if k == TOMBSTONE do continue
		v: json.Value = json.Null{} if m.values[i] == 0 else json.String(str(d.doc, m.values[i]))
		append(&out, pair_value(d, json.String(str(d.doc, k)), v))
	}
	return out
}

@(private = "file")
scalar_pairs :: proc(d: ^Dumper, keys: []Str, values: []$T) -> json.Value {
	out := make(json.Array, 0, len(keys), d.a)
	for k, i in keys {
		if k != TOMBSTONE do append(&out, pair_value(d, json.String(str(d.doc, k)), values[i]))
	}
	return out
}

@(private = "file")
dump_registry :: proc(d: ^Dumper) -> json.Value {
	doc := d.doc
	out := make(json.Object, 32, d.a)
	out["ids"] = node_pairs(d, &doc.ids)
	out["nameids"] = str_pairs(d, &doc.nameids)
	nametypes := make([]json.Value, len(doc.nametypes.values), d.a)
	for v, i in doc.nametypes.values do nametypes[i] = json.Boolean(v)
	out["nametypes"] = scalar_pairs(d, doc.nametypes.keys[:], nametypes)
	out["substitution_defs"] = node_pairs(d, &doc.substitution_defs)
	out["substitution_names"] = str_pairs(d, &doc.substitution_names)
	counters := make([]json.Value, len(doc.id_counter.values), d.a)
	for v, i in doc.id_counter.values do counters[i] = json.Integer(v)
	out["id_counter"] = scalar_pairs(d, doc.id_counter.keys[:], counters)
	out["autofootnote_start"] = json.Integer(doc.autofootnote_start)
	out["symbol_footnote_start"] = json.Integer(doc.symbol_footnote_start)
	out["decoration"] = ref(d, doc.decoration)
	source, has_source := doc.current_source.?
	out["current_source"] = json.String(source) if has_source else json.Null{}
	line, has_line := doc.current_line.?
	out["current_line"] = json.Integer(line) if has_line else json.Null{}
	rl := registry_lists(doc)
	for e in rl.maps {
		list := make(json.Array, 0, len(e.m.keys), d.a)
		for k, i in e.m.keys {
			if k == TOMBSTONE do continue
			append(&list, pair_value(d, json.String(str(doc, k)), refs(d, e.m.values[i][:])))
		}
		out[e.name] = list
	}
	for e in rl.lists do out[e.name] = refs(d, e.list[:])
	return out
}

@(private = "file")
Queue_Entry :: struct {
	key: string, // the priority string
	q:   ^Queued_Pending,
}

@(private = "file")
dump_transformer :: proc(d: ^Dumper) -> json.Value {
	entries := make([]Queue_Entry, len(d.doc.pending_queue), d.a)
	for &q, i in d.doc.pending_queue {
		entries[i] = {priority_string(q.priority, q.serial, d.a), &q}
	}
	slice.sort_by(entries, proc(a, b: Queue_Entry) -> bool {return a.key < b.key})
	queue := make(json.Array, 0, len(entries), d.a)
	for e in entries {
		item := make(json.Array, 4, d.a)
		item[0] = json.String(e.key)
		item[1] = json.String(e.q.transform)
		item[2] = ref(d, e.q.node)
		item[3] = details_value(d, e.q.kwargs[:])
		append(&queue, item)
	}
	out := make(json.Object, 2, d.a)
	out["queue"] = queue
	out["serialno"] = json.Integer(d.doc.transform_serial)
	return out
}

// ``'%03d-%03d' % (priority, serial)``.
@(private = "file")
priority_string :: proc(priority, serial: int, a: runtime.Allocator) -> string {
	b := strings.builder_make(a)
	for p, i in ([2]int{priority, serial}) {
		if i > 0 do strings.write_byte(&b, '-')
		if p < 0 do strings.write_byte(&b, '-')
		width := 2 if p < 0 else 3 // ``%03d`` counts the sign in the width
		digits := strings.builder_make(a)
		write_int(&digits, abs(p))
		for _ in strings.builder_len(digits) ..< width do strings.write_byte(&b, '0')
		strings.write_string(&b, strings.to_string(digits))
	}
	return strings.to_string(b)
}

@(private = "file")
dump_reporter :: proc(d: ^Dumper) -> json.Value {
	r := &d.doc.reporter
	out := make(json.Object, 8, d.a)
	out["source"] = json.String(r.source)
	out["report_level"] = json.Integer(r.report_level)
	out["halt_level"] = json.Integer(r.halt_level)
	out["debug"] = json.Boolean(r.debug_flag)
	out["max_level"] = json.Integer(r.max_level)
	observers := make(json.Array, 0, len(r.observers), d.a)
	for o in r.observers {
		name := "note_parse_message" if o == observe_parse_message else "note_transform_message"
		append(&observers, json.String(name))
	}
	out["observers"] = observers
	out["source_lines"] = source_lines_value(d)
	written := make(json.Array, 0, len(r.written), d.a)
	for w in r.written {
		if w.node == 0 do continue // written by another reporter (a nested parse)
		msg := make(json.Object, 3, d.a)
		msg["level"] = json.Integer(w.level)
		msg["node"] = ref(d, w.node)
		msg["text"] = json.String(w.text)
		append(&written, msg)
	}
	out["written"] = written
	return out
}

@(private = "file")
source_lines_value :: proc(d: ^Dumper) -> json.Value {
	r := &d.doc.reporter
	if r.source_and_line != interchange_source_line do return json.Null{}
	m := (^Source_Lines)(r.source_line_data)
	runs := make(json.Array, 0, len(m.runs), d.a)
	for run in m.runs {
		item := make(json.Array, 3, d.a)
		src, has_src := run.source.?
		item[0] = json.String(src) if has_src else json.Null{}
		item[1] = json.Integer(run.offset)
		item[2] = json.Integer(run.count)
		append(&runs, item)
	}
	out := make(json.Object, 3, d.a)
	out["input_offset"] = json.Integer(m.input_offset)
	out["line_offset"] = json.Integer(m.line_offset)
	out["runs"] = runs
	return out
}

// The fields of ``Settings`` (enumerations left out).
@(private = "file")
settings_value :: proc(d: ^Dumper) -> json.Value {
	out := make(json.Object, 128, d.a)
	s := d.doc.settings
	for f in reflect.struct_fields_zipped(Settings) {
		ptr := rawptr(uintptr(&s) + f.offset)
		switch f.type.id {
		case int:
			out[f.name] = json.Integer((^int)(ptr)^)
		case bool:
			out[f.name] = json.Boolean((^bool)(ptr)^)
		case string:
			out[f.name] = json.String((^string)(ptr)^)
		case []string:
			items := make(json.Array, 0, len((^[]string)(ptr)^), d.a)
			for x in (^[]string)(ptr)^ do append(&items, json.String(x))
			out[f.name] = items
		}
	}
	return out
}

@(private = "file")
expected_value :: proc(d: ^Dumper) -> json.Value {
	out := make(json.Object, 1, d.a)
	out["pformat"] = json.String(pformat(d.doc, d.doc.root, allocator = d.a))
	return out
}

// --- writing -----------------------------------------------------------------------

// ``json.dumps(v, sort_keys=True, indent=1, ensure_ascii=False)``.
@(private)
write_json :: proc(b: ^strings.Builder, v: json.Value, level: int) {
	switch x in v {
	case json.Null:
		strings.write_string(b, "null")
	case json.Integer:
		write_int(b, int(x))
	case json.Float:
		strings.write_string(b, py_float_repr(x))
	case json.Boolean:
		strings.write_string(b, "true" if x else "false")
	case json.String:
		write_json_string(b, x)
	case json.Array:
		if len(x) == 0 {
			strings.write_string(b, "[]")
			return
		}
		strings.write_byte(b, '[')
		for e, i in x {
			write_item_start(b, i, level)
			write_json(b, e, level + 1)
		}
		write_close(b, ']', level)
	case json.Object:
		write_json_object(b, x, level)
	case:
		strings.write_string(b, "null")
	}
}

@(private = "file")
write_json_object :: proc(b: ^strings.Builder, obj: json.Object, level: int) {
	if len(obj) == 0 {
		strings.write_string(b, "{}")
		return
	}
	keys, _ := slice.map_keys((map[string]json.Value)(obj), context.temp_allocator)
	slice.sort(keys)
	strings.write_byte(b, '{')
	for k, i in keys {
		write_item_start(b, i, level)
		write_json_string(b, k)
		strings.write_string(b, ": ")
		write_json(b, obj[k], level + 1)
	}
	write_close(b, '}', level)
}

@(private = "file")
write_item_start :: proc(b: ^strings.Builder, i, level: int) {
	if i > 0 do strings.write_byte(b, ',')
	strings.write_byte(b, '\n')
	for _ in 0 ..= level do strings.write_byte(b, ' ')
}

@(private = "file")
write_close :: proc(b: ^strings.Builder, c: u8, level: int) {
	strings.write_byte(b, '\n')
	for _ in 0 ..< level do strings.write_byte(b, ' ')
	strings.write_byte(b, c)
}

// A JSON string as Python writes it with ``ensure_ascii=False``: only ``"``,
// ``\`` and the control characters below U+0020 are escaped.
@(private = "file")
write_json_string :: proc(b: ^strings.Builder, s: string) {
	hex := "0123456789abcdef"
	strings.write_byte(b, '"')
	start := 0
	for i in 0 ..< len(s) {
		c := s[i]
		if c >= 0x20 && c != '"' && c != '\\' do continue
		strings.write_string(b, s[start:i])
		start = i + 1
		switch c {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case '\b':
			strings.write_string(b, `\b`)
		case '\f':
			strings.write_string(b, `\f`)
		case:
			strings.write_string(b, `\u00`)
			strings.write_byte(b, hex[c >> 4])
			strings.write_byte(b, hex[c & 0xF])
		}
	}
	strings.write_string(b, s[start:])
	strings.write_byte(b, '"')
}
