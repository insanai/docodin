package writers

import "core:strings"

import dt "../doctree"
import rst "../rst"

// HTML5 visitors of text, inline elements, references, targets, terms,
// titles and meta tags.

html_visit_text :: proc(t: ^Html, n: dt.Node) -> Visit {
	text := astext(t.doc, n)
	if !(t.in_mailto && t.s.cloak_email_addresses) {
		begin(&t.body)
		write_encoded(&t.body, text)
		return .Continue
	}
	enc := encoded(text)
	enc, _ = strings.replace_all(enc, "&#64;", "<span>&#64;</span>", context.temp_allocator)
	enc, _ = strings.replace_all(enc, ".", "<span>&#46;</span>", context.temp_allocator)
	put(&t.body, enc)
	return .Continue
}

// An inline element written as ``<tag>`` … ``</tag>``.
@(private = "file")
Simple_Inline :: struct {
	tag, close: string,
}

@(private = "file")
SIMPLE_INLINES := #partial [dt.Tag]Simple_Inline {
	.abbreviation    = {"abbr", "</abbr>"},
	.acronym         = {"abbr", "</abbr>"},
	.emphasis        = {"em", "</em>"},
	.strong          = {"strong", "</strong>"},
	.subscript       = {"sub", "</sub>"},
	.superscript     = {"sup", "</sup>"},
	.title_reference = {"cite", "</cite>"},
}

html_visit_simple_inline :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, SIMPLE_INLINES[dt.tag(t.doc, n)].tag, "")
	return .Continue
}

html_depart_simple_inline :: proc(t: ^Html, n: dt.Node) {
	put(&t.body, SIMPLE_INLINES[dt.tag(t.doc, n)].close)
}

html_visit_citation_reference :: proc(t: ^Html, n: dt.Node) -> Visit {
	href := "#"
	if has(t.doc, n, "refid") {
		href = cat("#", attr(t.doc, n, "refid"))
	} else if has(t.doc, n, "refname") {
		id, ok := nameid(t.doc, attr(t.doc, n, "refname"))
		if !ok {
			t.err = "KeyError: document.nameids[refname]"
			return .Skip_Node
		}
		href = cat("#", id)
	}
	starttag(
		t,
		n,
		"a",
		"[",
		classes = {"citation-reference"},
		atts = {{"href", href}, {"role", "doc-biblioref"}},
	)
	return .Continue
}

html_depart_citation_reference :: proc(t: ^Html, n: dt.Node) {
	put(&t.body, "]</a>")
}

html_visit_footnote_reference :: proc(t: ^Html, n: dt.Node) -> Visit {
	if !has(t.doc, n, "refid") {
		t.err = "KeyError: 'refid'"
		return .Skip_Node
	}
	href := cat("#", attr(t.doc, n, "refid"))
	starttag(
		t,
		n,
		"a",
		"",
		classes = {t.s.footnote_references},
		atts = {{"role", "doc-noteref"}, {"href", href}},
	)
	put(&t.body, "<span class=\"fn-bracket\">[</span>")
	return .Continue
}

html_depart_footnote_reference :: proc(t: ^Html, n: dt.Node) {
	put(&t.body, "<span class=\"fn-bracket\">]</span>")
	put(&t.body, "</a>")
}

html_visit_generated :: proc(t: ^Html, n: dt.Node) -> Visit {
	if !has_class(t.doc, n, "sectnum") do return .Continue
	sectnum := strings.trim_right(astext(t.doc, n), " ")
	begin(&t.body)
	w(&t.body, "<span class=\"sectnum\">")
	write_encoded(&t.body, sectnum)
	w(&t.body, " </span>")
	return .Skip_Node
}

// ``supported_inline_tags``: HTML text-level tags used for class values.
@(private = "file")
INLINE_TAGS := [?]string {
	"code", "kbd", "dfn", "samp", "var", "bdi", "del", "ins", "mark", "small", "b", "i", "q",
	"s", "u",
}

// The first class value that is a supported inline tag ("" if none).
@(private = "file")
inline_tag_class :: proc(doc: ^dt.Doc, n: dt.Node) -> string {
	for c in list_strings(doc, n, dt.K_CLASSES) {
		if contains(INLINE_TAGS[:], c) do return c
	}
	return ""
}

html_visit_inline :: proc(t: ^Html, n: dt.Node) -> Visit {
	doc := t.doc
	tag := "span"
	p := dt.parent(doc, n)
	in_code :=
		(dt.tag(doc, p) == .literal_block && has_class(doc, p, "code")) ||
		(dt.tag(doc, p) == .literal && t.tagnames[p] == "code")
	if in_code {
		classes := dt.attr_list(doc, n, dt.K_CLASSES)
		if len(classes) == 1 && dt.str(doc, classes[0]) == "ln" {
			// line numbers are not part of the "fragment of computer code"
			if last(&t.body) == "<code>" {
				truncate(&t.body, chunks(&t.body) - 1)
			} else {
				put(&t.body, "</code>")
			}
			tag = "small"
		}
	} else if c := inline_tag_class(doc, n); c != "" {
		tag = c
		dt.list_remove(doc, n, dt.K_CLASSES, c)
	}
	t.tagnames[n] = tag
	starttag(t, n, tag, "")
	return .Continue
}

html_depart_inline :: proc(t: ^Html, n: dt.Node) {
	doc := t.doc
	tag := t.tagnames[n]
	begin(&t.body)
	w(&t.body, "</")
	w(&t.body, tag)
	wb(&t.body, '>')
	classes := dt.attr_list(doc, n, dt.K_CLASSES)
	is_ln := len(classes) == 1 && dt.str(doc, classes[0]) == "ln"
	if tag == "small" && is_ln && parent_is(doc, n, {.literal_block}) {
		begin(&t.body)
		w(&t.body, "<code data-lineno=\"")
		w(&t.body, astext(doc, n))
		w(&t.body, "\">")
	}
	delete_key(&t.tagnames, n)
}

html_visit_literal :: proc(t: ^Html, n: dt.Node) -> Visit {
	tag := "span"
	if c := inline_tag_class(t.doc, n); c != "" {
		tag = c
		dt.list_remove(t.doc, n, dt.K_CLASSES, c)
	}
	if tag == "code" {
		t.tagnames[n] = tag
		starttag(t, n, tag, "")
		return .Continue
	}
	starttag(t, n, tag, "", class = "docutils literal")
	literal_text(t, n)
	begin(&t.body)
	w(&t.body, "</")
	w(&t.body, tag)
	wb(&t.body, '>')
	return .Skip_Node
}

// ``_literal_text``: the encoded text of an inline literal, with ``<span
// class="pre">`` around words with wrap points inside.
@(private = "file")
literal_text :: proc(t: ^Html, n: dt.Node) {
	text := astext(t.doc, n)
	if !parent_is(t.doc, n, {.literal_block}) {
		text, _ = strings.replace_all(text, "\n", " ", context.temp_allocator)
	}
	i := 0
	for i < len(text) {
		j := i + 1
		switch text[i] {
		case '\n':
		case ' ':
			for j < len(text) && text[j] == ' ' do j += 1
		case:
			for j < len(text) && text[j] != ' ' && text[j] != '\n' do j += 1
		}
		token := text[i:j]
		begin(&t.body)
		if strings.trim_space(token) != "" && in_word_wrap_point(token) {
			w(&t.body, "<span class=\"pre\">")
			write_encoded(&t.body, token)
			w(&t.body, "</span>")
		} else {
			write_encoded(&t.body, token)
		}
		i = j
	}
}

// ``re.compile(r".+\W\W.+|[-?].+").search(token)`` for a token without
// newlines.
@(private = "file")
in_word_wrap_point :: proc(token: string) -> bool {
	runes := make([dynamic]rune, 0, len(token), context.temp_allocator)
	for r in token do append(&runes, r)
	n := len(runes)
	for r, i in runes {
		if (r == '-' || r == '?') && i < n - 1 do return true
	}
	for i in 1 ..< max(n - 2, 1) {
		if !is_word_rune(runes[i]) && !is_word_rune(runes[i + 1]) && i + 2 < n do return true
	}
	return false
}

// Regex ``\w``.
@(private = "file")
is_word_rune :: proc(r: rune) -> bool {
	return r == '_' || rst.is_alnum(r)
}

html_depart_literal :: proc(t: ^Html, n: dt.Node) {
	html_depart_inline(t, n)
}

html_visit_problematic :: proc(t: ^Html, n: dt.Node) -> Visit {
	if has(t.doc, n, "refid") {
		begin(&t.body)
		w(&t.body, "<a href=\"#")
		w(&t.body, attr(t.doc, n, "refid"))
		w(&t.body, "\">")
		push_ctx(t, "</a>")
	} else {
		push_ctx(t, "")
	}
	starttag(t, n, "span", "", class = "problematic")
	return .Continue
}

html_depart_problematic :: proc(t: ^Html, n: dt.Node) {
	put(&t.body, "</span>")
	put(&t.body, pop_string(t))
}

html_visit_raw :: proc(t: ^Html, n: dt.Node) -> Visit {
	if !format_has(attr(t.doc, n, "format"), "html") do return .Skip_Node
	tag := "span" if in_text_element(t.doc, n) else "div"
	classes := len(dt.attr_list(t.doc, n, dt.K_CLASSES)) > 0
	if classes do starttag(t, n, tag, "")
	put(&t.body, astext(t.doc, n))
	if classes {
		begin(&t.body)
		w(&t.body, "</")
		w(&t.body, tag)
		wb(&t.body, '>')
	}
	return .Skip_Node
}

html_visit_reference :: proc(t: ^Html, n: dt.Node) -> Visit {
	doc := t.doc
	classes := make([dynamic]string, 0, 3, context.temp_allocator)
	append(&classes, "reference")
	href: string
	if has(doc, n, "refuri") {
		href = attr(doc, n, "refuri")
		if t.s.cloak_email_addresses && strings.has_prefix(href, "mailto:") {
			href, _ = strings.replace_all(href, "@", "%40", context.temp_allocator)
			t.in_mailto = true
		}
		append(&classes, "external")
	} else {
		if !has(doc, n, "refid") {
			t.err = "AssertionError: References must have \"refuri\" or \"refid\" attribute."
			return .Skip_Node
		}
		href = cat("#", attr(doc, n, "refid"))
		append(&classes, "internal")
	}
	first := dt.first_child(doc, n)
	if first != 0 && dt.next_sibling(doc, first) == 0 && dt.tag(doc, first) == .image {
		append(&classes, "image-reference")
	}
	suffix := "" if in_text_element(doc, n) else "\n"
	starttag(t, n, "a", suffix, classes = classes[:], atts = {{"href", href}})
	return .Continue
}

html_depart_reference :: proc(t: ^Html, n: dt.Node) {
	put(&t.body, "</a>")
	if !in_text_element(t.doc, n) do put(&t.body, "\n")
	t.in_mailto = false
}

html_visit_target :: proc(t: ^Html, n: dt.Node) -> Visit {
	doc := t.doc
	if !has(doc, n, "refuri") && !has(doc, n, "refid") && !has(doc, n, "refname") {
		starttag(t, n, "span", "", class = "target")
		push_ctx(t, "</span>")
	} else {
		push_ctx(t, "")
	}
	return .Continue
}

// ``body.append(context.pop())``.
html_depart_pop :: proc(t: ^Html, n: dt.Node) {
	put(&t.body, pop_string(t))
}

html_visit_term :: proc(t: ^Html, n: dt.Node) -> Visit {
	p := dt.parent(t.doc, n)
	if has_class(t.doc, dt.parent(t.doc, p), "details") {
		starttag(t, n, "summary", "")
	} else {
		starttag(t, n, "dt", "", classes_of = p, ids = list_strings(t.doc, p, dt.K_IDS))
	}
	return .Continue
}

// ``depart_term`` (also called for the last classifier).
html_depart_term :: proc(t: ^Html, n: dt.Node) {
	for s := dt.next_sibling(t.doc, n); s != 0; s = dt.next_sibling(t.doc, s) {
		if dt.tag(t.doc, s) == .classifier do return
	}
	p := dt.parent(t.doc, n)
	details := has_class(t.doc, dt.parent(t.doc, p), "details")
	put(&t.body, "</summary>\n" if details else "</dt>\n")
}

html_visit_subtitle :: proc(t: ^Html, n: dt.Node) -> Visit {
	class: string
	#partial switch dt.tag(t.doc, dt.parent(t.doc, n)) {
	case .sidebar:
		class = "sidebar-subtitle"
	case .document:
		class = "subtitle"
		t.in_document_title = chunks(&t.body) + 1
	case .section:
		class = "section-subtitle"
	case:
		t.err = "UnboundLocalError: cannot access local variable 'classes'"
		return .Skip_Node
	}
	starttag(t, n, "p", "", classes = {class})
	return .Continue
}

html_depart_subtitle :: proc(t: ^Html, n: dt.Node) {
	put(&t.body, "</p>\n")
	if !parent_is(t.doc, n, {.document}) do return
	put_range(&t.subtitle, &t.body, t.in_document_title, -1)
	t.in_document_title = 0
	put_out(&t.body_pre_docinfo, &t.body)
	put_out(&t.html_subtitle, &t.body)
	reset(&t.body)
}

html_visit_title :: proc(t: ^Html, n: dt.Node) -> Visit {
	doc := t.doc
	p := dt.parent(doc, n)
	close := "</p>\n"
	switch {
	case dt.tag(doc, p) == .topic:
		starttag(t, n, "p", "", class = "topic-title")
		if t.s.toc_backlinks != "" && has_class(doc, p, "contents") {
			put(&t.body, "<a class=\"reference internal\" href=\"#top\">")
			close = "</a></p>\n"
		}
	case dt.tag(doc, p) == .sidebar:
		starttag(t, n, "p", "", class = "sidebar-title")
	case dt.is_a(doc, p, .Admonition):
		starttag(t, n, "p", "", class = "admonition-title")
	case dt.tag(doc, p) == .table:
		starttag(t, n, "caption", "")
		close = "</caption>\n"
	case dt.tag(doc, p) == .document:
		starttag(t, n, "h1", "", class = "title")
		close = "</h1>\n"
		t.in_document_title = chunks(&t.body)
	case dt.tag(doc, p) == .section:
		close = section_title_tags(t, n)
	case:
		t.err = "AssertionError: title parent is not a section"
		return .Skip_Node
	}
	push_ctx(t, close)
	return .Continue
}

html_depart_title :: proc(t: ^Html, n: dt.Node) {
	put(&t.body, pop_string(t))
	if t.in_document_title == 0 do return
	put_range(&t.title, &t.body, t.in_document_title, -1)
	t.in_document_title = 0
	put_out(&t.body_pre_docinfo, &t.body)
	put_out(&t.html_title, &t.body)
	reset(&t.body)
}

// ``section_title_tags``: write the start tag(s) of a section title and
// return the closing tags.
@(private = "file")
section_title_tags :: proc(t: ^Html, n: dt.Node) -> string {
	doc := t.doc
	level := t.section_level + t.initial_header_level - 1
	tag := cat("h", int_str(min(level, 6)))
	starttag(t, n, tag, "", atts = {{"aria-level", int_str(level)}} if level > 6 else nil)
	close := cat("</", tag, ">\n")
	if has(doc, n, "refid") {
		href := cat("#", attr(doc, n, "refid"))
		atts := []Att{{"role", "doc-backlink"}, {"href", href}}
		starttag(t, 0, "a", "", class = "toc-backref", atts = atts)
		close = cat("</a>", close)
	}
	ids := dt.attr_list(doc, dt.parent(doc, n), dt.K_IDS)
	if len(ids) > 0 && t.s.section_self_link && !parent_is(doc, n, {.document}) {
		link := cat(
			"<a class=\"self-link\" title=\"link to this section\" href=\"#",
			dt.str(doc, ids[0]),
			"\"></a></h",
		)
		close, _ = strings.replace_all(close, "</h", link, context.temp_allocator)
	}
	return close
}

html_visit_meta :: proc(t: ^Html, n: dt.Node) -> Visit {
	doc := t.doc
	if v, ok := dt.get_attr(doc, n, "lang"); ok do dt.set_attr(doc, n, "xml:lang", v)
	atts := make([dynamic]Att, 0, 8, context.temp_allocator)
	classes, ids: []string
	for a in dt.attributes(doc, n) {
		if !dt.is_not_default(doc, n, a.key) do continue
		switch a.key {
		case "classes":
			classes = list_strings(doc, n, dt.K_CLASSES)
		case "ids":
			ids = list_strings(doc, n, dt.K_IDS)
		case:
			append(&atts, Att{a.key, attr_text(doc, a.value)})
		}
	}
	emptytag(t, n, "meta", classes = classes, atts = atts[:], o = &t.meta)
	_ = ids
	return .Continue
}
