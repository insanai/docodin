package reader

import "core:strings"

import dt "../doctree"

// The table directives (``directives.tables``): ``table`` (reST table
// content), ``csv-table`` (content or file; URLs are not fetched) and
// ``list-table``.

@(private = "file")
TABLE_ALIGN := [?]string{"left", "center", "right"}
@(private = "file")
AUTO_GRID := [?]string{"auto", "grid"}
@(private = "file")
AUTO := [?]string{"auto"}

@(private = "file")
table_align :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	return choice(c, argument, TABLE_ALIGN[:])
}

@(private = "file")
widths_auto_grid :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	return widths_option(c, argument, AUTO_GRID[:])
}

@(private = "file")
widths_auto :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	return widths_option(c, argument, AUTO[:])
}

@(private = "file")
TABLE_OPTIONS := [?]Option_Spec {
	{"class", class_option},
	{"name", unchanged},
	{"align", table_align},
	{"width", length_or_percentage_or_unitless},
	{"widths", widths_auto_grid},
}

@(private = "file")
CSV_OPTIONS := [?]Option_Spec {
	{"header-rows", nonnegative_int},
	{"stub-columns", nonnegative_int},
	{"header", unchanged},
	{"width", length_or_percentage_or_unitless},
	{"widths", widths_auto},
	{"file", path},
	{"url", uri},
	{"encoding", encoding},
	{"class", class_option},
	{"name", unchanged},
	{"align", table_align},
	{"delim", single_char_or_whitespace_or_unicode},
	{"keepspace", flag},
	{"quote", single_char_or_unicode},
	{"escape", single_char_or_unicode},
}

@(private = "file")
LIST_TABLE_OPTIONS := [?]Option_Spec {
	{"header-rows", nonnegative_int},
	{"stub-columns", nonnegative_int},
	{"width", length_or_percentage_or_unitless},
	{"widths", widths_auto},
	{"class", class_option},
	{"name", unchanged},
	{"align", table_align},
}

RST_TABLE := Directive_Spec {
	optional_arguments        = 1,
	final_argument_whitespace = true,
	option_spec               = TABLE_OPTIONS[:],
	has_content               = true,
	run                       = run_rst_table,
}

CSV_TABLE := Directive_Spec {
	optional_arguments        = 1,
	final_argument_whitespace = true,
	option_spec               = CSV_OPTIONS[:],
	has_content               = true,
	run                       = run_csv_table,
}

LIST_TABLE := Directive_Spec {
	optional_arguments        = 1,
	final_argument_whitespace = true,
	option_spec               = LIST_TABLE_OPTIONS[:],
	has_content               = true,
	run                       = run_list_table,
}

// --- Table base class ---------------------------------------------------------------

// An error with the directive block (``SystemMessagePropagation``).
@(private = "file")
table_error :: proc(c: ^Context, d: ^Directive, level: dt.Level, parts: ..string) -> dt.Node {
	lit := dt.new_element(c.doc, .literal_block, d.block_text, d.block_text)
	text := strings.concatenate(parts, c.allocator)
	return dt.system_message(c.doc, level, text, {children = {lit}, line = d.lineno})
}

// ``Table.make_title``.
@(private = "file")
make_title :: proc(c: ^Context, d: ^Directive) -> (title: dt.Node, messages: [dynamic]dt.Node) {
	if len(d.arguments) == 0 do return 0, nil
	title_text := d.arguments[0]
	text_nodes, msgs := d_inline_text(c, d, title_text, d.lineno)
	title = element(c, .title, title_text, text_nodes[:])
	d_set_source_line(c, d, title, d.lineno)
	return title, msgs
}

// ``Table.check_table_dimensions``: the error, if any.
@(private = "file")
check_table_dimensions :: proc(
	c: ^Context,
	d: ^Directive,
	row_lengths: []int,
	header_rows,
	stub_columns: int,
) -> dt.Node {
	n := len(row_lengths)
	if n < header_rows {
		return table_error(
			c, d, .ERROR, itoa(header_rows), " header row(s) specified but only ", itoa(n),
			" row(s) of data supplied (\"", d.name, "\" directive).",
		)
	}
	if n == header_rows && header_rows > 0 {
		return table_error(
			c, d, .ERROR, "Insufficient data supplied (", itoa(n), " row(s)); no data remaining ",
			"for table body, required by \"", d.name, "\" directive.",
		)
	}
	for cols in row_lengths {
		if cols < stub_columns {
			return table_error(
				c, d, .ERROR, itoa(stub_columns), " stub column(s) specified but only ",
				itoa(cols),
				" columns(s) of data supplied (\"", d.name, "\" directive).",
			)
		}
		if cols == stub_columns && stub_columns > 0 {
			return table_error(
				c, d, .ERROR, "Insufficient data supplied (", itoa(cols), " columns(s)); no data ",
				"remaining for table body, required by \"", d.name, "\" directive.",
			)
		}
	}
	return 0
}

// ``Table.get_column_widths``: the widths, or the error.
@(private = "file")
get_column_widths :: proc(c: ^Context, d: ^Directive, n_cols: int) -> ([]int, dt.Node) {
	if widths, is_list := options_widths(d).([]int); is_list {
		if len(widths) != n_cols {
			return nil, table_error(
				c, d, .ERROR, "\"", d.name,
				"\" widths do not match the number of columns in table (",
				itoa(n_cols), ").",
			)
		}
		return widths, 0
	}
	if n_cols == 0 do return nil, table_error(c, d, .ERROR, "No table data detected in CSV file.")
	out := make([]int, n_cols, c.allocator)
	for &w in out do w = 100 / n_cols
	return out, 0
}

// ``self.widths``: ``options.get('widths', '')``.
@(private = "file")
options_widths :: proc(d: ^Directive) -> Option_Value {
	v, ok := options_get(&d.options, "widths")
	return v if ok else ""
}

// The classes for the "widths" option (``colwidths-auto``/``-given``).
@(private = "file")
add_widths_class :: proc(c: ^Context, d: ^Directive, table: dt.Node) {
	switch w in options_widths(d) {
	case string:
		if w == "auto" do dt.list_append(c.doc, table, dt.K_CLASSES, "colwidths-auto")
		else if w != "" do dt.list_append(c.doc, table, dt.K_CLASSES, "colwidths-given")
	case []int:
		dt.list_append(c.doc, table, dt.K_CLASSES, "colwidths-given")
	case int, []string, Opt_None:
	}
}

// The "class", "align" and "width" options, the name and the title.
@(private = "file")
finish_table :: proc(c: ^Context, d: ^Directive, table: dt.Node, title: dt.Node) {
	doc := c.doc
	set_align(c, d, table)
	for cl in options_list(&d.options, "class") do dt.list_append(doc, table, dt.K_CLASSES, cl)
	set_width(c, d, table)
	add_name(c, d, table)
	if title != 0 do dt.insert_child(doc, table, 0, title)
}

@(private = "file")
set_width :: proc(c: ^Context, d: ^Directive, table: dt.Node) {
	if v, ok := options_get(&d.options, "width"); ok {
		dt.set_attr(c.doc, table, "width", v.(string) or_else "")
	}
}

// --- table --------------------------------------------------------------------------

@(private = "file")
run_rst_table :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	doc := c.doc
	if sl_len(d.content) == 0 {
		msg := table_error(
			c, d, .WARNING, "Content block expected for the \"", d.name,
			"\" directive; none found.",
		)
		return result_of(c, msg), nil
	}
	title, messages := make_title(c, d)
	node := dt.new_element(doc, .Element) // anonymous container for parsing
	d_nested_parse(c, d, node)
	table := dt.first_child(doc, node)
	if dt.child_count(doc, node) != 1 || !dt.is(doc, table, {.table}) {
		msg := table_error(
			c, d, .ERROR, "Error parsing content block for the \"", d.name,
			"\" directive: exactly one table expected.",
		)
		return result_of(c, msg), nil
	}
	for cl in options_list(&d.options, "class") do dt.list_append(doc, table, dt.K_CLASSES, cl)
	set_width(c, d, table)
	set_align(c, d, table)
	if err := set_colspec_widths(c, d, table); err != 0 do return result_of(c, err), nil
	add_widths_class(c, d, table)
	add_name(c, d, table)
	if title != 0 do dt.insert_child(doc, table, 0, title)
	out := result_of(c, table)
	append(&out, ..messages[:])
	return out, nil
}

// The "align" option.
@(private = "file")
set_align :: proc(c: ^Context, d: ^Directive, table: dt.Node) {
	if v, ok := options_get(&d.options, "align"); ok {
		dt.set_attr(c.doc, table, "align", v.(string) or_else "")
	}
}

// A list of "widths" becomes the ``colwidth`` of the table's colspecs.
@(private = "file")
set_colspec_widths :: proc(c: ^Context, d: ^Directive, table: dt.Node) -> dt.Node {
	doc := c.doc
	if _, is_list := options_widths(d).([]int); !is_list do return 0
	tgroup := dt.first_child(doc, table)
	widths, err := get_column_widths(c, d, dt.get_int(doc, tgroup, "cols"))
	if err != 0 do return err
	k := 0
	for ch in dt.children(doc, tgroup, c.allocator) {
		if k >= len(widths) do break
		if dt.tag(doc, ch) != .colspec do continue
		dt.set_attr(doc, ch, "colwidth", widths[k])
		k += 1
	}
	return 0
}

// --- list-table ---------------------------------------------------------------------

@(private = "file")
run_list_table :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	doc := c.doc
	if sl_len(d.content) == 0 {
		msg := table_error(
			c, d, .ERROR, "The \"", d.name, "\" directive is empty; content required.",
		)
		return result_of(c, msg), nil
	}
	title, messages := make_title(c, d)
	node := dt.new_element(doc, .Element) // anonymous container for parsing
	d_nested_parse(c, d, node)
	widths, rows, err := check_list_content(c, d, node)
	if err != 0 do return result_of(c, err), nil
	header_rows := options_int(d, "header-rows")
	stub_columns := options_int(d, "stub-columns")
	lengths := make([]int, len(rows), c.allocator)
	for r, i in rows do lengths[i] = dt.child_count(doc, r)
	if msg := check_table_dimensions(c, d, lengths, header_rows, stub_columns); msg != 0 {
		return result_of(c, msg), nil
	}
	table := table_from_list(c, d, rows, widths, header_rows, stub_columns)
	finish_table(c, d, table, title)
	out := result_of(c, table)
	append(&out, ..messages[:])
	return out, nil
}

// An int option, 0 if missing.
@(private = "file")
options_int :: proc(d: ^Directive, name: string) -> int {
	v, _ := options_get(&d.options, name)
	return v.(int) or_else 0
}

// ``ListTable.check_list_content``: the column widths and the rows (the
// second-level bullet lists), or the error.
@(private = "file")
check_list_content :: proc(
	c: ^Context,
	d: ^Directive,
	node: dt.Node,
) -> (widths: []int, rows: []dt.Node, err: dt.Node) {
	doc := c.doc
	list := dt.first_child(doc, node)
	if dt.child_count(doc, node) != 1 || !dt.is(doc, list, {.bullet_list}) {
		err = table_error(
			c, d, .ERROR, "Error parsing content block for the \"", d.name,
			"\" directive: exactly one bullet list expected.",
		)
		return
	}
	row_lists := make([dynamic]dt.Node, c.allocator)
	num_cols := 0
	for item, index in dt.children(doc, list, c.allocator) {
		sub := dt.first_child(doc, item)
		if dt.child_count(doc, item) != 1 || !dt.is(doc, sub, {.bullet_list}) {
			err = table_error(
				c, d, .ERROR, "Error parsing content block for the \"", d.name,
				"\" directive: two-level bullet list expected, but row ", itoa(index + 1),
				" does not contain a second-level bullet list.",
			)
			return
		}
		cols := dt.child_count(doc, sub)
		if index > 0 && cols != num_cols {
			err = table_error(
				c, d, .ERROR, "Error parsing content block for the \"", d.name,
				"\" directive: uniform two-level bullet list expected, but row ", itoa(index + 1),
				" does not contain the same number of items as row 1 (", itoa(cols), " vs ",
				itoa(num_cols), ").",
			)
			return
		}
		if index == 0 do num_cols = cols
		append(&row_lists, sub)
	}
	widths, err = get_column_widths(c, d, num_cols)
	return widths, row_lists[:], err
}

// ``ListTable.build_table_from_list``.
@(private = "file")
table_from_list :: proc(
	c: ^Context,
	d: ^Directive,
	rows: []dt.Node,
	widths: []int,
	header_rows,
	stub_columns_in: int,
) -> dt.Node {
	doc := c.doc
	stub_columns := stub_columns_in
	table := dt.new_element(doc, .table)
	add_widths_class(c, d, table)
	tgroup := dt.new_element(doc, .tgroup)
	dt.set_attr(doc, tgroup, "cols", len(widths))
	dt.append_child(doc, table, tgroup)
	for w in widths {
		colspec := dt.new_element(doc, .colspec)
		dt.set_attr(doc, colspec, "colwidth", w)
		if stub_columns > 0 {
			dt.set_attr(doc, colspec, "stub", true)
			stub_columns -= 1
		}
		dt.append_child(doc, tgroup, colspec)
	}
	row_nodes := make([dynamic]dt.Node, c.allocator)
	for r in rows {
		row := dt.new_element(doc, .row)
		for item in dt.children(doc, r, c.allocator) {
			entry := element(c, .entry, "", dt.children(doc, item, c.allocator))
			dt.append_child(doc, row, entry)
		}
		append(&row_nodes, row)
	}
	if header_rows > 0 {
		thead := element(c, .thead, "", row_nodes[:header_rows])
		dt.append_child(doc, tgroup, thead)
	}
	dt.append_child(doc, tgroup, element(c, .tbody, "", row_nodes[header_rows:]))
	return table
}

// --- csv-table ---------------------------------------------------------------------

// A cell of ``Body.build_table`` data (``(morerows, morecols, offset, block)``).
@(private = "file")
Csv_Cell :: struct {
	lines:  []string,
	source: string,
}

@(private = "file")
run_csv_table :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	has_file := options_has(&d.options, "file")
	has_url := options_has(&d.options, "url")
	if !c.doc.settings.file_insertion_enabled && (has_file || has_url) {
		msg := table_error(
			c,
			d,
			.WARNING,
			"File and URL access deactivated; ignoring \"",
			d.name,
			"\" directive.",
		)
		return result_of(c, msg), nil
	}
	title, messages := make_title(c, d)
	head, body, widths, err := csv_table_data(c, d)
	if err != 0 do return result_of(c, err), nil
	table := build_table(c, d, widths, head, body, options_int(d, "stub-columns"))
	finish_table(c, d, table, title)
	out := result_of(c, table)
	append(&out, ..messages[:])
	return out, nil
}

// The header and body rows and the column widths of a CSV table, or the error.
@(private = "file")
csv_table_data :: proc(
	c: ^Context,
	d: ^Directive,
) -> (head, body: [][]Csv_Cell, widths: []int, err: dt.Node) {
	source: string
	line_list: []string
	line_list, source, err = csv_data(c, d)
	if err != 0 do return
	dialect := csv_dialect(d)
	head_rows: [][]Csv_Cell
	max_header_cols: int
	head_rows, max_header_cols, err = csv_header(c, d, dialect)
	if err != 0 do return
	rows: [][]Csv_Cell
	max_cols: int
	rows, max_cols, err = parse_csv_rows(c, d, line_list, dialect, source)
	if err != 0 do return
	max_cols = max(max_cols, max_header_cols)
	header_rows := options_int(d, "header-rows")
	lengths := make([]int, len(rows), c.allocator)
	for r, i in rows do lengths[i] = len(r)
	stub_columns := options_int(d, "stub-columns")
	if msg := check_table_dimensions(c, d, lengths, header_rows, stub_columns); msg != 0 {
		return nil, nil, nil, msg
	}
	all_head := make([dynamic][]Csv_Cell, c.allocator)
	append(&all_head, ..head_rows)
	append(&all_head, ..rows[:header_rows])
	widths, err = get_column_widths(c, d, max_cols)
	if err != 0 do return
	head = extend_short_rows(c, all_head[:], max_cols)
	body = extend_short_rows(c, rows[header_rows:], max_cols)
	return
}

@(private = "file")
extend_short_rows :: proc(c: ^Context, rows: [][]Csv_Cell, columns: int) -> [][]Csv_Cell {
	out := make([][]Csv_Cell, len(rows), c.allocator)
	for r, i in rows {
		if len(r) >= columns {
			out[i] = r
			continue
		}
		row := make([]Csv_Cell, columns, c.allocator)
		copy(row, r)
		out[i] = row
	}
	return out
}

// ``CSVTable.DocutilsDialect``.
@(private = "file")
csv_dialect :: proc(d: ^Directive) -> Csv_Dialect {
	dialect := Csv_Dialect {
		delimiter        = ',',
		quotechar        = '"',
		doublequote      = true,
		skipinitialspace = true,
	}
	first_rune :: proc(s: string) -> rune {
		for r in s do return r
		return 0
	}
	if v, ok := options_get(&d.options, "delim"); ok {
		dialect.delimiter = first_rune(v.(string) or_else ",")
	}
	if options_has(&d.options, "keepspace") do dialect.skipinitialspace = false
	if v, ok := options_get(&d.options, "quote"); ok {
		dialect.quotechar = first_rune(v.(string) or_else "\"")
	}
	if v, ok := options_get(&d.options, "escape"); ok {
		dialect.doublequote = false
		dialect.escapechar = first_rune(v.(string) or_else "")
	}
	return dialect
}

// ``CSVTable.get_csv_data``: the lines and their source, or the error.
@(private = "file")
csv_data :: proc(c: ^Context, d: ^Directive) -> (lines: []string, source: string, err: dt.Node) {
	has_file := options_has(&d.options, "file")
	has_url := options_has(&d.options, "url")
	switch {
	case sl_len(d.content) > 0:
		if has_file || has_url {
			err = table_error(
				c, d, .ERROR, "\"", d.name,
				"\" directive may not both specify an external file and have content.",
			)
			return
		}
		return d.content.data[:], d.content.items[0].source, 0
	case has_file:
		if has_url {
			err = table_error(
				c, d, .ERROR, "The \"file\" and \"url\" options may not be simultaneously ",
				"specified for the \"", d.name, "\" directive.",
			)
			return
		}
		source = adapt_path(c, options_string(&d.options, "file"), c.doc.settings.root_prefix)
		text, failure := read_file(c, d, source)
		if e, failed := failure.?; failed {
			detail := strings.trim_prefix(
				e.msg, concat("Problems with \"", d.name, "\" directive path:\nInputError: "),
			)
			err = table_error(
				c, d, .SEVERE, "Problems with \"", d.name, "\" directive path:\n", detail,
			)
			return
		}
		return dt.py_splitlines(text, allocator = c.allocator), source, 0
	case has_url:
		url := options_string(&d.options, "url")
		text, class, fetch_err := read_url(c, d, url)
		if class != "" {
			err = table_error(
				c, d, .SEVERE, "Problems with \"", d.name, "\" directive URL \"", url, "\":\n",
				fetch_err, ".",
			)
			return
		}
		return dt.py_splitlines(text, allocator = c.allocator), url, 0
	}
	err = table_error(
		c, d, .WARNING, "The \"", d.name, "\" directive requires content; none supplied.",
	)
	return
}

// ``CSVTable.process_header_option``.
@(private = "file")
csv_header :: proc(
	c: ^Context,
	d: ^Directive,
	dialect: Csv_Dialect,
) -> (rows: [][]Csv_Cell, max_cols: int, err: dt.Node) {
	header, ok := options_get(&d.options, "header")
	if !ok do return nil, 0, 0
	// ``state_machine.get_source(lineno - 1)``
	info, _, _ := sl_info(input_lines(c, d.sm), d.lineno - 1 - d.sm.input_offset)
	lines := strings.split(header.(string) or_else "", "\n", c.allocator)
	return parse_csv_rows(c, d, lines, dialect, info.source)
}

// ``CSVTable.parse_csv_data_into_rows``.
@(private = "file")
parse_csv_rows :: proc(
	c: ^Context,
	d: ^Directive,
	lines: []string,
	dialect: Csv_Dialect,
	source: string,
) -> (rows: [][]Csv_Cell, max_cols: int, err: dt.Node) {
	records, csv_err := csv_read(lines, dialect, c.allocator)
	if csv_err != "" {
		err = table_error(
			c, d, .ERROR, "Error with CSV data in \"", d.name, "\" directive:\n", csv_err,
		)
		return
	}
	out := make([][]Csv_Cell, len(records), c.allocator)
	for fields, i in records {
		row := make([]Csv_Cell, len(fields), c.allocator)
		for f, k in fields do row[k] = {dt.py_splitlines(f, allocator = c.allocator), source}
		out[i] = row
		max_cols = max(max_cols, len(fields))
	}
	return out, max_cols, 0
}

// ``Body.build_table`` for CSV data: the cells are parsed at the content
// offset, numbered from their own first line.
@(private = "file")
build_table :: proc(
	c: ^Context,
	d: ^Directive,
	widths: []int,
	head, body: [][]Csv_Cell,
	stub_columns_in: int,
) -> dt.Node {
	doc := c.doc
	stub_columns := stub_columns_in
	table := dt.new_element(doc, .table)
	add_widths_class(c, d, table)
	tgroup := dt.new_element(doc, .tgroup)
	dt.set_attr(doc, tgroup, "cols", len(widths))
	dt.append_child(doc, table, tgroup)
	for w in widths {
		colspec := dt.new_element(doc, .colspec)
		dt.set_attr(doc, colspec, "colwidth", w)
		if stub_columns > 0 {
			dt.set_attr(doc, colspec, "stub", true)
			stub_columns -= 1
		}
		dt.append_child(doc, tgroup, colspec)
	}
	if len(head) > 0 {
		thead := dt.new_element(doc, .thead)
		dt.append_child(doc, tgroup, thead)
		for r in head do dt.append_child(doc, thead, csv_row(c, d, r))
	}
	tbody := dt.new_element(doc, .tbody)
	dt.append_child(doc, tgroup, tbody)
	for r in body do dt.append_child(doc, tbody, csv_row(c, d, r))
	return table
}

// ``Body.build_table_row``.
@(private = "file")
csv_row :: proc(c: ^Context, d: ^Directive, cells: []Csv_Cell) -> dt.Node {
	doc := c.doc
	row := dt.new_element(doc, .row)
	for cell in cells {
		entry := dt.new_element(doc, .entry)
		dt.append_child(doc, row, entry)
		if strings.concatenate(cell.lines, c.allocator) == "" do continue
		block := sl_make(cell.lines, cell.source, c.allocator)
		nested_parse(c, d.sm, block, d.content_offset, entry)
	}
	return row
}
