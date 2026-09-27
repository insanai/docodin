package transforms

import "core:fmt"
import "core:strings"

import dt "../doctree"

// ``docutils.transforms.references``: targets, hyperlinks and footnotes
// (``Substitutions``, ``TargetNotes`` and ``DanglingReferences`` are in
// references_resolve.odin).

// The list of ``m[key]`` (``m.get(key, [])``) as it is now.
refs_of :: proc(m: ^dt.Ordered_Map([dynamic]dt.Node), key: dt.Str) -> []dt.Node {
	l, _ := dt.om_get(m, key)
	return l[:]
}

// ``m.get(name)`` for a name given as text.
@(private = "file")
lookup_str :: proc(doc: ^dt.Doc, m: ^dt.Ordered_Map($V), name: string) -> (V, bool) {
	k, ok := dt.lookup(doc, name)
	if !ok do return {}, false
	return dt.om_get(m, k)
}

// ``node[key] = other[key]``.
@(private = "file")
copy_attr :: proc(doc: ^dt.Doc, node, other: dt.Node, key: dt.Str) {
	v, _ := dt.get_attr(doc, other, key)
	dt.set_attr(doc, node, key, v)
}

// --- PropagateTargets --------------------------------------------------------

// ``PropagateTargets``: the ids and names of an empty internal target go
// to the next element, which the target then refers to.
propagate_targets :: proc(r: ^Run, _: dt.Node, _: []dt.Detail) {
	doc := r.doc
	it := dt.findall(doc, doc.root, dt.Tag_Set{.target})
	for target in dt.next(&it) {
		if dt.is_a(doc, dt.parent(doc, target), .TextElement) do continue
		if dt.has_attr(doc, target, dt.K_REFID) || dt.has_attr(doc, target, dt.K_REFURI) ||
		   dt.has_attr(doc, target, dt.K_REFNAME) {
			continue
		}
		next := dt.next_node(doc, target, ascend = true)
		for dt.is(doc, next, {.system_message}) {
			next = dt.next_node(doc, next, ascend = true, descend = false)
		}
		if next == 0 do continue
		if (dt.is_a(doc, next, .Invisible) || dt.is_a(doc, next, .Targetable)) &&
		   dt.tag(doc, next) != .target {
			continue
		}
		propagate(r, target, next)
	}
}

@(private = "file")
propagate :: proc(r: ^Run, target, next: dt.Node) {
	doc := r.doc
	ids := clone_strs(dt.attr_list(doc, target, dt.K_IDS))
	names := clone_strs(dt.attr_list(doc, target, dt.K_NAMES))
	for id in ids do dt.list_append(doc, next, dt.K_IDS, id)
	for name in names do dt.list_append(doc, next, dt.K_NAMES, name)
	ni := ensure_expect_maps(doc, next)
	for id in ids {
		dt.om_set(&doc.ids, id, next)
		expect_set(&ni.expect_referenced_by_id, id, target)
	}
	for name in names do expect_set(&ni.expect_referenced_by_name, name, target)
	if tni, ok := doc.internals[target]; ok {
		by_name, by_id := &ni.expect_referenced_by_name, &ni.expect_referenced_by_id
		for e in tni.expect_referenced_by_name do expect_set(by_name, e.name, e.node)
		for e in tni.expect_referenced_by_id do expect_set(by_id, e.name, e.node)
	}
	doc.internals[next] = ni
	if dt.is(doc, dt.parent(doc, target), {.figure}) && dt.is(doc, next, {.caption}) {
		py_remove(r, target)
		return
	}
	if len(ids) == 0 {
		fail(r, "IndexError: list index out of range")
		return
	}
	dt.set_attr(doc, target, dt.K_REFID, dt.str(doc, ids[0]))
	dt.set_list(doc, target, dt.K_IDS)
	dt.set_list(doc, target, dt.K_NAMES)
	dt.note_refid(doc, target)
}

clone_strs :: proc(items: []dt.Str) -> []dt.Str {
	out := make([]dt.Str, len(items), context.temp_allocator)
	copy(out, items)
	return out
}

// The internals of ``n`` with both ``expect_referenced_by_*`` maps.
@(private = "file")
ensure_expect_maps :: proc(doc: ^dt.Doc, n: dt.Node) -> dt.Node_Internals {
	ni := ensure_internals(doc, n)
	if ni.expect_referenced_by_id == nil {
		ni.expect_referenced_by_id = make([dynamic]dt.Name_Ref, doc.allocator)
	}
	if ni.expect_referenced_by_name == nil {
		ni.expect_referenced_by_name = make([dynamic]dt.Name_Ref, doc.allocator)
	}
	return ni
}

// --- AnonymousHyperlinks ------------------------------------------------------

@(private = "file")
anonymous_of :: proc(doc: ^dt.Doc, t: dt.Tag) -> []dt.Node {
	out := make([dynamic]dt.Node, 0, 8, context.temp_allocator)
	for n in dt.traverse(doc, doc.root, dt.Tag_Set{t}) {
		if attr_truthy(doc, n, "anonymous") do append(&out, n)
	}
	return out[:]
}

// ``AnonymousHyperlinks``: link anonymous references to anonymous targets
// in order.
anonymous_hyperlinks :: proc(r: ^Run, _: dt.Node, _: []dt.Detail) {
	doc := r.doc
	refs := anonymous_of(doc, .reference)
	targets := anonymous_of(doc, .target)
	if len(refs) != len(targets) {
		text := fmt.tprintf(
			"Anonymous hyperlink mismatch: %d references but %d targets.\n" +
			"See \"backrefs\" attribute for IDs.",
			len(refs),
			len(targets),
		)
		msg := dt.error(doc, text)
		msgid := dt.set_id(doc, msg)
		for ref in refs do dt.replace_self(doc, ref, new_problematic(doc, ref, msg, msgid))
		return
	}
	for ref, i in refs {
		if dt.has_attr(doc, ref, dt.K_REFID) || dt.has_attr(doc, ref, dt.K_REFURI) do continue
		target := targets[i]
		dt.set_flag(doc, target, .Referenced)
		for {
			if dt.has_attr(doc, target, dt.K_REFURI) {
				copy_attr(doc, ref, target, dt.K_REFURI)
				dt.set_flag(doc, ref, .Resolved)
				break
			}
			id, has_id := first_item(doc, target, dt.K_IDS)
			if has_id {
				dt.set_attr(doc, ref, dt.K_REFID, dt.str(doc, id))
				dt.note_refid(doc, ref)
				break
			}
			// a propagated target
			next, ok := lookup_str(doc, &doc.ids, attr_text(doc, target, dt.K_REFID))
			if !ok {
				fail(r, "KeyError: %s", attr_text(doc, target, dt.K_REFID))
				return
			}
			target = next
		}
	}
}

// --- IndirectHyperlinks -----------------------------------------------------------

@(private = "file")
Indirect :: struct {
	r:        ^Run,
	doc:      ^dt.Doc,
	multiply: map[dt.Node]struct{}, // ``target.multiply_indirect``
}

// ``IndirectHyperlinks``: indirect targets take the ``refuri`` or
// ``refid`` of their final target, and so do their references.
indirect_hyperlinks :: proc(r: ^Run, _: dt.Node, _: []dt.Detail) {
	doc := r.doc
	st := Indirect {
		r        = r,
		doc      = doc,
		multiply = make(map[dt.Node]struct{}, 8, context.temp_allocator),
	}
	for i := 0; i < len(doc.indirect_targets) && r.err == nil; i += 1 {
		target := doc.indirect_targets[i]
		if !dt.has_flag(doc, target, .Resolved) do resolve_indirect_target(&st, target)
		resolve_indirect_references(&st, target)
	}
}

@(private = "file")
resolve_indirect_target :: proc(st: ^Indirect, target: dt.Node) {
	doc := st.doc
	refname, has_refname := dt.get_attr(doc, target, dt.K_REFNAME)
	reftarget_id: dt.Str
	if !has_refname {
		reftarget_id = dt.intern(doc, attr_text(doc, target, dt.K_REFID))
	} else {
		b := strings.builder_make(context.temp_allocator)
		dt.write_py_str(&b, doc, refname)
		id, _ := lookup_str(doc, &doc.nameids, strings.to_string(b))
		if id == 0 {
			nonexistent_indirect_target(st, target)
			return
		}
		reftarget_id = id
	}
	reftarget, ok := dt.om_get(&doc.ids, reftarget_id)
	if !ok {
		fail(st.r, "KeyError: %q", dt.str(doc, reftarget_id))
		return
	}
	note_referenced_by(doc, reftarget, id = reftarget_id)
	if dt.tag(doc, reftarget) == .target && !dt.has_flag(doc, reftarget, .Resolved) &&
	   dt.has_attr(doc, reftarget, dt.K_REFNAME) {
		if target in st.multiply {
			indirect_target_error(st, target, "forming a circular reference")
			return
		}
		st.multiply[target] = {}
		resolve_indirect_target(st, reftarget) // multiply indirect
		delete_key(&st.multiply, target)
	}
	if !take_reference(st, target, reftarget, reftarget_id) do return
	if has_refname do dt.delete_attr(doc, target, dt.K_REFNAME)
	dt.set_flag(doc, target, .Resolved)
}

// The target takes the reference of its (resolved) reference target;
// false if there is none.
@(private = "file")
take_reference :: proc(st: ^Indirect, target, reftarget: dt.Node, reftarget_id: dt.Str) -> bool {
	doc := st.doc
	switch {
	case dt.has_attr(doc, reftarget, dt.K_REFURI):
		copy_attr(doc, target, reftarget, dt.K_REFURI)
		if dt.has_attr(doc, target, dt.K_REFID) do dt.delete_attr(doc, target, dt.K_REFID)
	case dt.has_attr(doc, reftarget, dt.K_REFID):
		copy_attr(doc, target, reftarget, dt.K_REFID)
		dt.note_refid(doc, target)
	case len(dt.attr_list(doc, reftarget, dt.K_IDS)) > 0:
		dt.set_attr(doc, target, dt.K_REFID, dt.str(doc, reftarget_id))
		dt.note_refid(doc, target)
	case:
		nonexistent_indirect_target(st, target)
		return false
	}
	return true
}

@(private = "file")
nonexistent_indirect_target :: proc(st: ^Indirect, target: dt.Node) {
	doc := st.doc
	if _, ok := lookup_str(doc, &doc.nameids, attr_text(doc, target, dt.K_REFNAME)); ok {
		msg := "which is a duplicate, and cannot be used as a unique reference"
		indirect_target_error(st, target, msg)
	} else {
		indirect_target_error(st, target, "which does not exist")
	}
}

@(private = "file")
indirect_target_error :: proc(st: ^Indirect, target: dt.Node, explanation: string) {
	doc := st.doc
	ta := context.temp_allocator
	naming := ""
	reflist := make([dynamic]dt.Node, 0, 8, ta)
	names := dt.attr_list(doc, target, dt.K_NAMES)
	ids := dt.attr_list(doc, target, dt.K_IDS)
	if len(names) > 0 do naming = fmt.tprintf(`"%s" `, dt.str(doc, names[0]))
	for name in names do append(&reflist, ..refs_of(&doc.refnames, name))
	for id in ids do append(&reflist, ..refs_of(&doc.refids, id))
	if len(ids) > 0 {
		naming = strings.concatenate({naming, fmt.tprintf(`(id="%s")`, dt.str(doc, ids[0]))}, ta)
	}
	text := fmt.tprintf(
		`Indirect hyperlink target %s refers to target "%s", %s.`,
		naming,
		attr_text(doc, target, dt.K_REFNAME),
		explanation,
	)
	msg := dt.error(doc, text, {base_node = target})
	msgid := dt.set_id(doc, msg)
	seen := make(map[dt.Node]struct{}, len(reflist), ta)
	for ref in reflist {
		if ref in seen do continue
		seen[ref] = {}
		prb := new_problematic(doc, ref, msg, msgid)
		if dt.parent(doc, ref) == 0 || !dt.replace_self(doc, ref, prb) {
			fail(st.r, "ValueError: problematic reference is not in the tree")
			return
		}
	}
	dt.set_flag(doc, target, .Resolved)
}

@(private = "file")
resolve_indirect_references :: proc(st: ^Indirect, target: dt.Node) {
	doc := st.doc
	attname: dt.Str
	switch {
	case dt.has_attr(doc, target, dt.K_REFID):
		attname = dt.K_REFID
	case dt.has_attr(doc, target, dt.K_REFURI):
		attname = dt.K_REFURI
	case:
		return
	}
	attval, _ := dt.get_attr(doc, target, attname)
	for name in clone_strs(dt.attr_list(doc, target, dt.K_NAMES)) {
		if len(refs_of(&doc.refnames, name)) > 0 do note_referenced_by(doc, target, name = name)
		resolve_list(st, &doc.refnames, name, dt.K_REFNAME, attname, attval)
	}
	for id in clone_strs(dt.attr_list(doc, target, dt.K_IDS)) {
		if len(refs_of(&doc.refids, id)) > 0 do note_referenced_by(doc, target, id = id)
		resolve_list(st, &doc.refids, id, dt.K_REFID, attname, attval)
	}
}

// Point the unresolved references of ``m[key]`` (a list that may grow
// meanwhile) at ``attname = attval`` instead of ``old``.
@(private = "file")
resolve_list :: proc(
	st: ^Indirect,
	m: ^dt.Ordered_Map([dynamic]dt.Node),
	key, old, attname: dt.Str,
	attval: dt.Attr_Value,
) {
	doc := st.doc
	for i := 0; i < len(refs_of(m, key)); i += 1 {
		ref := refs_of(m, key)[i]
		if dt.has_flag(doc, ref, .Resolved) do continue
		dt.delete_attr(doc, ref, old)
		dt.set_attr(doc, ref, attname, attval)
		if attname == dt.K_REFID do dt.note_refid(doc, ref)
		dt.set_flag(doc, ref, .Resolved)
		if dt.tag(doc, ref) == .target do resolve_indirect_references(st, ref)
	}
}

// --- ExternalTargets, InternalTargets ------------------------------------------------

// ``ExternalTargets``: references to an external target by name take its
// ``refuri``.
external_targets :: proc(r: ^Run, _: dt.Node, _: []dt.Detail) {
	doc := r.doc
	it := dt.findall(doc, doc.root, dt.Tag_Set{.target})
	for target in dt.next(&it) {
		refuri, has := dt.get_attr(doc, target, dt.K_REFURI)
		if !has do continue
		for name in dt.attr_list(doc, target, dt.K_NAMES) {
			reflist := refs_of(&doc.refnames, name)
			if len(reflist) > 0 do note_referenced_by(doc, target, name = name)
			for ref in reflist {
				if dt.has_flag(doc, ref, .Resolved) do continue
				dt.delete_attr(doc, ref, dt.K_REFNAME)
				dt.set_attr(doc, ref, dt.K_REFURI, refuri)
				dt.set_flag(doc, ref, .Resolved)
			}
		}
	}
}

// ``InternalTargets``: references to an internal target by name take its
// id as ``refid``.
internal_targets :: proc(r: ^Run, _: dt.Node, _: []dt.Detail) {
	doc := r.doc
	it := dt.findall(doc, doc.root, dt.Tag_Set{.target})
	for target in dt.next(&it) {
		if dt.has_attr(doc, target, dt.K_REFURI) do continue
		if dt.has_attr(doc, target, dt.K_REFID) do continue
		for name in dt.attr_list(doc, target, dt.K_NAMES) {
			refid, _ := dt.om_get(&doc.nameids, name)
			reflist := refs_of(&doc.refnames, name)
			if len(reflist) > 0 do note_referenced_by(doc, target, name = name)
			for ref in reflist {
				if dt.has_flag(doc, ref, .Resolved) do continue
				if refid != 0 {
					dt.delete_attr(doc, ref, dt.K_REFNAME)
					dt.set_attr(doc, ref, dt.K_REFID, dt.str(doc, refid))
				}
				dt.set_flag(doc, ref, .Resolved)
			}
		}
	}
}

// --- Footnotes -----------------------------------------------------------------------

@(private = "file")
SYMBOLS := [10]string{"*", "†", "‡", "§", "¶", "#", "♠", "♥", "♦", "♣"}

// ``Footnotes``: number the auto-numbered footnotes, label the symbol
// footnotes, and link footnotes and citations with their references.
footnotes :: proc(r: ^Run, _: dt.Node, _: []dt.Detail) {
	doc := r.doc
	labels := make([dynamic]string, 0, 8, context.temp_allocator)
	startnum := doc.autofootnote_start
	doc.autofootnote_start = number_footnotes(doc, startnum, &labels)
	number_footnote_references(r, labels[:])
	if r.err != nil do return
	symbolize_footnotes(doc)
	resolve_footnotes_and_citations(doc)
}

@(private = "file")
new_label :: proc(doc: ^dt.Doc, text: string) -> dt.Node {
	return dt.new_element(doc, .label, "", text)
}

@(private = "file")
number_footnotes :: proc(doc: ^dt.Doc, start: int, labels: ^[dynamic]string) -> int {
	startnum := start
	for i := 0; i < len(doc.autofootnotes); i += 1 {
		footnote := doc.autofootnotes[i]
		label: string
		for {
			label = fmt.aprintf("%d", startnum, allocator = context.temp_allocator)
			startnum += 1
			if !dt.has_name(doc, label) do break
		}
		dt.insert_child(doc, footnote, 0, new_label(doc, label))
		for name in clone_strs(dt.attr_list(doc, footnote, dt.K_NAMES)) {
			for ref in refs_of(&doc.footnote_refs, name) {
				dt.append_child(doc, ref, dt.new_text(doc, label))
				dt.delete_attr(doc, ref, dt.K_REFNAME)
				link_reference(doc, ref, footnote)
				dt.note_refid(doc, ref)
				dt.set_flag(doc, ref, .Resolved)
			}
		}
		if len(dt.attr_list(doc, footnote, dt.K_NAMES)) == 0 &&
		   len(dt.attr_list(doc, footnote, dt.K_DUPNAMES)) == 0 {
			dt.list_append(doc, footnote, dt.K_NAMES, label)
			dt.note_explicit_target(doc, footnote, footnote)
			append(labels, label)
		}
	}
	return startnum
}

// ``ref['refid'] = note['ids'][0]; note.add_backref(ref['ids'][0])``.
@(private = "file")
link_reference :: proc(doc: ^dt.Doc, ref, note: dt.Node) {
	id, _ := first_item(doc, note, dt.K_IDS)
	dt.set_attr(doc, ref, dt.K_REFID, dt.str(doc, id))
	refid, _ := first_item(doc, ref, dt.K_IDS)
	dt.add_backref(doc, note, refid)
}

// Replace the references of ``refs`` (from ``i`` on) that are not resolved
// and lack ``key`` by problematic elements linked to ``msg``.
@(private = "file")
too_many :: proc(doc: ^dt.Doc, refs: []dt.Node, i: int, key: dt.Str, msg: dt.Node) {
	msgid := dt.set_id(doc, msg)
	for ref in refs[i:] {
		if dt.has_flag(doc, ref, .Resolved) || dt.has_attr(doc, ref, key) do continue
		dt.replace_self(doc, ref, new_problematic(doc, ref, msg, msgid))
	}
}

@(private = "file")
number_footnote_references :: proc(r: ^Run, labels: []string) {
	doc := r.doc
	i := 0
	refs := doc.autofootnote_refs[:]
	for ref in refs {
		if dt.has_flag(doc, ref, .Resolved) || dt.has_attr(doc, ref, dt.K_REFID) do continue
		if i >= len(labels) {
			n := len(labels)
			text := fmt.tprintf(
				"Too many autonumbered footnote references: " +
				"only %d corresponding footnote%s available.",
				n,
				"s" if n > 1 else "",
			)
			too_many(doc, refs, i, dt.K_REFNAME, dt.error(doc, text, {base_node = ref}))
			break
		}
		dt.append_child(doc, ref, dt.new_text(doc, labels[i]))
		id, _ := lookup_str(doc, &doc.nameids, labels[i])
		footnote, ok := dt.om_get(&doc.ids, id)
		if id == 0 || !ok {
			fail(r, "KeyError: %s", labels[i])
			return
		}
		dt.set_attr(doc, ref, dt.K_REFID, dt.str(doc, id))
		dt.note_refid(doc, ref)
		refid, _ := first_item(doc, ref, dt.K_IDS)
		dt.add_backref(doc, footnote, refid)
		dt.set_flag(doc, ref, .Resolved)
		i += 1
	}
}

@(private = "file")
symbolize_footnotes :: proc(doc: ^dt.Doc) {
	labels := make([dynamic]string, 0, 8, context.temp_allocator)
	for footnote in doc.symbol_footnotes {
		reps, index := doc.symbol_footnote_start / 10, doc.symbol_footnote_start % 10
		labeltext := strings.repeat(SYMBOLS[index], reps + 1, context.temp_allocator)
		append(&labels, labeltext)
		dt.insert_child(doc, footnote, 0, new_label(doc, labeltext))
		doc.symbol_footnote_start += 1
		dt.set_id(doc, footnote)
	}
	refs := doc.symbol_footnote_refs[:]
	for ref, i in refs {
		if i >= len(labels) {
			text := fmt.tprintf(
				"Too many symbol footnote references: only %d corresponding footnotes available.",
				len(labels),
			)
			too_many(doc, refs, i, dt.K_REFID, dt.error(doc, text, {base_node = ref}))
			break
		}
		dt.append_child(doc, ref, dt.new_text(doc, labels[i]))
		link_reference(doc, ref, doc.symbol_footnotes[i])
		dt.note_refid(doc, ref)
	}
}

@(private = "file")
resolve_footnotes_and_citations :: proc(doc: ^dt.Doc) {
	for footnote in doc.footnotes {
		for label in dt.attr_list(doc, footnote, dt.K_NAMES) {
			if dt.om_has(&doc.footnote_refs, label) {
				resolve_references(doc, footnote, refs_of(&doc.footnote_refs, label))
			}
		}
	}
	for citation in doc.citations {
		for label in dt.attr_list(doc, citation, dt.K_NAMES) {
			if dt.om_has(&doc.citation_refs, label) {
				resolve_references(doc, citation, refs_of(&doc.citation_refs, label))
			}
		}
	}
}

@(private = "file")
resolve_references :: proc(doc: ^dt.Doc, note: dt.Node, reflist: []dt.Node) {
	for ref in reflist {
		if dt.has_flag(doc, ref, .Resolved) do continue
		dt.delete_attr(doc, ref, dt.K_REFNAME)
		link_reference(doc, ref, note)
		dt.set_flag(doc, ref, .Resolved)
	}
	dt.set_flag(doc, note, .Resolved)
}

// --- CitationReferences -------------------------------------------------------------

// ``CitationReferences``: with ``use_bibtex``, citation references without
// a target keep their text (the BibTeX key) and count as resolved.
citation_references :: proc(r: ^Run, _: dt.Node, _: []dt.Detail) {
	doc := r.doc
	if v, ok := raw_setting(doc, "use_bibtex"); ok {
		if !json_truthy(v) do return
	} else if doc.settings.use_bibtex == "" {
		return
	}
	it := dt.findall(doc, doc.root, dt.Tag_Set{.citation_reference})
	for n in dt.next(&it) {
		if dt.has_flag(doc, n, .Resolved) do continue
		if refname, ok := dt.get_attr(doc, n, dt.K_REFNAME); ok {
			b := strings.builder_make(context.temp_allocator)
			dt.write_py_str(&b, doc, refname)
			if id, _ := lookup_str(doc, &doc.nameids, strings.to_string(b)); id != 0 do continue
		}
		if dt.astext(doc, n) != "" {
			dt.delete_attr(doc, n, dt.K_REFNAME)
			dt.set_flag(doc, n, .Resolved)
		}
	}
}
