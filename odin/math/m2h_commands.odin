package texmath

// The known commands (``_math2html_commands``): each kind reads its parameters as
// its table prescribes and decides the output.

import "core:strings"

THIN_SPACE :: "\u2009"

// ``parsebit`` of the command kinds.
parse_command_bit :: proc(m: ^M2h, bit: ^Node) {
	#partial switch bit.kind {
	case .Alpha_Command, .Empty_Command, .Spaced_Command:
		parse_constant_command(bit)
	case .One_Param_Function, .Font_Function, .Bracket_Command:
		set_tag(bit, bit.translated)
		parse_parameter(m, bit)
		simplify_if_possible(bit)
	case .Text_Function:
		set_tag(bit, bit.translated)
		parse_text(m, bit)
	case .Combining_Function:
		parse_combining(m, bit)
	case .Overset_Function, .Underset_Function:
		embellish(m, bit, bit.kind == .Overset_Function ? "sup" : "sub")
	case .Limit_Command:
		set_tag(bit, `span class="limits"`)
		append(&bit.contents, tagged_constant(bit.translated, `span class="limit"`))
	case .Begin_Command:
		parse_begin(m, bit)
	case .Hybrid_Function:
		parse_hybrid(m, bit)
	}
}

// ``EmptyCommand``, ``AlphaCommand`` (letters in italics, except upright Greek
// capitals) and ``SpacedCommand`` (relations, padded with thin spaces).
@(private = "file")
parse_constant_command :: proc(bit: ^Node) {
	text := bit.translated
	#partial switch bit.kind {
	case .Alpha_Command:
		if !has_name(GREEK_CAPITALS[:], bit.command) {
			bit.type = "alpha"
		}
	case .Spaced_Command:
		text = strings.concatenate({THIN_SPACE, bit.translated, THIN_SPACE})
	}
	append(&bit.contents, new_constant(text))
}

// The command table of a kind (``commandmap``).
@(private = "file")
command_table :: proc(kind: Bit_Kind) -> Command_Kind {
	#partial switch kind {
	case .Font_Function:
		return .Font
	case .Bracket_Command:
		return .Bracket
	case .Overset_Function:
		return .Overset
	case .Underset_Function:
		return .Underset
	case .Combining_Function:
		return .Combining
	}
	return .One_Param
}

// ``OneParamFunction.simplifyifpossible``: the fixed translation of the whole
// source, like ``\mathbb{R}``, if any.
simplify_if_possible :: proc(bit: ^Node) {
	if html, found := command_value(command_table(bit.kind), bit.original); found {
		bit.output = .Fixed
		bit.text = html
	}
}

// ``ContainerExtractor(ContainerConfig.extracttext).extract``: the constants
// reachable through textual containers.
extract_constants :: proc(bit: ^Node, found: ^[dynamic]^Node) {
	for child in bit.contents {
		if has_name(EXTRACTED_CLASSES[:], CLASS_NAMES[child.kind]) {
			extract_constants(child, found)
		}
		if child.kind == .Formula_Constant {
			append(found, child)
		}
	}
}

// ``Container.extracttext``.
extract_text :: proc(bit: ^Node) -> string {
	found := make([dynamic]^Node)
	extract_constants(bit, &found)
	b := strings.builder_make()
	for constant in found {
		strings.write_string(&b, constant.text)
	}
	return strings.to_string(b)
}

// ``CombiningFunction.parsebit``: a combining character after the first
// character of the parameter (composed if possible: ``\not{=}`` is ≠).
@(private = "file")
parse_combining :: proc(m: ^M2h, bit: ^Node) {
	clear_skipped(m)
	parameter: ^Node
	if !finished(m) {
		parameter = parse_parameter(m, bit)
	}
	if parameter == nil {
		trace_error(m, "Missing parameter for combining function ", bit.command)
		return
	}
	if parameter.kind != .Formula_Constant {
		found := make([dynamic]^Node)
		extract_constants(parameter, &found)
		if len(found) == 0 {
			trace_error(m, `No base character found for "`, bit.command, `".`)
			return
		}
		parameter = found[0]
	}
	text := parameter.text
	split := cp_offset(text, strings.has_prefix(text, THIN_SPACE) ? 2 : 1)
	parameter.text = nfc(strings.concatenate({text[:split], bit.translated, text[split:]}))
}

// ``_embellish``: the translated symbol over or under the parameter.
@(private = "file")
embellish :: proc(m: ^M2h, bit: ^Node, symbol_tag: string) {
	symbol := tagged_constant(bit.translated, symbol_tag)
	parameter := parse_parameter(m, bit)
	set_tag(bit, `span class="embellished"`)
	inject_at(&bit.contents, 0, symbol)
	if parameter == nil {
		raise(m, none_attribute_set("output"))
		return
	}
	set_tag(parameter, `span class="base"`)
	simplify_if_possible(bit)
}

// ``BracketCommand.create``: a ``\left`` or ``\right`` bracket for `char`.
new_bracket_command :: proc(direction: string, char: string) -> ^Node {
	bit := new_node(.Bracket_Command)
	bit.original = char
	bit.command = concat(COMMAND_START, direction)
	append(&bit.contents, new_constant(char))
	return bit
}
