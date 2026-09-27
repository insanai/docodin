package transforms

import "core:fmt"
import "core:strings"

import dt "../doctree"

// ``docutils.transforms.references``: ``Substitutions``, ``TargetNotes``
// and ``DanglingReferences``.

// --- Substitutions -------------------------------------------------------------

@(private = "file")
Substituter :: struct {
	r:          ^Run,
	doc:        ^dt.Doc,
	nested:     map[dt.Str][dynamic]dt.Str,
	subreflist: [dynamic]dt.Node,
}

// ``Substitutions``: replace each substitution reference by (a copy of) the
// contents of its definition, following nested references and reporting
// circular ones.
substitutions :: proc(r: ^Run, _: dt.Node, _: []dt.Detail) {
	doc := r.doc
	ta := context.temp_allocator
	s := Substituter {
		r          = r,
		doc        = doc,
		nested     = make(map[dt.Str][dynamic]dt.Str, 8, ta),
		subreflist = make([dynamic]dt.Node, 0, 16, ta),
	}
	append(&s.subreflist, ..dt.traverse(doc, doc.root, dt.Tag_Set{.substitution_reference}))
	// Mutually nested definitions can escape docutils' circularity check and
	// expand forever: stop at a generous bound.
	limit := 100 * (len(s.subreflist) + len(doc.substitution_defs.keys)) + 10_000
	node_limit := 50 * dt.node_count(doc) + 1_000_000
	for i := 0; i < len(s.subreflist) && r.err == nil; i += 1 {
		if i > limit || dt.node_count(doc) > node_limit {
			fail(r, "Substitutions: the expansion of nested substitutions does not terminate")
			return
		}
		substitute(&s, s.subreflist[i])
	}
}

// The definition name of a reference name (exact, else case-insensitive).
@(private = "file")
definition_key :: proc(doc: ^dt.Doc, refname: string) -> (dt.Str, bool) {
	k, ok := dt.lookup(doc, refname)
	if ok && dt.om_has(&doc.substitution_defs, k) do return k, true
	normed, found := dt.lookup(doc, dt.py_lower(refname))
	if !found do return 0, false
	return dt.om_get(&doc.substitution_names, normed)
}

// The definition a reference refers to; 0 (after an error message) if it is
// undefined or too long.
@(private = "file")
reference_definition :: proc(s: ^Substituter, ref: dt.Node, refname: string) -> (dt.Str, dt.Node) {
	doc := s.doc
	key, found := definition_key(doc, refname)
	msg: dt.Node
	subdef: dt.Node
	if !found {
		text := fmt.tprintf(`Undefined substitution referenced: "%s".`, refname)
		msg = dt.error(doc, text, {base_node = ref})
	} else {
		subdef, _ = dt.om_get(&doc.substitution_defs, key)
		if py_len(dt.astext(doc, subdef)) > doc.settings.line_length_limit {
			text := `Substitution definition "%s" exceeds the line-length-limit.`
			msg = dt.error(doc, fmt.tprintf(text, dt.str(doc, key)))
		}
	}
	if msg == 0 do return key, subdef
	report_problematic(doc, ref, msg)
	return 0, 0
}

@(private = "file")
substitute :: proc(s: ^Substituter, ref: dt.Node) {
	doc := s.doc
	refname := attr_text(doc, ref, dt.K_REFNAME)
	key, subdef := reference_definition(s, ref, refname)
	if subdef == 0 do return
	trim_around(doc, ref, subdef)
	subdef_copy := deepcopy_with_origin(s.r, subdef)
	switch note_nested(s, ref, key, subdef_copy) {
	case .Error:
		return
	case .Circular:
		circular_substitution(s, ref, refname)
		return
	case .Ok:
	}
	kids := dt.children(doc, subdef_copy)
	dt.replace_self_list(doc, ref, kids)
	// register the refnames of the replacement nodes
	for n in kids {
		if !dt.is_a(doc, n, .Referential) || !dt.has_attr(doc, n, dt.K_REFNAME) do continue
		dt.note_refname(doc, n)
	}
}

@(private = "file")
Nested :: enum u8 {
	Ok,
	Circular,
	Error,
}

// Queue the references nested in a definition's copy, detecting circular
// definitions (as far as docutils does).
@(private = "file")
note_nested :: proc(s: ^Substituter, ref: dt.Node, key: dt.Str, subdef_copy: dt.Node) -> Nested {
	doc := s.doc
	it := dt.findall(doc, subdef_copy, dt.Tag_Set{.substitution_reference})
	for nested_ref in dt.next(&it) {
		nested_key := dt.py_lower(attr_text(doc, nested_ref, dt.K_REFNAME))
		k, has_k := dt.lookup(doc, nested_key)
		nested_name, ok := dt.om_get(&doc.substitution_names, k)
		if !has_k || !ok {
			key_error(s.r, nested_key)
			return .Error
		}
		list := s.nested[nested_name] or_else make([dynamic]dt.Str, context.temp_allocator)
		if contains_key(list[:], nested_name) do return .Circular
		append(&list, key)
		s.nested[nested_name] = list
		s.r.ref_origin[nested_ref] = ref
		append(&s.subreflist, nested_ref)
	}
	return .Ok
}

@(private = "file")
contains_key :: proc(list: []dt.Str, key: dt.Str) -> bool {
	for x in list do if x == key do return true
	return false
}

// The ``ltrim``/``rtrim``/``trim`` options: strip the whitespace of the
// text before/after the reference.
@(private = "file")
trim_around :: proc(doc: ^dt.Doc, ref, subdef: dt.Node) {
	parent := dt.parent(doc, ref)
	index := dt.index_identity(doc, parent, ref)
	trim := dt.has_attr(doc, subdef, "trim")
	if trim || dt.has_attr(doc, subdef, "ltrim") {
		prev := dt.child_at(doc, parent, index - 1)
		if index > 0 && dt.tag(doc, prev) == .Text {
			set_child_at(doc, parent, index - 1, dt.new_text(doc, py_rstrip(dt.text(doc, prev))))
		}
	}
	if trim || dt.has_attr(doc, subdef, "rtrim") {
		next := dt.child_at(doc, parent, index + 1)
		if next != 0 && dt.tag(doc, next) == .Text {
			set_child_at(doc, parent, index + 1, dt.new_text(doc, py_lstrip(dt.text(doc, next))))
		}
	}
}

// ``subdef.deepcopy()``: the copies of references carry their
// ``ref-origin``.
@(private = "file")
deepcopy_with_origin :: proc(r: ^Run, n: dt.Node) -> dt.Node {
	doc := r.doc
	c := dt.deepcopy(doc, n)
	if len(r.ref_origin) > 0 do copy_origins(r, n, c)
	return c
}

@(private = "file")
copy_origins :: proc(r: ^Run, n, c: dt.Node) {
	doc := r.doc
	if origin, ok := r.ref_origin[n]; ok do r.ref_origin[c] = origin
	a, b := dt.first_child(doc, n), dt.first_child(doc, c)
	for a != 0 && b != 0 {
		copy_origins(r, a, b)
		a, b = dt.next_sibling(doc, a), dt.next_sibling(doc, b)
	}
}

@(private = "file")
circular_substitution :: proc(s: ^Substituter, ref: dt.Node, refname: string) {
	doc := s.doc
	parent := dt.parent(doc, ref)
	if dt.tag(doc, parent) == .substitution_definition {
		raw := dt.text(doc, parent)
		opts := dt.Message_Options {
			base_node = parent,
			children  = {dt.new_element(doc, .literal_block, raw, raw)},
		}
		if l, ok := dt.line(doc, parent); ok do opts.line = l
		msg := dt.error(doc, "Circular substitution definition detected:", opts)
		dt.replace_self(doc, parent, msg)
		return
	}
	// the original reference that caused this error
	origin := ref
	for {
		o, ok := s.r.ref_origin[origin]
		if !ok do break
		origin = o
	}
	text := fmt.tprintf(`Circular substitution definition referenced: "%s".`, refname)
	report_problematic(doc, ref, dt.error(doc, text, {base_node = origin}))
}

// --- TargetNotes --------------------------------------------------------------------

@(private = "file")
Target_Notes :: struct {
	doc:     ^dt.Doc,
	classes: []string,
	notes:   map[string]dt.Node, // refuri -> footnote
	trim:    bool,
}

// ``TargetNotes``: a footnote for each external target (and anonymous
// external reference) that is referenced, with footnote references after
// the references; the footnotes replace the pending element.
target_notes :: proc(r: ^Run, pending: dt.Node, _: []dt.Detail) {
	doc := r.doc
	tn := Target_Notes {
		doc     = doc,
		classes = detail_strings(doc, pending, "class"),
		notes   = make(map[string]dt.Node, 8, context.temp_allocator),
		trim    = trim_footnote_ref_space(doc),
	}
	nodelist := make([dynamic]dt.Node, 0, 8, context.temp_allocator)
	it := dt.findall(doc, doc.root, dt.Tag_Set{.target})
	for target in dt.next(&it) {
		if !dt.has_attr(doc, target, dt.K_REFURI) do continue
		refs := make([dynamic]dt.Node, 0, 4, context.temp_allocator)
		for name in dt.attr_list(doc, target, dt.K_NAMES) {
			append(&refs, ..refs_of(&doc.refnames, name))
		}
		if len(refs) == 0 do continue
		add_note(&tn, &nodelist, attr_text(doc, target, dt.K_REFURI), refs[:])
	}
	it = dt.findall(doc, doc.root, dt.Tag_Set{.reference})
	for ref in dt.next(&it) {
		if !attr_truthy(doc, ref, "anonymous") || !dt.has_attr(doc, ref, dt.K_REFURI) do continue
		add_note(&tn, &nodelist, attr_text(doc, ref, dt.K_REFURI), {ref})
	}
	py_replace_self(r, pending, ..nodelist[:])
}

@(private = "file")
add_note :: proc(tn: ^Target_Notes, nodelist: ^[dynamic]dt.Node, refuri: string, refs: []dt.Node) {
	footnote := make_target_footnote(tn, refuri, refs)
	if refuri in tn.notes do return
	tn.notes[strings.clone(refuri, context.temp_allocator)] = footnote
	append(nodelist, footnote)
}

@(private = "file")
make_target_footnote :: proc(tn: ^Target_Notes, refuri: string, refs: []dt.Node) -> dt.Node {
	doc := tn.doc
	footnote, dup := tn.notes[refuri]
	footnote_name: string
	if dup {
		name, _ := first_item(doc, footnote, dt.K_NAMES)
		footnote_name = dt.str(doc, name)
	} else {
		footnote = dt.new_element(doc, .footnote)
		footnote_id := dt.set_id(doc, footnote)
		// uppercase letters and a colon: the parser cannot produce them in names
		id := dt.str(doc, footnote_id)
		footnote_name = strings.concatenate({"TARGET_NOTE: ", id}, context.temp_allocator)
		dt.set_attr(doc, footnote, "auto", 1)
		dt.set_list(doc, footnote, dt.K_NAMES, footnote_name)
		paragraph := dt.new_element(doc, .paragraph)
		ref := dt.new_element(doc, .reference, "", refuri)
		dt.set_attr(doc, ref, dt.K_REFURI, refuri)
		dt.append_child(doc, paragraph, ref)
		dt.append_child(doc, footnote, paragraph)
		dt.note_autofootnote(doc, footnote)
		dt.note_explicit_target(doc, footnote, footnote)
	}
	for ref in refs {
		if dt.tag(doc, ref) != .target do add_footnote_reference(tn, ref, footnote_name)
	}
	return footnote
}

@(private = "file")
add_footnote_reference :: proc(tn: ^Target_Notes, ref: dt.Node, footnote_name: string) {
	doc := tn.doc
	refnode := dt.new_element(doc, .footnote_reference)
	dt.set_attr(doc, refnode, dt.K_REFNAME, footnote_name)
	dt.set_attr(doc, refnode, "auto", 1)
	extend_classes(doc, refnode, tn.classes)
	dt.note_autofootnote_ref(doc, refnode)
	dt.note_footnote_ref(doc, refnode)
	parent := dt.parent(doc, ref)
	index := dt.index_identity(doc, parent, ref) + 1
	reflist := make([dynamic]dt.Node, 0, 2, context.temp_allocator)
	if !tn.trim {
		if len(tn.classes) > 0 {
			space := dt.new_element(doc, .inline, "", " ")
			for c in tn.classes do dt.list_append(doc, space, dt.K_CLASSES, c)
			append(&reflist, space)
		} else {
			append(&reflist, dt.new_text(doc, " "))
		}
	}
	append(&reflist, refnode)
	dt.insert_children(doc, parent, index, reflist[:])
}

// --- DanglingReferences -----------------------------------------------------------

@(private = "file")
Dangling_Visitor :: struct {
	using base: Visitor,
	r:          ^Run,
}

// ``DanglingReferences``: resolve the remaining references by name, report
// the unknown ones, then report the unreferenced targets.
dangling_references :: proc(r: ^Run, _: dt.Node, _: []dt.Detail) {
	doc := r.doc
	v := Dangling_Visitor {
		base = {
			doc = doc,
			visit = dangling_visit,
			visit_name = dangling_visit_name,
			depart_name = sparse_visit_name,
		},
		r = r,
	}
	walk(&v, doc.root)
	it := dt.findall(doc, doc.root, dt.Tag_Set{.target})
	for target in dt.next(&it) {
		if dt.has_flag(doc, target, .Referenced) do continue
		if attr_truthy(doc, target, "anonymous") do continue
		naming: string
		if name, ok := first_item(doc, target, dt.K_NAMES); ok {
			naming = dt.str(doc, name)
		} else if id, has_id := first_item(doc, target, dt.K_IDS); has_id {
			naming = dt.str(doc, id)
		} else {
			naming = attr_text(doc, target, dt.K_REFID)
		}
		text := fmt.tprintf(`Hyperlink target "%s" is not referenced.`, naming)
		dt.info(doc, text, {base_node = target})
	}
}

@(private = "file")
REFERENCES :: dt.Tag_Set{.reference, .footnote_reference, .citation_reference}

@(private = "file")
dangling_visit_name :: proc(t: dt.Tag) -> string {
	if t in REFERENCES do return "visit_reference"
	return sparse_visit_name(t)
}

@(private = "file")
dangling_visit :: proc(v: ^Visitor, node: dt.Node) -> Visit {
	doc := v.doc
	if !dt.is(doc, node, REFERENCES) do return .Continue
	if dt.has_flag(doc, node, .Resolved) do return .Continue
	if !dt.has_attr(doc, node, dt.K_REFNAME) do return .Continue
	refname := attr_text(doc, node, dt.K_REFNAME)
	k, interned := dt.lookup(doc, refname)
	id, known := dt.om_get(&doc.nameids, k)
	known = known && interned
	if known && id != 0 {
		dt.delete_attr(doc, node, dt.K_REFNAME)
		dt.set_attr(doc, node, dt.K_REFID, dt.str(doc, id))
		target, _ := dt.om_get(&doc.ids, id)
		if target != 0 do note_referenced_by(doc, target, id = id)
		dt.set_flag(doc, node, .Resolved)
		return .Continue
	}
	msg: dt.Node
	if known {
		text := `Duplicate target name, cannot be used as a unique reference: "%s".`
		msg = dt.error(doc, fmt.tprintf(text, refname), {base_node = node})
	} else {
		opts := dt.Message_Options {
			base_node = node,
		}
		if hint := embedding_hint(refname); hint != "" {
			opts.children = {dt.new_element(doc, .paragraph, "", hint)}
		}
		msg = dt.error(doc, fmt.tprintf(`Unknown target name: "%s".`, refname), opts)
	}
	msgid := dt.set_id(doc, msg)
	raw := dt.text(doc, node)
	prb := dt.new_element(doc, .problematic, raw, raw)
	dt.set_attr(doc, prb, dt.K_REFID, dt.str(doc, msgid))
	prbid, has_id := first_item(doc, node, dt.K_IDS)
	if !has_id do prbid = dt.set_id(doc, prb)
	dt.add_backref(doc, msg, prbid)
	dt.replace_self(doc, node, prb)
	return .Continue
}

// The hint for a reference name that looks like a failed embedded URI.
@(private = "file")
embedding_hint :: proc(refname: string) -> string {
	has :: strings.contains
	if !has(refname, "<") && !has(refname, ">") do return ""
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "Did you want to embed a URI or alias?")
	if !has(refname, "<") {
		strings.write_string(&b, "\nOpening bracket missing.")
	} else if !has(refname, " <") {
		strings.write_string(&b, "\nThe embedded reference must be preceded by whitespace.")
	}
	if !has(refname, ">") {
		strings.write_string(&b, "\nClosing bracket missing.")
	} else if !strings.has_suffix(refname, ">") {
		last := "\nThe embedded reference must be the last text before the end string."
		strings.write_string(&b, last)
	}
	if has(refname, "< ") || has(refname, " >") {
		strings.write_string(&b, "\nWhitespace around the embedded reference is not allowed.")
	}
	return strings.to_string(b)
}
