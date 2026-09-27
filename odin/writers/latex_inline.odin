package writers

import "core:slice"
import "core:strings"

import dt "../doctree"
import texmath "../math"

// Auxiliary methods of the LaTeX translator and the visitors of inline
// elements (``latex2e._translator`` and ``_visit_body``).

// ``ids_to_labels``: label definitions for all ids of ``n``.
ids_to_labels :: proc(
	t: ^Latex,
	n: dt.Node,
	set_anchor := true,
	protect := false,
	newline := false,
	pre_nl := false,
) -> []string {
	ids := list_strings(t.doc, n, dt.K_IDS)
	if len(ids) == 0 do return nil
	out := make([dynamic]string, 0, len(ids) + 3, context.temp_allocator)
	if pre_nl do append(&out, "\n")
	if set_anchor do append(&out, "\\phantomsection")
	prefix := "\\protect" if protect else ""
	for id in ids do append(&out, cat(prefix, "\\label{", id, "}"))
	if newline do append(&out, "\n")
	return out[:]
}

// ``self.out += self.ids_to_labels(...)``.
put_labels :: proc(
	t: ^Latex,
	n: dt.Node,
	set_anchor := true,
	protect := false,
	newline := false,
	pre_nl := false,
) {
	for l in ids_to_labels(t, n, set_anchor, protect, newline, pre_nl) do o(t, l)
}

// Hypertargets for all ids of ``n`` (one chunk).
append_hypertargets :: proc(t: ^Latex, n: dt.Node) {
	begin(t.out)
	for id, i in list_strings(t.doc, n, dt.K_IDS) {
		if i > 0 do w(t.out, "%\n")
		w(t.out, cat("\\raisebox{1em}{\\hypertarget{", id, "}{}}"))
	}
}

provide_fallback :: proc(t: ^Latex, feature: string, key := "") {
	if t.fallback_stylesheet do return
	t.fallbacks[key if key != "" else feature] = preamble_cmd(feature)
}

is_inline :: proc(t: ^Latex, n: dt.Node) -> bool {
	return in_text_element(t.doc, n)
}

@(private = "file")
is_table_style_class :: proc(t: ^Latex, n: dt.Node, cls: string) -> bool {
	if dt.tag(t.doc, n) != .table do return false
	switch cls {
	case "booktabs", "borderless", "colwidths-auto", "nolines", "standard", "colwidths-given":
		return true
	}
	return false
}

// Open a group and insert declarations for class values.
duclass_open :: proc(t: ^Latex, n: dt.Node) {
	if !parent_is(t.doc, n, {.compound}) do o(t, "\n")
	for cls in list_strings(t.doc, n, dt.K_CLASSES) {
		switch {
		case strings.has_prefix(cls, "language-"):
			if lang := babel_language_name(&t.babel, cls[9:]); lang != "" {
				t.babel.otherlanguages[lang] = true
				o(t, cat("\\begin{selectlanguage}{", lang, "}\n"))
			}
		case is_table_style_class(t, n, cls):
		case:
			provide_fallback(t, "duclass", "DUclass")
			o(t, cat("\\begin{DUclass}{", cls, "}\n"))
		}
	}
}

duclass_close :: proc(t: ^Latex, n: dt.Node) {
	classes := list_strings(t.doc, n, dt.K_CLASSES)
	#reverse for cls in classes {
		switch {
		case strings.has_prefix(cls, "language-"):
			if babel_language_name(&t.babel, cls[9:]) != "" do o(t, "\\end{selectlanguage}\n")
		case is_table_style_class(t, n, cls):
		case:
			provide_fallback(t, "duclass", "DUclass")
			o(t, "\\end{DUclass}\n")
		}
	}
}

// ``term_postfix``: LaTeX code between a term or field name and content.
term_postfix :: proc(t: ^Latex, n: dt.Node) -> string {
	doc := t.doc
	child: dt.Node
	for c := dt.first_child(doc, n); c != 0; c = dt.next_sibling(doc, c) {
		if !dt.is_a(doc, c, .Invisible) && !dt.is(doc, c, {.footnote, .citation}) {
			child = c
			break
		}
	}
	if child == 0 do return ""
	#partial switch dt.tag(doc, child) {
	case .container, .compound:
		return term_postfix(t, child)
	case .image:
		return "\\leavevmode\n"
	case .paragraph, .math_block:
		return ""
	}
	return "\\leavevmode"
}

// ``to_latex_length``: a LaTeX length for a measure.
to_latex_length :: proc(t: ^Latex, length: string, n: dt.Node) -> (string, bool) {
	value, unit, ok := parse_measure(length)
	if !ok {
		t.err = cat("ValueError: \"", length, "\" is no valid measure.")
		return "", false
	}
	res: string
	switch unit {
	case "em", "ex", "cm", "mm", "in", "pc", "px", "bp", "cc", "dd", "sp", "mu":
		res = length
	case "", "pt":
		res = cat(num_str(value), "bp")
	case "Q":
		res = cat(num_str(as_f64(value) / 4), "mm")
	case "%":
		res = cat(float_g(as_f64(value) / 100), "\\linewidth")
	case "vw":
		res = cat(float_g(as_f64(value) / 100), "\\paperwidth")
	case "vh":
		res = cat(float_g(as_f64(value) / 100), "\\paperheight")
	case:
		if _, known := preamble_lookup(unit); !known {
			msg := cat("Unit \"", unit, "\" not supported by LaTeX.\n",
				"  Define lenght \"\\DU", unit, "dimen\" in preamble,",
				" raw LaTeX, or custom stylesheet.")
			dt.warning(t.doc, msg, {base_node = n})
		} else {
			if unit == "ch" {
				t.fallbacks["ch"] = preamble_cmd("ch")
			} else {
				provide_fallback(t, "providelength", "_providelength")
				provide_fallback(t, unit)
			}
		}
		res = cat(num_str(value), "\\DU", unit, "dimen")
	}
	if t.is_xetex && strings.has_suffix(res, "px") {
		if !t.fallback_stylesheet do t.fallbacks["_providelength"] = preamble_cmd("providelength")
		t.fallbacks["px"] = "\n\\DUprovidelength{\\pdfpxdimen}{1bp}"
		res, _ = strings.replace_all(res, "px", "\\pdfpxdimen", context.temp_allocator)
	}
	return res, true
}

// Convert ``align-*`` class arguments into an "align" attribute.
set_align_from_classes :: proc(t: ^Latex, n: dt.Node) {
	doc := t.doc
	classes := list_strings(doc, n, dt.K_CLASSES)
	align := ""
	rest := make([dynamic]string, 0, len(classes), context.temp_allocator)
	for cls in classes {
		if strings.has_prefix(cls, "align-") {
			align = cls[6:]
		} else {
			append(&rest, cls)
		}
	}
	if len(rest) == len(classes) do return
	dt.set_attr(doc, n, "align", align)
	dt.set_list(doc, n, dt.K_CLASSES, ..rest[:])
}

insert_align_declaration :: proc(t: ^Latex, n: dt.Node) {
	switch attr(t.doc, n, "align") {
	case "left":
		o(t, "\\raggedright\n")
	case "center":
		o(t, "\\centering\n")
	case "right":
		o(t, "\\raggedleft\n")
	}
}

// ``visit_inline``: labels and class wrappers (also used by other inline
// elements, <caption> and <paragraph>).
latex_visit_inline :: proc(t: ^Latex, n: dt.Node) -> Visit {
	doc := t.doc
	anchor := dt.Tag_Set{.caption, .subtitle, .title}
	set_anchor := !(parent_is(doc, n, anchor) || dt.is(doc, n, anchor))
	put_labels(t, n, set_anchor = set_anchor, newline = dt.tag(doc, n) == .paragraph)
	for cls in list_strings(doc, n, dt.K_CLASSES) {
		if strings.has_prefix(cls, "language-") {
			if lang := babel_language_name(&t.babel, cls[9:]); lang != "" {
				t.babel.otherlanguages[lang] = true
				o(t, cat("\\foreignlanguage{", lang, "}{"))
			}
		} else {
			provide_fallback(t, "inline")
			o(t, cat("\\DUrole{", cls, "}{"))
		}
	}
	return .Continue
}

latex_depart_inline :: proc(t: ^Latex, n: dt.Node) {
	o(t, strings.repeat("}", len(dt.attr_list(t.doc, n, dt.K_CLASSES)), context.temp_allocator))
}

// Insert a class value at the front (``node["classes"].insert(0, cls)``).
insert_class :: proc(doc: ^dt.Doc, n: dt.Node, cls: string) {
	classes := list_strings(doc, n, dt.K_CLASSES)
	all := make([]string, len(classes) + 1, context.temp_allocator)
	all[0] = cls
	copy(all[1:], classes)
	dt.set_list(doc, n, dt.K_CLASSES, ..all)
}

latex_visit_text :: proc(t: ^Latex, n: dt.Node) -> Visit {
	o(t, latex_encode(t, astext(t.doc, n)))
	return .Continue
}

latex_visit_abbreviation :: proc(t: ^Latex, n: dt.Node) -> Visit {
	insert_class(t.doc, n, dt.tagname(t.doc, n))
	return latex_visit_inline(t, n)
}

// An inline element wrapped in a command: ``\cmd{`` + inline + ``}``.
@(private = "file")
Wrapped :: struct {
	open, close: string,
}

@(private = "file")
WRAPPED := #partial [dt.Tag]Wrapped {
	.superscript = {"\\textsuperscript{", "}"},
	.subscript = {"\\textsubscript{", "}"},
	.caption = {"\\caption{", "}\n"},
	.emphasis = {"\\emph{", "}"},
	.strong = {"\\textbf{", "}"},
	.title_reference = {"\\DUroletitlereference{", "}"},
}

latex_visit_wrapped :: proc(t: ^Latex, n: dt.Node) -> Visit {
	tag := dt.tag(t.doc, n)
	if tag == .title_reference do provide_fallback(t, "titlereference")
	o(t, WRAPPED[tag].open)
	return latex_visit_inline(t, n)
}

latex_depart_wrapped :: proc(t: ^Latex, n: dt.Node) {
	latex_depart_inline(t, n)
	o(t, WRAPPED[dt.tag(t.doc, n)].close)
}

latex_visit_citation_reference :: proc(t: ^Latex, n: dt.Node) -> Visit {
	doc := t.doc
	if len(t.s.use_bibtex) > 0 do append(&t.bibitems, Bibitem{label = astext(doc, n)})
	if t.use_latex_citations {
		if !t.inside_citation_reference_label {
			o(t, "\\cite{")
			t.inside_citation_reference_label = true
		} else {
			l := last(t.out)
			if l != " " && l != "\n" {
				t.err = "AssertionError: unexpected non-whitespace while in reference label"
				return .Skip_Node
			}
			truncate(t.out, chunks(t.out) - 1)
		}
		return .Continue
	}
	href := ""
	if has(doc, n, "refid") {
		href = attr(doc, n, "refid")
	} else if has(doc, n, "refname") {
		ok: bool
		href, ok = nameid(doc, attr(doc, n, "refname"))
		if !ok {
			t.err = "KeyError: nameids"
			return .Skip_Node
		}
	}
	o(t, cat("\\hyperlink{", href, "}{["))
	return .Continue
}

latex_depart_citation_reference :: proc(t: ^Latex, n: dt.Node) {
	if !t.use_latex_citations {
		o(t, "]}")
		return
	}
	doc := t.doc
	followup := false
	sib := dt.next_sibling(doc, n)
	if sib != 0 && dt.tag(doc, sib) == .Text {
		text := astext(doc, sib)
		sib2 := dt.next_sibling(doc, sib)
		followup = (text == " " || text == "\n") && dt.is(doc, sib2, {.citation_reference})
	}
	if followup {
		o(t, ",")
	} else {
		o(t, "}")
		t.inside_citation_reference_label = false
	}
}

latex_visit_footnote_reference :: proc(t: ^Latex, n: dt.Node) -> Visit {
	doc := t.doc
	href := ""
	if has(doc, n, "refid") {
		href = attr(doc, n, "refid")
	} else if has(doc, n, "refname") {
		ok: bool
		href, ok = nameid(doc, attr(doc, n, "refname"))
		if !ok {
			t.err = "KeyError: nameids"
			return .Skip_Node
		}
	}
	if t.s.footnote_references == "brackets" {
		append_hypertargets(t, n)
		o(t, cat("\\hyperlink{", href, "}{["))
		ctx_push(t, "]}")
		return .Continue
	}
	provide_fallback(t, "footnotes")
	ids := list_strings(doc, n, dt.K_IDS)
	if len(ids) == 0 {
		t.err = "IndexError: list index out of range"
		return .Skip_Node
	}
	o(t, cat("\\DUfootnotemark{", ids[0], "}{", href, "}{"))
	ctx_push(t, "}")
	return .Continue
}

latex_depart_context :: proc(t: ^Latex, n: dt.Node) {
	o(t, ctx_pop_str(t))
}

latex_visit_literal :: proc(t: ^Latex, n: dt.Node) -> Visit {
	t.literal = true
	if has_class(t.doc, n, "code") && t.s.syntax_highlight != "none" {
		t.requirements["color"] = preamble_cmd("color")
		provide_fallback(t, "highlight_rules", "code")
	}
	o(t, "\\texttt{")
	return latex_visit_inline(t, n)
}

latex_depart_literal :: proc(t: ^Latex, n: dt.Node) {
	t.literal = false
	latex_depart_inline(t, n)
	o(t, "}")
}

latex_visit_math :: proc(t: ^Latex, n: dt.Node) -> Visit {
	t.requirements["amsmath"] = "\\usepackage{amsmath}"
	latex_visit_inline(t, n)
	code := texmath.uni2tex_translate(astext(t.doc, n), context.temp_allocator)
	if t.alltt {
		put_all(t.out, "\\(", code, "\\)")
	} else {
		put_all(t.out, "$", code, "$")
	}
	latex_depart_inline(t, n)
	return .Skip_Node
}

latex_visit_problematic :: proc(t: ^Latex, n: dt.Node) -> Visit {
	t.requirements["color"] = preamble_cmd("color")
	o(t, "%\n")
	append_hypertargets(t, n)
	if !has(t.doc, n, "refid") {
		t.err = "KeyError: 'refid'"
		return .Skip_Node
	}
	o(t, cat("\\hyperlink{", attr(t.doc, n, "refid"), "}{\\textbf{\\color{red}"))
	return .Continue
}

latex_depart_problematic :: proc(t: ^Latex, n: dt.Node) {
	o(t, "}}")
}

latex_visit_raw :: proc(t: ^Latex, n: dt.Node) -> Visit {
	if !format_has(attr(t.doc, n, "format"), "latex") do return .Skip_Node
	if !(is_inline(t, n) || parent_is(t.doc, n, {.compound})) do o(t, "\n")
	latex_visit_inline(t, n)
	t.verbatim = true
	return .Continue
}

latex_depart_raw :: proc(t: ^Latex, n: dt.Node) {
	t.verbatim = false
	latex_depart_inline(t, n)
	if !is_inline(t, n) do o(t, "\n")
}

@(private = "file")
has_unbalanced_braces :: proc(s: string) -> bool {
	level := 0
	for c in transmute([]u8)s {
		if c == '{' do level += 1
		if c == '}' do level -= 1
		if level < 0 do return true
	}
	return level != 0
}

latex_visit_reference :: proc(t: ^Latex, n: dt.Node) -> Visit {
	doc := t.doc
	if !is_inline(t, n) do o(t, "\n")
	if has(doc, n, "refuri") {
		refuri := attr_str(doc, n, "refuri")
		b := strings.builder_make(context.temp_allocator)
		for c in transmute([]u8)refuri {
			switch c {
			case '#':
				strings.write_string(&b, "\\#")
			case '%':
				strings.write_string(&b, "\\%")
			case '\\':
				strings.write_string(&b, "\\\\")
			case:
				strings.write_byte(&b, c)
			}
		}
		href := strings.to_string(b)
		if strings.contains(href, "^^") || has_unbalanced_braces(href) {
			msg := cat("External link \"", href, "\" not supported by LaTeX.\n",
				" (Must not contain \"^^\" or unbalanced braces.)")
			dt.error(doc, msg)
		}
		if refuri == astext(doc, n) {
			o(t, cat("\\url{", href, "}"))
			return .Skip_Node
		}
		o(t, cat("\\href{", href, "}{"))
		return .Continue
	}
	href: string
	switch {
	case has(doc, n, "refid"):
		href = attr(doc, n, "refid")
	case has(doc, n, "refname"):
		ok: bool
		href, ok = nameid(doc, attr(doc, n, "refname"))
		if !ok {
			t.err = "KeyError: nameids"
			return .Skip_Node
		}
	case:
		t.err = "AssertionError: Unknown reference."
		return .Skip_Node
	}
	if t.s.reference_label != "" {
		plain, _ := strings.remove_all(href, "#", context.temp_allocator)
		o(t, cat("\\", t.s.reference_label, "{", plain, "}"))
		return .Skip_Node
	}
	o(t, cat("\\hyperref[", href, "]{"))
	return .Continue
}

latex_depart_reference :: proc(t: ^Latex, n: dt.Node) {
	o(t, "}")
	if !is_inline(t, n) do o(t, "\n")
}

latex_visit_target :: proc(t: ^Latex, n: dt.Node) -> Visit {
	doc := t.doc
	if has(doc, n, "refuri") || has(doc, n, "refid") || has(doc, n, "refname") do return .Continue
	if is_inline(t, n) do o(t, "%")
	o(t, "\n")
	return latex_visit_inline(t, n)
}

latex_visit_image :: proc(t: ^Latex, n: dt.Node) -> Visit {
	doc := t.doc
	t.requirements["graphicx"] = t.graphicx_package
	imagepath, err := uri2path(attr(doc, n, "uri"), "", t.s.root_prefix)
	if err != "" {
		t.err = cat("ValueError: ", err)
		return .Skip_Node
	}
	p := dt.parent(doc, n)
	if !has(doc, n, "align") {
		if dt.tag(doc, p) == .figure ||
		   (dt.tag(doc, p) == .reference && parent_is(doc, p, {.figure})) {
			dt.set_attr(doc, n, "align", "center")
		}
		set_align_from_classes(t, n)
	}
	pre := make([dynamic]string, 0, 4, context.temp_allocator)
	post := make([dynamic]string, 0, 2, context.temp_allocator)
	if dt.tag(doc, p) == .reference do append(&pre, pop_chunk(t.out))
	if has(doc, n, "align") {
		if code, ok := image_align_code(attr_str(doc, n, "align")); ok {
			append(&pre, code[0])
			append(&post, code[1])
		}
	}
	options, ok := include_graphics_options(t, n)
	if !ok do return .Skip_Node
	append(&pre, strings.concatenate(ids_to_labels(t, n, newline = true), context.temp_allocator))
	if !(is_inline(t, n) || dt.tag(doc, p) == .compound) do append(&pre, "\n")
	if !is_inline(t, n) do append(&post, "\n")
	#reverse for s in pre do o(t, s)
	cmd := "includegraphics"
	if path_suffix(imagepath) == ".svg" && stylesheet_has_svg(t.s) do cmd = "includesvg"
	o(t, cat("\\", cmd, options, "{", imagepath, "}"))
	for s in post do o(t, s)
	return .Continue
}

// ``"svg" in settings.stylesheet`` (a list, or a string).
@(private = "file")
stylesheet_has_svg :: proc(s: ^Settings) -> bool {
	if text, ok := s.stylesheet_text.?; ok do return strings.contains(text, "svg")
	return slice.contains(s.stylesheet, "svg")
}

@(private = "file")
image_align_code :: proc(align: string) -> ([2]string, bool) {
	switch align {
	case "bottom":
		return {"", ""}, true
	case "middle":
		return {"\\raisebox{-0.5\\height}{", "}"}, true
	case "top":
		return {"\\raisebox{-\\height}{", "}"}, true
	case "center":
		return {"\\noindent\\makebox[\\linewidth][c]{", "}"}, true
	case "left":
		return {"\\noindent{", "\\hfill}"}, true
	case "right":
		return {"\\noindent{\\hfill", "}"}, true
	}
	return {}, false
}

@(private = "file")
include_graphics_options :: proc(t: ^Latex, n: dt.Node) -> (res: string, ok: bool) {
	doc := t.doc
	options := make([dynamic]string, 0, 3, context.temp_allocator)
	if has(doc, n, "height") {
		l := to_latex_length(t, attr_str(doc, n, "height"), n) or_return
		append(&options, cat("height=", l))
	}
	if has(doc, n, "scale") {
		v, _ := dt.get_attr(doc, n, "scale")
		scale: f64
		#partial switch x in v {
		case int:
			scale = f64(x)
		case string:
			num, _, _ := parse_measure(x)
			scale = as_f64(num)
		}
		append(&options, cat("scale=", float_g(scale / 100)))
	}
	if has(doc, n, "width") {
		l := to_latex_length(t, attr_str(doc, n, "width"), n) or_return
		append(&options, cat("width=", l))
	}
	if len(options) == 0 do return "", true
	return cat("[", strings.join(options[:], ",", context.temp_allocator), "]"), true
}

// ``str(node[key])``.
attr_str :: proc(doc: ^dt.Doc, n: dt.Node, key: string) -> string {
	v, _ := dt.get_attr(doc, n, key)
	return attr_text(doc, v)
}
