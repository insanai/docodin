package transforms

import "core:fmt"
import "core:strings"

import dt "../doctree"

// ``docutils.transforms.frontmatter``: ``DocTitle``, ``SectionSubTitle``
// and ``DocInfo`` (RCS keywords and authors are in docinfo.odin).

// --- TitlePromoter -------------------------------------------------------------

// ``Element.update_all_atts_concatenating(other, replace=True,
// and_source=True)``.
update_all_atts_concatenating :: proc(doc: ^dt.Doc, n, other: dt.Node) {
	dt.update_basic_atts(doc, n, other)
	listed := dt.TAG_LIST_ATTRS[dt.tag(doc, n)]
	for a in dt.attributes(doc, other) {
		k := dt.intern(doc, a.key)
		if b, basic := dt.basic_of(k); basic && b in listed do continue
		own, has := dt.get_attr(doc, n, k)
		own_list, own_is_list := own.(dt.List)
		value_list, value_is_list := a.value.(dt.List)
		if has && own_is_list && value_is_list {
			if own_list == value_list do continue
			dt.append_attr_list(doc, n, k, dt.list_items(doc, value_list))
		} else {
			dt.set_attr(doc, n, k, a.value)
		}
	}
}

// ``TitlePromoter.candidate_index``: the lone section after the
// pre-bibliographic elements, and its index (-1: none).
@(private = "file")
candidate_index :: proc(doc: ^dt.Doc, n: dt.Node) -> (dt.Node, int) {
	index := dt.first_child_not_matching_class(doc, n, dt.tags_of(.PreBibliographic))
	if index < 0 || length(doc, n) > index + 1 do return 0, -1
	section := dt.child_at(doc, n, index)
	if dt.tag(doc, section) != .section do return 0, -1
	return section, index
}

// ``TitlePromoter.promote_title``: the lone top-level section's title and
// contents move up into ``n``.
promote_title :: proc(doc: ^dt.Doc, n: dt.Node) -> bool {
	section, index := candidate_index(doc, n)
	if index < 0 do return false
	update_all_atts_concatenating(doc, n, section)
	before := dt.children(doc, n)[:index]
	items := make([dynamic]dt.Node, 0, length(doc, section) + index, context.temp_allocator)
	append(&items, ..dt.children(doc, section)[:1])
	append(&items, ..before)
	append(&items, ..children_from(doc, section, 1))
	set_children(doc, n, items[:])
	return true
}

// ``TitlePromoter.promote_subtitle``: a lone subsection's title becomes the
// subtitle of ``n``, its contents move up.
promote_subtitle :: proc(doc: ^dt.Doc, n: dt.Node) -> bool {
	subsection, index := candidate_index(doc, n)
	if index < 0 do return false
	subtitle := dt.new_element(doc, .subtitle)
	update_all_atts_concatenating(doc, subtitle, subsection)
	set_children(doc, subtitle, dt.children(doc, dt.child_at(doc, subsection, 0)))
	all := dt.children(doc, n)
	items := make([dynamic]dt.Node, 0, len(all) + length(doc, subsection), context.temp_allocator)
	append(&items, ..all[:min(1, len(all))])
	append(&items, subtitle)
	if index > 1 do append(&items, ..all[1:index])
	append(&items, ..children_from(doc, subsection, 1))
	set_children(doc, n, items[:])
	return true
}

// --- DocTitle, SectionSubTitle ------------------------------------------------------

// ``DocTitle``: promote a lone top-level section's title to the document
// title (and a lone subsection's to the subtitle); set the ``title``
// attribute.
doc_title :: proc(r: ^Run, _: dt.Node, _: []dt.Detail) {
	doc := r.doc
	if setdefault_bool(doc, "doctitle_xform", doc.settings.doctitle_xform, true) {
		if promote_title(doc, doc.root) do promote_subtitle(doc, doc.root)
	}
	if dt.has_attr(doc, doc.root, dt.K_TITLE) do return
	if title, ok := title_setting(doc); ok {
		dt.set_attr(doc, doc.root, dt.K_TITLE, title)
	} else if first := dt.first_child(doc, doc.root); dt.is(doc, first, {.title}) {
		dt.set_attr(doc, doc.root, dt.K_TITLE, dt.astext(doc, first))
	}
}

// ``SectionSubTitle``: a lone subsection's title becomes its parent
// section's subtitle.
section_sub_title :: proc(r: ^Run, _: dt.Node, _: []dt.Detail) {
	doc := r.doc
	on := setdefault_bool(doc, "sectsubtitle_xform", doc.settings.sectsubtitle_xform, true)
	if !on do return
	it := dt.findall(doc, doc.root, dt.Tag_Set{.section})
	for section in dt.next(&it) do promote_subtitle(doc, section)
}

// --- DocInfo -------------------------------------------------------------------------

// The element classes of the canonical bibliographic fields
// (``DocInfo.biblio_nodes``); ``authors``: a list, ``topic``: a topic.
@(private = "file")
BIBLIO_TAGS := #partial [Label]dt.Tag {
	.author       = .author,
	.authors      = .authors,
	.organization = .organization,
	.address      = .address,
	.contact      = .contact,
	.version      = .version,
	.revision     = .revision,
	.status       = .status,
	.date         = .date,
	.copyright    = .copyright,
	.dedication   = .topic,
	.abstract     = .topic,
}

Docinfo_State :: struct {
	r:        ^Run,
	doc:      ^dt.Doc,
	docinfo:  dt.Node,
	reparsed: dt.Node, // the paragraph of ``reparse_author`` (its parent: the other document)
	topics:  [2]dt.Node, // dedication, abstract
}

// ``DocInfo``: a field list first in the document (after the titles and
// pre-bibliographic elements) becomes the ``docinfo`` element.
doc_info :: proc(r: ^Run, _: dt.Node, _: []dt.Detail) {
	doc := r.doc
	if !setdefault_bool(doc, "docinfo_xform", doc.settings.docinfo_xform, true) do return
	index := dt.first_child_not_matching_class(doc, doc.root, dt.tags_of(.PreBibliographic))
	if index < 0 do return
	candidate := dt.child_at(doc, doc.root, index)
	if dt.tag(doc, candidate) != .field_list do return
	front := dt.tags_of(.Titular) + {.decoration, .meta}
	biblioindex := dt.first_child_not_matching_class(doc, doc.root, front)
	nodelist := extract_bibliographic(r, candidate)
	dt.pop_child(doc, doc.root, index)
	dt.insert_children(doc, doc.root, biblioindex, nodelist)
}

@(private = "file")
extract_bibliographic :: proc(r: ^Run, field_list: dt.Node) -> []dt.Node {
	doc := r.doc
	st := Docinfo_State {
		r       = r,
		doc     = doc,
		docinfo = dt.new_element(doc, .docinfo),
	}
	for field in dt.children(doc, field_list) {
		if !extract_field(&st, field) do reject_field(&st, field)
	}
	nodelist := make([dynamic]dt.Node, 0, 3, context.temp_allocator)
	if length(doc, st.docinfo) > 0 do append(&nodelist, st.docinfo)
	for t in st.topics do if t != 0 do append(&nodelist, t)
	return nodelist[:]
}

// The normalized name of a field: its canonical bibliographic name, if any.
@(private = "file")
canonical_field :: proc(r: ^Run, normedname: string) -> (Label, bool) {
	for f in language(r).fields {
		if f.name == normedname do return f.canonical, true
	}
	return {}, false
}

@(private = "file")
field_name :: proc(doc: ^dt.Doc, field: dt.Node) -> string {
	first := dt.child_at(doc, dt.child_at(doc, field, 0), 0)
	return dt.astext(doc, first) if first != 0 else ""
}

// One field of the bibliographic field list; false: the field stays a
// field (``TransformError``).
@(private = "file")
extract_field :: proc(st: ^Docinfo_State, field: dt.Node) -> bool {
	doc := st.doc
	name := field_name(doc, field)
	canonical, known := canonical_field(st.r, dt.fully_normalize_name(name))
	if length(doc, field) != 2 || !known do return false
	if !check_empty_biblio_field(st, field, name) do return false
	body := dt.child_at(doc, field, 1)
	#partial switch canonical {
	case .authors:
		return extract_authors(st, field, name)
	case .dedication, .abstract:
		return extract_topic(st, field, name, canonical)
	case:
		if !check_compound_biblio_field(st, field, name) do return false
		para := dt.child_at(doc, body, 0)
		clean_rcs_keywords(doc, para, DOCINFO_RCS_KEYWORDS)
		el := dt.new_element(doc, BIBLIO_TAGS[canonical])
		dt.extend_children(doc, el, dt.children(doc, para))
		dt.append_child(doc, st.docinfo, el)
		// ``f_body.children = _document.children``: the body lists the paragraph,
		// but the paragraph's parent is the other document.
		if para == st.reparsed do remove_identity(doc, body, para)
	}
	return true
}

@(private = "file")
extract_topic :: proc(st: ^Docinfo_State, field: dt.Node, name: string, canonical: Label) -> bool {
	doc := st.doc
	slot := &st.topics[0 if canonical == .dedication else 1]
	if slot^ != 0 {
		text := fmt.tprintf(`There can only be one "%s" field.`, name)
		warning := dt.warning(doc, text, {base_node = field})
		append_to_last(doc, field, warning)
		return false
	}
	label := language(st.r).labels[canonical]
	topic := dt.new_element(doc, .topic)
	dt.append_child(doc, topic, dt.new_element(doc, .title, name, label))
	dt.extend_children(doc, topic, dt.children(doc, dt.child_at(doc, field, 1)))
	dt.set_list(doc, topic, dt.K_CLASSES, LABEL_NAMES[canonical])
	slot^ = topic
	return true
}

@(private = "file")
LABEL_NAMES := [Label]string {
	.author       = "author",
	.authors      = "authors",
	.organization = "organization",
	.address      = "address",
	.contact      = "contact",
	.version      = "version",
	.revision     = "revision",
	.status       = "status",
	.date         = "date",
	.copyright    = "copyright",
	.dedication   = "dedication",
	.abstract     = "abstract",
	.attention    = "attention",
	.caution      = "caution",
	.danger       = "danger",
	.error        = "error",
	.hint         = "hint",
	.important    = "important",
	.note         = "note",
	.tip          = "tip",
	.warning      = "warning",
	.contents     = "contents",
}

// The ``except TransformError`` branch: the field stays, with its RCS
// keywords cleaned and its normalized name as a class.
@(private = "file")
reject_field :: proc(st: ^Docinfo_State, field: dt.Node) {
	doc := st.doc
	body := dt.last_child(doc, field)
	if length(doc, body) == 1 && dt.is(doc, dt.first_child(doc, body), {.paragraph}) {
		clean_rcs_keywords(doc, dt.first_child(doc, body), DOCINFO_RCS_KEYWORDS)
	}
	normedname := dt.fully_normalize_name(field_name(doc, field))
	if classvalue := dt.make_id(normedname); classvalue != "" {
		dt.list_append(doc, field, dt.K_CLASSES, classvalue)
	}
	dt.append_child(doc, st.docinfo, field)
}

@(private = "file")
check_empty_biblio_field :: proc(st: ^Docinfo_State, field: dt.Node, name: string) -> bool {
	doc := st.doc
	body := dt.last_child(doc, field)
	if length(doc, body) >= 1 do return true
	text := fmt.tprintf(`Cannot extract empty bibliographic field "%s".`, name)
	append_to_last(doc, field, dt.warning(doc, text, {base_node = field}))
	return false
}

// The field body must be a single paragraph; an author name with an
// initial parsed as an enumerated list is re-parsed as a paragraph.
@(private = "file")
check_compound_biblio_field :: proc(st: ^Docinfo_State, field: dt.Node, name: string) -> bool {
	doc := st.doc
	body := dt.last_child(doc, field)
	first := dt.first_child(doc, body)
	if length(doc, body) == 1 && dt.is(doc, first, {.paragraph}) do return true
	raw := dt.text(doc, body)
	if dt.is(doc, first, {.enumerated_list}) && !strings.contains(py_strip(raw), "\n") {
		if reparse_author(st, body, raw) do return true
	}
	content := make([dynamic]string, 0, 4, context.temp_allocator)
	for c in dt.children(doc, body) {
		if dt.tag(doc, c) == .system_message do continue
		append(&content, fmt.tprintf("<%s>", dt.tagname(doc, c)))
	}
	listing: string
	if len(content) > 1 {
		joined := strings.join(content[:], ", ", context.temp_allocator)
		listing = strings.concatenate({"[", joined, "]"}, context.temp_allocator)
	} else if len(content) == 1 {
		listing = strings.concatenate({"a ", content[0]}, context.temp_allocator)
	} else {
		fail(st.r, "IndexError: list index out of range")
		return false
	}
	format := "Bibliographic field \"%s\"\nmust contain a single <paragraph>, not %s."
	text := fmt.tprintf(format, name, listing)
	dt.append_child(doc, body, dt.warning(doc, text, {base_node = field}))
	return false
}

// ``parser.parse('\\' + f_body.rawsource, new_document('*DocInfo
// transform*', settings))``: a lone paragraph replaces the body's children.
@(private = "file")
reparse_author :: proc(st: ^Docinfo_State, body: dt.Node, raw: string) -> bool {
	doc := st.doc
	parse := st.r.options.parse_rst
	if parse == nil do return false
	text := strings.concatenate({"\\", raw}, context.temp_allocator)
	settings := doc.settings
	settings.rst_language_cached = true
	sub := parse(text, settings, "*DocInfo transform*")
	defer dt.destroy(sub)
	// the new document's reporter writes to the same warning stream
	for m in sub.reporter.written {
		written := dt.Written_Message{m.level, 0, dt.clone(doc, m.text)}
		append(&doc.reporter.written, written)
	}
	para := dt.first_child(sub, sub.root)
	if length(sub, sub.root) != 1 || dt.tag(sub, para) != .paragraph do return false
	st.reparsed = import_subtree(doc, sub, para)
	set_children(doc, body, {st.reparsed})
	return true
}

// A copy of ``n`` of document ``src`` in ``dst`` that keeps the source,
// line and flags of every node (Text nodes included).
import_subtree :: proc(dst, src: ^dt.Doc, n: dt.Node) -> dt.Node {
	m: dt.Node
	if dt.tag(src, n) == .Text {
		m = dt.new_text(dst, dt.text(src, n))
	} else {
		m = dt.import_node(dst, src, n)
	}
	for c := dt.first_child(src, n); c != 0; c = dt.next_sibling(src, c) {
		mc := import_subtree(dst, src, c)
		dt.append_child(dst, m, mc)
		restore_location(dst, src, mc, c)
	}
	restore_location(dst, src, m, n)
	return m
}

@(private = "file")
restore_location :: proc(dst, src: ^dt.Doc, m, n: dt.Node) {
	source, has_source := dt.source(src, n)
	dt.set_source(dst, m, source if has_source else nil)
	line, has_line := dt.line(src, n)
	dt.set_line(dst, m, line if has_line else nil)
	for f in ([]dt.Node_Flag{.Has_Document, .Referenced, .Resolved}) {
		dt.set_flag(dst, m, f, dt.has_flag(src, n, f))
	}
}
