package texmath

// Environments (``\begin{name}...\end{name}``), tables of rows and cells, and big
// brackets (``_math2html_arrays``).  A multi-row environment pushes the optional
// endings ``\\`` (rows) and ``&`` (cells) and parses cells as whole formulas; an
// empty spacer row goes between two rows.

import "core:strings"

FOUR_PER_EM_SPACE :: "\u2005"
EM_SPACE :: "\u2003"

// ``BeginCommand.parsebit``: parse the environment up to ``\end{name}``.
parse_begin :: proc(m: ^M2h, bit: ^Node) {
	piece, found := parse_literal(m, bit)
	if !found {
		raise(m, none_attribute("replace"))
		return
	}
	environment := find_environment(piece)
	ending := strings.concatenate({"\\end{", piece, "}"})
	push_ending(m, ending)
	parse_environment(m, environment)
	add(bit, environment)
	bit.original = concat(bit.original, pop_ending(m, ending))
	bit.size = environment.size
}

// ``BeginCommand.findbit``: the bit for environment `piece` (starred or not).
@(private = "file")
find_environment :: proc(piece: string) -> ^Node {
	name, _ := strings.remove_all(piece, "*")
	switch name {
	case "equation":
		return new_node(.Formula_Equation)
	case "array":
		return new_node(.Formula_Array)
	case "cases":
		return new_node(.Formula_Cases)
	case "matrix":
		return new_node(.Formula_Matrix)
	}
	bit := new_node(.Equation_Environment)
	bit.piece = piece
	return bit
}

@(private = "file")
parse_environment :: proc(m: ^M2h, bit: ^Node) {
	#partial switch bit.kind {
	case .Formula_Equation:
		add(bit, parse_type(m, .Whole_Formula))
	case .Formula_Array:
		set_tag(bit, `span class="array"`)
		parse_square_literal(m, bit) // the vertical alignment (unused)
		alignments, found := parse_literal(m, bit)
		if !found {
			raise(m, {.Type_Error, "'NoneType' object is not iterable"})
			return
		}
		bit.alignments = characters(alignments)
		parse_rows(m, bit)
	case .Formula_Matrix:
		set_tag(bit, `span class="array"`)
		bit.alignments = {"c"}
		parse_rows(m, bit)
	case .Formula_Cases:
		parse_cases(m, bit)
	case .Equation_Environment:
		parse_equation_environment(m, bit)
	}
}

// ``list(string)``: the characters.
@(private = "file")
characters :: proc(s: string) -> []string {
	result := make([dynamic]string)
	for _, offset in s {
		size := cp_offset(s[offset:], 1)
		append(&result, s[offset:offset + size])
	}
	return result[:]
}

// ``FormulaCases.parsebit``: left-aligned rows after a big curly bracket.
@(private = "file")
parse_cases :: proc(m: ^M2h, bit: ^Node) {
	bit.alignments = {"l", "l"}
	parse_rows(m, bit)
	if m.err != nil {
		return
	}
	for row in bit.contents {
		for cell in row.contents {
			cell.tag = `span class="case align-l"`
			cell.breaklines = true
			append(&cell.contents, new_constant(EM_SPACE))
		}
	}
	array := tagged_complete(bit.contents[:], `span class="bracketcases"`, true)
	brace := big_bracket(len(bit.contents), "{", "l")
	clear(&bit.contents)
	append(&bit.contents, ..brace)
	append(&bit.contents, array)
}

// ``EquationEnvironment.parsebit``: an environment like ``align`` (unknown names
// are shown as unknown).
@(private = "file")
parse_equation_environment :: proc(m: ^M2h, bit: ^Node) {
	environment, _ := strings.remove_all(bit.piece, "*")
	set_tag(bit, strings.concatenate({`span class="environment `, environment, `"`}))
	if alignments, found := pieces(ENVIRONMENTS[:], environment); found {
		bit.alignments = alignments
	} else {
		trace_error(m, "Unknown equation environment ", bit.piece)
		set_tag(bit, `span class="unknown"`)
		add(bit, new_constant(strings.concatenate({"\\begin{", environment, "} "})))
		bit.alignments = {"l"}
	}
	parse_rows(m, bit)
}

pieces :: proc(table: []Pieces_Entry, key: string) -> ([]string, bool) {
	for entry in table {
		if entry.key == key {
			return entry.pieces, true
		}
	}
	return nil, false
}

// ``MultiRowFormula.parserows``: rows up to the end, with spacer rows between.
@(private = "file")
parse_rows :: proc(m: ^M2h, bit: ^Node) {
	rows := 0
	last: ^Node
	for {
		push_ending(m, ROW_SEPARATOR, true)
		row := new_row(bit.alignments)
		if rows > 0 {
			add_empty_row(m, bit, last)
		}
		parse_row(m, row)
		add(bit, row)
		rows += 1
		last = row
		if !check_for(m, ROW_SEPARATOR) {
			break
		}
		bit.original = concat(bit.original, pop_ending(m, ROW_SEPARATOR))
	}
	bit.size = 2 * rows - 1
}

@(private = "file")
new_row :: proc(alignments: []string) -> ^Node {
	row := new_node(.Formula_Row)
	row.alignments = alignments
	set_tag(row, `span class="arrayrow"`, true)
	return row
}

// ``FormulaRow.parsebit``: cells separated by ``&`` up to the end of the row.
@(private = "file")
parse_row :: proc(m: ^M2h, row: ^Node) {
	push_ending(m, CELL_SEPARATOR, true)
	for index := 0; !finished(m); index += 1 {
		cell := new_cell(m, row, index)
		if cell == nil {
			return
		}
		clear_skipped(m)
		if !finished(m) {
			add(cell, parse_type(m, .Whole_Formula))
		}
		add(row, cell)
		check_skip(m, CELL_SEPARATOR)
	}
	if len(row.contents) == 0 {
		row.output = .Empty
	}
}

// ``FormulaRow.createcell``: alignments repeat cyclically.
@(private = "file")
new_cell :: proc(m: ^M2h, row: ^Node, index: int) -> ^Node {
	if len(row.alignments) == 0 {
		raise(m, {.Zero_Division_Error, "division by zero"}) // CPython 3.14 wording
		return nil
	}
	alignment := row.alignments[index % len(row.alignments)]
	cell := new_node(.Formula_Cell)
	set_tag(cell, strings.concatenate({`span class="arraycell align-`, alignment, `"`}), true)
	return cell
}

// ``MultiRowFormula.addempty``: a spacer row as wide as the previous row.
@(private = "file")
add_empty_row :: proc(m: ^M2h, bit: ^Node, previous: ^Node) {
	row := new_row(bit.alignments)
	for index in 0 ..< len(previous.contents) {
		cell := new_cell(m, row, index)
		add(cell, new_constant(FOUR_PER_EM_SPACE))
		add(row, cell)
	}
	add(bit, row)
}

// Big brackets
// ------------

// ``BigBracket(size, bracket, alignment).getcontents()``: a bracket of `size`
// rows built from pieces, or a single stretchy sign.
big_bracket :: proc(size: int, bracket: string, alignment: string) -> []^Node {
	parts, found := pieces(BIG_BRACKETS[:], bracket)
	if size == 1 || !found {
		if bracket == "." {
			return slice_of(tagged_constant("", `span class="emptydot"`))
		}
		return slice_of(tagged_constant(bracket, `span class="stretchy"`))
	}
	span := strings.concatenate({`span class="bracket align-`, alignment, `"`})
	rows := make([]^Node, size)
	for index in 0 ..< size {
		cell := tagged_constant(bracket_piece(parts, size, index), span)
		rows[index] = tagged_complete({cell}, `span class="arrayrow"`)
	}
	return slice_of(tagged_complete(rows, `span class="array"`))
}

@(private = "file")
slice_of :: proc(node: ^Node) -> []^Node {
	result := make([]^Node, 1)
	result[0] = node
	return result
}

// ``BigBracket.getpiece``: top, extension (middle, extension) and bottom.
@(private = "file")
bracket_piece :: proc(parts: []string, size, index: int) -> string {
	switch len(parts) {
	case 1:
		return parts[0]
	case 3:
		if index == 0 {
			return parts[0]
		}
		return index == size - 1 ? parts[2] : parts[1]
	}
	switch {
	case index == 0:
		return parts[0]
	case index == size - 1:
		return parts[3]
	case (size - 1) % 2 == 0 && index == (size - 1) / 2:
		return parts[2]
	}
	return parts[1]
}
