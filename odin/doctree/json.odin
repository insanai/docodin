package doctree

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"

// The doctree interchange: a docutils document at a stage of the publisher,
// dumped to JSON by scripts/doctree_json.py, so that transforms and writers
// can be developed and tested against docutils without the native parser.
// ``load_json`` loads a dump into a ``Doc``; ``dump_json`` (json_dump.odin)
// writes one.  The format is described in docs/NATIVE_PIPELINE.md.
//
// Node records are numbered in preorder of the document tree, then of the
// detached subtrees (nodes that are referenced but not in the tree), and a
// record index ``i`` is the node handle ``i + 1``.

INTERCHANGE_FORMAT :: "docodin-doctree/1"

// What a dump carries besides the document, kept as loaded for
// ``dump_json``.
Interchange :: struct {
	stage:    string, // "parsed", "transformed" or "output"
	input:    json.Value, // source path, writer and settings overrides of the run
	settings: json.Value, // every setting of the run; ``Doc.settings`` holds the known ones
	expected: json.Value, // docutils' ``pformat`` (stage "output": ``output`` and ``parts``)
}

// A run of consecutive lines of one source in a state machine's
// ``input_lines`` (``StringList.items``).
Source_Run :: struct {
	source: Maybe(string),
	offset: int, // offset of the first line in its source
	count:  int,
}

// The line map behind ``Reporter.get_source_and_line`` after parsing: the
// ``input_lines``, ``input_offset`` and ``line_offset`` of the top-level
// state machine.
Source_Lines :: struct {
	input_offset: int,
	line_offset:  int,
	runs:         []Source_Run,
	total:        int, // number of lines
}

// An invalid dump; ``message`` is in the temp allocator.
Format_Error :: struct {
	message: string,
}

Load_Error :: union {
	json.Error,
	Format_Error,
}

@(private = "file")
Loader :: struct {
	doc:   ^Doc,
	total: int, // number of node records
	tags:  map[string]Tag,
	err:   string, // the first error
}

// Load a dump.  The ``Doc`` holds the tree, attributes, internal node state,
// ``pending`` data, registry, transformer queue, reporter state and settings
// of the dump; its reporter collects messages (``warning_stream`` is
// ``.Collect``).
load_json :: proc(data: string, allocator := context.allocator) -> (doc: ^Doc, err: Load_Error) {
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do panic("doctree: cannot reserve arena")
	defer virtual.arena_destroy(&scratch)
	a := virtual.arena_allocator(&scratch)
	value, jerr := json.parse_string(data, .JSON, true, a)
	if jerr != .None do return nil, jerr
	doc = make_doc(default_settings(), allocator)
	l := Loader {
		doc  = doc,
		tags = make(map[string]Tag, len(Tag), a),
	}
	for t in Tag do l.tags[TAG_NAMES[t]] = t
	load_dump(&l, value)
	if l.err != "" {
		destroy(doc)
		return nil, Format_Error{l.err}
	}
	return doc, nil
}

// --- JSON access -------------------------------------------------------------------

@(private = "file")
fail :: proc(l: ^Loader, format: string, args: ..any) {
	if l.err == "" do l.err = fmt.tprintf(format, ..args)
}

// ``v[key]``; nil if ``v`` is not an object or has no ``key``.
@(private = "file")
member :: proc(v: json.Value, key: string) -> json.Value {
	obj, _ := v.(json.Object)
	return obj[key]
}

@(private = "file")
is_null :: proc(v: json.Value) -> bool {
	_, null := v.(json.Null)
	return null || v == nil
}

@(private = "file")
as_string :: proc(l: ^Loader, v: json.Value, what: string) -> string {
	s, ok := v.(json.String)
	if !ok do fail(l, "%s: expected a string, got %v", what, v)
	return s
}

@(private = "file")
as_int :: proc(l: ^Loader, v: json.Value, what: string) -> int {
	i, ok := v.(json.Integer)
	if !ok do fail(l, "%s: expected an integer, got %v", what, v)
	return int(i)
}

@(private = "file")
as_bool :: proc(l: ^Loader, v: json.Value, what: string) -> bool {
	b, ok := v.(json.Boolean)
	if !ok do fail(l, "%s: expected a boolean, got %v", what, v)
	return b
}

@(private = "file")
as_array :: proc(l: ^Loader, v: json.Value, what: string) -> json.Array {
	arr, ok := v.(json.Array)
	if !ok do fail(l, "%s: expected an array, got %v", what, v)
	return arr
}

@(private = "file")
as_object :: proc(l: ^Loader, v: json.Value, what: string) -> json.Object {
	obj, ok := v.(json.Object)
	if !ok do fail(l, "%s: expected an object, got %v", what, v)
	return obj
}

// An optional member: missing is the empty array.
@(private = "file")
opt_array :: proc(l: ^Loader, v: json.Value, key: string) -> json.Array {
	x := member(v, key)
	return nil if x == nil else as_array(l, x, key)
}

// An optional boolean member: missing is false.
@(private = "file")
opt_flag :: proc(l: ^Loader, v: json.Value, key: string) -> bool {
	x := member(v, key)
	return x != nil && as_bool(l, x, key)
}

@(private = "file")
maybe_string :: proc(l: ^Loader, v: json.Value, what: string) -> Maybe(string) {
	if is_null(v) do return nil
	return clone(l.doc, as_string(l, v, what))
}

@(private = "file")
maybe_int :: proc(l: ^Loader, v: json.Value, what: string) -> Maybe(int) {
	if is_null(v) do return nil
	return as_int(l, v, what)
}

// A ``[key, value]`` pair.
@(private = "file")
pair :: proc(l: ^Loader, v: json.Value, what: string) -> (key: Str, value: json.Value) {
	arr := as_array(l, v, what)
	if len(arr) != 2 {
		fail(l, "%s: expected a [key, value] pair", what)
		return 0, nil
	}
	return intern(l.doc, as_string(l, arr[0], what)), arr[1]
}

// The keys of an object, sorted (a dump sorts them too).
@(private = "file")
sorted_keys :: proc(obj: json.Object) -> []string {
	keys, _ := slice.map_keys((map[string]json.Value)(obj), context.temp_allocator)
	slice.sort(keys)
	return keys
}

// A node reference: a record index or null.
@(private = "file")
node_ref :: proc(l: ^Loader, v: json.Value, what: string) -> Node {
	if is_null(v) do return 0
	i := as_int(l, v, what)
	if i < 0 || i >= l.total {
		fail(l, "%s: no node record %d", what, i)
		return 0
	}
	return Node(i + 1)
}

@(private = "file")
node_list :: proc(l: ^Loader, v: json.Value, what: string) -> [dynamic]Node {
	arr := as_array(l, v, what)
	out := make([dynamic]Node, 0, len(arr), l.doc.allocator)
	for x in arr do append(&out, node_ref(l, x, what))
	return out
}

// Deep copy of a JSON value into the document's arena.
@(private)
clone_value :: proc(doc: ^Doc, v: json.Value) -> json.Value {
	#partial switch x in v {
	case json.String:
		return json.String(clone(doc, x))
	case json.Array:
		out := make(json.Array, len(x), doc.allocator)
		for e, i in x do out[i] = clone_value(doc, e)
		return out
	case json.Object:
		out := make(json.Object, len(x), doc.allocator)
		for k, e in x do out[clone(doc, k)] = clone_value(doc, e)
		return out
	}
	return v
}

// --- the dump ----------------------------------------------------------------------

@(private = "file")
load_dump :: proc(l: ^Loader, v: json.Value) {
	as_object(l, v, "dump")
	if f := as_string(l, member(v, "format"), "format"); l.err == "" && f != INTERCHANGE_FORMAT {
		fail(l, "format: %q is not %q", f, INTERCHANGE_FORMAT)
	}
	if l.err != "" do return
	doc := l.doc
	load_settings(l, member(v, "settings"))
	tree := member(v, "tree")
	detached := as_array(l, member(v, "detached"), "detached")
	l.total = count_records(tree)
	for d in detached do l.total += count_records(member(d, "node"))
	if l.err != "" do return
	doc.root = load_node(l, tree)
	if doc.root != 1 || doc.nodes[doc.root].tag != .document do fail(l, "tree: not a document")
	for d in detached {
		n := load_node(l, member(d, "node"))
		doc.nodes[n].parent = node_ref(l, member(d, "parent"), "detached parent")
	}
	load_registry(l, member(v, "registry"))
	load_transformer(l, member(v, "transformer"))
	load_reporter(l, member(v, "reporter"))
	doc.interchange.stage = clone(doc, as_string(l, member(v, "stage"), "stage"))
	doc.interchange.input = clone_value(doc, member(v, "input"))
	doc.interchange.expected = clone_value(doc, member(v, "expected"))
}

@(private = "file")
count_records :: proc(v: json.Value) -> int {
	n := 1
	children, _ := member(v, "children").(json.Array)
	for c in children do n += count_records(c)
	return n
}

// --- nodes ---------------------------------------------------------------------------

@(private = "file")
load_node :: proc(l: ^Loader, v: json.Value) -> Node {
	doc := l.doc
	name := as_string(l, member(v, "tag"), "tag")
	if name == "#text" {
		n := alloc_node(doc, .Text, as_string(l, member(v, "text"), "#text"))
		load_location(l, n, v)
		return n
	}
	t, known := l.tags[name]
	if !known do fail(l, "tag: unknown element <%s>", name)
	raw := member(v, "rawsource")
	n := alloc_node(doc, t, "" if raw == nil else as_string(l, raw, "rawsource"))
	load_location(l, n, v)
	load_element(l, n, v)
	for c in opt_array(l, v, "children") do link_before(doc, n, load_node(l, c), 0)
	return n
}

// ``source``, ``line`` (missing: None) and ``document`` (missing: None).
@(private = "file")
load_location :: proc(l: ^Loader, n: Node, v: json.Value) {
	doc := l.doc
	if src := member(v, "source"); src != nil do set_source(doc, n, as_string(l, src, "source"))
	if ln := member(v, "line"); ln != nil do set_line(doc, n, as_int(l, ln, "line"))
	if opt_flag(l, v, "document") do doc.nodes[n].flags += {.Has_Document}
}

@(private = "file")
load_element :: proc(l: ^Loader, n: Node, v: json.Value) {
	doc := l.doc
	t := doc.nodes[n].tag
	if attrs := member(v, "attributes"); attrs != nil {
		obj := as_object(l, attrs, "attributes")
		for k in sorted_keys(obj) do set_attr(doc, n, k, attr_value(l, obj[k], k))
	}
	for x in opt_array(l, v, "deleted") {
		name := as_string(l, x, "deleted")
		b, basic := basic_of(intern(doc, name))
		if !basic || b not_in TAG_LIST_ATTRS[t] {
			fail(l, "deleted: %s is not a list attribute of <%s>", name, TAG_NAMES[t])
			continue
		}
		doc.nodes[n].deleted += {b}
	}
	if opt_flag(l, v, "referenced") do doc.nodes[n].flags += {.Referenced}
	if opt_flag(l, v, "resolved") do doc.nodes[n].flags += {.Resolved}
	if internal := member(v, "internal"); internal != nil do load_internals(l, n, internal)
	pending := member(v, "pending")
	if (t == .pending) != (pending != nil) {
		fail(l, "pending: only (and every) <pending> has pending data")
	} else if pending != nil {
		load_pending(l, n, pending)
	}
}

@(private = "file")
attr_value :: proc(l: ^Loader, v: json.Value, key: string) -> Attr_Value {
	#partial switch x in v {
	case json.String:
		return string(x)
	case json.Integer:
		return int(x)
	case json.Boolean:
		return bool(x)
	case json.Null:
		return Attr_None{}
	case json.Array:
		items := make([]string, len(x), context.temp_allocator)
		for e, i in x do items[i] = as_string(l, e, key)
		return new_list(l.doc, ..items)
	case json.Object:
		// A float, as its ``repr`` (the doctree's representation of floats).
		if f, ok := x["float"].(json.String); ok && len(x) == 1 do return string(f)
	}
	fail(l, "attribute %s: unsupported value %v", key, v)
	return Attr_None{}
}

@(private = "file")
load_internals :: proc(l: ^Loader, n: Node, v: json.Value) {
	doc := l.doc
	ni: Node_Internals
	for k, x in as_object(l, v, "internal") {
		switch k {
		case "indent":
			ni.indent = as_int(l, x, k)
		case "indirect_reference_name":
			ni.indirect_reference_name = clone(doc, as_string(l, x, k))
		case "expect_referenced_by_id":
			ni.expect_referenced_by_id = name_refs(l, x, k)
		case "expect_referenced_by_name":
			ni.expect_referenced_by_name = name_refs(l, x, k)
		case:
			fail(l, "internal: unknown state %s", k)
		}
	}
	doc.internals[n] = ni
}

@(private = "file")
name_refs :: proc(l: ^Loader, v: json.Value, what: string) -> [dynamic]Name_Ref {
	arr := as_array(l, v, what)
	out := make([dynamic]Name_Ref, 0, len(arr), l.doc.allocator)
	for x in arr {
		name, node := pair(l, x, what)
		append(&out, Name_Ref{name, node_ref(l, node, what)})
	}
	return out
}

@(private = "file")
load_pending :: proc(l: ^Loader, n: Node, v: json.Value) {
	doc := l.doc
	p := Pending {
		transform        = clone(doc, as_string(l, member(v, "transform"), "transform")),
		default_priority = as_int(l, member(v, "default_priority"), "default_priority"),
		details          = load_details(l, member(v, "details"), "details"),
	}
	doc.nodes[n].extra = u32(len(doc.pendings))
	append(&doc.pendings, p)
}

// ``pending.details`` or transform kwargs, by sorted key.
@(private = "file")
load_details :: proc(l: ^Loader, v: json.Value, what: string) -> [dynamic]Detail {
	obj := as_object(l, v, what)
	out := make([dynamic]Detail, 0, len(obj), l.doc.allocator)
	for k in sorted_keys(obj) {
		append(&out, Detail{clone(l.doc, k), detail_value(l, obj[k], k)})
	}
	return out
}

@(private = "file")
detail_value :: proc(l: ^Loader, v: json.Value, key: string) -> Detail_Value {
	doc := l.doc
	#partial switch x in v {
	case json.String:
		return clone(doc, x)
	case json.Integer:
		return int(x)
	case json.Boolean:
		return bool(x)
	case json.Null:
		return Detail_None{}
	case json.Array:
		items := make([]string, len(x), doc.allocator)
		for e, i in x do items[i] = clone(doc, as_string(l, e, key))
		return items
	case json.Object:
		if node, ok := x["node"]; ok && len(x) == 1 do return node_ref(l, node, key)
		if list, ok := x["nodes"]; ok && len(x) == 1 do return node_list(l, list, key)[:]
	}
	fail(l, "detail %s: unsupported value %v", key, v)
	return Detail_None{}
}

// --- document state ----------------------------------------------------------------

@(private = "file")
load_registry :: proc(l: ^Loader, v: json.Value) {
	doc := l.doc
	as_object(l, v, "registry")
	for x in as_array(l, member(v, "ids"), "ids") {
		k, node := pair(l, x, "ids")
		om_set(&doc.ids, k, node_ref(l, node, "ids"))
	}
	for x in as_array(l, member(v, "nameids"), "nameids") {
		k, id := pair(l, x, "nameids")
		om_set(&doc.nameids, k, 0 if is_null(id) else intern(doc, as_string(l, id, "nameids")))
	}
	for x in as_array(l, member(v, "nametypes"), "nametypes") {
		k, explicit := pair(l, x, "nametypes")
		om_set(&doc.nametypes, k, as_bool(l, explicit, "nametypes"))
	}
	for x in as_array(l, member(v, "substitution_defs"), "substitution_defs") {
		k, node := pair(l, x, "substitution_defs")
		om_set(&doc.substitution_defs, k, node_ref(l, node, "substitution_defs"))
	}
	for x in as_array(l, member(v, "substitution_names"), "substitution_names") {
		k, name := pair(l, x, "substitution_names")
		om_set(&doc.substitution_names, k, intern(doc, as_string(l, name, "substitution_names")))
	}
	for x in as_array(l, member(v, "id_counter"), "id_counter") {
		k, count := pair(l, x, "id_counter")
		om_set(&doc.id_counter, k, as_int(l, count, "id_counter"))
	}
	load_registry_lists(l, v)
	doc.autofootnote_start = as_int(l, member(v, "autofootnote_start"), "autofootnote_start")
	start := member(v, "symbol_footnote_start")
	doc.symbol_footnote_start = as_int(l, start, "symbol_footnote_start")
	doc.decoration = node_ref(l, member(v, "decoration"), "decoration")
	doc.current_source = maybe_string(l, member(v, "current_source"), "current_source")
	doc.current_line = maybe_int(l, member(v, "current_line"), "current_line")
}

// The registry's node lists and name -> node list maps, in the order in
// which a dump references their nodes.
@(private)
Registry_Lists :: struct {
	maps:  [4]struct {
		name: string,
		m:    ^Ordered_Map([dynamic]Node),
	},
	lists: [9]struct {
		name: string,
		list: ^[dynamic]Node,
	},
}

@(private)
registry_lists :: proc(doc: ^Doc) -> Registry_Lists {
	return {
		maps = {
			{"refnames", &doc.refnames},
			{"refids", &doc.refids},
			{"footnote_refs", &doc.footnote_refs},
			{"citation_refs", &doc.citation_refs},
		},
		lists = {
			{"indirect_targets", &doc.indirect_targets},
			{"autofootnotes", &doc.autofootnotes},
			{"autofootnote_refs", &doc.autofootnote_refs},
			{"symbol_footnotes", &doc.symbol_footnotes},
			{"symbol_footnote_refs", &doc.symbol_footnote_refs},
			{"footnotes", &doc.footnotes},
			{"citations", &doc.citations},
			{"parse_messages", &doc.parse_messages},
			{"transform_messages", &doc.transform_messages},
		},
	}
}

@(private = "file")
load_registry_lists :: proc(l: ^Loader, v: json.Value) {
	rl := registry_lists(l.doc)
	for e in rl.maps {
		for x in as_array(l, member(v, e.name), e.name) {
			k, list := pair(l, x, e.name)
			om_set(e.m, k, node_list(l, list, e.name))
		}
	}
	for e in rl.lists do e.list^ = node_list(l, member(v, e.name), e.name)
}

@(private = "file")
load_transformer :: proc(l: ^Loader, v: json.Value) {
	doc := l.doc
	for x in as_array(l, member(v, "queue"), "queue") {
		item := as_array(l, x, "queue")
		if len(item) != 4 {
			fail(l, "queue: expected [priority, transform, pending, kwargs]")
			continue
		}
		q: Queued_Pending
		q.priority, q.serial = parse_priority(l, as_string(l, item[0], "queue priority"))
		q.transform = clone(doc, as_string(l, item[1], "queue transform"))
		q.node = node_ref(l, item[2], "queue pending")
		q.kwargs = load_details(l, item[3], "queue kwargs")
		if q.node != 0 && doc.nodes[q.node].tag != .pending do fail(l, "queue: not a <pending>")
		append(&doc.pending_queue, q)
	}
	doc.transform_serial = as_int(l, member(v, "serialno"), "serialno")
}

// ``"%03d-%03d" % (priority, serial)``.
@(private = "file")
parse_priority :: proc(l: ^Loader, s: string) -> (priority, serial: int) {
	i := strings.last_index_byte(s, '-')
	p, ok1 := strconv.parse_int(s[:max(i, 0)], 10)
	n, ok2 := strconv.parse_int(s[i + 1:], 10)
	if i <= 0 || !ok1 || !ok2 do fail(l, "queue: invalid priority string %q", s)
	return p, n
}

@(private = "file")
load_reporter :: proc(l: ^Loader, v: json.Value) {
	doc := l.doc
	init_reporter(doc, as_string(l, member(v, "source"), "reporter source"))
	r := &doc.reporter
	r.report_level = as_int(l, member(v, "report_level"), "report_level")
	r.halt_level = as_int(l, member(v, "halt_level"), "halt_level")
	r.debug_flag = as_bool(l, member(v, "debug"), "debug")
	r.max_level = as_int(l, member(v, "max_level"), "max_level")
	for x in as_array(l, member(v, "observers"), "observers") {
		switch name := as_string(l, x, "observers"); name {
		case "note_parse_message":
			append(&r.observers, observe_parse_message)
		case "note_transform_message":
			append(&r.observers, observe_transform_message)
		case:
			fail(l, "observers: unknown observer %s", name)
		}
	}
	if lines := member(v, "source_lines"); !is_null(lines) {
		r.source_and_line = interchange_source_line
		r.source_line_data = load_source_lines(l, lines)
	}
	for x in as_array(l, member(v, "written"), "written") {
		level := as_int(l, member(x, "level"), "written level")
		if level < 0 || level > int(max(Level)) do fail(l, "written: invalid level %d", level)
		node := node_ref(l, member(x, "node"), "written node")
		text := clone(doc, as_string(l, member(x, "text"), "written text"))
		append(&r.written, Written_Message{Level(clamp(level, 0, 4)), node, text})
	}
}

@(private = "file")
load_source_lines :: proc(l: ^Loader, v: json.Value) -> ^Source_Lines {
	m := new(Source_Lines, l.doc.allocator)
	m.input_offset = as_int(l, member(v, "input_offset"), "input_offset")
	m.line_offset = as_int(l, member(v, "line_offset"), "line_offset")
	runs := as_array(l, member(v, "runs"), "runs")
	m.runs = make([]Source_Run, len(runs), l.doc.allocator)
	for x, i in runs {
		run := as_array(l, x, "runs")
		if len(run) != 3 {
			fail(l, "runs: expected [source, offset, count]")
			continue
		}
		m.runs[i] = {
			source = maybe_string(l, run[0], "run source"),
			offset = as_int(l, run[1], "run offset"),
			count  = as_int(l, run[2], "run count"),
		}
		m.total += m.runs[i].count
	}
	return m
}

// ``StateMachine.get_source_and_line`` over a loaded ``Source_Lines``.
@(private)
interchange_source_line :: proc(
	doc: ^Doc,
	data: rawptr,
	line: Maybe(int),
) -> (
	Maybe(string),
	Maybe(int),
) {
	m := (^Source_Lines)(data)
	offset := m.line_offset
	if l, ok := line.?; ok do offset = l - m.input_offset - 1
	return source_line_at(m, offset)
}

@(private = "file")
source_line_at :: proc(m: ^Source_Lines, offset: int) -> (Maybe(string), Maybe(int)) {
	if offset == m.total && m.total > 0 {
		// ``StringList.info`` just past the end: the line after the last one.
		src, ln := source_line_at(m, offset - 1)
		if l, ok := ln.?; ok do return src, l + 1
		return src, nil
	}
	i := offset + m.total if offset < 0 else offset // Python indexing
	if i < 0 || i >= m.total do return nil, nil
	for run in m.runs {
		if i < run.count do return run.source, run.offset + i + 1
		i -= run.count
	}
	return nil, nil
}

// --- settings ----------------------------------------------------------------------

// The docutils settings of a dump.  The known ones (the fields of
// ``Settings``) are converted: ``None`` and ``False`` become "", 0, false or
// an empty list; ``smart_quotes`` "alt" sets ``smart_quotes_alt``.
@(private = "file")
load_settings :: proc(l: ^Loader, v: json.Value) {
	obj := as_object(l, v, "settings")
	s := default_settings()
	for f in reflect.struct_fields_zipped(Settings) {
		x, present := obj[f.name]
		if !present do continue
		ptr := rawptr(uintptr(&s) + f.offset)
		switch f.type.id {
		case int:
			(^int)(ptr)^ = setting_int(l, x, f.name)
		case bool:
			(^bool)(ptr)^ = py_truthy(x)
		case string:
			(^string)(ptr)^ = setting_string(l, x, f.name)
		case []string:
			(^[]string)(ptr)^ = setting_strings(l, x, f.name)
		}
	}
	if q, ok := obj["smart_quotes"].(json.String); ok {
		s.smart_quotes_alt = strings.has_prefix(q, "alt")
	}
	s.warning_stream = .Collect
	l.doc.settings = s
	l.doc.interchange.settings = clone_value(l.doc, v)
}

@(private = "file")
py_truthy :: proc(v: json.Value) -> bool {
	switch x in v {
	case json.Null:
		return false
	case json.Boolean:
		return x
	case json.Integer:
		return x != 0
	case json.Float:
		return x != 0
	case json.String:
		return x != ""
	case json.Array:
		return len(x) > 0
	case json.Object:
		return len(x) > 0
	}
	return false
}

@(private = "file")
setting_int :: proc(l: ^Loader, v: json.Value, name: string) -> int {
	#partial switch x in v {
	case json.Integer:
		return int(x)
	case json.Boolean:
		return 1 if x else 0
	case json.Null:
		return 0
	case json.String:
		if i, ok := strconv.parse_int(x, 10); ok do return i
	}
	fail(l, "settings: %s is not an integer: %v", name, v)
	return 0
}

@(private = "file")
setting_string :: proc(l: ^Loader, v: json.Value, name: string) -> string {
	#partial switch x in v {
	case json.String:
		return clone(l.doc, x)
	case json.Null:
		return ""
	case json.Boolean:
		if !x do return ""
	}
	fail(l, "settings: %s is not a string: %v", name, v)
	return ""
}

@(private = "file")
setting_strings :: proc(l: ^Loader, v: json.Value, name: string) -> []string {
	#partial switch x in v {
	case json.Array:
		out := make([]string, len(x), l.doc.allocator)
		for e, i in x do out[i] = setting_item(l, e, name)
		return out
	case json.String:
		if x == "" do return nil
		out := make([]string, 1, l.doc.allocator)
		out[0] = clone(l.doc, x)
		return out
	case json.Null:
		return nil
	}
	fail(l, "settings: %s is not a list of strings: %v", name, v)
	return nil
}

// An item of a list setting: a string, or a pair such as a
// ``smartquotes_locales`` entry ``(language, quotes)`` as "language:quotes".
@(private = "file")
setting_item :: proc(l: ^Loader, v: json.Value, name: string) -> string {
	if p, ok := v.(json.Array); ok && len(p) == 2 {
		parts := [2]string{as_string(l, p[0], name), as_string(l, p[1], name)}
		return strings.join(parts[:], ":", l.doc.allocator)
	}
	return clone(l.doc, as_string(l, v, name))
}
