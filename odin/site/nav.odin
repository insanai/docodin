package site

import "core:strings"

// The theme's navigation: the site tree in the left sidebar (every toctree
// from the root, titles only, hidden toctrees included, as furo shows it),
// with the current page's ancestors open, and the page's own sections on
// the right ("On this page").

@(private = "file")
Nav :: struct {
	sb:      ^strings.Builder,
	b:       ^Build,
	current: Doc_Id,
	from:    string, // the page's docname
	chain:   []Doc_Id, // the current page and its ancestors
	boxes:   int, // checkboxes written
}

nav_tree :: proc(sb: ^strings.Builder, b: ^Build, current: Doc_Id) {
	s := b.site
	nav := Nav {
		sb      = sb,
		b       = b,
		current = current,
		from    = s.docs[current].name if current != NO_DOC else "search",
	}
	if current != NO_DOC do nav.chain = ancestors(b, current)
	w :: strings.write_string
	w(sb, "<nav class=\"nav-tree\" aria-label=\"Contents\">\n")
	for t in doc_toctrees(b, s.root) {
		caption := b.toctrees[t].caption
		if caption == "" do caption = part_title(b, t)
		if caption != "" {
			w(sb, "<p class=\"caption\"><span class=\"caption-text\">")
			w(sb, html_escape(caption))
			w(sb, "</span></p>\n")
		}
		w(sb, "<ul>\n")
		for e in toctree_entries(b, t) do nav_item(&nav, e, 1)
		w(sb, "</ul>\n")
	}
	w(sb, "</nav>\n")
}

@(private = "file")
nav_item :: proc(nav: ^Nav, e: Toc_Entry, level: int) {
	sb := nav.sb
	b := nav.b
	w :: strings.write_string
	if e.doc == NO_DOC {
		nav_external(nav, e, level)
		return
	}
	in_chain := contains_doc(nav.chain, e.doc)
	children := doc_toctrees(b, e.doc)
	has_children := false
	for t in children do if b.toctrees[t].count > 0 do has_children = true
	w(sb, "<li class=\"toctree-l")
	w(sb, rd_itoa(level))
	if in_chain do w(sb, " current")
	if has_children do w(sb, " has-children")
	w(sb, "\"><a class=\"reference")
	if e.doc == nav.current do w(sb, " current-page\" aria-current=\"page")
	w(sb, "\" href=\"")
	w(sb, relative_url(nav.from, b.site.docs[e.doc].name))
	w(sb, "\">")
	title := e.title if e.title != "" else numbered_title(b, e.doc)
	w(sb, html_escape(title))
	w(sb, "</a>")
	if has_children {
		nav_toggle(nav, title, in_chain)
		w(sb, "<ul>\n")
		for t in children do for sub in toctree_entries(b, t) do nav_item(nav, sub, level + 1)
		w(sb, "</ul>\n")
	}
	w(sb, "</li>\n")
}

@(private = "file")
nav_external :: proc(nav: ^Nav, e: Toc_Entry, level: int) {
	w :: strings.write_string
	w(nav.sb, "<li class=\"toctree-l")
	w(nav.sb, rd_itoa(level))
	w(nav.sb, "\"><a class=\"reference external\" href=\"")
	w(nav.sb, html_escape(e.url))
	w(nav.sb, "\">")
	w(nav.sb, html_escape(e.title if e.title != "" else e.url))
	w(nav.sb, "</a></li>\n")
}

// The checkbox and label that open and close an item's children.
@(private = "file")
nav_toggle :: proc(nav: ^Nav, title: string, open: bool) {
	w :: strings.write_string
	sb := nav.sb
	nav.boxes += 1
	id := strings.concatenate({"nav-", rd_itoa(nav.boxes)})
	w(sb, "<input type=\"checkbox\" class=\"toctree-checkbox\" id=\"")
	w(sb, id)
	w(sb, "\"")
	if open do w(sb, " checked")
	w(sb, " /><label for=\"")
	w(sb, id)
	w(sb, "\"><span class=\"visually-hidden\">Toggle ")
	w(sb, html_escape(title))
	w(sb, "</span>")
	w(sb, ICON_CHEVRON)
	w(sb, "</label>\n")
}

@(private = "file")
contains_doc :: proc(list: []Doc_Id, id: Doc_Id) -> bool {
	for x in list do if x == id do return true
	return false
}

// The title of the root's section holding toctree ``t`` (a part of the
// book), "" when it is not in a section below the title.
part_title :: proc(b: ^Build, t: int) -> string {
	top := b.pages[b.site.root].toc
	if top == 0 do return ""
	for it := b.toc[top].first; it != 0; it = b.toc[it].next {
		if b.toc[it].kind == .Section && holds_toctree(b, b.toc[it].first, t) {
			return b.toc[it].title
		}
	}
	return ""
}

@(private = "file")
holds_toctree :: proc(b: ^Build, first: Toc_Id, t: int) -> bool {
	for it := first; it != 0; it = b.toc[it].next {
		item := b.toc[it]
		if item.kind == .Toctree && item.toctree == t do return true
		if item.kind == .Section && holds_toctree(b, item.first, t) do return true
	}
	return false
}

// --- on this page ------------------------------------------------------------------------

LOCAL_TOC_DEPTH :: 3

page_local_toc :: proc(sb: ^strings.Builder, b: ^Build, id: Doc_Id) {
	top := b.pages[id].toc
	w :: strings.write_string
	has := top != 0 && has_sections(b, b.toc[top].first)
	w(sb, "<aside class=\"dod-toc")
	if !has do w(sb, " empty")
	w(sb, "\" aria-label=\"On this page\">\n<div class=\"dod-toc-inner\">\n")
	if has {
		w(sb, "<p class=\"dod-toc-title\">On this page</p>\n")
		local_toc_list(sb, b, b.toc[top].first, 1)
	}
	w(sb, "</div>\n</aside>\n")
}

@(private = "file")
has_sections :: proc(b: ^Build, first: Toc_Id) -> bool {
	for it := first; it != 0; it = b.toc[it].next do if b.toc[it].kind == .Section do return true
	return false
}

@(private = "file")
local_toc_list :: proc(sb: ^strings.Builder, b: ^Build, first: Toc_Id, depth: int) {
	w :: strings.write_string
	w(sb, "<ul>\n")
	for it := first; it != 0; it = b.toc[it].next {
		item := b.toc[it]
		if item.kind != .Section do continue
		w(sb, "<li><a href=\"#")
		w(sb, item.id)
		w(sb, "\">")
		w(sb, html_escape(item.title))
		w(sb, "</a>")
		if depth < LOCAL_TOC_DEPTH && has_sections(b, item.first) {
			local_toc_list(sb, b, item.first, depth + 1)
		}
		w(sb, "</li>\n")
	}
	w(sb, "</ul>\n")
}

// --- icons -------------------------------------------------------------------------------

LOGO ::
	`<svg class="logo" viewBox="0 0 32 32" aria-hidden="true"><defs>` +
	`<linearGradient id="logo-g" x1="0" y1="0" x2="1" y2="1">` +
	`<stop offset="0" stop-color="#3b6cf6"/><stop offset="1" stop-color="#1b2a55"/>` +
	`</linearGradient></defs><rect width="32" height="32" rx="8" fill="url(#logo-g)"/>` +
	`<path d="M10 8.5h5.5a7.5 7.5 0 0 1 0 15H10z" fill="none" stroke="#fff" stroke-width="2.4"/>` +
	`<path d="M10 16h6" stroke="#9fc0ff" stroke-width="2.4"/>` +
	`<circle cx="23.5" cy="8.5" r="2.2" fill="#9fc0ff"/></svg>`

@(private = "file")
SVG :: `<svg viewBox="0 0 24 24" aria-hidden="true">`

ICON_MENU :: SVG + `<path d="M4 6h16M4 12h16M4 18h16"/></svg>`
ICON_TOC :: SVG + `<path d="M4 6h10M4 12h16M4 18h12"/></svg>`
ICON_CHEVRON :: `<svg class="chevron" viewBox="0 0 24 24" aria-hidden="true">` +
	`<path d="M9 6l6 6-6 6"/></svg>`
ICON_BOOK :: SVG + `<path d="M4 5a2 2 0 0 1 2-2h13v16H6a2 2 0 0 0-2 2z"/>` +
	`<path d="M8 7h7M8 11h5"/></svg>`
ICON_SUN :: `<svg class="icon-sun" viewBox="0 0 24 24" aria-hidden="true">` +
	`<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4` +
	`M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>`
ICON_MOON :: `<svg class="icon-moon" viewBox="0 0 24 24" aria-hidden="true">` +
	`<path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/></svg>`
ICON_AUTO :: `<svg class="icon-auto" viewBox="0 0 24 24" aria-hidden="true">` +
	`<circle cx="12" cy="12" r="8"/><path d="M12 4a8 8 0 0 1 0 16z" class="fill"/></svg>`
