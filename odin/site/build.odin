package site

import "base:runtime"
import "core:mem/virtual"
import "core:strings"

import dt "../doctree"
import pb "../publish"
import rd "../reader"

// A build of a site for one output format: every document read with the
// native reader (with the Sphinx directives and roles of ``extension.odin``)
// and the standard transforms, then what Sphinx's environment collects:
// the table of contents of each document, the toctree graph, labels and
// glossary terms, section and figure numbers.  The documents are read
// once per format, as ``only`` and a few roles depend on it.

Format :: enum u8 {
	Html,
	Latex,
}

FORMAT_TAGS := [Format]string {
	.Html  = "html",
	.Latex = "latex",
}

// A ``toctree`` directive.  Its entries are ``Build.entries[first:][:count]``.
Toctree :: struct {
	doc:        Doc_Id,
	caption:    string,
	maxdepth:   int, // -1: unlimited
	numbered:   int, // depth of numbering; 0: none
	hidden:     bool,
	titlesonly: bool,
	first:      int,
	count:      int,
}

// A toctree entry: a document (with an explicit title or ""), or a URL.
Toc_Entry :: struct {
	title: string,
	doc:   Doc_Id,
	url:   string,
}

Toc_Id :: distinct u32

Toc_Kind :: enum u8 {
	Section,
	Toctree,
}

// An item of a document's local table of contents (Sphinx's ``env.tocs``):
// a section, or a toctree in the section that holds it.  Items are linked
// as a tree (``first`` child, ``next`` sibling).
Toc_Node :: struct {
	kind:    Toc_Kind,
	doc:     Doc_Id,
	section: dt.Node, // Section
	id:      string, // Section: the anchor ("" for the document title)
	title:   string, // Section: plain text
	toctree: int, // Toctree: index into ``Build.toctrees``
	first:   Toc_Id,
	next:    Toc_Id,
	number:  []int, // section number (nil: not numbered)
}

// A label (``.. _name:``), a glossary term or a numbered object.
Target :: struct {
	doc:     Doc_Id,
	id:      string,
	title:   string, // "" when the label must be referenced with a title
	figtype: Figtype,
	node:    dt.Node,
}

Figtype :: enum u8 {
	None,
	Section,
	Figure,
	Table,
	Code_Block,
}

// What a build knows of each document.
Page :: struct {
	doc:       ^dt.Doc,
	title:     string, // plain text
	toc:       Toc_Id, // the first top-level item
	parent:    Doc_Id, // the document whose toctree includes it
	prev:      Doc_Id,
	next:      Doc_Id,
	included:  bool, // in some toctree (or the root)
	metadata:  map[string]string, // the docinfo fields (``:orphan:`` etc.), lowercase names
	highlight: string, // the ``highlight`` language while reading
}

Build :: struct {
	site:      ^Site,
	format:    Format,
	arena:     virtual.Arena,
	allocator: runtime.Allocator,
	pages:     []Page, // by Doc_Id
	toctrees:  [dynamic]Toctree,
	entries:   [dynamic]Toc_Entry,
	toc:       [dynamic]Toc_Node, // toc[0] is the null item
	labels:    map[string]Target,
	terms:     map[string]Target,
	fignums:   map[Fig_Key][]int,
	order:     [dynamic]Doc_Id, // reading order: the toctrees depth first from the root
	current:   Doc_Id, // the document being read
	extension: rd.Extension,
	assets:    [dynamic]Asset, // files the output needs
	outdir:    string, // the output directory of the format
}

Fig_Key :: struct {
	doc: Doc_Id,
	id:  string,
}

// Read every document of ``s`` for ``format`` and collect the environment.
build_make :: proc(s: ^Site, format: Format) -> ^Build {
	b := new(Build, s.allocator)
	b.site, b.format = s, format
	if virtual.arena_init_growing(&b.arena) != nil do panic("site: cannot reserve arena")
	b.allocator = virtual.arena_allocator(&b.arena)
	context.allocator = b.allocator
	b.pages = make([]Page, len(s.docs))
	b.toctrees = make([dynamic]Toctree)
	b.entries = make([dynamic]Toc_Entry)
	b.toc = make([dynamic]Toc_Node)
	append(&b.toc, Toc_Node{})
	b.labels = make(map[string]Target)
	b.terms = make(map[string]Target)
	b.fignums = make(map[Fig_Key][]int)
	b.order = make([dynamic]Doc_Id)
	b.assets = make([dynamic]Asset)
	b.extension = sphinx_extension(b)
	for i in 1 ..< len(s.docs) do read_page(b, Doc_Id(i))
	for i in 1 ..< len(s.docs) do collect_labels(b, Doc_Id(i))
	link_pages(b)
	assign_section_numbers(b)
	assign_figure_numbers(b)
	return b
}

build_destroy :: proc(b: ^Build) {
	for p in b.pages do if p.doc != nil do dt.destroy(p.doc)
	virtual.arena_destroy(&b.arena)
}

// The docutils settings of a Sphinx build (``sphinx.environment``'s
// ``default_settings``), for the writer of ``format``.
@(private = "file")
read_overrides :: proc(format: Format, language: string) -> []pb.Override {
	out := make([dynamic]pb.Override)
	append(&out, pb.Override{"doctitle_xform", false})
	append(&out, pb.Override{"sectsubtitle_xform", false})
	append(&out, pb.Override{"auto_id_prefix", "id"})
	append(&out, pb.Override{"halt_level", 5})
	append(&out, pb.Override{"report_level", 2})
	append(&out, pb.Override{"smart_quotes", true})
	append(&out, pb.Override{"syntax_highlight", "none"})
	append(&out, pb.Override{"language_code", language})
	append(&out, pb.Override{"pep_references", pb.None{}})
	append(&out, pb.Override{"rfc_references", pb.None{}})
	if format == .Html {
		append(&out, pb.Override{"initial_header_level", "1"})
		append(&out, pb.Override{"section_self_link", true})
		append(&out, pb.Override{"cloak_email_addresses", true})
	}
	return out[:]
}

WRITER_OF := [Format]string {
	.Html  = "html5",
	.Latex = "xetex",
}

// Read and transform one document, then collect its table of contents.
@(private = "file")
read_page :: proc(b: ^Build, id: Doc_Id) {
	s := b.site
	src := &s.docs[id]
	b.current = id
	page := &b.pages[id]
	page.highlight = "default"
	page.metadata = make(map[string]string)
	options := pb.Read_Options {
		options = {docutils_dir = DOCUTILS_DIR, extension = &b.extension},
	}
	overrides := read_overrides(b.format, s.conf.language)
	r := pb.read_document(src.text, src.path, WRITER_OF[b.format], overrides, options)
	page.doc = r.doc
	for m in r.messages {
		if m.level < 2 do continue
		source := m.source if m.source != "" else src.path
		warn_at(s, id, source, m.line, m.text, m.level)
	}
	if e, failed := r.err.(pb.Settings_Error); failed do warn(s, id, e.message, 0, 4)
	if r.doc == nil do return
	take_metadata(b, id)
	page.toc = collect_toc(b, id, r.doc.root)
	if page.toc != 0 do page.title = b.toc[page.toc].title
	if page.title == "" do page.title = "<no title>"
	b.current = NO_DOC
}

// Sphinx's ``MetadataCollector``: the docinfo fields become metadata and
// the docinfo leaves the document.
@(private = "file")
take_metadata :: proc(b: ^Build, id: Doc_Id) {
	doc := b.pages[id].doc
	for n := dt.first_child(doc, doc.root); n != 0; n = dt.next_sibling(doc, n) {
		if !dt.is(doc, n, {.docinfo}) do continue
		for f := dt.first_child(doc, n); f != 0; f = dt.next_sibling(doc, f) {
			name, value := field_text(doc, f)
			b.pages[id].metadata[strings.to_lower(name)] = value
		}
		dt.remove_child(doc, doc.root, n)
		return
	}
}

// The name and body text of a docinfo item (a ``field`` or a bibliographic
// element).
@(private = "file")
field_text :: proc(doc: ^dt.Doc, f: dt.Node) -> (name, value: string) {
	if !dt.is(doc, f, {.field}) {
		return strings.clone(dt.TAG_NAMES[dt.tag(doc, f)]), dt.astext(doc, f, context.allocator)
	}
	name_node := dt.first_child(doc, f)
	body := dt.next_sibling(doc, name_node)
	name = dt.astext(doc, name_node, context.allocator)
	if body != 0 do value = dt.astext(doc, body, context.allocator)
	return
}

// --- the local table of contents -----------------------------------------------------------

// The toc items of the children of ``parent`` (``TocTreeCollector.build_toc``):
// sections, and the toctrees in the elements between them.
@(private = "file")
collect_toc :: proc(b: ^Build, id: Doc_Id, parent: dt.Node) -> Toc_Id {
	doc := b.pages[id].doc
	first, last: Toc_Id
	add :: proc(b: ^Build, first, last: ^Toc_Id, item: Toc_Id) {
		if first^ == 0 do first^ = item
		else do b.toc[last^].next = item
		last^ = item
	}
	for n := dt.first_child(doc, parent); n != 0; n = dt.next_sibling(doc, n) {
		if dt.is(doc, n, {.section}) {
			add(b, &first, &last, section_item(b, id, n, first == 0 && parent == doc.root))
			continue
		}
		if dt.tag(doc, n) == .Text do continue
		for t in dt.traverse(doc, n, dt.tags_of(.Element)) {
			if dt.is(doc, t, {.section}) do continue
			if idx, ok := toctree_index(doc, t); ok {
				append(&b.toc, Toc_Node{kind = .Toctree, doc = id, toctree = idx})
				add(b, &first, &last, Toc_Id(len(b.toc) - 1))
			}
		}
	}
	return first
}

@(private = "file")
section_item :: proc(b: ^Build, id: Doc_Id, sec: dt.Node, is_title: bool) -> Toc_Id {
	doc := b.pages[id].doc
	title := dt.first_child(doc, sec)
	item := Toc_Node {
		kind    = .Section,
		doc     = id,
		section = sec,
		title   = title_text(doc, title) if dt.is(doc, title, {.title}) else "",
	}
	ids := dt.attr_list(doc, sec, dt.K_IDS)
	if !is_title && len(ids) > 0 do item.id = strings.clone(dt.str(doc, ids[0]))
	append(&b.toc, item)
	handle := Toc_Id(len(b.toc) - 1)
	children := collect_toc(b, id, sec)
	b.toc[handle].first = children
	return handle
}

// The text of a title without generated section numbers.
title_text :: proc(doc: ^dt.Doc, title: dt.Node) -> string {
	sb := strings.builder_make()
	for t in dt.traverse(doc, title, dt.Tag_Set{.Text}) {
		skip := false
		for p := dt.parent(doc, t); p != title && p != 0; p = dt.parent(doc, p) {
			if dt.is(doc, p, {.generated}) do skip = true
		}
		if !skip do strings.write_string(&sb, doc.nodes[t].text)
	}
	return strings.to_string(sb)
}

// The toctree placeholder ``n`` (see ``run_toctree``) and its index.
toctree_index :: proc(doc: ^dt.Doc, n: dt.Node) -> (int, bool) {
	if !dt.is(doc, n, {.compound}) || !dt.has_attr(doc, n, ATTR_TOCTREE) do return 0, false
	return dt.get_int(doc, n, ATTR_TOCTREE), true
}

ATTR_TOCTREE :: "docodin_toctree"

// --- labels ---------------------------------------------------------------------------------

// The explicit targets of a document (``StandardDomain.process_doc``):
// labels of sections, figures, tables and code blocks have a title.
@(private = "file")
collect_labels :: proc(b: ^Build, id: Doc_Id) {
	doc := b.pages[id].doc
	if doc == nil do return
	for key, i in doc.nameids.keys {
		if key == dt.TOMBSTONE do continue
		explicit, _ := dt.om_get(&doc.nametypes, key)
		refid := doc.nameids.values[i]
		if !explicit || refid == 0 do continue
		node, found := dt.om_get(&doc.ids, refid)
		if !found do continue
		name := dt.str(doc, key)
		if !strings.has_prefix(name, "term-") || !is_term(doc, node) {
			add_label(b, id, strings.clone(name), strings.clone(dt.str(doc, refid)), node)
		}
	}
}

@(private = "file")
is_term :: proc(doc: ^dt.Doc, n: dt.Node) -> bool {
	return dt.is(doc, n, {.term})
}

@(private = "file")
add_label :: proc(b: ^Build, id: Doc_Id, name, refid: string, node: dt.Node) {
	doc := b.pages[id].doc
	if dt.is(doc, node, {.target}) do return // an external or indirect target
	t := Target {
		doc     = id,
		id      = refid,
		node    = node,
		figtype = figtype_of(doc, node),
	}
	t.title = figure_title(doc, node, t.figtype)
	if old, dup := b.labels[name]; dup && old.doc != id {
		src := b.site.docs[old.doc].path
		warn(b.site, id, strings.concatenate({"duplicate label ", name,
			", other instance in ", src}), node_line(doc, node), 2)
	}
	b.labels[name] = t
}

// Sphinx's enumerable node types.
figtype_of :: proc(doc: ^dt.Doc, n: dt.Node) -> Figtype {
	#partial switch dt.tag(doc, n) {
	case .section:
		return .Section
	case .figure:
		return .Figure
	case .table:
		return .Table
	case .container:
		if wr_has_class(doc, n, "literal-block-wrapper") do return .Code_Block
	}
	return .None
}

// The title of a labelled section, figure, table or captioned code block.
@(private = "file")
figure_title :: proc(doc: ^dt.Doc, n: dt.Node, figtype: Figtype) -> string {
	want: dt.Tag_Set
	switch figtype {
	case .Section, .Table:
		want = {.title}
	case .Figure:
		want = {.caption}
	case .Code_Block:
		want = {.caption, .paragraph}
	case .None:
		return ""
	}
	for c := dt.first_child(doc, n); c != 0; c = dt.next_sibling(doc, c) {
		if dt.is(doc, c, want) do return title_text(doc, c)
	}
	return ""
}

wr_has_class :: proc(doc: ^dt.Doc, n: dt.Node, class: string) -> bool {
	return dt.list_contains(doc, n, dt.K_CLASSES, class)
}

node_line :: proc(doc: ^dt.Doc, n: dt.Node) -> int {
	for m := n; m != 0; m = dt.parent(doc, m) {
		if ln, ok := dt.line(doc, m); ok do return ln
	}
	return 0
}
