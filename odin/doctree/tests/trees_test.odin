package doctree_tests

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:testing"

import dt ".."

// Differential test: replay the scenarios of fixtures/trees.json (generated
// by scripts/doctree_fixtures.py with docutils) through the doctree API and
// compare every observation byte for byte.

TREES_JSON :: #load("fixtures/trees.json", string)

@(private = "file")
Replay :: struct {
	t:        ^testing.T,
	doc:      ^dt.Doc,
	vars:     map[string]dt.Node,
	scenario: string,
	op:       int,
	failures: int,
}

@(private = "file")
node :: proc(r: ^Replay, v: json.Value) -> dt.Node {
	if jnull(v) do return 0
	n, ok := r.vars[jstr(v)]
	if !ok do fmt.panicf("%s: op %d: unknown node %v", r.scenario, r.op, v)
	return n
}

@(private = "file")
check :: proc(r: ^Replay, what, got, want: string) {
	if got == want do return
	r.failures += 1
	if r.failures > 20 do return
	diff := first_difference(got, want)
	testing.expectf(r.t, false, "%s op %d (%s): mismatch at %s", r.scenario, r.op, what, diff)
}

@(private = "file")
check_list :: proc(r: ^Replay, what: string, got: []string, want: json.Value) {
	w := jarr(want)
	b1 := strings.builder_make(context.temp_allocator)
	b2 := strings.builder_make(context.temp_allocator)
	for s in got do fmt.sbprintf(&b1, "%s\n", s)
	for s in w do fmt.sbprintf(&b2, "%s\n", jstr(s))
	check(r, what, strings.to_string(b1), strings.to_string(b2))
}

@(private = "file")
new_doc :: proc(r: ^Replay, args: []json.Value) {
	s := dt.default_settings()
	s.warning_stream = .Collect
	opts := args[1].(json.Object) or_else nil
	for k, v in opts {
		switch k {
		case "id_prefix":
			s.id_prefix = jstr(v)
		case "auto_id_prefix":
			s.auto_id_prefix = jstr(v)
		case "report_level":
			s.report_level = jint(v)
		case "halt_level":
			s.halt_level = jint(v)
		case "detailed":
			s.detailed = jbool(v)
		}
	}
	dt.destroy(r.doc)
	r.doc = dt.new_document(jstr(args[0]), s)
	clear(&r.vars)
	r.vars["doc"] = r.doc.root
}

@(private = "file")
attr_value :: proc(r: ^Replay, v: json.Value) -> dt.Attr_Value {
	#partial switch x in v {
	case json.String:
		return string(x)
	case json.Integer:
		return int(x)
	case json.Boolean:
		return bool(x)
	case json.Array:
		items := make([]string, len(x), context.temp_allocator)
		for s, i in x do items[i] = jstr(s)
		return dt.new_list(r.doc, ..items)
	}
	return dt.Attr_None{}
}

@(private = "file")
new_pending :: proc(r: ^Replay, args: []json.Value) {
	details := make([dynamic]dt.Detail, context.temp_allocator)
	for k, v in args[3].(json.Object) or_else nil {
		value: dt.Detail_Value = dt.Detail_None{}
		#partial switch x in v {
		case json.String:
			value = string(x)
		case json.Integer:
			value = int(x)
		case json.Boolean:
			value = bool(x)
		case json.Array:
			items := make([]string, len(x), context.temp_allocator)
			for s, i in x do items[i] = jstr(s)
			value = items
		case json.Object:
			value = node(r, x["node"])
		}
		append(&details, dt.Detail{k, value})
	}
	p := dt.new_pending(r.doc, jstr(args[1]), jint(args[2]), details[:])
	r.vars[jstr(args[0])] = p
}

@(private = "file")
new_message :: proc(r: ^Replay, args: []json.Value) {
	opts: dt.Message_Options
	for k, v in args[3].(json.Object) or_else nil {
		switch k {
		case "base_node":
			opts.base_node = node(r, v)
		case "line":
			opts.line = jint(v)
		case "source":
			opts.source = jstr(v)
		case "backrefs":
			refs := make([]string, len(jarr(v)), context.temp_allocator)
			for s, i in jarr(v) do refs[i] = jstr(s)
			opts.backrefs = refs
		}
	}
	msg := dt.system_message(r.doc, dt.Level(jint(args[1])), jstr(args[2]), opts)
	r.vars[jstr(args[0])] = msg
}

@(private = "file")
NOTES := [?]struct {
	kind: string,
	fn:   proc(doc: ^dt.Doc, n: dt.Node),
} {
	{"refname", dt.note_refname},
	{"refid", dt.note_refid},
	{"indirect_target", dt.note_indirect_target},
	{"anonymous_target", dt.note_anonymous_target},
	{"autofootnote", dt.note_autofootnote},
	{"autofootnote_ref", dt.note_autofootnote_ref},
	{"symbol_footnote", dt.note_symbol_footnote},
	{"symbol_footnote_ref", dt.note_symbol_footnote_ref},
	{"footnote", dt.note_footnote},
	{"footnote_ref", dt.note_footnote_ref},
	{"citation", dt.note_citation},
	{"citation_ref", dt.note_citation_ref},
	{"parse_message", dt.note_parse_message},
	{"transform_message", dt.note_transform_message},
}

// ``document.note_<kind>(node)``.
@(private = "file")
note :: proc(r: ^Replay, kind: string, n: dt.Node) {
	for entry in NOTES {
		if entry.kind == kind {
			entry.fn(r.doc, n)
			return
		}
	}
	fmt.panicf("unknown note kind %s", kind)
}

// Operations that build or change the document; false if not one.
@(private = "file")
run_build_op :: proc(r: ^Replay, name: string, a: []json.Value) -> bool {
	d := r.doc
	switch name {
	case "doc":
		new_doc(r, a)
	case "elem":
		t, _ := tag_by_name(jstr(a[1]))
		r.vars[jstr(a[0])] = dt.new_element(d, t, jstr(a[2]), jstr(a[3]))
	case "text":
		r.vars[jstr(a[0])] = dt.new_text(d, jstr(a[1]))
	case "pending":
		new_pending(r, a)
	case "msg":
		new_message(r, a)
	case:
		return run_tree_op(r, name, a)
	}
	return true
}

@(private = "file")
run_tree_op :: proc(r: ^Replay, name: string, a: []json.Value) -> bool {
	d := r.doc
	switch name {
	case "append":
		dt.append_child(d, node(r, a[0]), node(r, a[1]))
	case "insert":
		dt.insert_child(d, node(r, a[0]), jint(a[1]), node(r, a[2]))
	case "remove":
		dt.remove_child(d, node(r, a[0]), node(r, a[1]))
	case "replace":
		dt.replace(d, node(r, a[0]), node(r, a[1]), node(r, a[2]))
	case "replace_self":
		news := make([dynamic]dt.Node, context.temp_allocator)
		for v in jarr(a[1]) do append(&news, node(r, v))
		dt.replace_self_list(d, node(r, a[0]), news[:])
	case "pop":
		dt.pop_child(d, node(r, a[0]), jint(a[1]))
	case "copy":
		r.vars[jstr(a[0])] = dt.copy_node(d, node(r, a[1]))
	case "deepcopy":
		r.vars[jstr(a[0])] = dt.deepcopy(d, node(r, a[1]))
	case:
		return run_attr_op(r, name, a)
	}
	return true
}

@(private = "file")
run_attr_op :: proc(r: ^Replay, name: string, a: []json.Value) -> bool {
	d := r.doc
	switch name {
	case "set":
		dt.set_attr(d, node(r, a[0]), jstr(a[1]), attr_value(r, a[2]))
	case "listappend":
		dt.list_append(d, node(r, a[0]), jstr(a[1]), jstr(a[2]))
	case "del":
		dt.delete_attr(d, node(r, a[0]), jstr(a[1]))
	case "update_basic":
		dt.update_basic_atts(d, node(r, a[0]), node(r, a[1]))
	case:
		return run_registry_op(r, name, a)
	}
	return true
}

@(private = "file")
run_registry_op :: proc(r: ^Replay, name: string, a: []json.Value) -> bool {
	d := r.doc
	switch name {
	case "setid":
		dt.set_id(d, node(r, a[0]), node(r, a[1]), jstr(a[2]))
	case "target":
		if jbool(a[2]) {
			dt.note_explicit_target(d, node(r, a[0]), node(r, a[1]))
		} else {
			dt.note_implicit_target(d, node(r, a[0]), node(r, a[1]))
		}
	case "note":
		note(r, jstr(a[0]), node(r, a[1]))
	case "subdef":
		dt.note_substitution_def(d, node(r, a[0]), jstr(a[1]), node(r, a[2]))
	case "subref":
		dt.note_substitution_ref(d, node(r, a[0]), jstr(a[1]))
	case "note_pending":
		priority: Maybe(int) = nil if jnull(a[1]) else jint(a[1])
		dt.note_pending(d, node(r, a[0]), priority)
	case "note_source":
		src: Maybe(string) = nil if jnull(a[0]) else jstr(a[0])
		off: Maybe(int) = nil if jnull(a[1]) else jint(a[1])
		dt.note_source(d, src, off)
	case "decoration":
		r.vars[jstr(a[0])] = dt.get_decoration(d)
	case "findall_mutate":
		findall_mutate(r, a)
	case:
		return false
	}
	return true
}

@(private = "file")
mutate :: proc(d: ^dt.Doc, n: dt.Node, action: string) {
	p := dt.parent(d, n)
	linked := p != 0 && dt.index(d, p, n) >= 0
	t := dt.tag(d, n)
	switch action {
	case "remove":
		if linked do dt.remove_child(d, p, n)
	case "replace2":
		if t != .Text && linked && t != .strong {
			a := dt.new_element(d, .strong, "", "a")
			b := dt.new_element(d, .strong, "", "b")
			dt.replace_self_list(d, n, {a, b})
		}
	case "grow":
		if t != .Text && t != .inline && t != .document {
			dt.append_child(d, n, dt.new_element(d, .inline, "", "x"))
		}
	case "before":
		if linked && t != .emphasis {
			dt.insert_child(d, p, dt.index(d, p, n), dt.new_element(d, .emphasis, "", "e"))
		}
	}
}

@(private = "file")
findall_mutate :: proc(r: ^Replay, a: []json.Value) {
	cond: dt.Condition
	if tags, _ := tag_set(a[1]); len(jarr(a[1])) > 0 do cond = tags
	seen := make([dynamic]string, context.temp_allocator)
	it := dt.findall(r.doc, node(r, a[0]), cond)
	for n in dt.next(&it) {
		append(&seen, desc(r.doc, n))
		if len(seen) >= 200 do break
		mutate(r.doc, n, jstr(a[2]))
	}
	check_list(r, "findall_mutate", seen[:], a[3])
}

@(private = "file")
run_check_op :: proc(r: ^Replay, name: string, a: []json.Value) -> bool {
	d := r.doc
	switch name {
	case "pformat":
		got := dt.pformat(d, node(r, a[0]), allocator = context.temp_allocator)
		check(r, name, got, jstr(a[1]))
	case "astext":
		check(r, name, dt.astext(d, node(r, a[0])), jstr(a[1]))
	case "registry":
		check(r, name, dump_registry(d), jstr(a[0]))
	case "written":
		b := strings.builder_make(context.temp_allocator)
		for w in d.reporter.written do strings.write_string(&b, w.text)
		check(r, name, strings.to_string(b), jstr(a[0]))
	case "halted":
		check(r, name, fmt.tprint(d.reporter.halted), fmt.tprint(jbool(a[0])))
	case "desc":
		check(r, name, desc(d, node(r, a[0])), jstr(a[1]))
	case "index":
		i := dt.index(d, node(r, a[0]), node(r, a[1]))
		check(r, name, fmt.tprint(i), fmt.tprint(jint(a[2])))
	case:
		return run_query_op(r, name, a)
	}
	return true
}

@(private = "file")
run_query_op :: proc(r: ^Replay, name: string, a: []json.Value) -> bool {
	d := r.doc
	switch name {
	case "findall":
		cond: dt.Condition
		if tags, ok := tag_set(a[1]); ok do cond = tags
		flags := [4]bool{jbool(a[2]), jbool(a[3]), jbool(a[4]), jbool(a[5])}
		found := dt.traverse(d, node(r, a[0]), cond, flags[0], flags[1], flags[2], flags[3])
		descs := make([]string, len(found), context.temp_allocator)
		for n, i in found do descs[i] = desc(d, n)
		check_list(r, name, descs, a[6])
	case "first_matching", "first_not_matching":
		tags, _ := tag_set(a[1])
		p := node(r, a[0])
		start := jint(a[2])
		i := dt.first_child_matching_class(d, p, tags, start)
		if name == "first_not_matching" do i = dt.first_child_not_matching_class(d, p, tags, start)
		check(r, name, fmt.tprint(i), fmt.tprint(jint(a[3])))
	case "section_hierarchy":
		secs := dt.section_hierarchy(d, node(r, a[0]))
		descs := make([]string, len(secs), context.temp_allocator)
		for n, i in secs do descs[i] = desc(d, n)
		check_list(r, name, descs, a[1])
	case "validate":
		ok, msg, prob := dt.validate(d, node(r, a[0]), jbool(a[1]))
		want := jarr(a[2])
		got := fmt.tprintf("%v|%s|%s", ok, msg, desc(d, prob))
		check(r, name, got, fmt.tprintf("%v|%s|%s", jbool(want[0]), jstr(want[1]), jstr(want[2])))
	case "source_line":
		src, ln := dt.get_source_line(d, node(r, a[0]))
		want := jarr(a[1])
		got := fmt.tprintf("%v|%v", src, ln)
		ws: Maybe(string) = nil if jnull(want[0]) else jstr(want[0])
		wl: Maybe(int) = nil if jnull(want[1]) else jint(want[1])
		check(r, name, got, fmt.tprintf("%v|%v", ws, wl))
	case:
		return false
	}
	return true
}

@(test)
test_trees_match_docutils :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	root, err := json.parse_string(TREES_JSON, .JSON, true)
	testing.expect_value(t, err, json.Error.None)
	r := Replay{t = t}
	defer dt.destroy(r.doc)
	for sc in jarr(root.(json.Object)["scenarios"]) {
		obj := sc.(json.Object)
		r.scenario = jstr(obj["name"])
		for op, i in jarr(obj["ops"]) {
			r.op = i
			a := jarr(op)
			name := jstr(a[0])
			args := a[1:]
			if !run_build_op(&r, name, args) && !run_check_op(&r, name, args) {
				fmt.panicf("%s: unknown op %s", r.scenario, name)
			}
		}
		free_all(context.temp_allocator)
	}
	testing.expectf(t, r.failures == 0, "%d mismatches", r.failures)
}
