package site

import "core:strings"

import dt "../doctree"

// A page's document made ready for the html5 writer: references resolved,
// toctrees rendered as nested lists (``compound`` "toctree-wrapper" with a
// caption paragraph and a bullet list, as Sphinx renders them), section
// numbers as ``generated`` "sectnum" elements and figure numbers as
// ``inline`` "caption-number" elements.

prepare_html_page :: proc(b: ^Build, id: Doc_Id) {
	context.allocator = b.allocator
	doc := b.pages[id].doc
	r := Resolver{b, doc, id}
	resolve_refs(&r)
	resolve_images(&r, id)
	for n in dt.traverse(doc, doc.root, dt.Tag_Set{.compound}) {
		t, ok := toctree_index(doc, n)
		if !ok do continue
		if b.toctrees[t].hidden {
			dt.remove_child(doc, dt.parent(doc, n), n)
			continue
		}
		dt.replace_self(doc, n, render_toctree(&r, t))
	}
	number_sections(b, id, b.pages[id].toc)
	number_captions(b, id)
}

// --- toctrees ----------------------------------------------------------------------------

@(private = "file")
render_toctree :: proc(r: ^Resolver, t: int) -> dt.Node {
	doc := r.doc
	tt := r.b.toctrees[t]
	wrapper := dt.new_element(doc, .compound)
	dt.list_append(doc, wrapper, dt.K_CLASSES, "toctree-wrapper")
	if tt.caption != "" {
		para := dt.new_element(doc, .paragraph)
		dt.list_append(doc, para, dt.K_CLASSES, "caption")
		span := dt.new_element(doc, .inline, "", tt.caption)
		dt.list_append(doc, span, dt.K_CLASSES, "caption-text")
		dt.append_child(doc, para, span)
		dt.append_child(doc, wrapper, para)
	}
	list := dt.new_element(doc, .bullet_list)
	dt.set_attr(doc, list, "bullet", "*")
	for e in toctree_entries(r.b, t) {
		dt.append_child(doc, list, entry_item(r, e, 1, tt))
	}
	if dt.child_count(doc, list) > 0 do dt.append_child(doc, wrapper, list)
	return wrapper
}

// The list item of a toctree entry at ``level`` (1: the toctree's own).
@(private = "file")
entry_item :: proc(r: ^Resolver, e: Toc_Entry, level: int, tt: Toctree) -> dt.Node {
	b := r.b
	if e.doc == NO_DOC {
		title := e.title if e.title != "" else e.url
		ref := dt.new_element(r.doc, .reference, title, title)
		dt.set_attr(r.doc, ref, dt.K_REFURI, e.url)
		return toc_item(r, level, ref, 0)
	}
	page := &b.pages[e.doc]
	title := e.title if e.title != "" else page.title
	number: []int
	if page.toc != 0 do number = b.toc[page.toc].number
	ref := toc_reference(r, Link{e.doc, ""}, number, title)
	sub: dt.Node
	if tt.maxdepth < 0 || level < tt.maxdepth {
		if page.toc != 0 do sub = toc_children(r, e.doc, b.toc[page.toc].first, level + 1, tt)
	}
	item := toc_item(r, level, ref, sub)
	if e.doc == r.from do dt.list_append(r.doc, item, dt.K_CLASSES, "current")
	return item
}

// The nested list of the toc items from ``first`` (0 when empty).
@(private = "file")
toc_children :: proc(r: ^Resolver, id: Doc_Id, first: Toc_Id, level: int, tt: Toctree) -> dt.Node {
	b := r.b
	doc := r.doc
	list := dt.new_element(doc, .bullet_list)
	dt.set_attr(doc, list, "bullet", "*")
	for it := first; it != 0; it = b.toc[it].next {
		item := b.toc[it]
		switch item.kind {
		case .Section:
			if tt.titlesonly do continue
			ref := toc_reference(r, Link{id, item.id}, item.number, item.title)
			sub: dt.Node
			if tt.maxdepth < 0 || level < tt.maxdepth {
				sub = toc_children(r, id, item.first, level + 1, tt)
			}
			dt.append_child(doc, list, toc_item(r, level, ref, sub))
		case .Toctree:
			if b.toctrees[item.toctree].hidden do continue
			for e in toctree_entries(b, item.toctree) {
				dt.append_child(doc, list, entry_item(r, e, level, tt))
			}
		}
	}
	if dt.child_count(doc, list) == 0 do return 0
	return list
}

@(private = "file")
toc_item :: proc(r: ^Resolver, level: int, ref: dt.Node, sub: dt.Node) -> dt.Node {
	doc := r.doc
	item := dt.new_element(doc, .list_item)
	dt.list_append(doc, item, dt.K_CLASSES, strings.concatenate({"toctree-l", rd_itoa(level)}))
	para := dt.new_element(doc, .paragraph)
	dt.append_child(doc, para, ref)
	dt.append_child(doc, item, para)
	if sub != 0 do dt.append_child(doc, item, sub)
	return item
}

@(private = "file")
toc_reference :: proc(r: ^Resolver, link: Link, number: []int, title: string) -> dt.Node {
	ref := make_reference(r, link, 0)
	text := title
	if number != nil do text = strings.concatenate({number_text(number), ". ", title})
	dt.append_child(r.doc, ref, dt.new_text(r.doc, text))
	return ref
}

rd_itoa :: proc(n: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_int(&sb, n)
	return strings.to_string(sb)
}

// --- numbers --------------------------------------------------------------------------

// Section numbers before the numbered section titles.
@(private = "file")
number_sections :: proc(b: ^Build, id: Doc_Id, first: Toc_Id) {
	doc := b.pages[id].doc
	for it := first; it != 0; it = b.toc[it].next {
		item := b.toc[it]
		if item.kind != .Section do continue
		title := dt.first_child(doc, item.section)
		if item.number != nil && dt.is(doc, title, {.title}) {
			text := strings.concatenate({number_text(item.number), "."})
			gen := dt.new_element(doc, .generated, "", text)
			dt.list_append(doc, gen, dt.K_CLASSES, "sectnum")
			dt.insert_child(doc, title, 0, gen)
		}
		number_sections(b, id, item.first)
	}
}

// "Fig. 1.2 " before the captions of numbered figures, tables and code
// blocks.
@(private = "file")
number_captions :: proc(b: ^Build, id: Doc_Id) {
	doc := b.pages[id].doc
	for key, number in b.fignums {
		if key.doc != id do continue
		node, found := dt.om_get(&doc.ids, dt.intern(doc, key.id))
		if !found do continue
		figtype := figtype_of(doc, node)
		caption := caption_of(doc, node, figtype)
		if caption == 0 do continue
		format := numfig_format(b, figtype)
		label, _ := strings.replace_all(format, "%s", number_text(number))
		span := dt.new_element(doc, .inline, "", strings.concatenate({label, " "}))
		dt.list_append(doc, span, dt.K_CLASSES, "caption-number")
		dt.insert_child(doc, caption, 0, span)
	}
}

// The caption (figure), title (table) or caption paragraph (code block).
caption_of :: proc(doc: ^dt.Doc, n: dt.Node, figtype: Figtype) -> dt.Node {
	want: dt.Tag_Set
	#partial switch figtype {
	case .Figure:
		want = {.caption}
	case .Table:
		want = {.title}
	case .Code_Block:
		want = {.paragraph}
	case:
		return 0
	}
	for c := dt.first_child(doc, n); c != 0; c = dt.next_sibling(doc, c) {
		if dt.is(doc, c, want) do return c
	}
	return 0
}
