package doctree

import "core:fmt"
import "core:strings"

// The ``docutils.nodes.document`` registry: ids, names, references,
// footnotes, citations, substitutions, pending transforms and messages.

// ``utils.new_document(source_path, settings)``: a document with its
// root ``document`` element, reporter and ``note_source(source_path, -1)``.
new_document :: proc(
	source_path: string,
	settings: Settings,
	allocator := context.allocator,
) -> ^Doc {
	doc := make_doc(settings, allocator)
	init_reporter(doc, source_path)
	doc.root = alloc_node(doc, .document, "")
	doc.nodes[doc.root].flags += {.Has_Document}
	set_attr(doc, doc.root, K_SOURCE, source_path)
	note_source(doc, source_path, -1)
	return doc
}

// ``new_document`` with ``default_settings()``.
new_default_document :: proc(source_path: string, allocator := context.allocator) -> ^Doc {
	return new_document(source_path, default_settings(), allocator)
}

// ``document.copy()``: a new document (fresh registry) with the same
// settings, reporter configuration, attributes, source and line.
copy_document :: proc(doc: ^Doc, allocator := context.allocator) -> ^Doc {
	cp := make_doc(doc.settings, allocator)
	init_reporter(cp, doc.reporter.source)
	cp.reporter.source_and_line = doc.reporter.source_and_line
	cp.reporter.source_line_data = doc.reporter.source_line_data
	cp.root = import_node(cp, doc, doc.root)
	cp.nodes[cp.root].flags += {.Has_Document}
	return cp
}

// ``document.note_source(source, offset)``.
note_source :: proc(doc: ^Doc, source: Maybe(string), offset: Maybe(int)) {
	if s, ok := source.?; ok {
		doc.current_source = clone(doc, s)
	} else {
		doc.current_source = nil
	}
	if o, ok := offset.?; ok {
		doc.current_line = o + 1
	} else {
		doc.current_line = nil
	}
}

// --- ids and names -----------------------------------------------------------------

// ``document.set_id(node, msgnode, suggested_prefix)``: register the ids of
// ``node``, or generate one from its names or the auto-id prefix.
set_id :: proc(doc: ^Doc, node: Node, msgnode: Node = 0, suggested_prefix := "") -> Str {
	if ids := attr_list(doc, node, K_IDS); len(ids) > 0 {
		id: Str
		for x in ids {
			id = x
			other := om_ptr(&doc.ids, id)
			if other^ == 0 do other^ = node
			if other^ == node do continue
			text := fmt.tprintf(
				"Duplicate ID: \"%s\" used by %s and %s",
				str(doc, id),
				starttag(doc, other^),
				starttag(doc, node),
			)
			msg := error(doc, text, {base_node = node})
			if msgnode != 0 do append_child(doc, msgnode, msg)
		}
		return id
	}
	id := generate_id(doc, node, suggested_prefix)
	list_append(doc, node, K_IDS, id)
	om_set(&doc.ids, id, node)
	return id
}

@(private = "file")
id_taken :: proc(doc: ^Doc, id: string) -> bool {
	k, ok := lookup(doc, id)
	return ok && om_has(&doc.ids, k)
}

@(private = "file")
generate_id :: proc(doc: ^Doc, node: Node, suggested_prefix: string) -> Str {
	ta := context.temp_allocator
	id_prefix := doc.settings.id_prefix
	auto_prefix := doc.settings.auto_id_prefix
	base_id, id: string
	for name in attr_list(doc, node, K_NAMES) {
		if id_prefix != "" { 	// allow names starting with numbers
			base_id = make_id(strings.concatenate({"x", str(doc, name)}, ta))[1:]
		} else {
			base_id = make_id(str(doc, name))
		}
		id = strings.concatenate({id_prefix, base_id}, ta)
		if base_id != "" && !id_taken(doc, id) do return intern(doc, id)
	}
	prefix: string
	if base_id != "" && strings.has_suffix(auto_prefix, "%") {
		prefix = strings.concatenate({id, "-"}, ta) // disambiguate name-derived ID
	} else {
		prefix = strings.concatenate({id_prefix, auto_prefix}, ta)
		if strings.has_suffix(prefix, "%") {
			tag_id := suggested_prefix
			if tag_id == "" do tag_id = make_id(tagname(doc, node))
			prefix = strings.concatenate({prefix[:len(prefix) - 1], tag_id, "-"}, ta)
		}
	}
	counter := om_ptr(&doc.id_counter, intern(doc, prefix))
	for {
		counter^ += 1
		id = fmt.tprintf("%s%d", prefix, counter^)
		if !id_taken(doc, id) do return intern(doc, id)
	}
}

// ``document.set_name_id_map(node, id, msgnode, explicit)``: map the names
// of ``node`` to ``id``, resolving duplicates (see
// ``set_duplicate_name_id``).
set_name_id_map :: proc(doc: ^Doc, node: Node, id: Str, msgnode: Node = 0, explicit := false) {
	names := make([dynamic]Str, 0, 2, context.temp_allocator)
	for x in attr_list(doc, node, K_NAMES) do append(&names, x)
	for name in names {
		if om_has(&doc.nameids, name) {
			set_duplicate_name_id(doc, node, id, name, msgnode, explicit)
		} else {
			om_set(&doc.nameids, name, id)
			om_set(&doc.nametypes, name, explicit)
		}
	}
}

// ``'key' in node and node['key'] == old.get('key')``.
@(private = "file")
same_reference :: proc(doc: ^Doc, node, old: Node, key: Str) -> bool {
	v, ok := get_attr(doc, node, key)
	if !ok || old == 0 do return false
	w, _ := get_attr(doc, old, key)
	return attr_equal(doc, v, w)
}

@(private)
attr_equal :: proc(doc: ^Doc, a, b: Attr_Value) -> bool {
	switch x in a {
	case string:
		y, ok := b.(string)
		return ok && x == y
	case int:
		y, ok := b.(int)
		return ok && x == y
	case bool:
		y, ok := b.(bool)
		return ok && x == y
	case Attr_None:
		_, ok := b.(Attr_None)
		return ok
	case List:
		y, ok := b.(List)
		if !ok || len(doc.lists[x]) != len(doc.lists[y]) do return false
		for s, i in doc.lists[x] do if s != doc.lists[y][i] do return false
		return true
	}
	return b == nil
}

// Python truthiness of an attribute value.
@(private)
attr_truthy :: proc(doc: ^Doc, v: Attr_Value) -> bool {
	switch x in v {
	case string:
		return x != ""
	case int:
		return x != 0
	case bool:
		return x
	case List:
		return len(doc.lists[x]) > 0
	case Attr_None:
		return false
	}
	return false
}

@(private = "file")
Dup_Result :: struct {
	level:   int, // system message level: 1-info, 2-warning
	message: string,
}

// ``document.set_duplicate_name_id``: the state transition table of
// ``set_name_id_map`` for a name that is already mapped.
set_duplicate_name_id :: proc(
	doc: ^Doc,
	node: Node,
	id: Str,
	name: Str,
	msgnode: Node,
	explicit: bool,
) {
	old_id, _ := om_get(&doc.nameids, name) // 0 if name is only dupname
	old_explicit, _ := om_get(&doc.nametypes, name)
	old_node: Node
	if old_id != 0 do old_node, _ = om_get(&doc.ids, old_id)
	om_set(&doc.nametypes, name, old_explicit || explicit)
	r := resolve_duplicate(doc, node, id, name, old_id, old_node, old_explicit, explicit)
	if r.level == 0 do return
	backrefs := []string{str(doc, id)}
	// don't add backref id for empty targets (not shown in output)
	if doc.nodes[node].tag == .target && has_attr(doc, node, K_REFURI) do backrefs = nil
	msg := system_message(doc, Level(r.level), r.message, {backrefs = backrefs, base_node = node})
	// try appending near to the problem:
	if msgnode == 0 do return
	append_child(doc, msgnode, msg)
	if ok, _, _ := validate(doc, msgnode, recursive = false); !ok {
		// detach -> will be handled by `Messages` transform
		pop_child(doc, msgnode)
		doc.nodes[msg].parent = 0
	}
}

@(private = "file")
resolve_duplicate :: proc(
	doc: ^Doc,
	node: Node,
	id, name, old_id: Str,
	old_node: Node,
	old_explicit, explicit: bool,
) -> (
	r: Dup_Result,
) {
	n := str(doc, name)
	if old_id != 0 &&
	   (same_reference(doc, node, old_node, K_REFNAME) ||
			   same_reference(doc, node, old_node, K_REFURI)) {
		// indirect targets with same reference -> keep old target
		ref, _ := get_attr(doc, node, K_REFURI)
		if !attr_truthy(doc, ref) do ref, _ = get_attr(doc, node, K_REFNAME)
		b := strings.builder_make(context.temp_allocator)
		write_py_str(&b, doc, ref)
		msg := "Duplicate name \"%s\" for external target \"%s\"."
		r = {1, fmt.tprintf(msg, n, strings.to_string(b))}
		dupname(doc, node, name)
	} else if explicit && old_explicit {
		r = {2, fmt.tprintf("Duplicate explicit target name: \"%s\".", n)}
		dupname(doc, node, name)
		if old_id != 0 {
			dupname(doc, old_node, name)
			om_set(&doc.nameids, name, Str(0))
		}
	} else if explicit { 	// new explicit, old implicit -> override
		om_set(&doc.nameids, name, id)
		if old_id != 0 {
			r = {1, fmt.tprintf("Target name overrides implicit target name \"%s\".", n)}
			dupname(doc, old_node, name)
		}
	} else { 	// new name is implicit
		r = {1, fmt.tprintf("Duplicate implicit target name: \"%s\".", n)}
		dupname(doc, node, name)
		if old_id != 0 && !old_explicit {
			dupname(doc, old_node, name)
			om_set(&doc.nameids, name, Str(0))
		}
	}
	return
}

// ``document.has_name(name)``.
has_name :: proc(doc: ^Doc, name: string) -> bool {
	k, ok := lookup(doc, name)
	return ok && om_has(&doc.nameids, k)
}

// ``document.note_implicit_target(target, msgnode)``.
note_implicit_target :: proc(doc: ^Doc, target: Node, msgnode: Node = 0) {
	id := set_id(doc, target, msgnode)
	set_name_id_map(doc, target, id, msgnode, explicit = false)
}

// ``document.note_explicit_target(target, msgnode)``.
note_explicit_target :: proc(doc: ^Doc, target: Node, msgnode: Node = 0) {
	id := set_id(doc, target, msgnode)
	set_name_id_map(doc, target, id, msgnode, explicit = true)
}

// --- references --------------------------------------------------------------------

@(private = "file")
add_ref :: proc(doc: ^Doc, m: ^Ordered_Map([dynamic]Node), node: Node, key: Str) {
	v, _ := get_attr(doc, node, key)
	b := strings.builder_make(context.temp_allocator)
	write_py_str(&b, doc, v)
	list := om_ptr(m, intern(doc, strings.to_string(b)))
	if list.allocator.procedure == nil do list^ = make([dynamic]Node, doc.allocator)
	append(list, node)
}

// ``document.note_refname(node)``.
note_refname :: proc(doc: ^Doc, node: Node) {
	add_ref(doc, &doc.refnames, node, K_REFNAME)
}

// ``document.note_refid(node)``.
note_refid :: proc(doc: ^Doc, node: Node) {
	add_ref(doc, &doc.refids, node, K_REFID)
}

// ``document.note_indirect_target(target)``.
note_indirect_target :: proc(doc: ^Doc, target: Node) {
	append(&doc.indirect_targets, target)
	if len(attr_list(doc, target, K_NAMES)) > 0 do note_refname(doc, target)
}

// ``document.note_anonymous_target(target)``.
note_anonymous_target :: proc(doc: ^Doc, target: Node) {
	set_id(doc, target)
}

note_autofootnote :: proc(doc: ^Doc, footnote: Node) {
	set_id(doc, footnote)
	append(&doc.autofootnotes, footnote)
}

note_autofootnote_ref :: proc(doc: ^Doc, ref: Node) {
	set_id(doc, ref)
	append(&doc.autofootnote_refs, ref)
}

note_symbol_footnote :: proc(doc: ^Doc, footnote: Node) {
	set_id(doc, footnote)
	append(&doc.symbol_footnotes, footnote)
}

note_symbol_footnote_ref :: proc(doc: ^Doc, ref: Node) {
	set_id(doc, ref)
	append(&doc.symbol_footnote_refs, ref)
}

note_footnote :: proc(doc: ^Doc, footnote: Node) {
	set_id(doc, footnote)
	append(&doc.footnotes, footnote)
}

note_footnote_ref :: proc(doc: ^Doc, ref: Node) {
	set_id(doc, ref)
	add_ref(doc, &doc.footnote_refs, ref, K_REFNAME)
	note_refname(doc, ref)
}

note_citation :: proc(doc: ^Doc, citation: Node) {
	append(&doc.citations, citation)
}

note_citation_ref :: proc(doc: ^Doc, ref: Node) {
	set_id(doc, ref)
	add_ref(doc, &doc.citation_refs, ref, K_REFNAME)
	note_refname(doc, ref)
}

// --- substitutions, pending transforms, messages ---------------------------------------

// ``document.note_substitution_def(subdef, def_name, msgnode)``.
note_substitution_def :: proc(doc: ^Doc, subdef: Node, def_name: string, msgnode: Node = 0) {
	name := intern(doc, whitespace_normalize_name(def_name))
	if old, ok := om_get(&doc.substitution_defs, name); ok {
		text := fmt.tprintf("Duplicate substitution definition name: \"%s\".", str(doc, name))
		msg := error(doc, text, {base_node = subdef})
		if msgnode != 0 do append_child(doc, msgnode, msg)
		dupname(doc, old, name)
	}
	// keep only the last definition:
	om_set(&doc.substitution_defs, name, subdef)
	// case-insensitive mapping:
	om_set(&doc.substitution_names, intern(doc, fully_normalize_name(str(doc, name))), name)
}

// ``document.note_substitution_ref(subref, refname)``.
note_substitution_ref :: proc(doc: ^Doc, subref: Node, refname: string) {
	set_attr(doc, subref, K_REFNAME, whitespace_normalize_name(refname))
}

// ``document.note_pending(pending, priority)``: queue the pending transform
// (``Transformer.add_pending``); ``priority`` defaults to the transform's
// ``default_priority``.
note_pending :: proc(doc: ^Doc, pending: Node, priority: Maybe(int) = nil) {
	data := pending_of(doc, pending)
	doc.transform_serial += 1
	append(
		&doc.pending_queue,
		Queued_Pending {
			priority = priority.? or_else data.default_priority,
			serial = doc.transform_serial,
			node = pending,
			transform = data.transform,
		},
	)
}

note_parse_message :: proc(doc: ^Doc, message: Node) {
	append(&doc.parse_messages, message)
}

note_transform_message :: proc(doc: ^Doc, message: Node) {
	append(&doc.transform_messages, message)
}

// ``document.get_decoration()``: the ``decoration`` element, created after
// the titles and ``meta`` elements if missing.
get_decoration :: proc(doc: ^Doc) -> Node {
	if doc.decoration == 0 {
		doc.decoration = new_element(doc, .decoration)
		i := first_child_not_matching_class(doc, doc.root, tags_of(.Titular) + {.meta})
		if i < 0 {
			append_child(doc, doc.root, doc.decoration)
		} else {
			insert_child(doc, doc.root, i, doc.decoration)
		}
	}
	return doc.decoration
}

// ``decoration.get_header()``.
get_header :: proc(doc: ^Doc, decoration: Node) -> Node {
	first := doc.nodes[decoration].first
	if first == 0 || doc.nodes[first].tag != .header {
		insert_child(doc, decoration, 0, new_element(doc, .header))
	}
	return doc.nodes[decoration].first
}

// ``decoration.get_footer()``.
get_footer :: proc(doc: ^Doc, decoration: Node) -> Node {
	last := doc.nodes[decoration].last
	if last == 0 || doc.nodes[last].tag != .footer {
		append_child(doc, decoration, new_element(doc, .footer))
	}
	return doc.nodes[decoration].last
}
