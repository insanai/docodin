package doctree_tests

import "core:encoding/json"
import "core:fmt"
import "core:strings"

import dt ".."

// Helpers shared by the differential tests: JSON access, name lookup and
// the canonical dumps that scripts/doctree_fixtures.py writes with docutils.

@(private)
tag_by_name :: proc(name: string) -> (dt.Tag, bool) {
	if name == "Text" do return .Text, true
	for t in dt.Tag {
		if dt.TAG_NAMES[t] == name do return t, true
	}
	return .Text, false
}

// A ``Tag_Set`` for a list of class names (concrete classes or categories).
@(private)
tag_set :: proc(names: json.Value) -> (set: dt.Tag_Set, ok: bool) {
	arr, is_arr := names.(json.Array)
	if !is_arr do return {}, false
	for v in arr {
		name := v.(json.String) or_else ""
		if t, found := tag_by_name(name); found {
			set += {t}
			continue
		}
		for c in dt.Category {
			if fmt.tprint(c) == name do set += dt.tags_of(c)
		}
	}
	return set, true
}

@(private)
jstr :: proc(v: json.Value) -> string {
	return v.(json.String) or_else ""
}

@(private)
jint :: proc(v: json.Value) -> int {
	return int(v.(json.Integer) or_else 0)
}

@(private)
jbool :: proc(v: json.Value) -> bool {
	return v.(json.Boolean) or_else false
}

@(private)
jnull :: proc(v: json.Value) -> bool {
	#partial switch _ in v {
	case json.Null:
		return true
	case nil:
		return true
	}
	return false
}

@(private)
jarr :: proc(v: json.Value) -> json.Array {
	return v.(json.Array) or_else nil
}

// Text: ``#text:`` + data; elements: the start tag.
@(private)
desc :: proc(doc: ^dt.Doc, n: dt.Node) -> string {
	if n == 0 do return "None"
	if dt.tag(doc, n) == .Text {
		return strings.concatenate({"#text:", dt.text(doc, n)}, context.temp_allocator)
	}
	return dt.starttag(doc, n)
}

@(private)
node_list :: proc(b: ^strings.Builder, doc: ^dt.Doc, list: []dt.Node) {
	strings.write_byte(b, '[')
	for n, i in list {
		if i > 0 do strings.write_string(b, ", ")
		strings.write_string(b, desc(doc, n))
	}
	strings.write_byte(b, ']')
}

@(private = "file")
dump_nodes :: proc(b: ^strings.Builder, doc: ^dt.Doc, title: string, m: ^dt.Ordered_Map(dt.Node)) {
	fmt.sbprintf(b, "%s:\n", title)
	for k, i in m.keys {
		if k == dt.TOMBSTONE do continue
		fmt.sbprintf(b, "  %s -> %s\n", dt.str(doc, k), desc(doc, m.values[i]))
	}
}

@(private = "file")
dump_lists :: proc(
	b: ^strings.Builder,
	doc: ^dt.Doc,
	title: string,
	m: ^dt.Ordered_Map([dynamic]dt.Node),
) {
	fmt.sbprintf(b, "%s:\n", title)
	for k, i in m.keys {
		if k == dt.TOMBSTONE do continue
		fmt.sbprintf(b, "  %s -> ", dt.str(doc, k))
		node_list(b, doc, m.values[i][:])
		strings.write_byte(b, '\n')
	}
}

@(private = "file")
dump_strs :: proc(b: ^strings.Builder, doc: ^dt.Doc, title: string, m: ^dt.Ordered_Map(dt.Str)) {
	fmt.sbprintf(b, "%s:\n", title)
	for k, i in m.keys {
		if k == dt.TOMBSTONE do continue
		v := m.values[i]
		fmt.sbprintf(b, "  %s -> %s\n", dt.str(doc, k), "None" if v == 0 else dt.str(doc, v))
	}
}

// The registry dump of ``dump_registry`` in scripts/doctree_fixtures.py.
@(private)
dump_registry :: proc(doc: ^dt.Doc) -> string {
	b := strings.builder_make(context.temp_allocator)
	dump_nodes(&b, doc, "ids", &doc.ids)
	dump_strs(&b, doc, "nameids", &doc.nameids)
	strings.write_string(&b, "nametypes:\n")
	for k, i in doc.nametypes.keys {
		v := doc.nametypes.values[i]
		fmt.sbprintf(&b, "  %s -> %s\n", dt.str(doc, k), "True" if v else "False")
	}
	dump_lists(&b, doc, "refnames", &doc.refnames)
	dump_lists(&b, doc, "refids", &doc.refids)
	dump_nodes(&b, doc, "substitution_defs", &doc.substitution_defs)
	dump_strs(&b, doc, "substitution_names", &doc.substitution_names)
	dump_lists(&b, doc, "footnote_refs", &doc.footnote_refs)
	dump_lists(&b, doc, "citation_refs", &doc.citation_refs)
	strings.write_string(&b, "id_counter:\n")
	for k, i in doc.id_counter.keys {
		fmt.sbprintf(&b, "  %s -> %d\n", dt.str(doc, k), doc.id_counter.values[i])
	}
	lists := [?]struct {
		name: string,
		list: []dt.Node,
	} {
		{"indirect_targets", doc.indirect_targets[:]},
		{"autofootnotes", doc.autofootnotes[:]},
		{"autofootnote_refs", doc.autofootnote_refs[:]},
		{"symbol_footnotes", doc.symbol_footnotes[:]},
		{"symbol_footnote_refs", doc.symbol_footnote_refs[:]},
		{"footnotes", doc.footnotes[:]},
		{"citations", doc.citations[:]},
		{"parse_messages", doc.parse_messages[:]},
		{"transform_messages", doc.transform_messages[:]},
	}
	for l in lists {
		fmt.sbprintf(&b, "%s: ", l.name)
		node_list(&b, doc, l.list)
		strings.write_byte(&b, '\n')
	}
	dump_pending(&b, doc)
	return strings.to_string(b)
}

@(private = "file")
dump_pending :: proc(b: ^strings.Builder, doc: ^dt.Doc) {
	strings.write_string(b, "pending: [")
	for q, i in doc.pending_queue {
		if i > 0 do strings.write_string(b, ", ")
		p := dt.pending_of(doc, q.node)
		fmt.sbprintf(b, "%03d-%03d %s %s", q.priority, q.serial, p.transform, desc(doc, q.node))
	}
	strings.write_string(b, "]\ncurrent: ")
	if s, ok := doc.current_source.?; ok do strings.write_string(b, s)
	else do strings.write_string(b, "None")
	if l, ok := doc.current_line.?; ok do fmt.sbprintf(b, " %d\n", l)
	else do strings.write_string(b, " None\n")
}

// The first line where ``a`` and ``b`` differ, for failure messages.
@(private)
first_difference :: proc(a, b: string) -> string {
	la := strings.split_lines(a, context.temp_allocator)
	lb := strings.split_lines(b, context.temp_allocator)
	for i in 0 ..< max(len(la), len(lb)) {
		x := la[i] if i < len(la) else "<end>"
		y := lb[i] if i < len(lb) else "<end>"
		if x != y do return fmt.tprintf("line %d:\n  got:  %q\n  want: %q", i + 1, x, y)
	}
	return "(no line differs)"
}
