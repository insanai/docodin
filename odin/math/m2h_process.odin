package texmath

// Processing the parsed formula in place (``FormulaProcessor``): the bits process
// themselves; the maths processors stack scripts and limits and resize
// ``\left``/``\right`` brackets; letters are set in italics and a thin space
// separates a number from a following unit.

import "core:strings"

// ``FormulaProcessor.process``.
process_formula :: proc(m: ^M2h, whole: ^Node) {
	process_contents(whole)
	process_insides(m, whole)
	last: ^Node
	traverse_whole(whole, &last)
}

// ``FormulaProcessor.processcontents``: each bit processes itself.
@(private = "file")
process_contents :: proc(bit: ^Node) {
	if bit.kind == .Formula_Constant {
		return
	}
	#partial switch bit.kind {
	case .Text_Function:
		bit.type = "font"
	case .Font_Function:
		bit.type = "font"
		simplify_if_possible(bit)
	}
	for child in bit.contents {
		process_contents(child)
	}
}

// ``FormulaProcessor.processinsides``: the processors may restructure the list
// being walked; the recursion goes into the element found at each index before
// processing.
@(private = "file")
process_insides :: proc(m: ^M2h, bit: ^Node) {
	if bit.kind == .Formula_Constant {
		return
	}
	for index := 0; index < len(bit.contents); index += 1 {
		element := bit.contents[index]
		if !m.simple {
			process_limits(m, &bit.contents, index)
			process_brackets(&bit.contents, index)
		}
		process_insides(m, element)
	}
}

// LimitsProcessor
// ---------------

@(private = "file")
is_script :: proc(contents: ^[dynamic]^Node, index: int) -> bool {
	return index < len(contents) && contents[index].kind == .Symbol_Function
}

// ``LimitsProcessor.process``.
@(private = "file")
process_limits :: proc(m: ^M2h, contents: ^[dynamic]^Node, index: int) {
	if m.display && contents[index].kind == .Limit_Command && is_script(contents, index + 1) {
		modify_limits(contents, index)
	}
	if is_script(contents, index) && is_script(contents, index + 1) {
		modify_scripts(contents, index)
	}
}

// ``LimitsProcessor.modifylimits``: move the scripts after a big operator above
// and below it.
@(private = "file")
modify_limits :: proc(contents: ^[dynamic]^Node, index: int) {
	limited := contents[index]
	subscript := take_limit(contents, index + 1)
	superscript: ^Node
	if is_script(contents, index + 1) {
		superscript = take_limit(contents, index + 1)
	} else {
		superscript = tagged_constant(THIN_SPACE, `sup class="limit"`)
	}
	if subscript.command == "^" {
		superscript, subscript = subscript, superscript
	}
	append(&limited.contents, subscript)
	inject_at(&limited.contents, 0, superscript)
}

@(private = "file")
take_limit :: proc(contents: ^[dynamic]^Node, index: int) -> ^Node {
	limit := take_script(contents, index)
	limit.tag, _ = strings.replace_all(limit.tag, "script", "limit")
	return limit
}

@(private = "file")
take_script :: proc(contents: ^[dynamic]^Node, index: int) -> ^Node {
	bit := contents[index]
	ordered_remove(contents, index)
	bit.tag = strings.concatenate({bit.tag, ` class="script"`})
	return bit
}

// ``LimitsProcessor.modifyscripts``: a sub- and superscript pair becomes a stack.
@(private = "file")
modify_scripts :: proc(contents: ^[dynamic]^Node, index: int) {
	subscript := take_script(contents, index)
	superscript := take_script(contents, index)
	if subscript.command == "^" {
		superscript, subscript = subscript, superscript
	}
	scripts := tagged_complete({superscript, subscript}, `span class="scripts"`)
	inject_at(contents, index, scripts)
}

// BracketProcessor
// ----------------

@(private = "file")
is_bracket :: proc(bit: ^Node, command: string) -> bool {
	return bit.kind == .Bracket_Command && bit.command == command
}

// ``BracketProcessor.process``: resize a left bracket and its matching right
// bracket to the largest size between them.
@(private = "file")
process_brackets :: proc(contents: ^[dynamic]^Node, index: int) {
	if !is_bracket(contents[index], "\\left") {
		return
	}
	depth := 1
	right := -1
	for position in index + 1 ..< len(contents) {
		if is_bracket(contents[position], "\\left") {
			depth += 1
		}
		if is_bracket(contents[position], "\\right") {
			depth -= 1
		}
		if depth == 0 {
			right = position
			break
		}
	}
	if right < 0 {
		return
	}
	size := contents[index].size
	for element in contents[index + 1:right] {
		size = max(size, element.size)
	}
	resize_bracket(contents[index], size)
	resize_bracket(contents[right], size)
}

// ``BracketProcessor.resize``: rebuild a bracket command as a big bracket.
@(private = "file")
resize_bracket :: proc(bit: ^Node, size: int) {
	direction, _ := strings.remove_all(bit.command, "\\")
	contents := big_bracket(size, extract_text(bit), direction)
	bit.output = .Contents
	clear(&bit.contents)
	append(&bit.contents, ..contents)
}

// Italics
// -------

// ``FormulaProcessor.traversewhole``: the typed bits in document order (not
// looking into them), with the list holding each.
@(private = "file")
traverse_whole :: proc(bit: ^Node, last: ^^Node) {
	for index := 0; index < len(bit.contents); index += 1 {
		element := bit.contents[index]
		switch {
		case len(element.type) > 0:
			if element.type == "alpha" {
				bit.contents[index] = tagged_complete({element}, "i")
			} else if element.type == "font" && last^ != nil && last^.type == "number" {
				inject_at(&element.contents, 0, new_constant(THIN_SPACE))
			}
			last^ = element
		case element.kind != .Formula_Constant:
			traverse_whole(element, last)
		}
	}
}
