package writers

import "core:strings"

import dt "../doctree"
import texmath "../math"

// Visitors of the LaTeX translator for body elements (``_visit_body``) and
// the dispatch tables.

@(private = "file")
LATEX_VISIT := #partial [dt.Tag]proc(t: ^Latex, n: dt.Node) -> Visit {
	.Text = latex_visit_text,
	.abbreviation = latex_visit_abbreviation,
	.acronym = latex_visit_abbreviation,
	.address = latex_visit_address,
	.admonition = latex_visit_admonition,
	.attribution = latex_visit_attribution,
	.author = latex_visit_author,
	.authors = latex_visit_docinfo_item,
	.block_quote = latex_visit_block_quote,
	.bullet_list = latex_visit_bullet_list,
	.caption = latex_visit_wrapped,
	.citation = latex_visit_citation,
	.citation_reference = latex_visit_citation_reference,
	.classifier = latex_visit_classifier,
	.colspec = latex_visit_colspec,
	.comment = latex_visit_comment,
	.compound = latex_visit_compound,
	.contact = latex_visit_docinfo_item,
	.container = latex_visit_container,
	.copyright = latex_visit_docinfo_item,
	.date = latex_visit_docinfo_item,
	.decoration = latex_visit_pass,
	.definition = latex_visit_pass,
	.definition_list = latex_visit_definition_list,
	.definition_list_item = latex_visit_definition_list_item,
	.description = latex_visit_description,
	.docinfo = latex_visit_docinfo,
	.doctest_block = latex_visit_literal_block,
	.document = latex_visit_document,
	.emphasis = latex_visit_wrapped,
	.entry = latex_visit_entry,
	.enumerated_list = latex_visit_enumerated_list,
	.field = latex_visit_field,
	.field_body = latex_visit_field_body,
	.field_list = latex_visit_field_list,
	.field_name = latex_visit_field_name,
	.figure = latex_visit_figure,
	.footer = latex_visit_header,
	.footnote = latex_visit_footnote,
	.footnote_reference = latex_visit_footnote_reference,
	.generated = latex_visit_pass,
	.header = latex_visit_header,
	.image = latex_visit_image,
	.inline = latex_visit_inline,
	.label = latex_visit_label,
	.legend = latex_visit_legend,
	.line = latex_visit_line,
	.line_block = latex_visit_line_block,
	.list_item = latex_visit_list_item,
	.literal = latex_visit_literal,
	.literal_block = latex_visit_literal_block,
	.math = latex_visit_math,
	.math_block = latex_visit_math_block,
	.meta = latex_visit_meta,
	.option = latex_visit_option,
	.option_argument = latex_visit_option_argument,
	.option_group = latex_visit_option_group,
	.option_list = latex_visit_option_list,
	.option_list_item = latex_visit_option_list_item,
	.option_string = latex_visit_pass,
	.organization = latex_visit_docinfo_item,
	.paragraph = latex_visit_paragraph,
	.problematic = latex_visit_problematic,
	.raw = latex_visit_raw,
	.reference = latex_visit_reference,
	.revision = latex_visit_docinfo_item,
	.row = latex_visit_row,
	.rubric = latex_visit_rubric,
	.section = latex_visit_section,
	.sidebar = latex_visit_sidebar,
	.status = latex_visit_docinfo_item,
	.strong = latex_visit_wrapped,
	.subscript = latex_visit_wrapped,
	.substitution_definition = latex_visit_skip,
	.subtitle = latex_visit_subtitle,
	.superscript = latex_visit_wrapped,
	.system_message = latex_visit_system_message,
	.table = latex_visit_table,
	.target = latex_visit_target,
	.tbody = latex_visit_tbody,
	.term = latex_visit_term,
	.tgroup = latex_visit_pass,
	.thead = latex_visit_thead,
	.title = latex_visit_title,
	.title_reference = latex_visit_wrapped,
	.topic = latex_visit_topic,
	.transition = latex_visit_transition,
	.version = latex_visit_docinfo_item,
}

@(private = "file")
LATEX_DEPART := #partial [dt.Tag]proc(t: ^Latex, n: dt.Node) {
	.abbreviation = latex_depart_inline,
	.acronym = latex_depart_inline,
	.address = latex_depart_address,
	.admonition = latex_depart_admonition,
	.attribution = latex_depart_attribution,
	.author = latex_depart_author,
	.authors = latex_depart_docinfo_item,
	.block_quote = latex_depart_block_quote,
	.bullet_list = latex_depart_bullet_list,
	.caption = latex_depart_wrapped,
	.citation = latex_depart_citation,
	.citation_reference = latex_depart_citation_reference,
	.classifier = latex_depart_classifier,
	.compound = latex_depart_duclass,
	.contact = latex_depart_docinfo_item,
	.container = latex_depart_duclass,
	.copyright = latex_depart_docinfo_item,
	.date = latex_depart_docinfo_item,
	.definition_list = latex_depart_definition_list,
	.definition_list_item = latex_depart_definition_list_item,
	.docinfo = latex_depart_docinfo,
	.doctest_block = latex_depart_literal_block,
	.document = latex_depart_document,
	.emphasis = latex_depart_wrapped,
	.entry = latex_depart_entry,
	.enumerated_list = latex_depart_enumerated_list,
	.field_body = latex_depart_field_body,
	.field_list = latex_depart_field_list,
	.field_name = latex_depart_field_name,
	.figure = latex_depart_figure,
	.footer = latex_depart_header,
	.footnote = latex_depart_footnote,
	.footnote_reference = latex_depart_context,
	.header = latex_depart_header,
	.inline = latex_depart_inline,
	.label = latex_depart_label,
	.legend = latex_depart_legend,
	.line = latex_depart_line,
	.line_block = latex_depart_line_block,
	.literal = latex_depart_literal,
	.literal_block = latex_depart_literal_block,
	.option = latex_depart_option,
	.option_group = latex_depart_option_group,
	.option_list = latex_depart_option_list,
	.organization = latex_depart_docinfo_item,
	.paragraph = latex_depart_paragraph,
	.problematic = latex_depart_problematic,
	.raw = latex_depart_raw,
	.reference = latex_depart_reference,
	.revision = latex_depart_docinfo_item,
	.row = latex_depart_row,
	.rubric = latex_depart_rubric,
	.section = latex_depart_section,
	.sidebar = latex_depart_sidebar,
	.status = latex_depart_docinfo_item,
	.strong = latex_depart_wrapped,
	.subscript = latex_depart_wrapped,
	.subtitle = latex_depart_subtitle,
	.superscript = latex_depart_wrapped,
	.system_message = latex_depart_system_message,
	.table = latex_depart_table,
	.target = latex_depart_inline,
	.term = latex_depart_term,
	.thead = latex_depart_thead,
	.title = latex_depart_title,
	.title_reference = latex_depart_wrapped,
	.topic = latex_depart_topic,
	.version = latex_depart_docinfo_item,
}

latex_dispatch := Dispatch(Latex) {
	visit  = LATEX_VISIT,
	depart = LATEX_DEPART,
}

latex_visit_pass :: proc(t: ^Latex, n: dt.Node) -> Visit {
	return .Continue
}

latex_visit_skip :: proc(t: ^Latex, n: dt.Node) -> Visit {
	return .Skip_Node
}

latex_depart_duclass :: proc(t: ^Latex, n: dt.Node) {
	duclass_close(t, n)
}

// --- admonitions, quotes, lists ------------------------------------------------------------

latex_visit_admonition :: proc(t: ^Latex, n: dt.Node) -> Visit {
	doc := t.doc
	classes := make([dynamic]string, 0, 4, context.temp_allocator)
	for c in list_strings(doc, n, dt.K_CLASSES) do if c != "admonition" do append(&classes, c)
	dt.set_list(doc, n, dt.K_CLASSES, ..classes[:])
	is_error := has_class(doc, n, "error")
	if t.s.legacy_class_functions {
		t.fallbacks["admonition"] = preamble_cmd("admonition_legacy")
		if is_error do t.fallbacks["error"] = preamble_cmd("error_legacy")
		o(t, cat("\n\\DUadmonition[", strings.join(classes[:], ",", context.temp_allocator), "]{"))
		return .Continue
	}
	provide_fallback(t, "admonition")
	if is_error do provide_fallback(t, "error")
	if dt.tag(doc, n) != .system_message do put_labels(t, n, pre_nl = true)
	duclass_open(t, n)
	o(t, "\\begin{DUadmonition}")
	return .Continue
}

latex_depart_admonition :: proc(t: ^Latex, n: dt.Node) {
	if t.s.legacy_class_functions {
		o(t, "}\n")
		return
	}
	o(t, "\\end{DUadmonition}\n")
	duclass_close(t, n)
}

// Environments opened with labels and class declarations: ``\begin{env}``.
@(private = "file")
open_env :: proc(t: ^Latex, n: dt.Node, begin: string) -> Visit {
	put_labels(t, n, pre_nl = true)
	duclass_open(t, n)
	o(t, begin)
	return .Continue
}

@(private = "file")
close_env :: proc(t: ^Latex, n: dt.Node, end: string) {
	o(t, end)
	duclass_close(t, n)
}

latex_visit_block_quote :: proc(t: ^Latex, n: dt.Node) -> Visit {
	return open_env(t, n, "\\begin{quote}")
}

latex_depart_block_quote :: proc(t: ^Latex, n: dt.Node) {
	close_env(t, n, "\\end{quote}\n")
}

latex_visit_bullet_list :: proc(t: ^Latex, n: dt.Node) -> Visit {
	return open_env(t, n, "\\begin{itemize}")
}

latex_depart_bullet_list :: proc(t: ^Latex, n: dt.Node) {
	close_env(t, n, "\\end{itemize}\n")
}

latex_visit_definition_list :: proc(t: ^Latex, n: dt.Node) -> Visit {
	return open_env(t, n, "\\begin{description}\n")
}

latex_depart_definition_list :: proc(t: ^Latex, n: dt.Node) {
	close_env(t, n, "\\end{description}\n")
}

latex_visit_attribution :: proc(t: ^Latex, n: dt.Node) -> Visit {
	prefix, suffix := latex_attribution_affixes(t.s.attribution)
	o(t, "\\nopagebreak\n")
	put_labels(t, n, pre_nl = true)
	duclass_open(t, n)
	o(t, cat("\\raggedleft ", prefix))
	ctx_push(t, suffix)
	return .Continue
}

latex_depart_attribution :: proc(t: ^Latex, n: dt.Node) {
	o(t, cat(ctx_pop_str(t), "\n"))
	duclass_close(t, n)
}

latex_attribution_affixes :: proc(name: string) -> (prefix, suffix: string) {
	switch name {
	case "dash":
		return "—", ""
	case "parentheses", "parens":
		return "(", ")"
	}
	return "", ""
}

latex_visit_citation :: proc(t: ^Latex, n: dt.Node) -> Visit {
	if t.use_latex_citations {
		push_new_collector(t)
	} else {
		o(t, "\\begin{figure}[b]")
		append_hypertargets(t, n)
	}
	return .Continue
}

latex_depart_citation :: proc(t: ^Latex, n: dt.Node) {
	if !t.use_latex_citations {
		o(t, "\\end{figure}\n")
		return
	}
	if chunks(t.out) == 0 {
		t.err = "IndexError: list index out of range"
		return
	}
	label := chunk_at(t.out, 0)
	text := text_range(t.out, 1)
	append(&t.bibitems, Bibitem{label, text, true})
	pop_collector(t)
}

latex_visit_classifier :: proc(t: ^Latex, n: dt.Node) -> Visit {
	o(t, "(\\textbf{")
	return .Continue
}

latex_depart_classifier :: proc(t: ^Latex, n: dt.Node) {
	o(t, "})")
	for s := dt.next_sibling(t.doc, n); s != 0; s = dt.next_sibling(t.doc, s) {
		if dt.tag(t.doc, s) == .term {
			o(t, "\n")
			break
		}
	}
}

latex_visit_comment :: proc(t: ^Latex, n: dt.Node) -> Visit {
	if !parent_is(t.doc, n, {.compound}) do o(t, "\n")
	text, _ := strings.replace_all(astext(t.doc, n), "\n", "\n% ", context.temp_allocator)
	o(t, cat("% ", text, "\n"))
	return .Skip_Node
}

latex_visit_compound :: proc(t: ^Latex, n: dt.Node) -> Visit {
	if parent_is(t.doc, n, {.compound}) do o(t, "\n")
	put_labels(t, n, pre_nl = true)
	insert_class(t.doc, n, "compound")
	duclass_open(t, n)
	return .Continue
}

latex_visit_container :: proc(t: ^Latex, n: dt.Node) -> Visit {
	put_labels(t, n, pre_nl = true)
	duclass_open(t, n)
	return .Continue
}

latex_visit_definition_list_item :: proc(t: ^Latex, n: dt.Node) -> Visit {
	put_labels(t, n, newline = true)
	return .Continue
}

latex_depart_definition_list_item :: proc(t: ^Latex, n: dt.Node) {
	if dt.next_sibling(t.doc, n) != 0 do o(t, "\n")
}

latex_visit_description :: proc(t: ^Latex, n: dt.Node) -> Visit {
	o(t, " ")
	return .Continue
}

@(private = "file")
ENUM_TYPES := [?][2]string {
	{"", ""},
	{"arabic", "arabic"},
	{"loweralpha", "alph"},
	{"upperalpha", "Alph"},
	{"lowerroman", "roman"},
	{"upperroman", "Roman"},
}

@(private = "file")
DEFAULT_ENUM_LABELS := [4][3]string {
	{"", "arabic", "."},
	{"(", "alph", ")"},
	{"", "roman", "."},
	{"", "Alph", "."},
}

latex_visit_enumerated_list :: proc(t: ^Latex, n: dt.Node) -> Visit {
	doc := t.doc
	prefix := enumeration_prefix(t, n)
	name := attr(doc, n, "enumtype", "arabic")
	enumtype, found := "", false
	for e in ENUM_TYPES do if e[0] == name do enumtype, found = e[1], true
	if !found {
		t.err = cat("KeyError: '", name, "'")
		return .Skip_Node
	}
	suffix := attr(doc, n, "suffix", ".")
	level := len(t.enumeration_counters) + 1
	counter := cat("enum", roman(level, lower = true))
	label := cat(prefix, "\\", enumtype, "{", counter, "}", suffix)
	append(&t.enumeration_counters, label)
	put_labels(t, n, pre_nl = true)
	duclass_open(t, n)
	if level <= 4 {
		o(t, "\\begin{enumerate}")
		if ([3]string{prefix, enumtype, suffix}) != DEFAULT_ENUM_LABELS[level - 1] {
			o(t, cat("\n\\renewcommand{\\label", counter, "}{", label, "}"))
		}
	} else {
		t.fallbacks[counter] = cat("\\newcounter{", counter, "}")
		put_all(t.out, "\\begin{list}", cat("{", label, "}"), cat("{\\usecounter{", counter, "}}"))
	}
	if has(doc, n, "start") {
		o(t, cat("\n\\setcounter{", counter, "}{", int_str(dt.get_int(doc, n, "start") - 1), "}"))
	}
	return .Continue
}

@(private = "file")
enumeration_prefix :: proc(t: ^Latex, n: dt.Node) -> string {
	prefix := ""
	if t.s.compound_enumerators {
		if t.s.section_prefix_for_enumerators && t.section_level > 0 &&
		   len(t.enumeration_counters) == 0 {
			b := strings.builder_make(context.temp_allocator)
			for num, i in t.section_number[:min(t.section_level, len(t.section_number))] {
				if i > 0 do strings.write_byte(&b, '.')
				strings.write_int(&b, num)
			}
			prefix = cat(strings.to_string(b), t.section_enumerator_separator)
		}
		if len(t.enumeration_counters) > 0 {
			prefix = cat(prefix, t.enumeration_counters[len(t.enumeration_counters) - 1])
		}
	}
	return cat(prefix, attr(t.doc, n, "prefix"))
}

latex_depart_enumerated_list :: proc(t: ^Latex, n: dt.Node) {
	o(t, "\\end{enumerate}\n" if len(t.enumeration_counters) <= 4 else "\\end{list}\n")
	duclass_close(t, n)
	pop(&t.enumeration_counters)
}

latex_visit_field :: proc(t: ^Latex, n: dt.Node) -> Visit {
	put_labels(t, n, pre_nl = true)
	return .Continue
}

latex_visit_field_body :: proc(t: ^Latex, n: dt.Node) -> Visit {
	doc := t.doc
	if dt.tag(doc, dt.parent(doc, dt.parent(doc, n))) != .docinfo do o(t, term_postfix(t, n))
	return .Continue
}

latex_depart_field_body :: proc(t: ^Latex, n: dt.Node) {
	if t.out == &t.docinfo do o(t, "\\\\\n")
}

latex_visit_field_list :: proc(t: ^Latex, n: dt.Node) -> Visit {
	put_labels(t, n, pre_nl = true)
	duclass_open(t, n)
	if t.out != &t.docinfo {
		provide_fallback(t, "fieldlist")
		o(t, "\\begin{DUfieldlist}")
	}
	return .Continue
}

latex_depart_field_list :: proc(t: ^Latex, n: dt.Node) {
	if t.out != &t.docinfo do o(t, "\\end{DUfieldlist}\n")
	duclass_close(t, n)
}

latex_visit_field_name :: proc(t: ^Latex, n: dt.Node) -> Visit {
	o(t, "\\textbf{" if t.out == &t.docinfo else "\n\\item[{")
	return .Continue
}

latex_depart_field_name :: proc(t: ^Latex, n: dt.Node) {
	o(t, "}: &" if t.out == &t.docinfo else ":}]")
}

latex_visit_figure :: proc(t: ^Latex, n: dt.Node) -> Visit {
	t.requirements["float"] = preamble_cmd("float")
	put_labels(t, n, pre_nl = true)
	duclass_open(t, n)
	align := "center"
	if v, ok := dt.get_attr(t.doc, n, "align"); ok do align = attr_text(t.doc, v)
	if align != "center" {
		o(t, cat("\\begin{figure} % align = \"", align, "\""))
	} else {
		o(t, "\\begin{figure}")
	}
	return .Continue
}

latex_depart_figure :: proc(t: ^Latex, n: dt.Node) {
	close_env(t, n, "\\end{figure}\n")
}

latex_visit_footnote :: proc(t: ^Latex, n: dt.Node) -> Visit {
	doc := t.doc
	ids := list_strings(doc, n, dt.K_IDS)
	backrefs := list_strings(doc, n, dt.K_BACKREFS)
	if len(ids) == 0 {
		t.err = "IndexError: list index out of range"
		return .Skip_Node
	}
	backref := backrefs[0] if len(backrefs) > 0 else ids[0]
	if t.s.docutils_footnotes {
		provide_fallback(t, "footnotes")
		num := astext(doc, dt.first_child(doc, n))
		if t.s.footnote_references == "brackets" do num = cat("[", num, "]")
		o(t, cat("%\n\\DUfootnotetext{", ids[0], "}{", backref, "}{", latex_encode(t, num), "}{"))
		second := dt.child_at(doc, n, 1)
		if second != 0 && dt.tag(doc, second) == .paragraph do o(t, "%")
	}
	return .Continue
}

latex_depart_footnote :: proc(t: ^Latex, n: dt.Node) {
	o(t, "}\n")
}

// Footnote and citation labels.
latex_visit_label :: proc(t: ^Latex, n: dt.Node) -> Visit {
	return label_delim(t, n, "[")
}

latex_depart_label :: proc(t: ^Latex, n: dt.Node) {
	label_delim(t, n, "]")
}

@(private = "file")
label_delim :: proc(t: ^Latex, n: dt.Node, bracket: string) -> Visit {
	#partial switch dt.tag(t.doc, dt.parent(t.doc, n)) {
	case .footnote:
		return .Skip_Node
	case .citation:
		if !t.use_latex_citations do o(t, bracket)
		return .Continue
	}
	t.err = "AssertionError: label outside footnote or citation"
	return .Skip_Node
}

latex_visit_header :: proc(t: ^Latex, n: dt.Node) -> Visit {
	push_new_collector(t)
	is_header := dt.tag(t.doc, n) == .header
	o(t, "\\newcommand{\\DUheader}{" if is_header else "\\newcommand{\\DUfooter}{")
	return .Continue
}

latex_depart_header :: proc(t: ^Latex, n: dt.Node) {
	o(t, "}")
	key := "~header" if dt.tag(t.doc, n) == .header else "~footer"
	t.requirements[key] = strings.clone(text_of(t.out), context.temp_allocator)
	pop_collector(t)
}

latex_visit_legend :: proc(t: ^Latex, n: dt.Node) -> Visit {
	provide_fallback(t, "legend")
	o(t, "\\begin{DUlegend}")
	return .Continue
}

latex_depart_legend :: proc(t: ^Latex, n: dt.Node) {
	o(t, "\\end{DUlegend}\n")
}

latex_visit_line :: proc(t: ^Latex, n: dt.Node) -> Visit {
	o(t, "\\item[] ")
	return .Continue
}

latex_depart_line :: proc(t: ^Latex, n: dt.Node) {
	o(t, "\n")
}

latex_visit_line_block :: proc(t: ^Latex, n: dt.Node) -> Visit {
	provide_fallback(t, "providelength", "_providelength")
	provide_fallback(t, "lineblock")
	set_align_from_classes(t, n)
	if parent_is(t.doc, n, {.line_block}) {
		o(t, "\\item[]\n\\begin{DUlineblock}{\\DUlineblockindent}\n")
	} else {
		put_labels(t, n, pre_nl = true)
		duclass_open(t, n)
		o(t, "\\begin{DUlineblock}{0em}\n")
		insert_align_declaration(t, n)
	}
	return .Continue
}

latex_depart_line_block :: proc(t: ^Latex, n: dt.Node) {
	close_env(t, n, "\\end{DUlineblock}\n")
}

latex_visit_list_item :: proc(t: ^Latex, n: dt.Node) -> Visit {
	put_labels(t, n, pre_nl = true)
	o(t, "\n\\item ")
	return .Continue
}

latex_visit_meta :: proc(t: ^Latex, n: dt.Node) -> Visit {
	doc := t.doc
	if !has(doc, n, "name") || !has(doc, n, "content") do return .Skip_Node
	name := attr_str(doc, n, "name")
	content := latex_encode(t, attr_str(doc, n, "content"))
	switch name {
	case "author", "keywords", "producer", "subject", "title":
		append(&t.pdfinfo, cat("  pdf", name, "={", content, "},"))
	case "creator":
		append(&t.pdfinfo, cat("  addtopdfcreator={", content, "},"))
	case:
		append(&t.pdfinfo, cat("  pdfinfo={", name, "={", content, "}},"))
	}
	return .Continue
}

latex_visit_math_block :: proc(t: ^Latex, n: dt.Node) -> Visit {
	doc := t.doc
	t.requirements["amsmath"] = "\\usepackage{amsmath}"
	text := astext(doc, n)
	env := texmath.pick_math_environment(text)
	o(t, "%\n")
	if len(dt.attr_list(doc, n, dt.K_IDS)) > 0 do o(t, "\\phantomsection\n")
	classes := list_strings(doc, n, dt.K_CLASSES)
	for cls in classes {
		provide_fallback(t, "inline")
		o(t, cat("\\DUrole{", cls, "}{%\n"))
	}
	code := texmath.uni2tex_translate(text, context.temp_allocator)
	put_all(t.out, cat("\\begin{", env, "}\n"), code, "\n")
	put_labels(t, n, set_anchor = false, newline = true)
	o(t, cat("\\end{", env, "}"))
	if len(classes) > 0 {
		o(t, cat("\n", strings.repeat("}", len(classes), context.temp_allocator)))
	}
	return .Skip_Node
}

latex_visit_option :: proc(t: ^Latex, n: dt.Node) -> Visit {
	if count, _ := t.ctx[len(t.ctx) - 1].(int); count != 0 do o(t, ", ")
	return .Continue
}

latex_depart_option :: proc(t: ^Latex, n: dt.Node) {
	top := &t.ctx[len(t.ctx) - 1]
	count, _ := top.(int)
	top^ = count + 1
}

latex_visit_option_argument :: proc(t: ^Latex, n: dt.Node) -> Visit {
	o(t, attr(t.doc, n, "delimiter", " "))
	return .Continue
}

latex_visit_option_group :: proc(t: ^Latex, n: dt.Node) -> Visit {
	o(t, "\\item[")
	ctx_push(t, 0)
	return .Continue
}

latex_depart_option_group :: proc(t: ^Latex, n: dt.Node) {
	pop(&t.ctx)
	o(t, "] ")
}

latex_visit_option_list :: proc(t: ^Latex, n: dt.Node) -> Visit {
	provide_fallback(t, "providelength", "_providelength")
	provide_fallback(t, "optionlist")
	return open_env(t, n, "\\begin{DUoptionlist}\n")
}

latex_depart_option_list :: proc(t: ^Latex, n: dt.Node) {
	close_env(t, n, "\\end{DUoptionlist}\n")
}

latex_visit_option_list_item :: proc(t: ^Latex, n: dt.Node) -> Visit {
	put_labels(t, n, newline = true)
	return .Continue
}

latex_visit_paragraph :: proc(t: ^Latex, n: dt.Node) -> Visit {
	doc := t.doc
	p := dt.parent(doc, n)
	index := dt.index_identity(doc, p, n)
	switch {
	case index == 0 && dt.is(doc, p, {.list_item, .description, .compound, .container}):
	case index > 0 && dt.tag(doc, p) == .compound &&
	     !dt.is(doc, dt.child_at(doc, p, index - 1), {.paragraph, .compound}):
	case t.active_table.colwidths_auto:
		if index > 0 do o(t, "\n")
	case:
		o(t, "\n")
	}
	return latex_visit_inline(t, n)
}

latex_depart_paragraph :: proc(t: ^Latex, n: dt.Node) {
	latex_depart_inline(t, n)
	if !t.active_table.colwidths_auto do o(t, "\n")
}

latex_visit_rubric :: proc(t: ^Latex, n: dt.Node) -> Visit {
	provide_fallback(t, "rubric")
	return open_env(t, n, "\\DUrubric{")
}

latex_depart_rubric :: proc(t: ^Latex, n: dt.Node) {
	close_env(t, n, "}\n")
}

latex_visit_sidebar :: proc(t: ^Latex, n: dt.Node) -> Visit {
	put_labels(t, n, pre_nl = true)
	duclass_open(t, n)
	t.requirements["color"] = preamble_cmd("color")
	provide_fallback(t, "sidebar")
	o(t, "\\DUsidebar{")
	return .Continue
}

latex_depart_sidebar :: proc(t: ^Latex, n: dt.Node) {
	close_env(t, n, "}\n")
}

latex_visit_term :: proc(t: ^Latex, n: dt.Node) -> Visit {
	o(t, "\\item[{")
	return .Continue
}

latex_depart_term :: proc(t: ^Latex, n: dt.Node) {
	o(t, "}] ")
	next := dt.next_sibling(t.doc, n)
	if next == 0 {
		t.err = "TypeError: 'NoneType' object is not iterable"
		return
	}
	#partial switch dt.tag(t.doc, next) {
	case .term:
		o(t, "\n")
	case .classifier:
	case:
		o(t, term_postfix(t, next))
	}
}

latex_visit_transition :: proc(t: ^Latex, n: dt.Node) -> Visit {
	provide_fallback(t, "transition")
	o(t, cat("\n%", strings.repeat("_", 75, context.temp_allocator), "\n"))
	o(t, "\\DUtransition\n")
	return .Continue
}

// --- literal blocks ---------------------------------------------------------------------

latex_visit_literal_block :: proc(t: ^Latex, n: dt.Node) -> Visit {
	doc := t.doc
	first := dt.first_child(doc, n)
	plaintext := first != 0 && dt.next_sibling(doc, first) == 0 && dt.tag(doc, first) == .Text
	in_table := t.active_table.is_open
	autowidth := in_table && t.active_table.colwidths_auto
	no_env := dt.Tag_Set{.footnote, .sidebar}
	if t.s.legacy_class_functions do no_env += {.admonition, .system_message}
	use_env := plaintext && !parent_is(doc, n, no_env)
	use_listings := t.literal_block_env == "lstlisting" && use_env
	put_labels(t, n, pre_nl = true)
	duclass_open(t, n)
	if !plaintext && has_class(doc, n, "code") && t.s.syntax_highlight != "none" {
		t.requirements["color"] = preamble_cmd("color")
		provide_fallback(t, "highlight_rules", "code")
	}
	switch {
	case in_table && use_env && !autowidth:
		t.fallbacks["ttem"] = preamble_cmd("ttem")
		width := 0
		text := astext(doc, n)
		for line in strings.split_iterator(&text, "\n") do width = max(width, rune_len(line))
		o(t, cat("\\begin{minipage}{", int_str(width), "\\ttemwidth}\n"))
		ctx_push(t, "\n\\end{minipage}\n")
	case !in_table && !use_listings:
		o(t, "\\begin{quote}\n")
		ctx_push(t, "\n\\end{quote}\n")
	case:
		ctx_push(t, "\n")
	}
	open_literal_block_env(t, in_table, use_env, autowidth, use_listings)
	return .Continue
}

@(private = "file")
LITERAL_BLOCK_PACKAGES := [?][2]string {
	{"lstlisting", "\\usepackage{listings}\n\\lstset{xleftmargin=\\leftmargin}"},
	{"listing", "\\usepackage{moreverb}"},
	{"Verbatim", "\\usepackage{fancyvrb}"},
	{"verbatimtab", "\\usepackage{moreverb}"},
}

@(private = "file")
open_literal_block_env :: proc(t: ^Latex, in_table, use_env, autowidth, use_listings: bool) {
	env := t.literal_block_env
	switch {
	case env != "" && use_env && (!autowidth || use_listings):
		for p in LITERAL_BLOCK_PACKAGES do if p[0] == env do t.requirements["literal_block"] = p[1]
		t.verbatim = true
		if in_table && use_listings do o(t, "\\lstset{xleftmargin=0pt}\n")
		o(t, cat("\\begin{", env, "}", t.literal_block_options, "\n"))
		ctx_push(t, cat("\n\\end{", env, "}"))
	case use_env && !autowidth:
		t.alltt = true
		t.requirements["alltt"] = "\\usepackage{alltt}"
		o(t, "\\begin{alltt}\n")
		ctx_push(t, "\n\\end{alltt}")
	case:
		t.literal = true
		t.insert_newline = true
		t.insert_non_breaking_blanks = true
		o(t, "\\ttfamily\\raggedright\n")
		ctx_push(t, "")
	}
}

latex_depart_literal_block :: proc(t: ^Latex, n: dt.Node) {
	t.insert_non_breaking_blanks = false
	t.insert_newline = false
	t.literal = false
	t.verbatim = false
	t.alltt = false
	o(t, ctx_pop_str(t))
	o(t, ctx_pop_str(t))
	duclass_close(t, n)
}
