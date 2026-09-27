package writers

import dt "../doctree"

// The visit and depart tables of the HTML5 translator.  A missing visit
// procedure is ``unimplemented_visit`` (docutils raises
// ``NotImplementedError``); a missing depart procedure does nothing.

html_dispatch: Dispatch(Html)

// A depart procedure that appends a fixed closing tag.
@(private = "file")
Close :: struct {
	tag:   dt.Tag,
	close: string,
}

@(private = "file")
CLOSING_TAGS := [?]Close {
	{.admonition, "</aside>\n"},
	{.block_quote, "</blockquote>\n"},
	{.caption, "</p>\n"},
	{.compound, "</div>\n"},
	{.description, "</dd>\n"},
	{.doctest_block, "\n</pre>\n"},
	{.enumerated_list, "</ol>\n"},
	{.field_list, "</dl>\n"},
	{.field_name, "<span class=\"colon\">:</span></dt>\n"},
	{.field_body, "</dd>\n"},
	{.legend, "</div>\n"},
	{.line, "</div>\n"},
	{.line_block, "</div>\n"},
	{.list_item, "</li>\n"},
	{.option_argument, "</var>"},
	{.option_group, "</kbd></dt>\n"},
	{.option_list, "</dl>\n"},
	{.row, "</tr>\n"},
	{.rubric, "</p>\n"},
	{.system_message, "</aside>\n"},
	{.tbody, "</tbody>\n"},
	{.thead, "</thead>\n"},
}

@(private = "file")
html_depart_closing :: proc(t: ^Html, n: dt.Node) {
	tag := dt.tag(t.doc, n)
	for c in CLOSING_TAGS {
		if c.tag == tag {
			put(&t.body, c.close)
			return
		}
	}
}

@(private = "file")
html_visit_pass :: proc(t: ^Html, n: dt.Node) -> Visit {
	return .Continue
}

@(private = "file")
html_visit_skip :: proc(t: ^Html, n: dt.Node) -> Visit {
	return .Skip_Node
}

@(private = "file")
html_visit_block_quote :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "blockquote")
	return .Continue
}

@(init, private = "file")
init_html_dispatch :: proc "contextless" () {
	v := &html_dispatch.visit
	d := &html_dispatch.depart
	for c in CLOSING_TAGS do d[c.tag] = html_depart_closing
	inlines := [?]dt.Tag {
		.abbreviation, .acronym, .emphasis, .strong, .subscript, .superscript, .title_reference,
	}
	for tag in inlines {
		v[tag] = html_visit_simple_inline
		d[tag] = html_depart_simple_inline
	}
	for tag in ([?]dt.Tag{.contact, .organization, .revision, .status, .version}) {
		v[tag] = html_visit_docinfo_item
		d[tag] = html_depart_docinfo_item
	}
	for tag in ([?]dt.Tag{.authors, .copyright, .date}) do d[tag] = html_depart_docinfo_item
	for tag in ([?]dt.Tag{.decoration, .option_list_item, .option_string}) {
		v[tag] = html_visit_pass
	}
	v[.Text] = html_visit_text
	v[.address], d[.address] = html_visit_address, html_depart_address
	v[.admonition] = html_visit_admonition
	v[.attribution], d[.attribution] = html_visit_attribution, html_depart_attribution
	v[.author], d[.author] = html_visit_author, html_depart_author
	v[.authors] = html_visit_authors
	v[.block_quote] = html_visit_block_quote
	v[.bullet_list], d[.bullet_list] = html_visit_bullet_list, html_depart_bullet_list
	v[.caption] = html_visit_caption
	v[.citation], d[.citation] = html_visit_citation, html_depart_citation
	v[.citation_reference] = html_visit_citation_reference
	d[.citation_reference] = html_depart_citation_reference
	v[.classifier], d[.classifier] = html_visit_classifier, html_depart_classifier
	v[.colspec], d[.colspec] = html_visit_colspec, html_depart_colspec
	v[.comment] = html_visit_comment
	v[.compound] = html_visit_compound
	v[.container], d[.container] = html_visit_container, html_depart_tagname
	v[.copyright] = html_visit_copyright
	v[.date] = html_visit_date
	v[.definition], d[.definition] = html_visit_definition, html_depart_definition
	init_html_dispatch_2()
}

@(private = "file")
init_html_dispatch_2 :: proc "contextless" () {
	v := &html_dispatch.visit
	d := &html_dispatch.depart
	v[.definition_list] = html_visit_definition_list
	d[.definition_list] = html_depart_definition_list
	v[.definition_list_item] = html_visit_definition_list_item
	d[.definition_list_item] = html_depart_definition_list_item
	v[.description] = html_visit_description
	v[.docinfo], d[.docinfo] = html_visit_docinfo, html_depart_docinfo
	v[.doctest_block] = html_visit_doctest_block
	v[.document], d[.document] = html_visit_document, html_depart_document
	v[.entry], d[.entry] = html_visit_entry, html_depart_pop
	v[.enumerated_list] = html_visit_enumerated_list
	v[.field] = html_visit_field
	v[.field_body] = html_visit_field_body
	v[.field_list] = html_visit_field_list
	v[.field_name] = html_visit_field_name
	v[.figure], d[.figure] = html_visit_figure, html_depart_figure
	v[.footer], d[.footer] = html_visit_decoration_part, html_depart_footer
	v[.footnote], d[.footnote] = html_visit_footnote, html_depart_footnote
	v[.footnote_reference] = html_visit_footnote_reference
	d[.footnote_reference] = html_depart_footnote_reference
	v[.generated] = html_visit_generated
	v[.header], d[.header] = html_visit_decoration_part, html_depart_header
	v[.image] = html_visit_image
	v[.inline], d[.inline] = html_visit_inline, html_depart_inline
	v[.label], d[.label] = html_visit_label, html_depart_label
	v[.legend] = html_visit_legend
	v[.line] = html_visit_line
	v[.line_block] = html_visit_line_block
	v[.list_item] = html_visit_list_item
	v[.literal], d[.literal] = html_visit_literal, html_depart_literal
	v[.literal_block], d[.literal_block] = html_visit_literal_block, html_depart_literal_block
	init_html_dispatch_3()
}

@(private = "file")
init_html_dispatch_3 :: proc "contextless" () {
	v := &html_dispatch.visit
	d := &html_dispatch.depart
	v[.math] = html_visit_math
	v[.math_block], d[.math_block] = html_visit_math, html_depart_math_block
	v[.meta] = html_visit_meta
	v[.option], d[.option] = html_visit_option, html_depart_option
	v[.option_argument] = html_visit_option_argument
	v[.option_group] = html_visit_option_group
	v[.option_list] = html_visit_option_list
	v[.paragraph], d[.paragraph] = html_visit_paragraph, html_depart_paragraph
	v[.problematic], d[.problematic] = html_visit_problematic, html_depart_problematic
	v[.raw] = html_visit_raw
	v[.reference], d[.reference] = html_visit_reference, html_depart_reference
	v[.row] = html_visit_row
	v[.rubric] = html_visit_rubric
	v[.section], d[.section] = html_visit_section, html_depart_section
	v[.sidebar], d[.sidebar] = html_visit_sidebar, html_depart_sidebar
	v[.substitution_definition] = html_visit_skip
	v[.subtitle], d[.subtitle] = html_visit_subtitle, html_depart_subtitle
	v[.system_message] = html_visit_system_message
	v[.table], d[.table] = html_visit_table, html_depart_table
	v[.target], d[.target] = html_visit_target, html_depart_pop
	v[.tbody] = html_visit_tbody
	v[.term], d[.term] = html_visit_term, html_depart_term
	v[.tgroup] = html_visit_tgroup
	v[.thead] = html_visit_thead
	v[.title], d[.title] = html_visit_title, html_depart_title
	v[.topic], d[.topic] = html_visit_topic, html_depart_tagname
	v[.transition] = html_visit_transition
}

html_visit_description :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "dd", "")
	return .Continue
}
