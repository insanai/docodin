package site

import "core:os"
import "core:path/filepath"
import "core:strings"

import dt "../doctree"

// Resolving what the documents refer to across the project, once every
// document is read (Sphinx's post-transforms): cross references, toctrees
// (HTML), section and figure numbers (HTML), and images and downloads
// (files copied to the output).  For HTML each page is resolved in its own
// document; for LaTeX the book's single document is (see book.odin).

// Where a reference points: a document and an anchor ("" for the top).
Link :: struct {
	doc:    Doc_Id,
	anchor: string,
}

Resolver :: struct {
	b:    ^Build,
	doc:  ^dt.Doc,
	from: Doc_Id, // the page (HTML); NO_DOC in the book
}

// A file the output needs: copied from ``src`` to ``dst`` (relative to the
// output directory).
Asset :: struct {
	src, dst: string,
}

// The references of ``r.doc``, placeholders (see roles.odin) replaced.
resolve_refs :: proc(r: ^Resolver) {
	doc := r.doc
	for n in dt.traverse(r.doc, doc.root, dt.Tag_Set{.inline}) {
		if !dt.has_attr(doc, n, ATTR_REFTYPE) do continue
		kind := dt.get_string(doc, n, ATTR_REFTYPE)
		switch kind {
		case "download":
			resolve_download(r, n)
		case:
			resolve_xref(r, n, kind)
		}
	}
}

@(private = "file")
resolve_xref :: proc(r: ^Resolver, n: dt.Node, kind: string) {
	doc := r.doc
	b := r.b
	target := dt.get_string(doc, n, ATTR_REFTARGET)
	explicit, _ := dt.get_attr(doc, n, ATTR_REFEXPLICIT)
	is_explicit, _ := explicit.(bool)
	title := dt.astext(doc, n)
	link: Link
	ok: bool
	switch kind {
	case "doc":
		link, title, ok = resolve_doc(r, n, target, title, is_explicit)
	case "ref":
		link, title, ok = resolve_ref(r, n, target, title, is_explicit)
	case "numref":
		link, title, ok = resolve_numref(r, n, target, title, is_explicit)
	case "term":
		t, found := b.terms[target]
		link, ok = Link{t.doc, t.id}, found
		if !found do ref_warning(r, n, "term not in glossary: '", target, "'")
	}
	if !ok {
		dt.delete_attr(doc, n, ATTR_REFTYPE)
		return
	}
	inner := dt.new_element(doc, .inline)
	add_title_text(doc, inner, title)
	for c in dt.attr_list(doc, n, dt.K_CLASSES) {
		if dt.str(doc, c) != "xref" do dt.list_append(doc, inner, dt.K_CLASSES, dt.str(doc, c))
	}
	ref := make_reference(r, link, n)
	dt.append_child(doc, ref, inner)
	dt.set_list(doc, n, dt.K_CLASSES) // ``replace_self`` would give them to the reference
	dt.replace_self(doc, n, ref)
}

@(private = "file")
resolve_doc :: proc(
	r: ^Resolver,
	n: dt.Node,
	target, title: string,
	explicit: bool,
) -> (
	Link,
	string,
	bool,
) {
	id, found := r.b.site.by_name[target]
	if !found {
		ref_warning(r, n, "unknown document: '", target, "'")
		return {}, title, false
	}
	return Link{id, ""}, title if explicit else r.b.pages[id].title, true
}

@(private = "file")
resolve_ref :: proc(
	r: ^Resolver,
	n: dt.Node,
	target, title: string,
	explicit: bool,
) -> (
	Link,
	string,
	bool,
) {
	t, found := r.b.labels[target]
	if !found {
		ref_warning(r, n, "undefined label: '", target, "'")
		return {}, title, false
	}
	if explicit do return Link{t.doc, t.id}, title, true
	if t.title == "" {
		ref_warning(r, n, "Failed to create a cross reference. A title or caption not found: '",
			target, "'")
		return {}, title, false
	}
	return Link{t.doc, t.id}, t.title, true
}

@(private = "file")
resolve_numref :: proc(
	r: ^Resolver,
	n: dt.Node,
	target, title: string,
	explicit: bool,
) -> (
	Link,
	string,
	bool,
) {
	b := r.b
	t, found := b.labels[target]
	if !found {
		ref_warning(r, n, "undefined label: '", target, "'")
		return {}, title, false
	}
	number: []int
	if t.figtype == .Section {
		if it := section_toc(b, t.doc, t.node); it != 0 do number = b.toc[it].number
	} else {
		number = b.fignums[Fig_Key{t.doc, t.id}]
	}
	if number == nil || !b.site.conf.numfig {
		ref_warning(r, n, "Failed to create a cross reference. Any number is not assigned: ",
			target)
		return {}, title, false
	}
	format := title if explicit else numfig_format(b, t.figtype)
	text := number_text(number)
	if b.format == .Latex && (t.figtype == .Figure || t.figtype == .Table) {
		// LaTeX numbers its floats itself (see ``number_floats``)
		text = strings.concatenate({REF_MARK, global_id(b, t.doc, t.id), REF_MARK})
	}
	out, _ := strings.replace_all(format, "%s", text)
	out, _ = strings.replace_all(out, "{number}", text)
	out, _ = strings.replace_all(out, "{name}", t.title)
	return Link{t.doc, t.id}, out, true
}

// Around a book id in a reference title: LaTeX's number of that float.
@(private = "file")
REF_MARK :: "\x00"

// ``title`` as the text of ``parent``; the ``REF_MARK`` parts become raw
// ``\ref*`` commands.
@(private = "file")
add_title_text :: proc(doc: ^dt.Doc, parent: dt.Node, title: string) {
	rest := title
	for len(rest) > 0 {
		start := strings.index(rest, REF_MARK)
		if start < 0 {
			dt.append_child(doc, parent, dt.new_text(doc, rest))
			return
		}
		if start > 0 do dt.append_child(doc, parent, dt.new_text(doc, rest[:start]))
		after := rest[start + 1:]
		end := strings.index(after, REF_MARK)
		if end < 0 do end = len(after)
		command := strings.concatenate({"\\ref*{", after[:end], "-num}"})
		raw := dt.new_element(doc, .raw, "", command)
		dt.set_attr(doc, raw, "format", "latex")
		dt.append_child(doc, parent, raw)
		rest = after[min(end + 1, len(after)):]
	}
}

// A warning at the placeholder ``n``.
@(private = "file")
ref_warning :: proc(r: ^Resolver, n: dt.Node, parts: ..string) {
	doc := r.doc
	source, _ := dt.source(doc, n)
	line := node_line(doc, n)
	id := r.from
	if id == NO_DOC || source != r.b.site.docs[id].path do id = doc_of_path(r.b.site, source)
	warn_at(r.b.site, id, source, line, strings.concatenate(parts, context.temp_allocator), 2)
}

doc_of_path :: proc(s: ^Site, path: string) -> Doc_Id {
	for d, i in s.docs do if i > 0 && d.path == path do return Doc_Id(i)
	return NO_DOC
}

// A ``reference`` to ``link`` from the resolver's page (class "internal").
make_reference :: proc(r: ^Resolver, link: Link, from_node: dt.Node) -> dt.Node {
	doc := r.doc
	ref := dt.new_element(doc, .reference, from_node != 0 ? doc.nodes[from_node].text : "")
	switch {
	case r.from == NO_DOC:
		dt.set_attr(doc, ref, dt.K_REFID, global_id(r.b, link.doc, link.anchor))
	case link.doc == r.from && link.anchor != "":
		dt.set_attr(doc, ref, dt.K_REFID, link.anchor)
	case:
		dt.set_attr(doc, ref, dt.K_REFURI, page_url(r.b, r.from, link))
	}
	dt.list_append(doc, ref, dt.K_CLASSES, "internal")
	return ref
}

// The URL of ``link`` from page ``from``.
page_url :: proc(b: ^Build, from: Doc_Id, link: Link) -> string {
	s := b.site
	url := relative_url(s.docs[from].name, s.docs[link.doc].name)
	if link.anchor != "" do url = strings.concatenate({url, "#", link.anchor})
	return url
}

// The book's id of anchor ``anchor`` of document ``id`` (its top section
// for "").
global_id :: proc(b: ^Build, id: Doc_Id, anchor: string) -> string {
	a := anchor
	if a == "" do a = "top"
	name, _ := strings.replace_all(b.site.docs[id].name, "/", "-")
	return strings.concatenate({"doc-", name, "--", a})
}

// --- downloads and images -----------------------------------------------------------------

@(private = "file")
resolve_download :: proc(r: ^Resolver, n: dt.Node) {
	doc := r.doc
	path := dt.get_string(doc, n, ATTR_REFTARGET)
	dt.delete_attr(doc, n, ATTR_REFTYPE)
	if r.from == NO_DOC || !os.is_file(path) do return
	dst := strings.concatenate({"_downloads/", filepath.base(path)})
	append(&r.b.assets, Asset{strings.clone(path), dst})
	ref := dt.new_element(doc, .reference)
	dt.set_attr(doc, ref, dt.K_REFURI, relative_path(r.b.site.docs[r.from].name, dst))
	dt.list_append(doc, ref, dt.K_CLASSES, "download")
	for ch := dt.first_child(doc, n); ch != 0; ch = dt.first_child(doc, n) {
		dt.remove_child(doc, n, ch)
		dt.append_child(doc, ref, ch)
	}
	dt.append_child(doc, n, ref)
}

// Image URIs as Sphinx reads them (relative to the document, or to the
// source directory with a leading "/"; "name.*" picks a file for the
// format): the HTML pages refer to copies in the output tree, the book
// to the source files.
resolve_images :: proc(r: ^Resolver, from: Doc_Id) {
	doc := r.doc
	b := r.b
	for n in dt.traverse(doc, doc.root, dt.Tag_Set{.image}) {
		uri := dt.get_string(doc, n, "uri")
		if uri == "" || strings.contains(uri, "://") || strings.has_prefix(uri, "data:") {
			continue
		}
		rel := uri[1:] if strings.has_prefix(uri, "/") else
			normalize_docname(join(doc_dir(b.site.docs[from].name), uri))
		rel = pick_candidate(b, rel)
		src := join(b.site.srcdir, rel)
		if !os.is_file(src) {
			warn(b.site, from, strings.concatenate({"image file not readable: ", rel}),
				node_line(doc, n))
			continue
		}
		if b.format == .Html {
			append(&b.assets, Asset{src, rel})
			dt.set_attr(doc, n, "uri", relative_path(b.site.docs[r.from].name, rel))
		} else {
			dt.set_attr(doc, n, "uri", latex_image(b, src))
		}
	}
}

// "name.*": the first existing candidate in the format's order.
@(private = "file")
pick_candidate :: proc(b: ^Build, rel: string) -> string {
	if !strings.has_suffix(rel, ".*") do return rel
	stem := rel[:len(rel) - 1]
	html := []string{"svg", "png", "jpg", "jpeg", "gif", "webp"}
	latex := []string{"pdf", "png", "jpg", "jpeg", "svg"}
	for ext in (html if b.format == .Html else latex) {
		cand := strings.concatenate({stem, ext})
		if os.is_file(join(b.site.srcdir, cand)) do return cand
	}
	return rel
}
