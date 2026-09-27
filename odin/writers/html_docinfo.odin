package writers

import dt "../doctree"

// HTML5 visitors of the docinfo element and the bibliographic fields
// (``_html_base_docinfo.DocinfoTranslatorMixin`` with the html5 overrides).

// How a bibliographic element is written: its label and whether it gets a
// ``<meta>`` tag of its own name (html5: only "author" outside "authors").
@(private = "file")
Docinfo_Item :: struct {
	label: Label,
	name:  string,
}

@(private = "file")
DOCINFO_ITEMS := #partial [dt.Tag]Docinfo_Item {
	.address      = {.address, "address"},
	.author       = {.author, "author"},
	.authors      = {.authors, "authors"},
	.contact      = {.contact, "contact"},
	.copyright    = {.copyright, "copyright"},
	.date         = {.date, "date"},
	.organization = {.organization, "organization"},
	.revision     = {.revision, "revision"},
	.status       = {.status, "status"},
	.version      = {.version, "version"},
}

// ``<meta name="{name}" content="{attval(text)}" />``.
@(private = "file")
put_meta :: proc(t: ^Html, name, text: string) {
	begin(&t.meta)
	w(&t.meta, "<meta name=\"")
	w(&t.meta, name)
	w(&t.meta, "\" content=\"")
	write_attval(t, &t.meta, text)
	w(&t.meta, "\" />\n")
}

// ``visit_docinfo_item(node, name, meta)``.
@(private = "file")
visit_docinfo_item :: proc(t: ^Html, n: dt.Node, meta: bool) {
	item := DOCINFO_ITEMS[dt.tag(t.doc, n)]
	if meta do put_meta(t, item.name, astext(t.doc, n))
	begin(&t.body)
	w(&t.body, "<dt class=\"")
	w(&t.body, item.name)
	w(&t.body, "\">")
	w(&t.body, t.language.labels[item.label])
	w(&t.body, "<span class=\"colon\">:</span></dt>\n")
	starttag(t, n, "dd", "", class = item.name)
}

// ``depart_docinfo_item``.
html_depart_docinfo_item :: proc(t: ^Html, n: dt.Node) {
	put(&t.body, "</dd>\n")
}

// Items without a ``<meta>`` tag: address (below), contact, organization,
// revision, status and version.
html_visit_docinfo_item :: proc(t: ^Html, n: dt.Node) -> Visit {
	visit_docinfo_item(t, n, false)
	return .Continue
}

html_visit_address :: proc(t: ^Html, n: dt.Node) -> Visit {
	visit_docinfo_item(t, n, false)
	starttag(t, n, "pre", "", class = "address")
	return .Continue
}

html_depart_address :: proc(t: ^Html, n: dt.Node) {
	put(&t.body, "\n</pre>\n")
	put(&t.body, "</dd>\n")
}

html_visit_author :: proc(t: ^Html, n: dt.Node) -> Visit {
	if !parent_is(t.doc, n, {.authors}) do visit_docinfo_item(t, n, true)
	put(&t.body, "<p>")
	return .Continue
}

html_depart_author :: proc(t: ^Html, n: dt.Node) {
	put(&t.body, "</p>")
	put(&t.body, "\n" if parent_is(t.doc, n, {.authors}) else "</dd>\n")
}

html_visit_authors :: proc(t: ^Html, n: dt.Node) -> Visit {
	visit_docinfo_item(t, n, false)
	for c := dt.first_child(t.doc, n); c != 0; c = dt.next_sibling(t.doc, c) {
		put_meta(t, "author", astext(t.doc, c))
	}
	return .Continue
}

html_visit_copyright :: proc(t: ^Html, n: dt.Node) -> Visit {
	visit_docinfo_item(t, n, false)
	put_meta(t, "dcterms.rights", astext(t.doc, n))
	return .Continue
}

html_visit_date :: proc(t: ^Html, n: dt.Node) -> Visit {
	visit_docinfo_item(t, n, false)
	put_meta(t, "dcterms.date", astext(t.doc, n))
	return .Continue
}

html_visit_docinfo :: proc(t: ^Html, n: dt.Node) -> Visit {
	push_ctx(t, chunks(&t.body))
	starttag(t, n, "dl", classes = {"docinfo", "simple"} if is_compactable(t, n) else {"docinfo"})
	return .Continue
}

html_depart_docinfo :: proc(t: ^Html, n: dt.Node) {
	put(&t.body, "</dl>\n")
	start := pop_int(t)
	truncate(&t.docinfo, 0)
	put_range(&t.docinfo, &t.body, start)
	reset(&t.body)
}
