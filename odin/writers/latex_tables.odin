package writers

import "core:slice"
import "core:strings"

import dt "../doctree"

// Tables of the LaTeX writer (``latex2e._tables.Table`` and the table
// visitor methods).

Table :: struct {
	latex_type:           string, // "longtable" or "tabular"
	legacy_column_widths: bool,
	is_open:              bool,
	col_specs:            [dynamic]dt.Node,
	caption:              Out,
	align:                string, // ``_attrs["align"]``
	has_align:            bool,
	preamble_written:     bool,
	stubs:                [dynamic]bool,
	colwidths_auto:       bool,
	colwidths:            [dynamic]f64,
	rowspan:              [dynamic]int,
	in_thead:             int,
	cell_in_row:          int,
	borders:              string,
}

new_table :: proc(latex_type: string) -> ^Table {
	t := new(Table, context.temp_allocator)
	t.latex_type = latex_type
	table_close(t)
	t.colwidths = make([dynamic]f64, context.temp_allocator)
	t.rowspan = make([dynamic]int, context.temp_allocator)
	return t
}

@(private = "file")
table_open :: proc(t: ^Table) {
	t.is_open = true
	t.col_specs = make([dynamic]dt.Node, context.temp_allocator)
	t.caption = out_make(context.temp_allocator, 64)
	t.has_align = false
	t.preamble_written = false
}

@(private = "file")
table_close :: proc(t: ^Table) {
	t.is_open = false
	t.col_specs = make([dynamic]dt.Node, context.temp_allocator)
	t.caption = out_make(context.temp_allocator, 64)
	t.has_align = false
	t.preamble_written = false
	t.stubs = make([dynamic]bool, context.temp_allocator)
	t.colwidths_auto = false
}

@(private = "file")
set_table_style :: proc(tr: ^Latex, t: ^Table, n: dt.Node) {
	doc := tr.doc
	t.legacy_column_widths = tr.legacy_column_widths
	if has(doc, n, "align") {
		t.align = attr_str(doc, n, "align")
		t.has_align = true
	}
	t.borders = "standard"
	style := tr.s.table_style
	classes := list_strings(doc, n, dt.K_CLASSES)
	for list in ([][]string{style, classes}) {
		for cls in list {
			switch cls {
			case "standard", "booktabs", "borderless":
				t.borders = cls
			case "nolines":
				t.borders = "borderless"
			}
		}
	}
	auto := slice.contains(classes, "colwidths-auto") || slice.contains(style, "colwidths-auto")
	t.colwidths_auto = auto && !slice.contains(classes, "colwidths-given") && !has(doc, n, "width")
}

@(private = "file")
latex_type :: proc(t: ^Table) -> string {
	if t.latex_type == "longtable" && chunks(&t.caption) == 0 do return "longtable*"
	return t.latex_type
}

@(private = "file")
vertical_bar :: proc(t: ^Table) -> string {
	return "|" if t.borders == "standard" else ""
}

@(private = "file")
table_opening :: proc(t: ^Table, width: string) -> string {
	lines := make([dynamic]string, 0, 3, context.temp_allocator)
	align: string
	if t.has_align {
		switch t.align {
		case "left":
			align = "[l]"
		case "center":
			align = "[c]"
		case "right":
			align = "[r]"
		case:
			align = "None"
		}
	}
	type := latex_type(t)
	if align != "" && !strings.has_prefix(type, "longtable") {
		append(&lines, cat("\\noindent\\makebox[\\linewidth]", align, "{%"))
		align = ""
	}
	if !t.colwidths_auto {
		if t.borders == "standard" && !t.legacy_column_widths {
			n := int_str(len(t.col_specs) + 1)
			dimexpr := cat("\\dimexpr", width, "-", n, "\\arrayrulewidth\\relax")
			append(&lines, cat("\\setlength{\\DUtablewidth}{", dimexpr, "}%"))
		} else {
			append(&lines, cat("\\setlength{\\DUtablewidth}{", width, "}%"))
		}
	}
	append(&lines, cat("\\begin{", type, "}", align))
	return strings.join(lines[:], "\n", context.temp_allocator)
}

@(private = "file")
table_closing :: proc(t: ^Table) -> string {
	lines := make([dynamic]string, 0, 3, context.temp_allocator)
	if t.borders == "booktabs" do append(&lines, "\\bottomrule")
	type := latex_type(t)
	append(&lines, cat("\\end{", type, "}"))
	if t.has_align && t.align != "" && !strings.has_prefix(type, "longtable") {
		append(&lines, "}")
	}
	return strings.join(lines[:], "\n", context.temp_allocator)
}

// ``colspec.latex_propwidth()``.
latex_propwidth :: proc(doc: ^dt.Doc, n: dt.Node) -> f64 {
	v, _ := dt.get_attr(doc, n, "colwidth")
	#partial switch x in v {
	case int:
		return f64(x)
	case string:
		if x == "" || x == "*" do return 1
		num, _, ok := parse_measure(x, .Star)
		if ok do return as_f64(num)
	}
	return 1
}

@(private = "file")
colspecs_text :: proc(tr: ^Latex, t: ^Table, n: dt.Node) -> string {
	bar := vertical_bar(t)
	resize(&t.rowspan, len(t.col_specs))
	slice.zero(t.rowspan[:])
	specs := make([dynamic]string, 0, len(t.col_specs), context.temp_allocator)
	clear(&t.colwidths)
	switch {
	case t.colwidths_auto:
		for _ in t.col_specs do append(&specs, "l")
	case t.legacy_column_widths:
		legacy_colspecs(tr.doc, t, &specs)
	case:
		new_colspecs(tr.doc, t, n, &specs)
	}
	return cat(bar, strings.join(specs[:], bar, context.temp_allocator), bar)
}

@(private = "file")
legacy_colspecs :: proc(doc: ^dt.Doc, t: ^Table, specs: ^[dynamic]string) {
	width := 80.0
	factor := 0.93
	total := 0.0
	for c in t.col_specs do total += latex_propwidth(doc, c) + 1
	if total > width do factor *= width / total
	for c in t.col_specs {
		w := (factor * (latex_propwidth(doc, c) + 1) / width) + 0.005
		append(&t.colwidths, w)
		append(specs, cat("p{", float_f(w, 3), "\\DUtablewidth}"))
	}
}

@(private = "file")
new_colspecs :: proc(doc: ^dt.Doc, t: ^Table, n: dt.Node, specs: ^[dynamic]string) {
	table := dt.parent(doc, dt.parent(doc, n))
	allowance := 0.0 if has_class(doc, table, "colwidths-given") else 1.0
	total := 0.0
	for c in t.col_specs {
		w := (latex_propwidth(doc, c) + allowance) / 40
		append(&t.colwidths, w)
		total += w
	}
	if total > 1 || has(doc, table, "width") {
		for &w in t.colwidths do w = w / total
	}
	for w in t.colwidths do append(specs, cat("p{\\DUcolumnwidth{", float_f(w, 3), "}}"))
}

@(private = "file")
column_width :: proc(t: ^Table) -> string {
	if t.cell_in_row < 0 || t.cell_in_row >= len(t.colwidths) do return "*"
	w := t.colwidths[t.cell_in_row]
	if t.legacy_column_widths do return cat(float_f(w, 2), "\\DUtablewidth")
	return cat("\\DUcolumnwidth{", float_f(w, 2), "}")
}

@(private = "file")
multicolumn_width :: proc(t: ^Table, start, count: int) -> string {
	if start < 0 || start + count > len(t.colwidths) do return "l"
	sum := 0.0
	for i in 0 ..< count do sum += t.colwidths[start + i]
	if t.legacy_column_widths do return cat("p{", float_f(sum, 2), "\\DUtablewidth}")
	return cat("p{\\DUcolumnwidth{", float_f(sum, 3), "}}")
}

@(private = "file")
get_rowspan :: proc(t: ^Table, cell: int) -> int {
	if cell < 0 || cell >= len(t.rowspan) do return 0
	return t.rowspan[cell]
}

// --- visitors ------------------------------------------------------------------------------

latex_visit_colspec :: proc(t: ^Latex, n: dt.Node) -> Visit {
	append(&t.active_table.col_specs, n)
	v, _ := dt.get_attr(t.doc, n, "stub")
	append(&t.active_table.stubs, attr_truthy(t.doc, v))
	return .Continue
}

// Column delimiters for cells spanned from rows above.
@(private = "file")
insert_additional_delimiters :: proc(t: ^Latex) {
	tab := t.active_table
	for get_rowspan(tab, tab.cell_in_row) != 0 {
		o(t, " & ")
		tab.cell_in_row += 1
	}
}

latex_visit_entry :: proc(t: ^Latex, n: dt.Node) -> Visit {
	tab := t.active_table
	if tab.cell_in_row == 0 {
		insert_additional_delimiters(t)
	} else {
		o(t, " & ")
	}
	doc := t.doc
	if has(doc, n, "morerows") && has(doc, n, "morecols") {
		t.err = "NotImplementedError: Cells that span multiple rows *and* columns " +
			"currently not supported by the LaTeX writer"
		return .Skip_Node
	}
	open_spanning_cell(t, n)
	bold := entry_is_bold(t, n)
	if t.err != "" do return .Skip_Node
	if bold {
		o(t, "\\textbf{")
		ctx_push(t, "}")
	} else {
		ctx_push(t, "")
	}
	if !tab.colwidths_auto && strings.has_suffix(last(t.out), "{") && astext(doc, n) != "" {
		o(t, "%")
	}
	tab.cell_in_row += 1
	return .Continue
}

// Bold header or stub-column cell (``is_stub_column`` indexes ``stubs``
// with the cell number, an IndexError if it equals their number).
@(private = "file")
entry_is_bold :: proc(t: ^Latex, n: dt.Node) -> bool {
	doc := t.doc
	tab := t.active_table
	if dt.first_child(doc, n) == 0 do return false
	if dt.tag(doc, dt.parent(doc, dt.parent(doc, n))) == .thead do return true
	switch {
	case len(tab.stubs) > tab.cell_in_row:
		return tab.stubs[tab.cell_in_row]
	case len(tab.stubs) == tab.cell_in_row:
		t.err = "IndexError: list index out of range"
	}
	return false
}

@(private = "file")
open_spanning_cell :: proc(t: ^Latex, n: dt.Node) {
	tab := t.active_table
	doc := t.doc
	switch {
	case has(doc, n, "morerows"):
		t.requirements["multirow"] = "\\usepackage{multirow}"
		mrows := dt.get_int(doc, n, "morerows") + 1
		if tab.cell_in_row < len(tab.rowspan) do tab.rowspan[tab.cell_in_row] = mrows
		o(t, cat("\\multirow{", int_str(mrows), "}{", column_width(tab), "}{"))
		ctx_push(t, "}")
	case has(doc, n, "morecols"):
		bar1 := vertical_bar(tab) if tab.cell_in_row == 0 else ""
		mcols := dt.get_int(doc, n, "morecols") + 1
		width := multicolumn_width(tab, tab.cell_in_row, mcols)
		o(t, cat("\\multicolumn{", int_str(mcols), "}{", bar1, width, vertical_bar(tab), "}{"))
		ctx_push(t, "}")
	case:
		ctx_push(t, "")
	}
}

latex_depart_entry :: proc(t: ^Latex, n: dt.Node) {
	o(t, ctx_pop_str(t))
	o(t, ctx_pop_str(t))
	insert_additional_delimiters(t)
}

latex_visit_row :: proc(t: ^Latex, n: dt.Node) -> Visit {
	t.active_table.cell_in_row = 0
	return .Continue
}

latex_depart_row :: proc(t: ^Latex, n: dt.Node) {
	tab := t.active_table
	o(t, " \\\\\n")
	tab.cell_in_row = -1
	for &r in tab.rowspan do if r > 0 do r -= 1
	if tab.borders != "standard" do return
	b := strings.builder_make(context.temp_allocator)
	count := 0
	for r, i in tab.rowspan {
		if r > 0 do continue
		count += 1
		strings.write_string(&b, "\\cline{")
		strings.write_int(&b, i + 1)
		strings.write_byte(&b, '-')
		strings.write_int(&b, i + 1)
		strings.write_string(&b, "}\n")
	}
	o(t, "\\hline\n" if count == len(tab.rowspan) else strings.to_string(b))
}

latex_visit_table :: proc(t: ^Latex, n: dt.Node) -> Visit {
	t.requirements["table"] = preamble_cmd("table")
	if !t.legacy_column_widths do t.requirements["table1"] = preamble_cmd("table_columnwidth")
	if t.active_table.is_open {
		append(&t.table_stack, t.active_table)
		t.active_table = new_table("tabular")
	}
	doc := t.doc
	p := dt.parent(doc, n)
	if t.active_table.latex_type == "longtable" && dt.tag(doc, p) == .section &&
	   dt.index_identity(doc, p, n) == 1 &&
	   strings.contains(section_name(&t.d_class, t.section_level), "paragraph") {
		o(t, "\\leavevmode")
	}
	table_open(t.active_table)
	set_table_style(t, t.active_table, n)
	if t.active_table.borders == "booktabs" {
		t.requirements["booktabs"] = "\\usepackage{booktabs}"
	}
	push_new_collector(t)
	return .Continue
}

latex_depart_table :: proc(t: ^Latex, n: dt.Node) {
	content := pop_collector(t)
	width := "\\linewidth"
	if has(t.doc, n, "width") {
		ok: bool
		width, ok = to_latex_length(t, attr(t.doc, n, "width"), n)
		if !ok do return
	}
	tab := t.active_table
	if chunks(&tab.caption) == 0 {
		put_labels(t, n, set_anchor = len(t.table_stack) != 1, pre_nl = true)
	}
	duclass_open(t, n)
	o(t, table_opening(tab, width))
	put_out(t.out, content)
	o(t, cat(table_closing(tab), "\n"))
	table_close(tab)
	if len(t.table_stack) > 0 do t.active_table = pop(&t.table_stack)
	duclass_close(t, n)
}

latex_visit_tbody :: proc(t: ^Latex, n: dt.Node) -> Visit {
	if !t.active_table.preamble_written {
		latex_visit_thead(t, n)
		t.thead_depth -= 1
	}
	return .Continue
}

latex_visit_thead :: proc(t: ^Latex, n: dt.Node) -> Visit {
	tab := t.active_table
	t.thead_depth += 1
	if t.thead_depth == 1 {
		o(t, cat("{", colspecs_text(t, tab, n), "}\n"))
		tab.preamble_written = true
	}
	if chunks(&tab.caption) > 0 {
		if t.thead_depth == 1 {
			o(t, "\\caption{")
			put_out(t.out, &tab.caption)
			put_labels(t, dt.parent(t.doc, dt.parent(t.doc, n)), set_anchor = false)
			o(t, "}\\\\")
		} else {
			o(t, "\\caption[]{")
			put_out(t.out, &tab.caption)
			o(t, " (... continued)}\\\\")
		}
		o(t, "\n")
	}
	tab.in_thead += 1
	switch tab.borders {
	case "standard":
		o(t, "\\hline\n")
	case "booktabs":
		o(t, "\\toprule\n")
	}
	return .Continue
}

latex_depart_thead :: proc(t: ^Latex, n: dt.Node) {
	tab := t.active_table
	if tab.borders == "booktabs" do o(t, "\\midrule\n")
	if tab.latex_type == "longtable" {
		if t.thead_depth == 1 {
			o(t, "\\endfirsthead\n")
		} else {
			longtable_continuation(t, tab)
		}
	}
	tab.in_thead -= 1
	if tab.latex_type == "longtable" && t.thead_depth == 1 {
		walkabout(t, &latex_dispatch, n)
	}
	t.thead_depth -= 1
}

@(private = "file")
longtable_continuation :: proc(t: ^Latex, tab: ^Table) {
	o(t, "\\endhead\n")
	n_c := len(tab.col_specs)
	width := 0.0
	for c in tab.col_specs do width += latex_propwidth(t.doc, c) + 2
	if width > 30 || (width > 12 && !tab.colwidths_auto) {
		mw := multicolumn_width(tab, 0, n_c)
		cont := "}{\\raggedleft\\ldots continued on next page}\\\\\n"
		o(t, cat("\\multicolumn{", int_str(n_c), "}{", mw, cont))
	}
	o(t, "\\endfoot\n\\endlastfoot\n")
}
