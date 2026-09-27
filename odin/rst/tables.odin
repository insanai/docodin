package rst

import "base:runtime"
import "core:slice"
import "core:strings"

// Grid and simple tables: ports of docutils ``Body.table*``/``isolate_*`` and
// ``tableparser.GridTableParser``/``SimpleTableParser``.  Table text is
// processed as code points (``[]rune``); East Asian wide characters are padded
// with a NUL (docutils ``pad_double_width``) so that columns line up.

PAD :: rune(0)

Table_Kind :: enum u8 {Grid, Simple}

Table_Error :: struct {
	message: string,
	offset:  int,
}

Cell :: struct {
	morerows, morecols: int,
	offset:             int, // line offset of the cell content in the table
	lines:              []string,
	used:               bool,
}

Table_Data :: struct {
	colwidths: []int,
	head_rows: [][]Cell,
	body_rows: [][]Cell,
}

// --- helpers --------------------------------------------------------------------

@(private = "file")
to_runes :: proc(s: string, pad: bool, allocator: runtime.Allocator) -> []rune {
	out := make([dynamic]rune, 0, len(s) + 4, allocator)
	for r in s {
		append(&out, r)
		if pad && is_wide(r) do append(&out, PAD)
	}
	return out[:]
}

@(private = "file")
runes_to_string :: proc(rs: []rune, drop_pad: bool, allocator: runtime.Allocator) -> string {
	b := strings.builder_make_len_cap(0, len(rs), allocator)
	for r in rs {
		if drop_pad && r == PAD do continue
		strings.write_rune(&b, r)
	}
	return strings.to_string(b)
}

@(private = "file")
rune_rstrip :: proc "contextless" (rs: []rune) -> []rune {
	n := len(rs)
	for n > 0 && is_space(rs[n - 1]) do n -= 1
	return rs[:n]
}

@(private = "file")
rune_lstrip :: proc "contextless" (rs: []rune) -> []rune {
	i := 0
	for i < len(rs) && is_space(rs[i]) do i += 1
	return rs[i:]
}

@(private = "file")
rune_strip :: #force_inline proc "contextless" (rs: []rune) -> []rune {
	return rune_rstrip(rune_lstrip(rs))
}

@(private = "file")
strip_combining :: proc(rs: []rune, allocator: runtime.Allocator) -> []rune {
	out := make([dynamic]rune, 0, len(rs), allocator)
	for r in rs do if !is_combining(r) do append(&out, r)
	return out[:]
}

@(private = "file")
rune_at_or :: #force_inline proc "contextless" (rs: []rune, i: int) -> rune {
	return rs[i] if i >= 0 && i < len(rs) else 0
}

// ``StringList.get_2D_block(top, left, bottom, right)`` followed by
// ``replace(pad, '')``.
@(private = "file")
get_2d_block :: proc(block: [][]rune, top, left, bottom, right: int, allocator: runtime.Allocator) -> []string {
	rows := block[top:bottom]
	trimmed := make([][]rune, len(rows), allocator)
	indent := right
	for line, i in rows {
		// column_indices: indices of non-combining characters
		left_i, right_i := -1, -1
		col := 0
		for r, idx in line {
			if is_combining(r) do continue
			if col == left do left_i = idx
			if col == right do right_i = idx
			col += 1
		}
		if left_i < 0 do left_i = left
		if right_i < 0 do right_i = len(line)
		left_i = clamp(left_i, 0, len(line))
		right_i = clamp(right_i, left_i, len(line))
		t := rune_rstrip(line[left_i:right_i])
		trimmed[i] = t
		if len(t) > 0 do indent = min(indent, len(t) - len(rune_lstrip(t)))
	}
	out := make([]string, len(trimmed), allocator)
	for t, i in trimmed {
		t := t
		if 0 < indent && indent < right do t = t[min(indent, len(t)):]
		out[i] = runes_to_string(t, true, allocator)
	}
	return out
}

// ``Body.malformed_table``
@(private = "file")
malformed_table :: proc(sm: ^State_Machine, block: []string, detail: string, offset: int) -> ^Node {
	a := sm.p.allocator
	message := "Malformed table." if detail == "" else concat("Malformed table.\n", detail, allocator = a)
	startline := abs_line_number(sm) - len(block) + 1
	return make_message_block(sm.p, ERROR, message, join_lines(block, a), startline + offset)
}

@(private = "file")
rows_to_strings :: proc(rows: [][]rune, allocator: runtime.Allocator) -> []string {
	out := make([]string, len(rows), allocator)
	for r, i in rows do out[i] = runes_to_string(r, true, allocator)
	return out
}

// --- Body.table -------------------------------------------------------------------

body_table :: proc(sm: ^State_Machine, kind: Table_Kind) {
	a := sm.p.allocator
	top_line := abs_line_number(sm)
	nodes: Node_List
	block: [][]rune
	messages: Node_List
	blank_finish: bool
	switch kind {
	case .Grid:   block, messages, blank_finish = isolate_grid_table(sm)
	case .Simple: block, messages, blank_finish = isolate_simple_table(sm)
	}
	if len(block) > 0 {
		data: Table_Data
		err: Table_Error
		ok: bool
		switch kind {
		case .Grid:   data, err, ok = parse_grid_table(block, a)
		case .Simple: data, err, ok = parse_simple_table(block, a)
		}
		tableline := abs_line_number(sm) - len(block) + 1
		if ok {
			// Cells are nested-parsed with a 1-based offset (one line ahead of
			// the source).  When isolate_grid_table backs up too far (docutils
			// bug), ``tableline`` is lower still; docutils' cell lines come
			// from the source positions of the lines, so the delta absorbs it.
			cell_delta := -1 + (top_line - tableline)
			list_append(&nodes, build_table(sm, data, tableline, cell_delta))
		} else {
			list_append(&nodes, malformed_table(sm, rows_to_strings(block, a), err.message, err.offset))
		}
	}
	// isolation messages are attached with the table, after its cells were parsed
	for m := messages.first; m != nil; m = m.next do m.cur_line = i32(sm.p.cur_line)
	list_extend(&nodes, messages)
	append_chain(sm.parent, nodes.first)
	if !blank_finish {
		append_child(sm.parent, make_message(sm.p, WARNING, "Blank line required after table.", abs_line_number(sm) + 1))
	}
}

@(private = "file")
isolate_grid_table :: proc(sm: ^State_Machine) -> (rows: [][]rune, messages: Node_List, blank_finish: bool) {
	a := sm.p.allocator
	blank_finish = true
	lines, err_line := get_text_block(sm, flush_left = true)
	if err_line > 0 {
		list_append(&messages, make_message(sm.p, ERROR, "Unexpected indentation.", err_line))
		blank_finish = false
	}
	block := make([][]rune, len(lines), a)
	for l, i in lines do block[i] = to_runes(l, true, a)
	if len(block) == 0 do return nil, messages, blank_finish
	width := len(rune_strip(block[0]))
	i_var := 0 // Python's leaking loop variable
	for i in 0 ..< len(block) {
		i_var = i
		block[i] = rune_strip(block[i])
		first := rune_at_or(block[i], 0)
		if first != '+' && first != '|' {
			blank_finish = false
			previous_line(sm, len(block) - i)
			block = block[:i]
			break
		}
	}
	if len(block) == 0 do return nil, messages, blank_finish
	if !match_grid_table_top(runes_to_string(block[len(block) - 1], false, a)) {
		found := false
		for i := len(block) - 2; i > 1; i -= 1 {
			i_var = i
			if match_grid_table_top(runes_to_string(block[i], false, a)) {
				previous_line(sm, len(block) - i + 1)
				block = block[:i + 1]
				blank_finish = false
				found = true
				break
			}
		}
		if !found {
			list_append(&messages, malformed_table(sm, rows_to_strings(block, a), "Bottom border missing or corrupt.", i_var))
			return nil, messages, blank_finish
		}
	}
	for i in 0 ..< len(block) {
		stripped := strip_combining(block[i], a)
		last := rune_at_or(block[i], len(block[i]) - 1)
		if len(stripped) != width || (last != '+' && last != '|') {
			list_append(&messages, malformed_table(sm, rows_to_strings(block, a), "Right border not aligned or missing.", i))
			return nil, messages, blank_finish
		}
	}
	return block, messages, blank_finish
}

@(private = "file")
isolate_simple_table :: proc(sm: ^State_Machine) -> (rows: [][]rune, messages: Node_List, blank_finish: bool) {
	a := sm.p.allocator
	start := sm.line_offset
	lines := sm.lines
	limit := len(lines) - 1
	toplen := cp_len(strip(lines[start]))
	found := 0
	found_at := -1
	end := -1
	i := start + 1
	for i <= limit {
		line := lines[i]
		if match_simple_border(line) {
			if cp_len(strip(line)) != toplen {
				next_line(sm, i - start)
				list_append(&messages, malformed_table(sm, lines[start:i + 1],
					"Bottom border or header rule does not match top border.", i - start))
				return nil, messages, i == limit || len(lines[i + 1]) == 0
			}
			found += 1
			found_at = i
			if found == 2 || i == limit || len(lines[i + 1]) == 0 {
				end = i
				break
			}
		}
		i += 1
	}
	if end < 0 {
		details := "No bottom table border found."
		block: []string
		if found > 0 {
			details = "No bottom table border found or no blank line after table bottom."
			next_line(sm, found_at - start)
			block = lines[start:found_at + 1]
		} else {
			next_line(sm, i - start - 1)
			block = lines[start:]
		}
		list_append(&messages, malformed_table(sm, block, details, 0))
		return nil, messages, found == 0
	}
	next_line(sm, end - start)
	block := make([][]rune, end - start + 1, a)
	for l, k in lines[start:end + 1] do block[k] = to_runes(l, true, a)
	return block, messages, end == limit || len(lines[end + 1]) == 0
}

// ``Body.build_table`` / ``build_table_row``
build_table :: proc(sm: ^State_Machine, data: Table_Data, tableline: int, cell_delta: int) -> ^Node {
	table := make_node(sm, .Table, tableline)
	table.num[0] = i32(cell_delta)
	tgroup := make_node(sm, .TGroup, tableline)
	tgroup.num[0] = i32(len(data.colwidths))
	append_child(table, tgroup)
	for w in data.colwidths {
		cs := make_node(sm, .Colspec, tableline)
		cs.num[0] = i32(w)
		append_child(tgroup, cs)
	}
	if len(data.head_rows) > 0 {
		thead := make_node(sm, .THead, tableline)
		append_child(tgroup, thead)
		for row in data.head_rows do append_child(thead, build_table_row(sm, row, tableline, cell_delta))
	}
	tbody := make_node(sm, .TBody, tableline)
	append_child(tgroup, tbody)
	for row in data.body_rows do append_child(tbody, build_table_row(sm, row, tableline, cell_delta))
	table.cur_line = i32(sm.p.cur_line) // after the cells' nested parses
	return table
}

@(private = "file")
build_table_row :: proc(sm: ^State_Machine, row: []Cell, tableline: int, cell_delta: int) -> ^Node {
	r := make_node(sm, .Row, tableline)
	for cell in row {
		if !cell.used do continue
		entry := make_node(sm, .Entry, tableline + cell.offset)
		entry.num = {i32(cell.morerows), i32(cell.morecols)}
		append_child(r, entry)
		has_text := false
		for l in cell.lines do if len(l) > 0 { has_text = true; break }
		if has_text do nested_parse(sm, cell.lines, tableline + cell.offset, entry, line_delta = cell_delta)
	}
	return r
}

// --- GridTableParser --------------------------------------------------------------

@(private = "file")
Grid :: struct {
	block:         [][]rune,
	stripped:      [][]rune,
	bottom, right: int,
	head_body_sep: int,
	done:          []int,
	cells:         [dynamic]Grid_Cell,
	rowseps:       []bool,
	colseps:       []bool,
	allocator:     runtime.Allocator,
}

@(private = "file")
Grid_Cell :: struct {
	top, left, bottom, right: int,
	lines:                    []string,
}

@(private = "file")
Corner :: [2]int

// ``TableParser.find_head_body_sep`` (shared by both parsers).
@(private = "file")
find_head_body_sep :: proc(block: [][]rune, kind: Table_Kind, allocator: runtime.Allocator) -> (sep: int, err: Table_Error, ok: bool) {
	sep = -1
	i := 0
	for i = 0; i < len(block); i += 1 {
		text := runes_to_string(block[i], false, allocator)
		is_sep := match_grid_head_sep(text) if kind == .Grid else match_simple_border(text)
		if !is_sep do continue
		if sep > 0 {
			return sep, Table_Error{
				strings.concatenate({
					"Multiple head/body row separators (table lines ", int_str(sep + 1, allocator),
					" and ", int_str(i + 1, allocator), "); only one allowed.",
				}, allocator),
				i,
			}, false
		}
		sep = i
		for &r in block[i] do if r == '=' do r = '-'
	}
	if sep == 0 || (sep >= 0 && sep == len(block) - 1) {
		return sep, Table_Error{"The head/body row separator may not be the first or last line of the table.", len(block) - 1}, false
	}
	return sep, {}, true
}

parse_grid_table :: proc(rows: [][]rune, allocator: runtime.Allocator) -> (data: Table_Data, err: Table_Error, ok: bool) {
	g := Grid{allocator = allocator}
	g.block = make([][]rune, len(rows), allocator)
	for r, i in rows {
		g.block[i] = make([]rune, len(r), allocator)
		copy(g.block[i], r)
	}
	g.bottom = len(g.block) - 1
	g.right = len(g.block[0]) - 1
	g.done = make([]int, len(g.block[0]), allocator)
	for &d in g.done do d = -1
	g.rowseps = make([]bool, g.bottom + 1, allocator)
	g.colseps = make([]bool, g.right + 1, allocator)
	g.rowseps[0] = true
	g.colseps[0] = true
	g.cells = make([dynamic]Grid_Cell, 0, 16, allocator)

	sep_ok: bool
	g.head_body_sep, err, sep_ok = find_head_body_sep(g.block, .Grid, allocator)
	if !sep_ok do return {}, err, false

	g.stripped = make([][]rune, len(g.block), allocator)
	for line, i in g.block do g.stripped[i] = strip_combining(line, allocator)

	corners := make([dynamic]Corner, 0, 16, allocator)
	append(&corners, Corner{0, 0})
	for len(corners) > 0 {
		c := corners[0]
		ordered_remove(&corners, 0)
		top, left := c[0], c[1]
		if top == g.bottom || left == g.right || top <= g.done[left] do continue
		bottom, right, found := scan_cell(&g, top, left)
		if !found do continue
		if !mark_done(&g, top, left, bottom, right) {
			return {}, {"Malformed table; parse incomplete.", 0}, false
		}
		lines := get_2d_block(g.block, top + 1, left + 1, bottom, right, allocator)
		append(&g.cells, Grid_Cell{top, left, bottom, right, lines})
		append(&corners, Corner{top, right}, Corner{bottom, left})
		slice.sort_by(corners[:], proc(a, b: Corner) -> bool {
			return a[0] < b[0] || (a[0] == b[0] && a[1] < b[1])
		})
	}
	for col in 0 ..< g.right {
		if g.done[col] != g.bottom - 1 do return {}, {"Malformed table; parse incomplete.", 0}, false
	}
	return grid_structure(&g)
}

@(private = "file")
scan_cell :: proc(g: ^Grid, top, left: int) -> (bottom, right: int, ok: bool) {
	if rune_at_or(g.stripped[top], left) != '+' do return
	// scan_right
	line := g.stripped[top]
	pending_cols := make([dynamic]int, 0, 4, g.allocator)
	for i in left + 1 ..= g.right {
		c := rune_at_or(line, i)
		if c == '+' {
			append(&pending_cols, i)
			if b, rows, cols, found := scan_down(g, top, left, i); found {
				for x in pending_cols do g.colseps[x] = true
				for x in cols do g.colseps[x] = true
				for x in rows do g.rowseps[x] = true
				return b, i, true
			}
		} else if c != '-' {
			return
		}
	}
	return
}

@(private = "file")
scan_down :: proc(g: ^Grid, top, left, right: int) -> (bottom: int, rows: [dynamic]int, cols: [dynamic]int, ok: bool) {
	rows = make([dynamic]int, 0, 4, g.allocator)
	for i in top + 1 ..= g.bottom {
		c := rune_at_or(g.stripped[i], right)
		if c == '+' {
			append(&rows, i)
			if new_rows, new_cols, found := scan_left(g, top, left, i, right); found {
				append(&rows, ..new_rows[:])
				return i, rows, new_cols, true
			}
		} else if c != '|' {
			return
		}
	}
	return
}

@(private = "file")
scan_left :: proc(g: ^Grid, top, left, bottom, right: int) -> (rows: [dynamic]int, cols: [dynamic]int, ok: bool) {
	cols = make([dynamic]int, 0, 4, g.allocator)
	line := g.stripped[bottom]
	for i := right - 1; i > left; i -= 1 {
		c := rune_at_or(line, i)
		if c == '+' {
			append(&cols, i)
		} else if c != '-' {
			return
		}
	}
	if rune_at_or(line, left) != '+' do return
	// scan_up
	rows = make([dynamic]int, 0, 4, g.allocator)
	for i := bottom - 1; i > top; i -= 1 {
		c := rune_at_or(g.stripped[i], left)
		if c == '+' {
			append(&rows, i)
		} else if c != '|' {
			return
		}
	}
	return rows, cols, true
}

@(private = "file")
mark_done :: proc(g: ^Grid, top, left, bottom, right: int) -> bool {
	before, after := top - 1, bottom - 1
	for col in left ..< right {
		if g.done[col] != before do return false
		g.done[col] = after
	}
	return true
}

@(private = "file")
grid_structure :: proc(g: ^Grid) -> (data: Table_Data, err: Table_Error, ok: bool) {
	a := g.allocator
	rowindex := make([]int, g.bottom + 1, a)
	colindex := make([]int, g.right + 1, a)
	nrows, ncols := -1, -1
	rowseps := make([dynamic]int, 0, 8, a)
	colseps := make([dynamic]int, 0, 8, a)
	for present, i in g.rowseps {
		rowindex[i] = -1
		if present {
			nrows += 1
			rowindex[i] = nrows
			append(&rowseps, i)
		}
	}
	for present, i in g.colseps {
		colindex[i] = -1
		if present {
			ncols += 1
			colindex[i] = ncols
			append(&colseps, i)
		}
	}
	// A one-line table (e.g. cut short by unexpected indentation) has no
	// rows or columns; docutils builds an empty table for it.
	nrows, ncols = max(nrows, 0), max(ncols, 0)
	data.colwidths = make([]int, ncols, a)
	for i in 1 ..< len(colseps) do data.colwidths[i - 1] = colseps[i] - colseps[i - 1] - 1
	rows := make([][]Cell, nrows, a)
	for &r in rows do r = make([]Cell, ncols, a)
	remaining := nrows * ncols
	for c in g.cells {
		rownum, colnum := rowindex[c.top], colindex[c.left]
		brow, rcol := rowindex[c.bottom], colindex[c.right]
		if rownum < 0 || colnum < 0 || brow < 0 || rcol < 0 || rownum >= nrows || colnum >= ncols {
			return {}, {"Malformed table; parse incomplete.", 0}, false
		}
		if rows[rownum][colnum].used {
			return {}, {strings.concatenate({"Cell (row ", int_str(rownum + 1, a), ", column ", int_str(colnum + 1, a), ") already used."}, a), 0}, false
		}
		morerows := brow - rownum - 1
		morecols := rcol - colnum - 1
		remaining -= (morerows + 1) * (morecols + 1)
		rows[rownum][colnum] = Cell{morerows, morecols, c.top + 1, c.lines, true}
	}
	if remaining != 0 do return {}, {"Unused cells remaining.", 0}, false
	if g.head_body_sep > 0 {
		numhead := rowindex[g.head_body_sep]
		if numhead < 0 do return {}, {"Malformed table; parse incomplete.", 0}, false
		data.head_rows = rows[:numhead]
		data.body_rows = rows[numhead:]
	} else {
		data.body_rows = rows
	}
	return data, {}, true
}

// --- SimpleTableParser ------------------------------------------------------------

@(private = "file")
Simple :: struct {
	block:         [][]rune,
	head_body_sep: int,
	columns:       [dynamic][2]int,
	border_end:    int,
	table:         [dynamic][]Cell,
	allocator:     runtime.Allocator,
}

parse_simple_table :: proc(rows: [][]rune, allocator: runtime.Allocator) -> (data: Table_Data, err: Table_Error, ok: bool) {
	t := Simple{allocator = allocator}
	t.block = make([][]rune, len(rows), allocator)
	for r, i in rows {
		t.block[i] = make([]rune, len(r), allocator)
		copy(t.block[i], r)
	}
	for &r in t.block[0] do if r == '=' do r = '-'
	for &r in t.block[len(t.block) - 1] do if r == '=' do r = '-'
	t.columns = make([dynamic][2]int, 0, 8, allocator)
	t.table = make([dynamic][]Cell, 0, 8, allocator)

	sep_ok: bool
	t.head_body_sep, err, sep_ok = find_head_body_sep(t.block, .Simple, allocator)
	if !sep_ok do return {}, err, false

	// parse_table
	cols, cerr, cok := parse_columns(&t, t.block[0], 0)
	if !cok do return {}, cerr, false
	append(&t.columns, ..cols[:])
	if len(t.columns) == 0 do return {}, {"Malformed table.", 0}, false
	t.border_end = t.columns[len(t.columns) - 1][1]
	firststart, firstend := t.columns[0][0], t.columns[0][1]
	offset, start := 1, 1
	text_found := false
	for offset < len(t.block) {
		line := t.block[offset]
		line_text := runes_to_string(line, false, allocator)
		if match_simple_span(line_text) {
			if rerr, rok := parse_row(&t, t.block[start:offset], start, rune_rstrip(line), offset, true); !rok do return {}, rerr, false
			start = offset + 1
			text_found = false
		} else if len(rune_strip(line[min(firststart, len(line)):min(firstend, len(line))])) > 0 {
			if text_found && offset != start {
				if rerr, rok := parse_row(&t, t.block[start:offset], start, nil, 0, false); !rok do return {}, rerr, false
			}
			start = offset
			text_found = true
		} else if !text_found {
			start = offset + 1
		}
		offset += 1
	}
	// structure_from_cells
	data.colwidths = make([]int, len(t.columns), allocator)
	for c, i in t.columns do data.colwidths[i] = c[1] - c[0]
	first_body_row := 0
	if t.head_body_sep > 0 {
		for row, i in t.table {
			if row[0].offset > t.head_body_sep {
				first_body_row = i
				break
			}
		}
	}
	data.head_rows = t.table[:first_body_row]
	data.body_rows = t.table[first_body_row:]
	return data, {}, true
}

@(private = "file")
parse_columns :: proc(t: ^Simple, line: []rune, offset: int) -> (cols: [dynamic][2]int, err: Table_Error, ok: bool) {
	cols = make([dynamic][2]int, 0, 8, t.allocator)
	end := 0
	for {
		begin := -1
		for i in max(end, 0) ..< len(line) {
			if line[i] == '-' {
				begin = i
				break
			}
		}
		if begin < 0 do break
		end = -1
		for i in begin ..< len(line) {
			if line[i] == ' ' {
				end = i
				break
			}
		}
		if end < 0 do end = len(line)
		append(&cols, [2]int{begin, end})
	}
	if len(t.columns) > 0 {
		if len(cols) == 0 || cols[len(cols) - 1][1] != t.border_end {
			return cols, {concat("Column span incomplete in table line ", int_str(offset + 1, t.allocator), ".", allocator = t.allocator), offset}, false
		}
		cols[len(cols) - 1][1] = t.columns[len(t.columns) - 1][1]
	}
	return cols, {}, true
}

@(private = "file")
parse_row :: proc(t: ^Simple, lines: [][]rune, start: int, spanline: []rune, span_offset: int, has_span: bool) -> (err: Table_Error, ok: bool) {
	if len(lines) == 0 && !has_span do return {}, true
	columns: [dynamic][2]int
	if has_span {
		cerr: Table_Error
		cok: bool
		columns, cerr, cok = parse_columns(t, spanline, span_offset)
		if !cok do return cerr, false
	} else {
		columns = make([dynamic][2]int, len(t.columns), t.allocator)
		copy(columns[:], t.columns[:])
	}
	if cerr, cok := check_columns(t, lines, start, &columns); !cok do return cerr, false
	row, ierr, iok := init_row(t, columns[:], start)
	if !iok do return ierr, false
	for c, i in columns {
		row[i].lines = get_2d_block(lines, 0, c[0], len(lines), c[1], t.allocator)
	}
	append(&t.table, row)
	return {}, true
}

@(private = "file")
check_columns :: proc(t: ^Simple, lines: [][]rune, first_line: int, columns: ^[dynamic][2]int) -> (err: Table_Error, ok: bool) {
	MAXSIZE :: max(int)
	append(columns, [2]int{MAXSIZE, -1})
	lastcol := len(columns) - 2
	stripped := make([][]rune, len(lines), t.allocator)
	for l, i in lines do stripped[i] = strip_combining(l, t.allocator)
	for i in 0 ..< len(columns) - 1 {
		start, end := columns[i][0], columns[i][1]
		nextstart := columns[i + 1][0]
		for line, offset in stripped {
			tail := line[min(end, len(line)):]
			if i == lastcol && len(rune_strip(tail)) > 0 {
				text := rune_rstrip(line[min(start, len(line)):])
				new_end := start + len(text)
				main_start, main_end := t.columns[len(t.columns) - 1][0], t.columns[len(t.columns) - 1][1]
				columns[i] = {start, max(main_end, new_end)}
				if new_end > main_end do t.columns[len(t.columns) - 1] = {main_start, new_end}
			} else {
				margin := line[min(end, len(line)):min(max(nextstart, end), len(line))]
				if len(rune_strip(margin)) > 0 {
					return {concat("Text in column margin in table line ", int_str(first_line + offset + 1, t.allocator), ".", allocator = t.allocator), first_line + offset}, false
				}
			}
		}
	}
	pop(columns)
	return {}, true
}

@(private = "file")
init_row :: proc(t: ^Simple, colspec: [][2]int, offset: int) -> (cells: []Cell, err: Table_Error, ok: bool) {
	cells = make([]Cell, len(colspec), t.allocator)
	i := 0
	for c, k in colspec {
		morecols := 0
		bad := i >= len(t.columns) || c[0] != t.columns[i][0]
		for !bad && c[1] != t.columns[i][1] {
			i += 1
			morecols += 1
			if i >= len(t.columns) do bad = true
		}
		if bad {
			return nil, {concat("Column span alignment problem in table line ", int_str(offset + 2, t.allocator), ".", allocator = t.allocator), offset + 1}, false
		}
		cells[k] = Cell{0, morecols, offset, nil, true}
		i += 1
	}
	return cells, {}, true
}
