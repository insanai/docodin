package site

import "core:strings"

import dt "../doctree"

// The toctree graph (Sphinx's ``collect_relations``), section numbers
// (``TocTreeCollector.assign_section_numbers``) and figure numbers
// (``assign_figure_numbers``).

// The toctrees of a document, in document order.
doc_toctrees :: proc(b: ^Build, id: Doc_Id) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for t, i in b.toctrees do if t.doc == id do append(&out, i)
	return out[:]
}

// The entries of toctree ``t``.
toctree_entries :: proc(b: ^Build, t: int) -> []Toc_Entry {
	tt := b.toctrees[t]
	return b.entries[tt.first:][:tt.count]
}

// Parents, the reading order, previous and next pages; the documents no
// toctree includes are reported.
link_pages :: proc(b: ^Build) {
	s := b.site
	visited := make([]bool, len(s.docs), context.temp_allocator)
	visit_doc(b, s.root, NO_DOC, visited)
	for t in b.toctrees {
		for e in b.entries[t.first:][:t.count] {
			if e.doc != NO_DOC do b.pages[e.doc].included = true
		}
	}
	b.pages[s.root].included = true
	for i, k in b.order {
		if k > 0 do b.pages[i].prev = b.order[k - 1]
		if k + 1 < len(b.order) do b.pages[i].next = b.order[k + 1]
	}
	for i in 1 ..< len(s.docs) {
		id := Doc_Id(i)
		if b.pages[id].included || s.docs[id].orphan do continue
		if _, orphan := b.pages[id].metadata["orphan"]; orphan do continue
		warn(s, id, "document isn't included in any toctree", 0)
	}
}

@(private = "file")
visit_doc :: proc(b: ^Build, id, parent: Doc_Id, visited: []bool) {
	if visited[id] do return
	visited[id] = true
	b.pages[id].parent = parent
	append(&b.order, id)
	for t in doc_toctrees(b, id) {
		for e in toctree_entries(b, t) {
			if e.doc == NO_DOC || e.doc == id do continue
			if visited[e.doc] {
				if is_ancestor(b, e.doc, id) {
					warn(b.site, id, strings.concatenate({
						"circular toctree references detected, ignoring: ",
						b.site.docs[id].name, " <- ", b.site.docs[e.doc].name,
					}), 0)
				}
				continue
			}
			visit_doc(b, e.doc, id, visited)
		}
	}
}

@(private = "file")
is_ancestor :: proc(b: ^Build, a, id: Doc_Id) -> bool {
	for p := id; p != NO_DOC; p = b.pages[p].parent do if p == a do return true
	return false
}

// The documents from ``id`` up to the root (``id`` first).
ancestors :: proc(b: ^Build, id: Doc_Id) -> []Doc_Id {
	out := make([dynamic]Doc_Id, context.temp_allocator)
	for p := id; p != NO_DOC; p = b.pages[p].parent do append(&out, p)
	return out[:]
}

// --- section numbers ---------------------------------------------------------------------

@(private = "file")
Numbering :: struct {
	b:        ^Build,
	numstack: [dynamic]int,
	assigned: []bool,
}

assign_section_numbers :: proc(b: ^Build) {
	n := Numbering {
		b        = b,
		numstack = make([dynamic]int, context.temp_allocator),
		assigned = make([]bool, len(b.site.docs), context.temp_allocator),
	}
	for t in b.toctrees do if t.numbered > 0 do n.assigned[t.doc] = true
	for t, i in b.toctrees {
		if t.numbered == 0 do continue
		clear(&n.numstack)
		append(&n.numstack, 0)
		walk_toctree(&n, i, t.numbered)
	}
}

@(private = "file")
walk_toctree :: proc(n: ^Numbering, t: int, depth: int) {
	if depth == 0 do return
	b := n.b
	for e in toctree_entries(b, t) {
		if e.doc == NO_DOC || e.doc == b.toctrees[t].doc do continue
		if n.assigned[e.doc] {
			warn(b.site, e.doc, strings.concatenate({b.site.docs[e.doc].name,
				" is already assigned section numbers (nested numbered toctree?)"}), 0)
			continue
		}
		n.assigned[e.doc] = true
		walk_toc(n, b.pages[e.doc].toc, depth)
	}
}

// ``_walk_toc`` over the sibling items from ``first``.
@(private = "file")
walk_toc :: proc(n: ^Numbering, first: Toc_Id, depth: int) {
	b := n.b
	for it := first; it != 0; it = b.toc[it].next {
		item := &b.toc[it]
		switch item.kind {
		case .Section:
			n.numstack[len(n.numstack) - 1] += 1
			if depth > 0 {
				item.number = make([]int, len(n.numstack), b.allocator)
				copy(item.number, n.numstack[:])
			}
			if item.first != 0 {
				append(&n.numstack, 0)
				walk_toc(n, item.first, depth - 1)
				pop(&n.numstack)
			}
		case .Toctree:
			walk_toctree(n, item.toctree, depth)
		}
	}
}

// "1.2.3".
number_text :: proc(number: []int, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for x, i in number {
		if i > 0 do strings.write_byte(&sb, '.')
		strings.write_int(&sb, x)
	}
	return strings.to_string(sb)
}

// The toc item of a section of document ``id`` (0: none).
section_toc :: proc(b: ^Build, id: Doc_Id, section: dt.Node) -> Toc_Id {
	return find_section(b, b.pages[id].toc, section)
}

@(private = "file")
find_section :: proc(b: ^Build, first: Toc_Id, section: dt.Node) -> Toc_Id {
	for it := first; it != 0; it = b.toc[it].next {
		if b.toc[it].kind != .Section do continue
		if b.toc[it].section == section do return it
		if found := find_section(b, b.toc[it].first, section); found != 0 do return found
	}
	return 0
}

// ``get_section_number``: the section's number, else the document title's.
section_number :: proc(b: ^Build, id: Doc_Id, section: dt.Node) -> []int {
	if it := section_toc(b, id, section); it != 0 && b.toc[it].number != nil {
		return b.toc[it].number
	}
	if top := b.pages[id].toc; top != 0 do return b.toc[top].number
	return nil
}

// --- figure numbers ----------------------------------------------------------------------

NUMFIG_SECNUM_DEPTH :: 1

@(private = "file")
Fig_Counter :: struct {
	figtype: Figtype,
	prefix:  string, // the section number prefix, as text
}

@(private = "file")
Fig_Walk :: struct {
	b:        ^Build,
	visited:  []bool,
	counters: map[Fig_Counter]int,
}

assign_figure_numbers :: proc(b: ^Build) {
	if !b.site.conf.numfig do return
	w := Fig_Walk {
		b        = b,
		visited  = make([]bool, len(b.site.docs), context.temp_allocator),
		counters = make(map[Fig_Counter]int, 8, context.temp_allocator),
	}
	walk_fig_doc(&w, b.site.root, nil)
}

@(private = "file")
walk_fig_doc :: proc(w: ^Fig_Walk, id: Doc_Id, secnum: []int) {
	if w.visited[id] || w.b.pages[id].doc == nil do return
	w.visited[id] = true
	doc := w.b.pages[id].doc
	walk_fig_tree(w, id, doc.root, secnum)
}

@(private = "file")
walk_fig_tree :: proc(w: ^Fig_Walk, id: Doc_Id, parent: dt.Node, secnum: []int) {
	b := w.b
	doc := b.pages[id].doc
	for n := dt.first_child(doc, parent); n != 0; n = dt.next_sibling(doc, n) {
		if dt.tag(doc, n) == .Text do continue
		if dt.is(doc, n, {.section}) {
			next := section_number(b, id, n)
			walk_fig_tree(w, id, n, next if next != nil else secnum)
			continue
		}
		if t, ok := toctree_index(doc, n); ok {
			for e in toctree_entries(b, t) do if e.doc != NO_DOC do walk_fig_doc(w, e.doc, secnum)
			continue
		}
		figtype := figtype_of(doc, n)
		ids := dt.attr_list(doc, n, dt.K_IDS)
		if figtype != .None && len(ids) > 0 && numfig_title(doc, n, figtype) {
			register_fignumber(w, id, secnum, figtype, dt.str(doc, ids[0]))
		}
		walk_fig_tree(w, id, n, secnum)
	}
}

@(private = "file")
numfig_title :: proc(doc: ^dt.Doc, n: dt.Node, figtype: Figtype) -> bool {
	want: dt.Tag_Set = {.caption} if figtype == .Figure else {.title}
	if figtype == .Code_Block do want = {.paragraph}
	for c := dt.first_child(doc, n); c != 0; c = dt.next_sibling(doc, c) {
		if dt.is(doc, c, want) do return true
	}
	return false
}

@(private = "file")
register_fignumber :: proc(
	w: ^Fig_Walk,
	id: Doc_Id,
	secnum: []int,
	figtype: Figtype,
	fid: string,
) {
	b := w.b
	prefix := secnum[:min(len(secnum), NUMFIG_SECNUM_DEPTH)]
	key := Fig_Counter{figtype, strings.clone(number_text(prefix), context.temp_allocator)}
	w.counters[key] += 1
	number := make([]int, len(prefix) + 1, b.allocator)
	copy(number, prefix)
	number[len(prefix)] = w.counters[key]
	b.fignums[Fig_Key{id, strings.clone(fid, b.allocator)}] = number
}

// ``numfig_format``: the format of a figure type's number ("%s" is the
// number).
numfig_format :: proc(b: ^Build, figtype: Figtype) -> string {
	key, default: string
	switch figtype {
	case .Figure:
		key, default = "figure", "Fig. %s"
	case .Table:
		key, default = "table", "Table %s"
	case .Code_Block:
		key, default = "code-block", "Listing %s"
	case .Section, .None:
		key, default = "section", "Section %s"
	}
	if d, ok := b.site.conf.values["numfig_format"].(Dict); ok {
		for k, i in d.keys {
			if s, is_str := d.values[i].(string); is_str && k == key do return s
		}
	}
	return default
}
