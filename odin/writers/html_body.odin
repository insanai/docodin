package writers

import "core:strings"

import dt "../doctree"

// HTML5 visitors of body elements: lists, blocks, footnotes, citations,
// decoration and system messages.

@(private = "file")
ATTRIBUTION_FORMATS := [?][3]string {
	{"dash", "—", ""},
	{"parentheses", "(", ")"},
	{"parens", "(", ")"},
	{"none", "", ""},
}

// ``attribution_formats[settings.attribution]``.
attribution_format :: proc(name: string) -> (prefix, suffix: string, ok: bool) {
	for f in ATTRIBUTION_FORMATS {
		if f[0] == name do return f[1], f[2], true
	}
	return "", "", false
}

html_visit_admonition :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "aside", classes = {"admonition"})
	return .Continue
}

html_visit_attribution :: proc(t: ^Html, n: dt.Node) -> Visit {
	prefix, suffix, ok := attribution_format(t.s.attribution)
	if !ok {
		t.err = cat("KeyError: ", t.s.attribution)
		return .Skip_Node
	}
	push_ctx(t, suffix)
	starttag(t, n, "p", prefix, class = "attribution")
	return .Continue
}

html_depart_attribution :: proc(t: ^Html, n: dt.Node) {
	begin(&t.body)
	w(&t.body, pop_string(t))
	w(&t.body, "</p>\n")
}

html_visit_bullet_list :: proc(t: ^Html, n: dt.Node) -> Visit {
	old := t.compact_simple
	push_ctx(t, t.compact_simple)
	t.compact_simple = is_compactable(t, n)
	starttag(t, n, "ul", class = "simple" if t.compact_simple && !old else "")
	return .Continue
}

html_depart_bullet_list :: proc(t: ^Html, n: dt.Node) {
	t.compact_simple, _ = pop(&t.stack).(bool)
	put(&t.body, "</ul>\n")
}

html_visit_caption :: proc(t: ^Html, n: dt.Node) -> Visit {
	if parent_is(t.doc, n, {.figure}) do starttag(t, n, "figcaption")
	put(&t.body, "<p>")
	return .Continue
}

html_visit_citation :: proc(t: ^Html, n: dt.Node) -> Visit {
	if !dt.is(t.doc, dt.prev_sibling(t.doc, n), {.citation}) {
		put(&t.body, "<div role=\"list\" class=\"citation-list\">\n")
	}
	starttag(t, n, "div", classes = {"citation"}, atts = {{"role", "doc-biblioentry"}})
	return .Continue
}

html_depart_citation :: proc(t: ^Html, n: dt.Node) {
	put(&t.body, "</div>\n")
	if !dt.is(t.doc, dt.next_sibling(t.doc, n), {.citation}) do put(&t.body, "</div>\n")
}

html_visit_classifier :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "span", "", class = "classifier")
	return .Continue
}

html_depart_classifier :: proc(t: ^Html, n: dt.Node) {
	put(&t.body, "</span>")
	html_depart_term(t, n)
}

html_visit_comment :: proc(t: ^Html, n: dt.Node) -> Visit {
	text := astext(t.doc, n)
	begin(&t.body)
	w(&t.body, "<!-- ")
	for i in 0 ..< len(text) {
		wb(&t.body, text[i])
		if text[i] == '-' && i + 1 < len(text) && text[i + 1] == '-' do wb(&t.body, ' ')
	}
	w(&t.body, " -->\n")
	return .Skip_Node
}

html_visit_compound :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "div", class = "compound")
	return .Continue
}

html_visit_container :: proc(t: ^Html, n: dt.Node) -> Visit {
	tag := "div"
	found := 0
	for c in list_strings(t.doc, n, dt.K_CLASSES) {
		if c == "ins" || c == "del" {
			found += 1
			tag = c
		}
	}
	if found == 1 {
		dt.list_remove(t.doc, n, dt.K_CLASSES, tag)
	} else {
		tag = "div"
	}
	t.tagnames[n] = tag
	starttag(t, n, tag, class = "docutils container")
	return .Continue
}

// ``</{node.html5tagname}>\n``.
html_depart_tagname :: proc(t: ^Html, n: dt.Node) {
	begin(&t.body)
	w(&t.body, "</")
	w(&t.body, t.tagnames[n])
	w(&t.body, ">\n")
	delete_key(&t.tagnames, n)
}

// "details" in the classes of the definition list of a term, classifier or
// definition.
@(private = "file")
in_details :: proc(t: ^Html, n: dt.Node) -> bool {
	return has_class(t.doc, dt.parent(t.doc, dt.parent(t.doc, n)), "details")
}

html_visit_definition :: proc(t: ^Html, n: dt.Node) -> Visit {
	if !in_details(t, n) do starttag(t, n, "dd", "")
	return .Continue
}

html_depart_definition :: proc(t: ^Html, n: dt.Node) {
	if !in_details(t, n) do put(&t.body, "</dd>\n")
}

html_visit_definition_list :: proc(t: ^Html, n: dt.Node) -> Visit {
	if has_class(t.doc, n, "details") {
		starttag(t, n, "div")
	} else {
		starttag(t, n, "dl", classes = {"simple"} if is_compactable(t, n) else nil)
	}
	return .Continue
}

html_depart_definition_list :: proc(t: ^Html, n: dt.Node) {
	put(&t.body, "</div>\n" if has_class(t.doc, n, "details") else "</dl>\n")
}

html_visit_definition_list_item :: proc(t: ^Html, n: dt.Node) -> Visit {
	p := dt.parent(t.doc, n)
	if has_class(t.doc, p, "details") {
		open := has_class(t.doc, p, "open")
		starttag(t, n, "details", atts = {{"open", "open"}} if open else nil)
	}
	return .Continue
}

html_depart_definition_list_item :: proc(t: ^Html, n: dt.Node) {
	if has_class(t.doc, dt.parent(t.doc, n), "details") do put(&t.body, "</details>\n")
}

html_visit_doctest_block :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "pre", "", classes = {"code", "python", "doctest"})
	return .Continue
}

html_visit_enumerated_list :: proc(t: ^Html, n: dt.Node) -> Visit {
	classes := make([dynamic]string, 0, 2, context.temp_allocator)
	atts: []Att
	if v, ok := dt.get_attr(t.doc, n, "start"); ok do atts = one_att("start", attr_text(t.doc, v))
	if v, ok := dt.get_attr(t.doc, n, "enumtype"); ok do append(&classes, attr_text(t.doc, v))
	if is_compactable(t, n) do append(&classes, "simple")
	starttag(t, n, "ol", classes = classes[:], atts = atts)
	return .Continue
}

html_visit_field_list :: proc(t: ^Html, n: dt.Node) -> Visit {
	atts: []Att
	classes := list_strings(t.doc, n, dt.K_CLASSES)
	for c in classes {
		if !strings.has_prefix(c, "field-indent-") do continue
		indent, ok := length_or_percentage_or_unitless(c[len("field-indent-"):], "px")
		if !ok do break
		atts = one_att("style", cat("--field-indent: ", indent, ";"))
		dt.list_remove(t.doc, n, dt.K_CLASSES, c)
		break
	}
	dt.list_append(t.doc, n, dt.K_CLASSES, "field-list")
	if is_compactable(t, n) do dt.list_append(t.doc, n, dt.K_CLASSES, "simple")
	starttag(t, n, "dl", atts = atts)
	return .Continue
}

// ``directives.length_or_percentage_or_unitless(argument, default)``.
length_or_percentage_or_unitless :: proc(argument, default: string) -> (string, bool) {
	UNITS :: [?]string {
		"em", "ex", "ch", "rem", "vw", "vh", "vmin", "vmax", "cm", "mm", "Q", "in", "pt", "pc",
		"px", "%",
	}
	value, unit, ok := parse_measure(argument)
	if !ok do return "", false
	units := UNITS
	if as_f64(value) >= 0 && contains(units[:], unit) {
		return cat(num_str(value), unit), true
	}
	if as_f64(value) >= 0 && unit == "" {
		return cat(num_str(value), default), true
	}
	return "", false
}

html_visit_field :: proc(t: ^Html, n: dt.Node) -> Visit {
	ids := dt.attr_list(t.doc, n, dt.K_IDS)
	for c := dt.first_child(t.doc, n); c != 0; c = dt.next_sibling(t.doc, c) {
		if dt.tag(t.doc, c) == .field_name {
			for id in ids do dt.list_append(t.doc, c, dt.K_IDS, id)
		}
	}
	return .Continue
}

html_visit_field_name :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "dt", "", classes_of = dt.parent(t.doc, n))
	return .Continue
}

html_visit_field_body :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "dd", "", classes_of = dt.parent(t.doc, n))
	if dt.first_child(t.doc, n) == 0 do put(&t.body, "<p></p>")
	return .Continue
}

html_visit_figure :: proc(t: ^Html, n: dt.Node) -> Visit {
	atts := make([dynamic]Att, 0, 2, context.temp_allocator)
	if v, ok := dt.get_attr(t.doc, n, "width"); ok {
		append(&atts, Att{"style", cat("width: ", attr_text(t.doc, v))})
	}
	class := ""
	if align := attr(t.doc, n, "align"); align != "" {
		class = cat("align-", align)
	}
	starttag(t, n, "figure", class = class, atts = atts[:])
	return .Continue
}

html_depart_figure :: proc(t: ^Html, n: dt.Node) {
	if dt.child_count(t.doc, n) > 1 do put(&t.body, "</figcaption>\n")
	put(&t.body, "</figure>\n")
}

// ``visit_header``/``visit_footer``: remember where the content starts.
html_visit_decoration_part :: proc(t: ^Html, n: dt.Node) -> Visit {
	push_ctx(t, chunks(&t.body))
	return .Continue
}

html_depart_footer :: proc(t: ^Html, n: dt.Node) {
	start := pop_int(t)
	footer := out_make(context.temp_allocator)
	starttag(t, n, "footer", o = &footer)
	put_range(&footer, &t.body, start)
	put(&footer, "</footer>\n")
	put_out(&t.footer, &footer)
	suffix := out_make(context.temp_allocator)
	put_out(&suffix, &footer)
	put_out(&suffix, &t.body_suffix)
	t.body_suffix = suffix
	truncate(&t.body, start)
}

html_depart_header :: proc(t: ^Html, n: dt.Node) {
	start := pop_int(t)
	header := out_make(context.temp_allocator)
	starttag(t, n, "header", o = &header)
	put_range(&header, &t.body, start)
	put(&header, "</header>\n")
	put_out(&t.body_prefix, &header)
	put_out(&t.header, &header)
	truncate(&t.body, start)
}

html_visit_footnote :: proc(t: ^Html, n: dt.Node) -> Visit {
	style := t.s.footnote_references
	if !dt.is(t.doc, dt.prev_sibling(t.doc, n), {.footnote}) {
		begin(&t.body)
		w(&t.body, "<aside class=\"footnote-list ")
		w(&t.body, style)
		w(&t.body, "\">\n")
	}
	starttag(t, n, "aside", classes = {"footnote", style}, atts = {{"role", "doc-footnote"}})
	return .Continue
}

html_depart_footnote :: proc(t: ^Html, n: dt.Node) {
	put(&t.body, "</aside>\n")
	if !dt.is(t.doc, dt.next_sibling(t.doc, n), {.footnote}) do put(&t.body, "</aside>\n")
}

html_visit_label :: proc(t: ^Html, n: dt.Node) -> Visit {
	put(&t.body, "<span class=\"label\">")
	put(&t.body, "<span class=\"fn-bracket\">[</span>")
	if t.s.footnote_backlinks {
		backrefs := list_strings(t.doc, dt.parent(t.doc, n), dt.K_BACKREFS)
		if len(backrefs) == 1 {
			begin(&t.body)
			w(&t.body, "<a role=\"doc-backlink\" href=\"#")
			w(&t.body, backrefs[0])
			w(&t.body, "\">")
		}
	}
	return .Continue
}

html_depart_label :: proc(t: ^Html, n: dt.Node) {
	backrefs: []string
	if t.s.footnote_backlinks do backrefs = list_strings(t.doc, dt.parent(t.doc, n), dt.K_BACKREFS)
	if len(backrefs) == 1 do put(&t.body, "</a>")
	put(&t.body, "<span class=\"fn-bracket\">]</span></span>\n")
	if len(backrefs) <= 1 do return
	begin(&t.body)
	w(&t.body, "<span class=\"backrefs\">(")
	for ref, i in backrefs {
		if i > 0 do wb(&t.body, ',')
		w(&t.body, "<a role=\"doc-backlink\" href=\"#")
		w(&t.body, ref)
		w(&t.body, "\">")
		w(&t.body, int_str(i + 1))
		w(&t.body, "</a>")
	}
	w(&t.body, ")</span>\n")
}

html_visit_legend :: proc(t: ^Html, n: dt.Node) -> Visit {
	if !dt.is(t.doc, dt.prev_sibling(t.doc, n), {.caption}) do put(&t.body, "<figcaption>\n")
	starttag(t, n, "div", class = "legend")
	return .Continue
}

html_visit_line :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "div", "", class = "line")
	if dt.first_child(t.doc, n) == 0 do put(&t.body, "<br />")
	return .Continue
}

html_visit_line_block :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "div", class = "line-block")
	return .Continue
}

html_visit_list_item :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "li", "")
	return .Continue
}

html_visit_literal_block :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "pre", "", class = "literal-block")
	if has_class(t.doc, n, "code") do put(&t.body, "<code>")
	return .Continue
}

html_depart_literal_block :: proc(t: ^Html, n: dt.Node) {
	if has_class(t.doc, n, "code") do put(&t.body, "</code>")
	put(&t.body, "</pre>\n")
}

html_visit_option :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "span", "", class = "option")
	return .Continue
}

html_depart_option :: proc(t: ^Html, n: dt.Node) {
	put(&t.body, "</span>")
	if dt.is(t.doc, dt.next_sibling(t.doc, n), {.option}) do put(&t.body, ", ")
}

html_visit_option_argument :: proc(t: ^Html, n: dt.Node) -> Visit {
	v, ok := dt.get_attr(t.doc, n, dt.K_DELIMITER)
	put(&t.body, attr_text(t.doc, v) if ok else " ")
	starttag(t, n, "var", "")
	return .Continue
}

html_visit_option_group :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "dt", "")
	put(&t.body, "<kbd>")
	return .Continue
}

html_visit_option_list :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "dl", class = "option-list")
	return .Continue
}

html_visit_paragraph :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "p", "")
	return .Continue
}

html_depart_paragraph :: proc(t: ^Html, n: dt.Node) {
	put(&t.body, "</p>")
	p := dt.parent(t.doc, n)
	if !(dt.is(t.doc, p, {.list_item, .entry}) && dt.child_count(t.doc, p) == 1) {
		put(&t.body, "\n")
		report_messages(t, n)
	}
}

html_visit_rubric :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "p", "", class = "rubric")
	return .Continue
}

html_visit_section :: proc(t: ^Html, n: dt.Node) -> Visit {
	t.section_level += 1
	starttag(t, n, "section")
	return .Continue
}

html_depart_section :: proc(t: ^Html, n: dt.Node) {
	t.section_level -= 1
	put(&t.body, "</section>\n")
}

html_visit_sidebar :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "aside", class = "sidebar")
	t.in_sidebar = true
	return .Continue
}

html_depart_sidebar :: proc(t: ^Html, n: dt.Node) {
	put(&t.body, "</aside>\n")
	t.in_sidebar = false
}

html_visit_system_message :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "aside", class = "system-message")
	put(&t.body, "<p class=\"system-message-title\">")
	begin(&t.body)
	w(&t.body, "System Message: ")
	v, _ := dt.get_attr(t.doc, n, dt.K_TYPE)
	w(&t.body, attr_text(t.doc, v))
	wb(&t.body, '/')
	v, _ = dt.get_attr(t.doc, n, dt.K_LEVEL)
	w(&t.body, attr_text(t.doc, v))
	w(&t.body, " (<span class=\"docutils literal\">")
	v, _ = dt.get_attr(t.doc, n, dt.K_SOURCE)
	write_encoded(&t.body, attr_text(t.doc, v))
	w(&t.body, "</span>")
	if line, ok := dt.get_attr(t.doc, n, dt.K_LINE); ok {
		w(&t.body, ", line ")
		w(&t.body, attr_text(t.doc, line))
	}
	wb(&t.body, ')')
	write_backref_text(t, list_strings(t.doc, n, dt.K_BACKREFS))
	w(&t.body, "</p>\n")
	return .Continue
}

@(private = "file")
write_backref_text :: proc(t: ^Html, backrefs: []string) {
	if len(backrefs) == 1 {
		w(&t.body, "; <em><a href=\"#")
		w(&t.body, backrefs[0])
		w(&t.body, "\">backlink</a></em>")
		return
	}
	if len(backrefs) == 0 do return
	w(&t.body, "; <em>backlinks: ")
	for ref, i in backrefs {
		if i > 0 do w(&t.body, ", ")
		w(&t.body, "<a href=\"#")
		w(&t.body, ref)
		w(&t.body, "\">")
		w(&t.body, int_str(i + 1))
		w(&t.body, "</a>")
	}
	w(&t.body, "</em>")
}

html_visit_topic :: proc(t: ^Html, n: dt.Node) -> Visit {
	atts: []Att
	classes := one_str("topic")
	tag := "aside"
	switch {
	case has_class(t.doc, n, "contents"):
		tag = "nav"
		classes = nil
		if parent_is(t.doc, n, {.document}) {
			atts = one_att("role", "doc-toc")
			replace_chunk(&t.body_prefix, 0, "</head>\n<body class=\"with-toc\">\n")
		}
	case has_class(t.doc, n, "abstract"):
		tag = "div"
		atts = one_att("role", "doc-abstract")
	case has_class(t.doc, n, "dedication"):
		tag = "div"
		atts = one_att("role", "doc-dedication")
	}
	t.tagnames[n] = tag
	starttag(t, n, tag, classes = classes, atts = atts)
	return .Continue
}

html_visit_transition :: proc(t: ^Html, n: dt.Node) -> Visit {
	emptytag(t, n, "hr", class = "docutils")
	return .Continue
}

// --- compact lists -------------------------------------------------------------------------

// ``is_compactable(node)``.
is_compactable :: proc(t: ^Html, n: dt.Node) -> bool {
	doc := t.doc
	if has_class(doc, n, "compact") do return true
	if has_class(doc, n, "open") do return false
	if dt.is(doc, n, {.field_list, .definition_list}) && !t.s.compact_field_lists do return false
	if dt.is(doc, n, {.enumerated_list, .bullet_list}) && !t.s.compact_lists do return false
	if has_class(doc, dt.parent(doc, n), "contents") do return true
	return simple_list(doc, n)
}

// What ``SimpleListChecker`` does with a node.
@(private = "file")
Check :: enum u8 {
	Found, // ``default_visit``: not simple
	Pass, // ``pass_node``
	Ignore, // ``ignore_node``: skip the node
	Item, // ``visit_list_item``
}

@(private = "file")
SIMPLE_CHECKS := #partial [dt.Tag]Check {
	.Text                    = .Ignore,
	.paragraph               = .Ignore,
	.bullet_list             = .Pass,
	.enumerated_list         = .Pass,
	.docinfo                 = .Pass,
	.author                  = .Ignore,
	.authors                 = .Item,
	.address                 = .Item,
	.contact                 = .Pass,
	.copyright               = .Ignore,
	.date                    = .Ignore,
	.organization            = .Ignore,
	.status                  = .Ignore,
	.version                 = .Item,
	.definition_list         = .Pass,
	.definition_list_item    = .Pass,
	.term                    = .Ignore,
	.classifier              = .Pass,
	.definition              = .Item,
	.field_list              = .Pass,
	.field                   = .Pass,
	.field_body              = .Item,
	.field_name              = .Ignore,
	.list_item               = .Item,
	.comment                 = .Ignore,
	.substitution_definition = .Ignore,
	.target                  = .Ignore,
	.pending                 = .Ignore,
}

// ``check_simple_list(node)``: walk with ``SimpleListChecker``.
@(private = "file")
simple_list :: proc(doc: ^dt.Doc, n: dt.Node) -> bool {
	switch SIMPLE_CHECKS[dt.tag(doc, n)] {
	case .Found:
		return false
	case .Ignore:
		return true
	case .Item:
		if !simple_item(doc, n) do return false
	case .Pass:
	}
	for c := dt.first_child(doc, n); c != 0; c = dt.next_sibling(doc, c) {
		if !simple_list(doc, c) do return false
	}
	return true
}

// ``SimpleListChecker.visit_list_item``: at most a paragraph and a list.
@(private = "file")
simple_item :: proc(doc: ^dt.Doc, n: dt.Node) -> bool {
	first, last: dt.Node
	count := 0
	for c := dt.first_child(doc, n); c != 0; c = dt.next_sibling(doc, c) {
		if dt.is_a(doc, c, .Invisible) do continue
		if count == 0 do first = c
		last = c
		count += 1
	}
	lists := dt.Tag_Set{.bullet_list, .enumerated_list, .field_list}
	if count > 0 && dt.tag(doc, first) == .paragraph && dt.is(doc, last, lists) {
		count -= 1
	}
	return count <= 1
}
