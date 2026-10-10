package site

import "core:os"
import "core:path/filepath"
import "core:strings"

import dt "../doctree"
import wr "../writers"
import "../version"

// The HTML site: one page per document (the html5 writer's body in the
// docodin theme's page), the theme's stylesheet and script, the project's
// static files, the images and downloads the pages use, a search page and
// the search index.

THEME_CSS :: #load("../../docs/theme/docodin.css", string)
THEME_JS :: #load("../../docs/theme/docodin.js", string)

VERSION :: version.VERSION

Html_Options :: struct {
	pdf: string, // the PDF book to offer for download ("" for none)
}

// Build the HTML site of ``s`` into ``outdir``; false when a page or file
// could not be written (the warnings say why).
write_html :: proc(s: ^Site, outdir: string, options: Html_Options) -> bool {
	b := build_make(s, .Html)
	defer build_destroy(b)
	context.allocator = b.allocator
	index := search_index_make(b)
	ok := true
	for i in 1 ..< len(s.docs) {
		id := Doc_Id(i)
		if b.pages[id].doc == nil do continue
		prepare_html_page(b, id)
		body, err := page_body(b, id)
		if err != "" {
			warn(s, id, err, 0, 3)
			continue
		}
		search_index_add(&index, b, id)
		page := render_page(b, id, body, options)
		ok &= write_output(s, outdir, strings.concatenate({s.docs[id].name, ".html"}), page)
	}
	ok &= write_output(s, outdir, "search.html", render_search_page(b, options))
	ok &= write_output(s, outdir, "searchindex.json", search_index_json(&index))
	ok &= write_output(s, outdir, "searchindex.js", strings.concatenate({
		"window.DOCODIN_SEARCH_INDEX = ", search_index_json(&index), ";\n"}))
	ok &= copy_static(b, outdir)
	if options.pdf != "" {
		ok &= copy_asset(s, outdir, Asset{options.pdf, strings.concatenate({"_downloads/",
			filepath.base(options.pdf)})})
	}
	for a in b.assets do ok &= copy_asset(s, outdir, a)
	return ok
}

// The html5 writer's body of a page.
@(private = "file")
page_body :: proc(b: ^Build, id: Doc_Id) -> (string, string) {
	doc := b.pages[id].doc
	ws := wr.settings_for(doc, .Html5)
	_, parts, err := wr.write(doc, .Html5, ws, b.allocator)
	if err != "" do return "", err
	body, _ := wr.part(parts, "body")
	// links to other pages are internal (docutils calls every ``refuri``
	// external)
	body, _ = strings.replace_all(body, "class=\"reference external internal",
		"class=\"reference internal")
	return body, ""
}

// Write ``text`` to ``rel`` under ``outdir`` (making its directory).
write_output :: proc(s: ^Site, outdir, rel, text: string) -> bool {
	path := join(outdir, rel)
	os.make_directory_all(filepath.dir(path))
	if err := os.write_entire_file(path, text); err != nil {
		warn(s, NO_DOC, strings.concatenate({"cannot write ", path, ": ", os.error_string(err)}),
			0, 3)
		return false
	}
	return true
}

copy_asset :: proc(s: ^Site, outdir: string, a: Asset) -> bool {
	dst := join(outdir, a.dst)
	os.make_directory_all(filepath.dir(dst))
	if err := os.copy_file(dst, a.src); err != nil {
		warn(s, NO_DOC, strings.concatenate({"cannot copy ", a.src, ": ", os.error_string(err)}),
			0, 3)
		return false
	}
	return true
}

// The theme's files, then the files of ``html_static_path`` (but the
// theme's) into ``_static``.
@(private = "file")
copy_static :: proc(b: ^Build, outdir: string) -> bool {
	s := b.site
	ok := true
	for dir in s.conf.html_static_path {
		src := join(s.srcdir, dir)
		copy_tree(s, src, join(outdir, "_static"), &ok)
	}
	if logo := s.conf.html_logo; logo != "" {
		dst := strings.concatenate({"_static/", filepath.base(logo)})
		ok &= copy_asset(s, outdir, Asset{join(s.srcdir, logo), dst})
	}
	ok &= write_output(s, outdir, "_static/docodin.css", THEME_CSS)
	ok &= write_output(s, outdir, "_static/docodin.js", THEME_JS)
	return ok
}

@(private = "file")
copy_tree :: proc(s: ^Site, src, dst: string, ok: ^bool) {
	entries, err := os.read_all_directory_by_path(src, context.temp_allocator)
	if err != nil do return
	for fi in entries {
		if strings.has_prefix(fi.name, ".") do continue
		if fi.type == .Directory {
			copy_tree(s, fi.fullpath, join(dst, fi.name), ok)
			continue
		}
		if fi.name == "docodin.css" || fi.name == "docodin.js" do continue
		if strings.has_suffix(fi.name, ".tex") do continue
		ok^ &= copy_asset(s, "", Asset{fi.fullpath, join(dst, fi.name)})
	}
}

// --- the page ----------------------------------------------------------------------------

// The page of document ``id`` around the writer's ``body``.
@(private = "file")
render_page :: proc(b: ^Build, id: Doc_Id, body: string, options: Html_Options) -> string {
	s := b.site
	sb := strings.builder_make()
	name := s.docs[id].name
	title := s.conf.html_title
	if id != s.root do title = strings.concatenate({b.pages[id].title, " — ", title})
	page_head(&sb, b, name, title)
	page_sidebar(&sb, b, id, name, options)
	strings.write_string(&sb, "<main class=\"dod-main\" id=\"content\">\n")
	page_topbar(&sb, b, id)
	classes := "dod-article part-page" if is_part_page(b, id) else "dod-article"
	strings.write_string(&sb, "<article class=\"")
	strings.write_string(&sb, classes)
	strings.write_string(&sb, "\" role=\"main\">\n")
	part_eyebrow(&sb, b, id)
	strings.write_string(&sb, body)
	strings.write_string(&sb, "</article>\n")
	page_prev_next(&sb, b, id)
	page_footer(&sb, b)
	strings.write_string(&sb, "</main>\n")
	page_local_toc(&sb, b, id)
	strings.write_string(&sb, "</div>\n</body>\n</html>\n")
	return strings.to_string(sb)
}

@(private = "file")
page_head :: proc(sb: ^strings.Builder, b: ^Build, name, title: string) {
	root := relative_path(name, "")
	w :: strings.write_string
	w(sb, "<!DOCTYPE html>\n<html lang=\"")
	w(sb, html_escape(b.site.conf.language))
	w(sb, "\" class=\"docodin\" data-theme=\"auto\">\n<head>\n<meta charset=\"utf-8\" />\n")
	w(sb, "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />\n")
	w(sb, "<meta name=\"generator\" content=\"docodin " + VERSION + "\" />\n")
	w(sb, "<title>")
	w(sb, html_escape(title))
	w(sb, "</title>\n<link rel=\"stylesheet\" href=\"")
	w(sb, root)
	w(sb, "_static/docodin.css\" />\n")
	w(sb, "<script>try{var t=localStorage.getItem(\"docodin-theme\");")
	w(sb, "if(t)document.documentElement.dataset.theme=t}catch(e){}</script>\n")
	w(sb, "<script defer src=\"")
	w(sb, root)
	w(sb, "_static/docodin.js\"></script>\n</head>\n<body class=\"docodin-native\" data-root=\"")
	w(sb, root)
	w(sb, "\">\n<a class=\"skip-link\" href=\"#content\">Skip to content</a>\n")
	w(sb, "<input type=\"checkbox\" class=\"drawer-toggle\" id=\"nav-toggle\" hidden />\n")
	w(sb, "<input type=\"checkbox\" class=\"drawer-toggle\" id=\"toc-toggle\" hidden />\n")
	w(sb, "<label class=\"dod-overlay nav-overlay\" for=\"nav-toggle\"></label>\n")
	w(sb, "<label class=\"dod-overlay toc-overlay\" for=\"toc-toggle\"></label>\n")
	w(sb, "<div class=\"dod-page\">\n")
	mobile_header(sb, b, root)
}

@(private = "file")
mobile_header :: proc(sb: ^strings.Builder, b: ^Build, root: string) {
	w :: strings.write_string
	w(sb, "<header class=\"dod-mobile-header\">\n<label class=\"icon-button\" for=\"nav-toggle\" ")
	w(sb, "title=\"Navigation\">")
	w(sb, ICON_MENU)
	w(sb, "</label>\n<a class=\"mobile-brand\" href=\"")
	w(sb, root)
	w(sb, "index.html\">")
	w(sb, html_escape(b.site.conf.project))
	w(sb, "</a>\n<div class=\"header-actions\">")
	theme_button(sb)
	w(sb, "<label class=\"icon-button\" for=\"toc-toggle\" title=\"On this page\">")
	w(sb, ICON_TOC)
	w(sb, "</label></div>\n</header>\n")
}

theme_button :: proc(sb: ^strings.Builder) {
	strings.write_string(sb, "<button class=\"icon-button theme-toggle\" type=\"button\" ")
	strings.write_string(sb, "title=\"Colour theme\" aria-label=\"Colour theme\">")
	strings.write_string(sb, ICON_AUTO)
	strings.write_string(sb, ICON_SUN)
	strings.write_string(sb, ICON_MOON)
	strings.write_string(sb, "</button>")
}

@(private = "file")
page_sidebar :: proc(
	sb: ^strings.Builder,
	b: ^Build,
	id: Doc_Id,
	name: string,
	options: Html_Options,
) {
	s := b.site
	root := relative_path(name, "")
	w :: strings.write_string
	w(sb, "<aside class=\"dod-sidebar\" aria-label=\"Site navigation\">\n")
	w(sb, "<div class=\"dod-sidebar-inner\">\n")
	w(sb, "<a class=\"brand\" href=\"")
	w(sb, root)
	w(sb, "index.html\">")
	if s.conf.html_logo != "" {
		w(sb, "<img class=\"logo\" alt=\"\" src=\"")
		w(sb, root)
		w(sb, "_static/")
		w(sb, html_escape(filepath.base(s.conf.html_logo)))
		w(sb, "\" />")
	} else {
		w(sb, LOGO)
	}
	w(sb, "<span class=\"brand-text\"><span class=\"brand-title\">")
	w(sb, html_escape(s.conf.project))
	w(sb, "</span>")
	if s.conf.tagline != "" {
		w(sb, "<span class=\"brand-tagline\">")
		w(sb, html_escape(s.conf.tagline))
		w(sb, "</span>")
	}
	w(sb, "</span></a>\n")
	if s.conf.release != "" {
		w(sb, "<span class=\"version-badge\">v")
		w(sb, html_escape(s.conf.release))
		w(sb, "</span>\n")
	}
	w(sb, "<form class=\"search-form\" action=\"")
	w(sb, root)
	w(sb, "search.html\" method=\"get\" role=\"search\">\n")
	w(sb, "<input type=\"search\" name=\"q\" placeholder=\"Search\" aria-label=\"Search\" ")
	w(sb, "autocomplete=\"off\" /><kbd class=\"search-key\">/</kbd>\n")
	w(sb, "<div class=\"search-dropdown\" hidden></div>\n</form>\n")
	nav_tree(sb, b, id)
	if options.pdf != "" {
		w(sb, "<a class=\"pdf-link\" href=\"")
		w(sb, root)
		w(sb, "_downloads/")
		w(sb, filepath.base(options.pdf))
		w(sb, "\">")
		w(sb, ICON_BOOK)
		w(sb, "<span>Download the PDF book</span></a>\n")
	}
	w(sb, "</div>\n</aside>\n")
}

@(private = "file")
page_topbar :: proc(sb: ^strings.Builder, b: ^Build, id: Doc_Id) {
	s := b.site
	name := s.docs[id].name
	w :: strings.write_string
	w(sb, "<div class=\"dod-topbar\">\n<nav class=\"breadcrumbs\" aria-label=\"Breadcrumbs\">")
	chain := ancestors(b, id)
	for k := len(chain) - 1; k >= 0; k -= 1 {
		p := chain[k]
		if k < len(chain) - 1 do w(sb, "<span class=\"sep\">/</span>")
		if k == 0 {
			w(sb, "<span class=\"here\">")
			w(sb, html_escape(b.pages[p].title))
			w(sb, "</span>")
			continue
		}
		w(sb, "<a href=\"")
		w(sb, relative_url(name, s.docs[p].name))
		w(sb, "\">")
		w(sb, html_escape(b.pages[p].title if p != s.root else "Home"))
		w(sb, "</a>")
	}
	w(sb, "</nav>\n<div class=\"dod-topbar-actions\">")
	theme_button(sb)
	w(sb, "</div>\n</div>\n")
}

@(private = "file")
page_prev_next :: proc(sb: ^strings.Builder, b: ^Build, id: Doc_Id) {
	page := b.pages[id]
	if page.prev == NO_DOC && page.next == NO_DOC do return
	w :: strings.write_string
	w(sb, "<nav class=\"dod-prev-next\" aria-label=\"Previous and next pages\">\n")
	links := [2]Doc_Id{page.prev, page.next}
	labels := [2]string{"Previous", "Next"}
	classes := [2]string{"prev", "next"}
	for target, k in links {
		if target == NO_DOC {
			w(sb, "<span></span>\n")
			continue
		}
		w(sb, "<a class=\"")
		w(sb, classes[k])
		w(sb, "\" href=\"")
		w(sb, page_url(b, id, Link{target, ""}))
		w(sb, "\"><span class=\"label\">")
		w(sb, labels[k])
		w(sb, "</span><span class=\"title\">")
		w(sb, html_escape(numbered_title(b, target)))
		w(sb, "</span></a>\n")
	}
	w(sb, "</nav>\n")
}

@(private = "file")
page_footer :: proc(sb: ^strings.Builder, b: ^Build) {
	s := b.site
	w :: strings.write_string
	w(sb, "<footer class=\"dod-footer\">\n")
	if s.conf.copyright != "" {
		w(sb, "<span>© ")
		w(sb, html_escape(s.conf.copyright))
		w(sb, "</span>\n")
	}
	w(sb, "<span>Built natively with <a href=\"https://github.com/insanai/docodin\">docodin</a> ")
	w(sb, VERSION)
	w(sb, " — no Python in sight.</span>\n</footer>\n")
}

// A document's title with its number ("2.1. Title").
numbered_title :: proc(b: ^Build, id: Doc_Id) -> string {
	page := b.pages[id]
	if page.toc != 0 && b.toc[page.toc].number != nil {
		return strings.concatenate({number_text(b.toc[page.toc].number), ". ", page.title})
	}
	return page.title
}

// --- search page -------------------------------------------------------------------------

@(private = "file")
render_search_page :: proc(b: ^Build, options: Html_Options) -> string {
	s := b.site
	sb := strings.builder_make()
	title := strings.concatenate({"Search — ", s.conf.html_title})
	page_head(&sb, b, "search", title)
	page_sidebar(&sb, b, NO_DOC, "search", options)
	strings.write_string(&sb, "<main class=\"dod-main\" id=\"content\">\n")
	strings.write_string(&sb, "<div class=\"dod-topbar\">")
	strings.write_string(&sb, "<nav class=\"breadcrumbs\"><a href=\"index.html\">Home</a>")
	strings.write_string(&sb, "<span class=\"sep\">/</span><span class=\"here\">Search</span>")
	strings.write_string(&sb, "</nav><div class=\"dod-topbar-actions\">")
	theme_button(&sb)
	strings.write_string(&sb, "</div></div>\n<article class=\"dod-article\" role=\"main\">\n")
	strings.write_string(&sb, "<section id=\"search\"><h1>Search</h1>\n")
	strings.write_string(&sb, "<p class=\"search-summary\">Type in the search box to search ")
	strings.write_string(&sb, "the documentation.</p>\n<ol class=\"search-results\"></ol>\n")
	strings.write_string(&sb, "</section>\n</article>\n")
	page_footer(&sb, b)
	strings.write_string(&sb, "</main>\n<aside class=\"dod-toc empty\"></aside>\n</div>\n")
	strings.write_string(&sb, "<script defer src=\"searchindex.js\"></script>\n</body>\n</html>\n")
	return strings.to_string(sb)
}

// --- parts -------------------------------------------------------------------------------

// A part of the book as a page: when the root's sections are not the
// parts, a page that a toctree of the root lists and that holds toctrees.
is_part_page :: proc(b: ^Build, id: Doc_Id) -> bool {
	if id == NO_DOC || b.pages[id].parent != b.site.root || root_has_parts(b) do return false
	return len(doc_toctrees(b, id)) > 0
}

// The root's sections below its title hold the toctrees (the parts).
root_has_parts :: proc(b: ^Build) -> bool {
	for t in doc_toctrees(b, b.site.root) do if part_title(b, t) != "" do return true
	return false
}

// The "Part II" label above a part page's title (``docodin_part_labels``).
@(private = "file")
part_eyebrow :: proc(sb: ^strings.Builder, b: ^Build, id: Doc_Id) {
	if !b.site.conf.part_labels || !is_part_page(b, id) do return
	n := 0
	for t in doc_toctrees(b, b.site.root) {
		for e in toctree_entries(b, t) {
			if e.doc == NO_DOC || !is_part_page(b, e.doc) do continue
			n += 1
			if e.doc != id do continue
			strings.write_string(sb, "<p class=\"part-label\">Part ")
			strings.write_string(sb, roman(n))
			strings.write_string(sb, "</p>\n")
			return
		}
	}
}

// Upper-case Roman numerals.
roman :: proc(n: int) -> string {
	values := [?]int{1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1}
	glyphs := [?]string{"M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"}
	sb := strings.builder_make(context.temp_allocator)
	rest := n
	for v, i in values {
		for rest >= v {
			strings.write_string(&sb, glyphs[i])
			rest -= v
		}
	}
	return strings.to_string(sb)
}

// The plain text of a node, for the search index.
node_text :: proc(doc: ^dt.Doc, n: dt.Node) -> string {
	return dt.astext(doc, n, context.allocator)
}
