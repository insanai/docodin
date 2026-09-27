package site

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import dt "../doctree"
import pb "../publish"
import wr "../writers"

// The PDF book: one document assembled from the toctrees in reading order
// (Sphinx's ``inline_all_toctrees``), written by the native LaTeX (xetex)
// writer into the docodin book template, and compiled with LuaLaTeX (or
// XeLaTeX).  When the root document's sections hold the toctrees (or
// ``latex_toplevel_sectioning`` is "part"), those sections are the book's
// parts.  Every id is made global ("doc-<docname>--<id>") so references
// across documents become ``\hyperref``s.

BOOK_TEMPLATE :: #load("../../docs/theme/book.tex", string)

Book :: struct {
	b:       ^Build,
	doc:     ^dt.Doc, // the book
	visited: []bool,
	parts:   bool,
}

// Write the book's LaTeX source to ``tex``; false on failure (warned).
write_book_tex :: proc(s: ^Site, latex_dir, tex: string) -> bool {
	b := build_make(s, .Latex)
	defer build_destroy(b)
	context.allocator = b.allocator
	b.outdir = latex_dir
	for i in 1 ..< len(s.docs) {
		id := Doc_Id(i)
		if b.pages[id].doc == nil do continue
		r := Resolver{b, b.pages[id].doc, id}
		resolve_images(&r, id)
	}
	bk := Book {
		b       = b,
		visited = make([]bool, len(s.docs)),
		parts   = book_has_parts(b),
	}
	bk.doc = dt.new_document(tex, book_settings(bk.parts))
	defer dt.destroy(bk.doc)
	assemble_book(&bk)
	r := Resolver{b, bk.doc, NO_DOC}
	resolve_refs(&r)
	label_floats(bk.doc)
	ws := wr.settings_for(bk.doc, .Xetex)
	_, parts, err := wr.write(bk.doc, .Xetex, ws)
	if err != "" {
		warn(s, NO_DOC, strings.concatenate({"LaTeX writer: ", err}), 0, 3)
		return false
	}
	text, terr := fill_template(&bk, parts)
	if terr != "" {
		warn(s, NO_DOC, strings.concatenate({"book template: ", terr}), 0, 3)
		return false
	}
	return write_output(s, "", tex, text)
}

// The root document's sections below its title hold toctrees (or the
// configuration asks for parts).
@(private = "file")
book_has_parts :: proc(b: ^Build) -> bool {
	switch b.site.conf.latex_toplevel {
	case "part":
		return true
	case "chapter", "section":
		return false
	}
	top := b.pages[b.site.root].toc
	if top == 0 do return false
	for it := b.toc[top].first; it != 0; it = b.toc[it].next {
		if b.toc[it].kind == .Section && subtree_has_toctree(b, b.toc[it].first) do return true
	}
	return false
}

@(private = "file")
subtree_has_toctree :: proc(b: ^Build, first: Toc_Id) -> bool {
	for it := first; it != 0; it = b.toc[it].next {
		if b.toc[it].kind == .Toctree do return true
		if subtree_has_toctree(b, b.toc[it].first) do return true
	}
	return false
}

// The xetex writer's settings for the book.
@(private = "file")
book_settings :: proc(parts: bool) -> dt.Settings {
	settings := pb.default_settings(.Xetex, DOCUTILS_DIR)
	overrides := []pb.Override {
		{"documentclass", "book"},
		{"documentoptions", "11pt,a4paper,openany"},
		{"use_part_section", parts},
		{"doctitle_xform", false},
		{"table_style", "booktabs"},
		{"hyperlink_color", "0"},
		{"syntax_highlight", "none"},
		{"latex_preamble", ""},
	}
	pb.apply_overrides(&settings, .Xetex, overrides)
	return pb.to_doctree(settings)
}

// --- assembling ------------------------------------------------------------------------

@(private = "file")
assemble_book :: proc(bk: ^Book) {
	b := bk.b
	root := b.site.root
	src := b.pages[root].doc
	bk.visited[root] = true
	labels := strings.builder_make(context.temp_allocator)
	nodes := root_nodes(bk, &labels)
	// the opening text, up to the first section or toctree, is an
	// unnumbered chapter of the front matter
	k := 0
	opening := false
	for k < len(nodes) && !dt.is(src, nodes[k], {.section}) && !is_toctree(src, nodes[k]) {
		if !dt.is(src, nodes[k], {.comment, .target, .substitution_definition}) do opening = true
		k += 1
	}
	if opening {
		title := tex_escape(b.pages[root].title)
		add_raw(bk.doc, bk.doc.root, strings.concatenate({"\\chapter*{", title,
			"}\\addcontentsline{toc}{chapter}{", title, "}\\markboth{", title, "}{", title, "}",
			strings.to_string(labels)}))
		for n in nodes[:k] do import_node(bk, root, n, bk.doc.root)
		add_raw(bk.doc, bk.doc.root, "\\mainmatter")
	} else {
		opening_labels := strings.concatenate({"\\mainmatter", strings.to_string(labels)})
		add_raw(bk.doc, bk.doc.root, opening_labels)
		for n in nodes[:k] do import_node(bk, root, n, bk.doc.root)
	}
	for n in nodes[k:] do import_node(bk, root, n, bk.doc.root)
	label_terms(bk.doc)
}

// The root document's nodes, its title section replaced by its content
// (its title is the book's); the labels of the root into ``labels``.
@(private = "file")
root_nodes :: proc(bk: ^Book, labels: ^strings.Builder) -> []dt.Node {
	b := bk.b
	root := b.site.root
	src := b.pages[root].doc
	nodes := make([dynamic]dt.Node, context.temp_allocator)
	add_label(labels, global_id(b, root, ""))
	titled := false
	for n := dt.first_child(src, src.root); n != 0; n = dt.next_sibling(src, n) {
		if titled || !dt.is(src, n, {.section}) {
			if dt.tag(src, n) != .Text do append(&nodes, n)
			continue
		}
		titled = true
		for id in dt.attr_list(src, n, dt.K_IDS) {
			add_label(labels, global_id(b, root, dt.str(src, id)))
		}
		for c := dt.first_child(src, n); c != 0; c = dt.next_sibling(src, c) {
			if !dt.is(src, c, {.title}) && dt.tag(src, c) != .Text do append(&nodes, c)
		}
	}
	return nodes[:]
}

@(private = "file")
add_label :: proc(sb: ^strings.Builder, id: string) {
	strings.write_string(sb, "\\phantomsection\\label{")
	strings.write_string(sb, id)
	strings.write_string(sb, "}")
}

@(private = "file")
is_toctree :: proc(doc: ^dt.Doc, n: dt.Node) -> bool {
	_, ok := toctree_index(doc, n)
	return ok
}

// A raw LaTeX element with ``text`` under ``parent``.
@(private = "file")
add_raw :: proc(doc: ^dt.Doc, parent: dt.Node, text: string, first := false) {
	raw := dt.new_element(doc, .raw, "", text)
	dt.set_attr(doc, raw, "format", "latex")
	if first do dt.insert_child(doc, parent, 0, raw)
	else do dt.append_child(doc, parent, raw)
}

// Labels for the glossary terms (the writer gives terms none).
@(private = "file")
label_terms :: proc(doc: ^dt.Doc) {
	for n in dt.traverse(doc, doc.root, dt.Tag_Set{.term}) {
		ids := dt.attr_list(doc, n, dt.K_IDS)
		if len(ids) == 0 do continue
		sb := strings.builder_make(context.temp_allocator)
		for id in ids do add_label(&sb, dt.str(doc, id))
		add_raw(doc, n, strings.to_string(sb), first = true)
	}
}

// Import the children of ``parent`` (of document ``id``) under ``dst``.
@(private = "file")
import_children :: proc(bk: ^Book, id: Doc_Id, parent, dst: dt.Node) {
	src := bk.b.pages[id].doc
	for n := dt.first_child(src, parent); n != 0; n = dt.next_sibling(src, n) {
				import_node(bk, id, n, dst)
	}
}

// Import ``n`` (a toctree: the documents it lists) under ``dst``.
@(private = "file")
import_node :: proc(bk: ^Book, id: Doc_Id, n: dt.Node, dst: dt.Node) {
	b := bk.b
	src := b.pages[id].doc
	if t, ok := toctree_index(src, n); ok {
		for e in toctree_entries(b, t) {
			if e.doc == NO_DOC || bk.visited[e.doc] || b.pages[e.doc].doc == nil do continue
			bk.visited[e.doc] = true
			import_document(bk, e.doc, dst)
		}
		return
	}
	m := dt.import_node(bk.doc, src, n)
	globalize_ids(bk, id, m)
	dt.append_child(bk.doc, dst, m)
	import_children(bk, id, n, m)
}

// The top-level nodes of document ``id``; its first section gets the id of
// the document ("doc-<name>--top").
@(private = "file")
import_document :: proc(bk: ^Book, id: Doc_Id, dst: dt.Node) {
	src := bk.b.pages[id].doc
	first := true
	for n := dt.first_child(src, src.root); n != 0; n = dt.next_sibling(src, n) {
		if dt.tag(src, n) == .Text do continue
		before := dt.child_count(bk.doc, dst)
		import_node(bk, id, n, dst)
		if first && dt.is(src, n, {.section}) && dt.child_count(bk.doc, dst) > before {
			m := dt.child_at(bk.doc, dst, dt.child_count(bk.doc, dst) - 1)
			dt.list_append(bk.doc, m, dt.K_IDS, global_id(bk.b, id, ""))
			first = false
		}
	}
}

// Ids and id references of document ``id`` made global.
@(private = "file")
globalize_ids :: proc(bk: ^Book, id: Doc_Id, m: dt.Node) {
	doc := bk.doc
	if dt.tag(doc, m) == .Text do return
	for key in ([]dt.Str{dt.K_IDS, dt.K_BACKREFS}) {
		list := dt.attr_list(doc, m, key)
		if len(list) == 0 do continue
		values := make([]string, len(list), context.temp_allocator)
		for s, i in list do values[i] = global_id(bk.b, id, dt.str(doc, s))
		dt.set_list(doc, m, key, ..values)
	}
	if dt.has_attr(doc, m, dt.K_REFID) {
		dt.set_attr(doc, m, dt.K_REFID, global_id(bk.b, id, dt.get_string(doc, m, dt.K_REFID)))
	}
}

// ``\label{<id>-num}`` in the captions of figures and tables, for the
// ``numref`` references (``\ref*``) to their LaTeX numbers.
@(private = "file")
label_floats :: proc(doc: ^dt.Doc) {
	for n in dt.traverse(doc, doc.root, dt.Tag_Set{.figure, .table}) {
		ids := dt.attr_list(doc, n, dt.K_IDS)
		if len(ids) == 0 do continue
		caption := caption_of(doc, n, figtype_of(doc, n))
		if caption == 0 do continue
		raw := dt.new_element(doc, .raw, "", strings.concatenate({"\\label{",
			dt.str(doc, ids[0]), "-num}"}))
		dt.set_attr(doc, raw, "format", "latex")
		dt.append_child(doc, caption, raw)
	}
}

// --- the template ----------------------------------------------------------------------

@(private = "file")
fill_template :: proc(bk: ^Book, parts: wr.Parts) -> (string, string) {
	conf := &bk.b.site.conf
	values := make(map[string]string, 32, context.temp_allocator)
	for name in ([]string{"head_prefix", "requirements", "fallbacks", "pdfsetup", "body"}) {
		values[name], _ = wr.part(parts, name)
	}
	// numbered toctrees number the chapters; part labels number the parts
	values["secnumdepth"] = "2" if book_numbered(bk.b) else "-1" if conf.part_labels else "-2"
	values["tocdepth"] = "1" if bk.parts else "0" // sections under parts, else chapters
	values["title"] = tex_escape(conf.project)
	values["tagline"] = tex_escape(conf.tagline)
	values["version"] = tex_escape(conf.release)
	values["author"] = tex_escape(conf.author)
	values["copyright"] = tex_escape(conf.copyright)
	values["date"] = tex_escape(today(conf))
	values["generator"] = "docodin " + VERSION
	return wr.substitute_template(BOOK_TEMPLATE, values)
}

// Some toctree of the book is numbered.
@(private = "file")
book_numbered :: proc(b: ^Build) -> bool {
	for t in b.toctrees do if t.numbered > 0 do return true
	return false
}

// ``today`` in ``today_fmt`` (``%B %d, %Y`` by default).
today :: proc(conf: ^Conf) -> string {
	if s, ok := conf.values["today"].(string); ok && s != "" do return s
	sb := strings.builder_make(context.temp_allocator)
	format := conf.today_fmt
	for i := 0; i < len(format); i += 1 {
		if format[i] != '%' || i + 1 >= len(format) {
			strings.write_byte(&sb, format[i])
			continue
		}
		i += 1
		write_date_field(&sb, format[i])
	}
	return strings.to_string(sb)
}

// A ``strftime`` field of today's date (%B %b %d %m %Y).
@(private = "file")
write_date_field :: proc(sb: ^strings.Builder, field: u8) {
	y, m, d := time.date(time.now())
	months := [?]string{"January", "February", "March", "April", "May", "June", "July",
		"August", "September", "October", "November", "December"}
	two :: proc(sb: ^strings.Builder, n: int) {
		if n < 10 do strings.write_byte(sb, '0')
		strings.write_int(sb, n)
	}
	switch field {
	case 'B':
		strings.write_string(sb, months[int(m) - 1])
	case 'b':
		strings.write_string(sb, months[int(m) - 1][:3])
	case 'd':
		two(sb, d)
	case 'm':
		two(sb, int(m))
	case 'Y':
		strings.write_int(sb, y)
	case:
		strings.write_byte(sb, field)
	}
}

// Text for LaTeX (outside math).
tex_escape :: proc(s: string) -> string {
	sb := strings.builder_make()
	for r in s {
		switch r {
		case '\\':
			strings.write_string(&sb, "\\textbackslash{}")
		case '{', '}', '$', '&', '#', '_', '%':
			strings.write_byte(&sb, '\\')
			strings.write_rune(&sb, r)
		case '~':
			strings.write_string(&sb, "\\textasciitilde{}")
		case '^':
			strings.write_string(&sb, "\\textasciicircum{}")
		case:
			strings.write_rune(&sb, r)
		}
	}
	return strings.to_string(sb)
}

// --- images ----------------------------------------------------------------------------

// The file LaTeX includes for image ``src``: SVG images are converted to
// PDF with ``rsvg-convert`` (or Inkscape) into the LaTeX directory.
latex_image :: proc(b: ^Build, src: string) -> string {
	if !strings.has_suffix(strings.to_lower(src, context.temp_allocator), ".svg") do return src
	name := strings.concatenate({filepath.stem(src), "-", short_hash(src), ".pdf"})
	dst := join(join(b.outdir, "images"), name)
	os.make_directory_all(filepath.dir(dst))
	if tool, ok := find_program("rsvg-convert"); ok {
		if run_quiet({tool, "-f", "pdf", "-o", dst, src}) do return dst
	}
	if tool, ok := find_program("inkscape"); ok {
		target := strings.concatenate({"--export-filename=", dst})
		if run_quiet({tool, src, "--export-type=pdf", target}) {
			return dst
		}
	}
	warn(b.site, NO_DOC, strings.concatenate({"cannot convert the SVG image ", src,
		" to PDF for the book: install rsvg-convert (librsvg) or Inkscape"}), 0)
	return src
}

@(private = "file")
short_hash :: proc(s: string) -> string {
	h: u32 = 2166136261
	for i in 0 ..< len(s) do h = (h ~ u32(s[i])) * 16777619
	digits := "0123456789abcdef"
	buf := make([]u8, 8)
	for i in 0 ..< 8 do buf[7 - i] = digits[(h >> (4 * u32(i))) & 15]
	return string(buf)
}

@(private = "file")
run_quiet :: proc(command: []string) -> bool {
	state, _, _, err := os.process_exec(os.Process_Desc{command = command}, context.temp_allocator)
	return err == nil && state.success
}
