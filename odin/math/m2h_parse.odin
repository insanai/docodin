package texmath

// Parsing a formula into bits (``FormulaFactory`` and the basic bit kinds of
// ``_math2html_bits``).  At each position the first kind that detects the current
// character parses the next bit; a parse may hand back a replacement bit.

import "core:strings"

COMMAND_START :: "\\"
BRACKET_START :: "{"
BRACKET_END :: "}"
SQUARE_START :: "["
SQUARE_END :: "]"
COMMENT_START :: '%'
ROW_SEPARATOR :: "\\\\"
CELL_SEPARATOR :: "&"

// ``FormulaFactory.parseformula``: parse the whole formula.
parse_formula :: proc(m: ^M2h) -> ^Node {
	// ``TextPosition.__init__``: skip a byte order mark
	if !finished(m) && current(m) == 0xFEFF {
		skip_current(m)
	}
	whole := new_node(.Whole_Formula)
	parse_whole(m, whole)
	return whole
}

// ``WholeFormula.parsebit``: bits up to the end of the enclosing construct.
parse_whole :: proc(m: ^M2h, whole: ^Node) {
	for !finished(m) {
		add(whole, parse_any(m))
	}
}

// The kind of bit starting at the (unfinished) position, in the order of
// ``FormulaFactory.types``.
@(private = "file")
detect :: proc(m: ^M2h) -> (Bit_Kind, bool) {
	char := current(m)
	switch {
	case strings.contains_rune(UNMODIFIED, char) || has_key(MODIFIED[:], char_string(m)):
		return .Formula_Symbol, true
	case is_alpha(char):
		return .Raw_Text, true
	case is_digit(char):
		return .Formula_Number, true
	case check_for(m, BRACKET_START):
		return .Bracket, true
	case char == COMMENT_START:
		return .Comment, true
	case is_space(char):
		return .White_Space, true
	case check_for(m, COMMAND_START):
		return .Formula_Command, true
	case char == '^' || char == '_':
		return .Symbol_Function, true
	}
	return nil, false
}

// The current character as a string.
char_string :: proc(m: ^M2h) -> string {
	for _, offset in m.text[m.pos:] {
		if offset > 0 {
			return m.text[m.pos:m.pos + offset]
		}
	}
	return m.text[m.pos:]
}

// ``FormulaFactory.parseany``: a character no kind accepts is reported and kept.
parse_any :: proc(m: ^M2h) -> ^Node {
	if !finished(m) {
		if kind, found := detect(m); found {
			return parse_type(m, kind)
		}
	}
	trace_error(m, "Unrecognized formula at ", identifier(m))
	return new_constant(skip_current(m))
}

// ``FormulaFactory.parsetype``: parse a bit of the given kind.
parse_type :: proc(m: ^M2h, kind: Bit_Kind) -> ^Node {
	bit := new_node(kind)
	return parse_bit(m, bit)
}

// Enter a nested parse (false beyond `MAX_DEPTH`, which raises).
enter :: proc(m: ^M2h) -> bool {
	m.depth += 1
	if m.depth > MAX_DEPTH {
		raise(m, RECURSION_ERROR)
	}
	return m.err == nil
}

// ``parsebit`` of the bit kinds; returns the bit or its replacement.
parse_bit :: proc(m: ^M2h, bit: ^Node) -> ^Node {
	defer m.depth -= 1
	if !enter(m) {
		return bit
	}
	#partial switch bit.kind {
	case .Whole_Formula:
		parse_whole(m, bit)
	case .Raw_Text:
		add(bit, new_constant(glob(m, is_alpha)))
		bit.type = "alpha"
	case .Formula_Symbol:
		parse_symbol(m, bit)
	case .Formula_Number:
		add(bit, new_constant(glob(m, is_digit)))
		bit.type = "number"
	case .Comment:
		bit.original = concat(bit.original, glob_including(m, '\n'))
	case .White_Space:
		bit.original = concat(bit.original, glob(m, is_space))
	case .Bracket, .Square_Bracket:
		parse_complete(m, bit, parse_inner_formula)
	case .Formula_Command:
		return parse_command(m, bit)
	case .Symbol_Function:
		parse_script(m, bit)
	case:
		parse_command_bit(m, bit)
	}
	return bit
}

// ``FormulaSymbol.parsebit``: the character, or its translation with spacing.
@(private = "file")
parse_symbol :: proc(m: ^M2h, bit: ^Node) {
	char := char_string(m)
	symbol := char
	if !strings.contains(UNMODIFIED, char) {
		symbol, _ = lookup(MODIFIED[:], char)
	}
	bit.original = concat(bit.original, char)
	m.pos += len(char)
	append(&bit.contents, new_constant(symbol))
}

// ``FormulaFactory.clearskipped``: skip white space and comments.
clear_skipped :: proc(m: ^M2h) {
	for !finished(m) {
		char := current(m)
		if char == COMMENT_START {
			parse_type(m, .Comment)
		} else if is_space(char) {
			parse_type(m, .White_Space)
		} else {
			return
		}
	}
}

// Brackets
// --------

bracket_marks :: proc(bit: ^Node) -> (start: string, end: string) {
	if bit.kind == .Square_Bracket {
		return SQUARE_START, SQUARE_END
	}
	return BRACKET_START, BRACKET_END
}

// ``Bracket.parsecomplete``: the opening mark, the contents, the closing mark.
parse_complete :: proc(m: ^M2h, bit: ^Node, inner: proc(m: ^M2h, bit: ^Node)) {
	defer m.depth -= 1
	if !enter(m) {
		return
	}
	start, end := bracket_marks(bit)
	bit.original = concat(bit.original, start)
	m.pos += len(start)
	push_ending(m, end)
	inner(m, bit)
	bit.original = concat(bit.original, pop_ending(m, end))
	compute_size(bit)
}

// ``Bracket.innerformula``.
parse_inner_formula :: proc(m: ^M2h, bit: ^Node) {
	for !finished(m) {
		add(bit, parse_any(m))
	}
}

// ``Bracket.innertext``: characters are kept, except commands, scripts, groups
// and comments (which swallow one following space).
parse_inner_text :: proc(m: ^M2h, bit: ^Node) {
	for !finished(m) {
		if strings.contains_rune("^_\\{%", current(m)) {
			add(bit, parse_any(m))
			if check_skip(m, " ") {
				bit.original = concat(bit.original, " ")
			}
		} else {
			add(bit, new_constant(skip_current(m)))
		}
	}
}

// ``Bracket.innerliteral``: the raw text up to the closing mark.  A nested group
// is read with the same bracket and restarts `literal` (``{a{b}c}`` reads ``bc``).
parse_inner_literal :: proc(m: ^M2h, bit: ^Node) {
	start, end := bracket_marks(bit)
	bit.literal = ""
	for !finished(m) && !check_for(m, end) {
		if check_for(m, start) {
			parse_complete(m, bit, parse_inner_literal)
		} else {
			bit.literal = concat(bit.literal, skip_current(m))
		}
	}
	bit.original = concat(bit.original, bit.literal)
}

// Parameters of commands
// ----------------------

// ``CommandBit.parseparameter``: the next bit, after any space or comment.
parse_parameter :: proc(m: ^M2h, bit: ^Node) -> ^Node {
	clear_skipped(m)
	if finished(m) {
		return nil
	}
	parameter := parse_any(m)
	add(bit, parameter)
	return parameter
}

// ``CommandBit.parsesquare``: an optional ``[...]`` parameter.
parse_square :: proc(m: ^M2h, bit: ^Node) -> ^Node {
	clear_skipped(m)
	if finished(m) || !check_for(m, SQUARE_START) {
		return nil
	}
	bracket := parse_type(m, .Square_Bracket)
	add(bit, bracket)
	return bracket
}

// ``CommandBit.parseliteral``: a ``{...}`` group or a run of value characters
// read literally; `found` is false where docutils returns None.
parse_literal :: proc(m: ^M2h, bit: ^Node) -> (literal: string, found: bool) {
	clear_skipped(m)
	if finished(m) || !check_for(m, BRACKET_START) {
		if !is_value(m) {
			if m.err == nil {
				trace_error(m, "No literal parameter found at: ", identifier(m))
			}
			return "", false
		}
		return glob_value(m), true
	}
	return parse_literal_bracket(m, bit, .Bracket)
}

// ``CommandBit.parsesquareliteral``: an optional ``[...]`` parameter, literally.
parse_square_literal :: proc(m: ^M2h, bit: ^Node) -> (literal: string, found: bool) {
	clear_skipped(m)
	if finished(m) || !check_for(m, SQUARE_START) {
		return "", false
	}
	return parse_literal_bracket(m, bit, .Square_Bracket)
}

@(private = "file")
parse_literal_bracket :: proc(m: ^M2h, bit: ^Node, kind: Bit_Kind) -> (string, bool) {
	bracket := new_node(kind)
	parse_complete(m, bracket, parse_inner_literal)
	add(bit, bracket)
	return bracket.literal, true
}

// ``CommandBit.parsetext``: a ``{...}`` parameter read as text.
parse_text :: proc(m: ^M2h, bit: ^Node) -> ^Node {
	clear_skipped(m)
	if finished(m) || !check_for(m, BRACKET_START) {
		trace_error(m, "No text parameter for ", bit.command)
		return nil
	}
	bracket := new_node(.Bracket)
	parse_complete(m, bracket, parse_inner_text)
	add(bit, bracket)
	return bracket
}

// ``SymbolFunction.parsebit``: ``^`` or ``_`` and a parameter.
@(private = "file")
parse_script :: proc(m: ^M2h, bit: ^Node) {
	bit.command = char_string(m)
	bit.translated = bit.command == "^" ? "sup" : "sub"
	bit.original = concat(bit.original, bit.command)
	m.pos += len(bit.command)
	set_tag(bit, bit.translated)
	parse_parameter(m, bit)
}

// Commands
// --------

// The entries of `M2H_COMMANDS` for `name`, in order of precedence.
command_entries :: proc(name: string) -> []Command_Entry {
	table := M2H_COMMANDS[:]
	lo, hi := 0, len(table)
	for lo < hi {
		mid := (lo + hi) / 2
		if table[mid].name < name {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	end := lo
	for end < len(table) && table[end].name == name {
		end += 1
	}
	return table[lo:end]
}

// The translation of `name` in the table of `kind` (``name in commandmap``).
command_value :: proc(kind: Command_Kind, name: string) -> (string, bool) {
	for entry in command_entries(name) {
		if entry.kind == kind {
			return entry.value, true
		}
	}
	return "", false
}

// ``FormulaCommand.parsebit``: parse the command with its kind; an unknown
// command stays this bit, shown in a ``span class="unknown"``.
@(private = "file")
parse_command :: proc(m: ^M2h, bit: ^Node) -> ^Node {
	command := extract_command(m)
	if known := parse_with_command(m, command); known != nil {
		return known
	}
	if strings.has_prefix(command, "\\up") || strings.has_prefix(command, "\\Up") {
		if upgreek := parse_upgreek(m, command); upgreek != nil {
			return upgreek
		}
	}
	trace_error(m, "Unknown command ", command)
	set_tag(bit, `span class="unknown"`)
	add(bit, new_constant(command))
	return bit
}

// ``FormulaCommand.extractcommand``: a run of letters (and an optional ``*``) or
// one character; a backslash before an ending escapes it.
@(private = "file")
extract_command :: proc(m: ^M2h) -> string {
	m.pos += len(COMMAND_START)
	if finished(m) {
		command := ""
		if !is_out(m) {
			if ending, found := next_ending(m); found && check_skip(m, ending) {
				command = ending
			}
		}
		return concat(COMMAND_START, command)
	}
	if is_alpha(current(m)) {
		command := concat(COMMAND_START, glob(m, is_alpha))
		check_skip(m, "*")
		return command
	}
	return concat(COMMAND_START, skip_current(m))
}

// ``FormulaCommand.parsewithcommand``: parse with the kind that knows `command`.
@(private = "file")
parse_with_command :: proc(m: ^M2h, command: string) -> ^Node {
	entries := command_entries(command)
	if len(entries) == 0 {
		return nil
	}
	bit := new_node(COMMAND_BITS[entries[0].kind])
	bit.command = command
	bit.original = command
	bit.translated = entries[0].value
	return parse_bit(m, bit)
}

// ``FormulaCommand.parseupgreek``: ``\upalpha`` is the plain letter in a font.
@(private = "file")
parse_upgreek :: proc(m: ^M2h, command: string) -> ^Node {
	if cp_len(command) < 4 {
		return nil
	}
	upcommand: string
	if strings.has_prefix(command, "\\up") {
		upcommand = concat(COMMAND_START, command[3:])
	} else if check_skip(m, "\\Up") {
		b := strings.builder_make()
		strings.write_string(&b, COMMAND_START)
		rest := command[3:]
		first := cp_offset(rest, 1)
		for r in rest[:first] {
			upper(r, &b)
		}
		strings.write_string(&b, rest[first:])
		upcommand = strings.to_string(b)
	} else {
		trace_error(m, "Impossible upgreek command: ", command)
		return nil
	}
	upgreek := parse_with_command(m, upcommand)
	if upgreek != nil {
		upgreek.type = "font"
	}
	return upgreek
}
