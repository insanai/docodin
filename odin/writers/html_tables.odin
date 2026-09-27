package writers

import "core:strings"

import dt "../doctree"

// HTML5 visitors of tables (``_html_base_tables.TableTranslatorMixin``).

// ``colspec.propwidth()``: the proportional column width; ``ok`` is false
// where docutils raises ``ValueError``.
propwidth :: proc(doc: ^dt.Doc, colspec: dt.Node) -> (Num, bool) {
	v, _ := dt.get_attr(doc, colspec, "colwidth")
	value: Num
	switch x in v {
	case int:
		value = x
	case string:
		if x == "" || x == "*" {
			value = 1
		} else if n, _, ok := parse_measure(x, .Star); ok {
			value = n
		} else {
			value = -1
		}
	case bool, dt.List, dt.Attr_None:
		value = -1
	case:
		value = 1
	}
	return value, as_f64(value) > 0
}

html_visit_colspec :: proc(t: ^Html, n: dt.Node) -> Visit {
	append(&t.colspecs, n)
	stubs := &t.stubs[dt.parent(t.doc, n)]
	if stubs^ == nil do stubs^ = make([dynamic]bool, 0, 8, context.temp_allocator)
	v, ok := dt.get_attr(t.doc, n, "stub")
	append(stubs, ok && attr_truthy(t.doc, v))
	return .Continue
}

html_depart_colspec :: proc(t: ^Html, n: dt.Node) {
	doc := t.doc
	if dt.is(doc, dt.next_sibling(doc, n), {.colspec}) do return
	table := dt.parent(doc, dt.parent(doc, n))
	if has_class(doc, table, "colwidths-auto") do return
	grid := strings.contains(t.s.table_style_text, "colwidths-grid")
	if !grid && !has_class(doc, table, "colwidths-given") do return
	starttag(t, n, "colgroup")
	total: Num = 0
	widths := make([]Num, len(t.colspecs), context.temp_allocator)
	for c, i in t.colspecs {
		width, ok := propwidth(doc, c)
		if !ok {
			t.err = "ValueError: no proportional measure"
			return
		}
		widths[i] = width
		total = num_add(total, width)
	}
	for c, i in t.colspecs {
		pct := as_f64(widths[i]) / as_f64(total) * 100
		style := cat("width: ", float_f(pct, 1), "%")
		emptytag(t, c, "col", atts = {{"style", style}})
	}
	put(&t.body, "</colgroup>\n")
}

// ``a + b`` of Python numbers.
num_add :: proc(a, b: Num) -> Num {
	ai, a_int := a.(int)
	bi, b_int := b.(int)
	if a_int && b_int do return ai + bi
	return as_f64(a) + as_f64(b)
}

html_visit_entry :: proc(t: ^Html, n: dt.Node) -> Visit {
	doc := t.doc
	row := dt.parent(doc, n)
	classes := make([dynamic]string, 0, 2, context.temp_allocator)
	if dt.tag(doc, dt.parent(doc, row)) == .thead do append(&classes, "head")
	stubs := t.stubs[dt.parent(doc, dt.parent(doc, row))]
	column := t.row_column[row]
	if column >= len(stubs) {
		t.err = "IndexError: list index out of range"
		return .Skip_Node
	}
	if stubs[column] do append(&classes, "stub")
	tag := "th" if len(classes) > 0 else "td"
	t.row_column[row] = column + 1
	atts := make([dynamic]Att, 0, 2, context.temp_allocator)
	if rows, ok := dt.get_attr(doc, n, "morerows"); ok {
		append(&atts, Att{"rowspan", int_str(dt.get_int(doc, n, "morerows") + 1)})
		_ = rows
	}
	if has(doc, n, "morecols") {
		cols := dt.get_int(doc, n, "morecols")
		append(&atts, Att{"colspan", int_str(cols + 1)})
		t.row_column[row] += cols
	}
	starttag(t, n, tag, "", classes = classes[:], atts = atts[:])
	push_ctx(t, "</th>\n" if tag == "th" else "</td>\n")
	return .Continue
}

html_visit_row :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "tr", "")
	t.row_column[n] = 0
	return .Continue
}

html_visit_table :: proc(t: ^Html, n: dt.Node) -> Visit {
	doc := t.doc
	style_text, _ := strings.replace_all(t.s.table_style_text, ",", " ", context.temp_allocator)
	classes := make([dynamic]string, 0, 4, context.temp_allocator)
	rest := style_text
	for c in strings.fields_iterator(&rest) do append(&classes, c)
	if v, ok := dt.get_attr(doc, n, "align"); ok {
		append(&classes, cat("align-", attr_text(doc, v)))
	}
	atts: []Att
	if v, ok := dt.get_attr(doc, n, "width"); ok {
		width := attr_text(doc, v)
		if width == "" || strings.index_byte("0123456789.", width[len(width) - 1]) >= 0 {
			width = cat(width, "px")
		}
		atts = one_att("style", cat("width: ", width, ";"))
	}
	starttag(t, n, "table", classes = classes[:], atts = atts)
	return .Continue
}

html_depart_table :: proc(t: ^Html, n: dt.Node) {
	put(&t.body, "</table>\n")
	report_messages(t, n)
}

html_visit_tgroup :: proc(t: ^Html, n: dt.Node) -> Visit {
	clear(&t.colspecs)
	t.stubs[n] = make([dynamic]bool, 0, 8, context.temp_allocator)
	return .Continue
}

// A start tag with the given name and a closing tag in the depart method
// (tbody, thead).
html_visit_tbody :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "tbody")
	return .Continue
}

html_visit_thead :: proc(t: ^Html, n: dt.Node) -> Visit {
	starttag(t, n, "thead")
	return .Continue
}
