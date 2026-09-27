package writers

import "core:strings"

import dt "../doctree"

// Visitors of the LaTeX translator for the document, sections, titles,
// topics and bibliographic data (``latex2e._visit_document``).

@(private = "file")
TITLEDATA_NODES := dt.Tag_Set{.address, .author, .authors, .contact, .date, .organization}

latex_visit_address :: proc(t: ^Latex, n: dt.Node) -> Visit {
	t.insert_newline = true
	open_docinfo_item(t, n)
	return .Continue
}

latex_depart_address :: proc(t: ^Latex, n: dt.Node) {
	close_docinfo_item(t, n)
	t.insert_newline = false
}

latex_visit_author :: proc(t: ^Latex, n: dt.Node) -> Visit {
	append(&t.pdfauthor, latex_attval(t, astext(t.doc, n)))
	if parent_is(t.doc, n, {.authors}) {
		push_new_collector(t)
	} else {
		open_docinfo_item(t, n)
	}
	return .Continue
}

latex_depart_author :: proc(t: ^Latex, n: dt.Node) {
	if parent_is(t.doc, n, {.authors}) {
		name := pop_collector(t)
		o(t, text_of(name))
	} else {
		close_docinfo_item(t, n)
	}
}

// Visitor of the other bibliographic elements.
latex_visit_docinfo_item :: proc(t: ^Latex, n: dt.Node) -> Visit {
	open_docinfo_item(t, n)
	return .Continue
}

latex_depart_docinfo_item :: proc(t: ^Latex, n: dt.Node) {
	close_docinfo_item(t, n)
}

latex_visit_docinfo :: proc(t: ^Latex, n: dt.Node) -> Visit {
	push_collector(t, &t.docinfo)
	return .Continue
}

@(private = "file")
DOCINFO_START :: "\n% Docinfo\n\\begin{center}\n\\begin{tabularx}{\\DUdocinfowidth}{lX}\n"

latex_depart_docinfo :: proc(t: ^Latex, n: dt.Node) {
	pop_collector(t)
	if chunks(&t.docinfo) == 0 do return
	t.requirements["tabularx"] = "\\usepackage{tabularx}"
	provide_fallback(t, "providelength", "_providelength")
	provide_fallback(t, "docinfo")
	put_front(&t.docinfo, DOCINFO_START)
	put(&t.docinfo, "\\end{tabularx}\n\\end{center}\n")
}

// ``language_label(node.tagname)``.
@(private = "file")
docinfo_label :: proc(t: ^Latex, n: dt.Node) -> string {
	l: Label
	#partial switch dt.tag(t.doc, n) {
	case .author:
		l = .author
	case .authors:
		l = .authors
	case .organization:
		l = .organization
	case .address:
		l = .address
	case .contact:
		l = .contact
	case .version:
		l = .version
	case .revision:
		l = .revision
	case .status:
		l = .status
	case .date:
		l = .date
	case .copyright:
		l = .copyright
	}
	return t.lang.labels[l]
}

@(private = "file")
open_docinfo_item :: proc(t: ^Latex, n: dt.Node) {
	if t.s.use_latex_docinfo && dt.is(t.doc, n, TITLEDATA_NODES) {
		push_new_collector(t)
		return
	}
	label := docinfo_label(t, n)
	o(t, cat("\\textbf{", label, "}: &"))
	switch {
	case dt.tag(t.doc, n) == .address:
		o(t, " {\\raggedright\n")
	case rune_len(label) + rune_len(astext(t.doc, n)) > 64:
		o(t, "\n  ")
	case:
		o(t, " ")
	}
	if dt.tag(t.doc, n) == .authors do push_new_collector(t)
}

@(private = "file")
close_docinfo_item :: proc(t: ^Latex, n: dt.Node) {
	if t.s.use_latex_docinfo && dt.is(t.doc, n, TITLEDATA_NODES) {
		store_titledata(t, n)
		return
	}
	#partial switch dt.tag(t.doc, n) {
	case .address:
		o(t, "}")
	case .authors:
		names := pop_collector(t)
		seps := t.lang.author_separators
		sep := ""
		for i := len(seps) - 1; i >= 0; i -= 1 {
			sep = seps[i]
			if !any_chunk_contains(names, sep) do break
		}
		o(t, join_chunks(names, cat(sep, " ")))
	}
	o(t, " \\\\\n")
}

@(private = "file")
any_chunk_contains :: proc(out: ^Out, s: string) -> bool {
	for i in 0 ..< chunks(out) do if strings.contains(chunk_at(out, i), s) do return true
	return false
}

// ``sep.join(out)``.
join_chunks :: proc(out: ^Out, sep: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< chunks(out) {
		if i > 0 do strings.write_string(&b, sep)
		strings.write_string(&b, chunk_at(out, i))
	}
	return strings.to_string(b)
}

@(private = "file")
store_titledata :: proc(t: ^Latex, n: dt.Node) {
	doc := t.doc
	tag := dt.tag(doc, n)
	sep := ""
	if tag == .authors {
		sep = " \\and "
		for nn := dt.next_sibling(doc, n); nn != 0; nn = dt.next_sibling(doc, nn) {
			if dt.is(doc, nn, {.author, .authors}) do break
			if dt.is(doc, nn, {.address, .contact, .organization}) do sep = " \\quad "
		}
	}
	text := join_chunks(pop_collector(t), sep)
	#partial switch tag {
	case .date:
		append(&t.date, text)
	case .author, .authors:
		top := &t.author_stack[len(t.author_stack) - 1]
		if top[0] != "" {
			entry := make([dynamic]string, context.temp_allocator)
			append(&entry, text)
			append(&t.author_stack, entry)
		} else {
			top[0] = text
		}
	case:
		append(&t.author_stack[len(t.author_stack) - 1], text)
	}
}

latex_visit_document :: proc(t: ^Latex, n: dt.Node) -> Visit {
	first := dt.first_child(t.doc, n)
	if t.s.use_latex_docinfo || (first != 0 && dt.tag(t.doc, first) == .title) {
		protect := t.s.documentclass == "memoir"
		append(&t.title_labels, ..ids_to_labels(t, n, set_anchor = false, protect = protect))
	}
	return .Continue
}

latex_depart_document :: proc(t: ^Latex, n: dt.Node) {
	lang := t.babel.language
	if len(t.babel.otherlanguages) > 0 || (lang != "" && lang != "english") {
		t.requirements["babel"] = babel_setup(&t.babel)
	}
	complete_pdfsetup(t)
	stack := t.author_stack[:]
	has_author := len(stack) != 1 || len(stack[0]) != 1 || stack[0][0] != ""
	if chunks(&t.title) > 0 || len(t.date) > 0 || has_author do make_title(t)
	if len(t.bibitems) > 0 do append_bibliography(t)
	if "minitoc" in t.requirements && !t.has_latex_toc {
		o(t, "\n\\faketableofcontents % for local ToCs\n")
	}
}

@(private = "file")
complete_pdfsetup :: proc(t: ^Latex) {
	append(&t.pdfsetup, percent_s(preamble_cmd("linking"), t.hyperref_options))
	title := attr(t.doc, t.doc.root, "title")
	if title != "" do inject_at(&t.pdfinfo, 0, cat("  pdftitle={", latex_encode(t, title), "},"))
	if len(t.pdfauthor) > 0 {
		authors := ljoin(t.pdfauthor[:], cat(t.author_separator, " "))
		append(&t.pdfinfo, cat("  pdfauthor={", authors, "}"))
	}
	if len(t.pdfinfo) > 0 {
		append(&t.pdfsetup, "\\hypersetup{")
		append(&t.pdfsetup, ..t.pdfinfo[:])
		append(&t.pdfsetup, "}")
	}
}

@(private = "file")
make_title :: proc(t: ^Latex) {
	args := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&args, text_of(&t.title))
	if chunks(&t.title) > 0 do append(&args, ..t.title_labels[:])
	if chunks(&t.subtitle) > 0 {
		append(&args, "\\\\", cat("\\DUdocumentsubtitle{", text_of(&t.subtitle), "}"))
		append(&args, ..t.subtitle_labels[:])
	}
	append(&t.titledata, cat("\\title{", ljoin(args[:], "%\n  "), "}"))
	authors := make([dynamic]string, 0, 4, context.temp_allocator)
	for entry in t.author_stack {
		items := make([dynamic]string, 0, len(entry), context.temp_allocator)
		for e in entry do if e != "" do append(&items, e)
		append(&authors, strings.join(items[:], "\\\\\n", context.temp_allocator))
	}
	append(&t.titledata, cat("\\author{", ljoin(authors[:], " \\and\n"), "}"))
	append(&t.titledata, cat("\\date{", ljoin(t.date[:], ", "), "}"))
	put(&t.body_pre_docinfo, "\\maketitle\n")
}

@(private = "file")
append_bibliography :: proc(t: ^Latex) {
	bib := t.s.use_bibtex
	if len(bib) > 0 {
		o(t, cat("\n\\bibliographystyle{", bib[0], "}\n"))
		o(t, cat("\\bibliography{", strings.join(bib[1:], ",", context.temp_allocator), "}\n"))
		return
	}
	if !t.use_latex_citations do return
	widest := ""
	for item in t.bibitems do if rune_len(widest) < rune_len(item.label) do widest = item.label
	o(t, cat("\n\\begin{thebibliography}{", widest, "}\n"))
	for item in t.bibitems {
		key, _ := strings.replace_all(item.label, "\\_", "_", context.temp_allocator)
		o(t, cat("\\bibitem[", item.label, "]{", key, "}{", item.text, "}\n"))
	}
	o(t, "\\end{thebibliography}\n")
}

latex_visit_section :: proc(t: ^Latex, n: dt.Node) -> Visit {
	t.section_level += 1
	append(&t.section_number, 0)
	t.section_number[t.section_level - 1] += 1
	if "sectnum" in t.requirements do return .Continue
	depth: Maybe(int) = 0
	if !t.s.sectnum_xform {
		start, has_start := t.s.sectnum_start.?
		if !has_start {
			t.err = "TypeError: unsupported operand type(s) for -: 'NoneType' and 'int'"
			return .Skip_Node
		}
		if start != 1 {
			t.requirements["sectnum_start"] = cat(
				"\\setcounter{", t.d_class.sections[0], "}{", int_str(start - 1), "}")
		}
		depth = t.s.sectnum_depth
	}
	if d, ok := depth.?; ok {
		t.requirements["sectnum"] = cat(
			"\\setcounter{secnumdepth}{", int_str(latex_section_depth(&t.d_class, d)), "}")
	}
	return .Continue
}

latex_depart_section :: proc(t: ^Latex, n: dt.Node) {
	pop(&t.section_number)
	t.section_level -= 1
}

latex_visit_subtitle :: proc(t: ^Latex, n: dt.Node) -> Visit {
	#partial switch dt.tag(t.doc, dt.parent(t.doc, n)) {
	case .document:
		push_collector(t, &t.subtitle)
		provide_fallback(t, "documentsubtitle")
		protect := t.s.documentclass == "memoir"
		append(&t.subtitle_labels, ..ids_to_labels(t, n, set_anchor = false, protect = protect))
	case .section:
		o(t, cat("\\", section_name(&t.d_class, t.section_level + 1), "*{"))
	case:
		provide_fallback(t, "subtitle")
		o(t, "\n\\DUsubtitle{")
	}
	return .Continue
}

latex_depart_subtitle :: proc(t: ^Latex, n: dt.Node) {
	if parent_is(t.doc, n, {.document}) {
		pop_collector(t)
	} else {
		o(t, "}\n")
	}
}

latex_visit_system_message :: proc(t: ^Latex, n: dt.Node) -> Visit {
	doc := t.doc
	t.requirements["color"] = preamble_cmd("color")
	provide_fallback(t, "title")
	legacy := t.s.legacy_class_functions
	if legacy do t.fallbacks["title"] = preamble_cmd("title_legacy")
	dt.set_list(doc, n, dt.K_CLASSES, "system-message")
	o(t, "\n")
	append_hypertargets(t, n)
	latex_visit_admonition(t, n)
	if legacy {
		o(t, "\n\\DUtitle[system-message]{\\color{red}System Message}\n")
	} else {
		o(t, "\n\\DUtitle{\\color{red}System Message}\n")
	}
	line := ""
	if v, ok := dt.get_attr(doc, n, dt.K_LINE); ok do line = cat(", line~", attr_text(doc, v))
	type_v, _ := dt.get_attr(doc, n, dt.K_TYPE)
	level_v, _ := dt.get_attr(doc, n, dt.K_LEVEL)
	source_v, has_source := dt.get_attr(doc, n, dt.K_SOURCE)
	if !has_source {
		t.err = "KeyError: 'source'"
		return .Skip_Node
	}
	o(t, cat("\n", attr_text(doc, type_v), "/", attr_text(doc, level_v), " in \\texttt{",
		latex_encode(t, attr_text(doc, source_v)), "}", line, "\n"))
	backrefs := list_strings(doc, n, dt.K_BACKREFS)
	if len(backrefs) == 1 {
		o(t, cat("\n\\hyperlink{", backrefs[0], "}{"))
		ctx_push(t, "}\n")
		return .Continue
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "backrefs: ")
	for r, i in backrefs {
		if i > 0 do strings.write_byte(&b, ' ')
		strings.write_string(&b, cat("\\hyperlink{", r, "}{", int_str(i + 1), "}\n"))
	}
	ctx_push(t, strings.to_string(b))
	return .Continue
}

latex_depart_system_message :: proc(t: ^Latex, n: dt.Node) {
	o(t, ctx_pop_str(t))
	latex_depart_admonition(t, n)
}

latex_visit_title :: proc(t: ^Latex, n: dt.Node) -> Visit {
	doc := t.doc
	p := dt.parent(doc, n)
	#partial switch dt.tag(doc, p) {
	case .document:
		push_collector(t, &t.title)
		ctx_push(t, "")
	case .topic, .admonition, .sidebar:
		classes := list_strings(doc, p, dt.K_CLASSES)
		if len(classes) == 0 do classes = {dt.tagname(doc, p)}
		if t.s.legacy_class_functions {
			t.fallbacks["title"] = preamble_cmd("title_legacy")
			o(t, cat("\n\\DUtitle[", strings.join(classes, ",", context.temp_allocator), "]{"))
		} else {
			provide_fallback(t, "title")
			o(t, "\n\\DUtitle{")
		}
		ctx_push(t, "}\n")
	case .table:
		push_collector(t, &t.active_table.caption)
		ctx_push(t, "")
	case:
		visit_section_title(t, n)
	}
	return .Continue
}

@(private = "file")
visit_section_title :: proc(t: ^Latex, n: dt.Node) {
	level := t.section_level
	name := section_name(&t.d_class, level)
	o(t, "\n\n")
	unsupported := level > len(t.d_class.sections)
	legacy := t.s.legacy_class_functions
	if unsupported {
		if legacy {
			t.fallbacks["title"] = preamble_cmd("title_legacy")
			name = cat(name, "[section", roman(level), "]")
		} else {
			provide_fallback(t, "title")
			provide_fallback(t, "duclass", "DUclass")
			o(t, cat("\\begin{DUclass}{section", roman(level), "}\n"))
		}
	}
	p := dt.parent(t.doc, n)
	if has_class(t.doc, p, "system-messages") {
		t.requirements["color"] = preamble_cmd("color")
		o(t, cat("\\", name, "[", latex_encode(t, astext(t.doc, n)), "]{\\color{red}"))
	} else {
		o(t, cat("\\", name, "{"))
	}
	bookmark := make([dynamic]string, 0, 4, context.temp_allocator)
	append(&bookmark, "")
	append(&bookmark, ..ids_to_labels(t, p, set_anchor = false))
	close := cat(strings.join(bookmark[:], "%\n  ", context.temp_allocator), "%\n}\n")
	if unsupported && !legacy do close = cat(close, "\\end{DUclass}\n")
	ctx_push(t, close)
}

latex_depart_title :: proc(t: ^Latex, n: dt.Node) {
	o(t, ctx_pop_str(t))
	if parent_is(t.doc, n, {.table, .document}) do pop_collector(t)
}

@(private = "file")
minitoc_name :: proc(t: ^Latex, n: dt.Node) -> (string, bool) {
	switch section_name(&t.d_class, t.section_level) {
	case "part":
		return "part", true
	case "chapter":
		return "mini", true
	case "section":
		if !has_chapter(&t.d_class) do return "sect", true
	}
	return "", false
}

@(private = "file")
visit_contents :: proc(t: ^Latex, n: dt.Node) -> Visit {
	doc := t.doc
	local := has_class(doc, n, "local")
	mtc_name: string
	if t.s.use_latex_toc && local {
		ok: bool
		mtc_name, ok = minitoc_name(t, n)
		if !ok do return .Skip_Node
	}
	o(t, "\n")
	if len(dt.attr_list(doc, n, dt.K_NAMES)) > 1 do put_labels(t, n, newline = true)
	first := dt.first_child(doc, n)
	titled := first != 0 && dt.tag(doc, first) == .title
	if titled && !local && t.s.documentclass != "memoir" {
		ids := list_strings(doc, n, dt.K_IDS)
		if len(ids) == 0 {
			t.err = "IndexError: list index out of range"
			return .Skip_Node
		}
		o(t, cat("\\pdfbookmark[", int_str(t.section_level + 1), "]{", astext(doc, first), "}{",
			ids[0], "}\n"))
	}
	if !t.s.use_latex_toc {
		t.fallbacks["toc-list"] = preamble_cmd("toc_list")
		duclass_open(t, n)
		return .Continue
	}
	depth := 0
	if p := dt.next_node(doc, n, dt.Tag_Set{.pending}); p != 0 {
		if v, ok := dt.get_detail(doc, p, "depth"); ok {
			if d, is_int := v.(int); is_int do depth = d
		}
	}
	title := latex_encode(t, astext(doc, first)) if titled else ""
	if local {
		local_latex_toc(t, mtc_name, depth, title)
	} else {
		if depth != 0 {
			tocdepth := int_str(latex_section_depth(&t.d_class, depth))
			o(t, cat("\\setcounter{tocdepth}{", tocdepth, "}\n"))
		}
		if title != "Contents" do o(t, cat("\\renewcommand{\\contentsname}{", title, "}\n"))
		o(t, "\\tableofcontents\n")
		t.has_latex_toc = true
	}
	return .Skip_Node
}

@(private = "file")
local_latex_toc :: proc(t: ^Latex, mtc_name: string, depth: int, title: string) {
	maxdepth := len(t.d_class.sections)
	t.requirements["minitoc"] = preamble_cmd("minitoc")
	t.requirements[cat("minitoc-", mtc_name)] = cat("\\do", mtc_name, "toc")
	t.requirements[cat("minitoc-", mtc_name, "-depth")] = cat(
		"\\mtcsetdepth{", mtc_name, "toc}{", int_str(maxdepth), "}")
	offset := 0
	switch mtc_name {
	case "sect":
		offset = 1
	case "part":
		if has_chapter(&t.d_class) do offset = -1
	}
	if depth != 0 {
		o(t, cat("\\setcounter{", mtc_name, "tocdepth}{", int_str(depth + offset), "}"))
	}
	o(t, cat("\\mtcsettitle{", mtc_name, "toc}{", title, "}\n"))
	o(t, cat("\\", mtc_name, "toc\n"))
}

latex_visit_topic :: proc(t: ^Latex, n: dt.Node) -> Visit {
	doc := t.doc
	if has_class(doc, n, "contents") do return visit_contents(t, n)
	abstract := has_class(doc, n, "abstract")
	if abstract && t.s.use_latex_abstract {
		push_collector(t, &t.abstract)
		o(t, "\\begin{abstract}")
		first := dt.first_child(doc, n)
		if first != 0 && dt.tag(doc, first) == .title do dt.pop_child(doc, n, 0)
		return .Continue
	}
	switch {
	case abstract:
		provide_fallback(t, "abstract")
		if t.s.legacy_class_functions do t.fallbacks["abstract"] = preamble_cmd("abstract_legacy")
		push_collector(t, &t.abstract)
	case has_class(doc, n, "dedication"):
		provide_fallback(t, "dedication")
		push_collector(t, &t.dedication)
	case:
		classes := list_strings(doc, n, dt.K_CLASSES)
		all := make([]string, len(classes) + 1, context.temp_allocator)
		all[0] = "topic"
		copy(all[1:], classes)
		dt.set_list(doc, n, dt.K_CLASSES, ..all)
	}
	return latex_visit_block_quote(t, n)
}

latex_depart_topic :: proc(t: ^Latex, n: dt.Node) {
	doc := t.doc
	abstract := has_class(doc, n, "abstract")
	switch {
	case abstract && t.s.use_latex_abstract:
		o(t, "\\end{abstract}\n")
	case has_class(doc, n, "contents"):
		duclass_close(t, n)
	case:
		latex_depart_block_quote(t, n)
	}
	if abstract || has_class(doc, n, "dedication") do pop_collector(t)
}

// ``format % arg`` of a format with one "%s" (and "%%" escapes).
percent_s :: proc(format, arg: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(format); i += 1 {
		if format[i] == '%' && i + 1 < len(format) {
			switch format[i + 1] {
			case '%':
				strings.write_byte(&b, '%')
				i += 1
				continue
			case 's':
				strings.write_string(&b, arg)
				i += 1
				continue
			}
		}
		strings.write_byte(&b, format[i])
	}
	return strings.to_string(b)
}
