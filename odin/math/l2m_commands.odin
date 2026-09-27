package texmath

// The command handlers of ``latex2mathml`` (``_CMD_HANDLERS``).  The generator
// maps each command name to the first handler whose selector accepts it
// (`L2M_COMMANDS`); names ending in "limits" fall back to `.Limits`.

import "core:strings"
import "core:unicode/utf8"

L2m_Handler :: enum u8 {
	Letter,
	Ordinary,
	Function,
	Modulo,
	Boldsymbol,
	Math_Alphabet,
	Colon,
	Idotsint,
	Thick_Operator,
	Small_Operator,
	Operator,
	Bigdelimiter,
	Not,
	Text,
	Space,
	Hspace,
	Phantom,
	Boxed,
	Sqrt,
	Fraction,
	Newline,
	Accent,
	Over,
	Overset,
	Under,
	Underset,
	Xarrow,
	Layout_Style,
	Limits,
	Begin,
	End,
}

L2m_Command :: struct {
	name:    string,
	handler: L2m_Handler,
}

APPLY_FUNCTION :: "\u2061"

// A handler's result: the new insertion point and the remainder of the source.
Handled :: struct {
	node: ^Element,
	rest: string,
}

@(private = "file")
Handler_Proc :: #type proc(name: string, node: ^Element, rest: string) -> (Handled, Error)

@(private = "file", rodata)
HANDLERS := [L2m_Handler]Handler_Proc {
	.Letter         = cmd_letter,
	.Ordinary       = cmd_ordinary,
	.Function       = cmd_function,
	.Modulo         = cmd_modulo,
	.Boldsymbol     = cmd_boldsymbol,
	.Math_Alphabet  = cmd_alphabet,
	.Colon          = cmd_colon,
	.Idotsint       = cmd_idotsint,
	.Thick_Operator = cmd_thick_op,
	.Small_Operator = cmd_small_op,
	.Operator       = cmd_operator,
	.Bigdelimiter   = cmd_bigdelim,
	.Not            = cmd_not,
	.Text           = cmd_text,
	.Space          = cmd_space,
	.Hspace         = cmd_hspace,
	.Phantom        = cmd_phantom,
	.Boxed          = cmd_boxed,
	.Sqrt           = cmd_sqrt,
	.Fraction       = cmd_fraction,
	.Newline        = cmd_newline,
	.Accent         = cmd_accent,
	.Over           = cmd_over,
	.Overset        = cmd_overset,
	.Under          = cmd_under,
	.Underset       = cmd_underset,
	.Xarrow         = cmd_xarrow,
	.Layout_Style   = cmd_layout,
	.Limits         = cmd_limits,
	.Begin          = cmd_begin,
	.End            = cmd_end,
}

// Run the handler of command `name`: the new insertion point and the remainder.
run_handler :: proc(
	handler: L2m_Handler,
	name: string,
	node: ^Element,
	rest: string,
) -> (
	^Element,
	string,
	Error,
) {
	result, err := HANDLERS[handler](name, node, rest)
	return result.node, result.rest, err
}

@(private = "file")
cmd_letter :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	mi := token(.Mi, value(LETTERS[:], name))
	if has_name(L2M_GREEK_CAPITALS[:], name) {
		set(mi, "class", "capital-greek")
	}
	return appended(node, mi, rest)
}

@(private = "file")
cmd_ordinary :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	return appended(node, token(.Mi, value(ORDINARY[:], name)), rest)
}

@(private = "file")
cmd_boldsymbol :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	return append_new(node, leaf(.Mrow, attrs = {{"class", "boldsymbol"}}), rest)
}

@(private = "file")
cmd_colon :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	attrs := []Attr{{"form", "postfix"}, {"lspace", "0"}, {"rspace", "0.28em"}}
	return appended(node, token(.Mo, ":", attrs), rest)
}

@(private = "file")
cmd_idotsint :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	result := parse_latex_math(node, "\\int\\dotsi\\int") or_return
	return {result, rest}, nil
}

@(private = "file")
cmd_thick_op :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	mo := token(.Mo, value(THICK_OPERATORS[:], name), {{"style", "font-weight: bold"}})
	return appended(node, mo, rest)
}

@(private = "file")
cmd_small_op :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	mo := token(.Mo, value(SMALL_OPERATORS[:], name), {{"mathsize", "75%"}})
	return appended(node, mo, rest)
}

@(private = "file")
cmd_space :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	return appended(node, space(value(SPACES[:], name)), rest)
}

@(private = "file")
cmd_phantom :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	return append_new(node, leaf(.Mphantom), rest)
}

@(private = "file")
cmd_boxed :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	attrs := []Attr{{"notation", "box"}, {"class", "boxed"}}
	return append_new(node, leaf(.Menclose, attrs = attrs), rest)
}

// ``_cmd_newline``: ``\\`` ends a table row.
@(private = "file")
cmd_newline :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	entry := leaf(.Mtd)
	parent := close(close(node) or_return) or_return
	append_child(parent, leaf(.Mtr, {entry})) or_return
	return {entry, rest}, nil
}

@(private = "file")
cmd_accent :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	accent := token(.Mo, value(ACCENTS[:], name), {{"stretchy", "false"}})
	if name == "vec" {
		set(accent, "scriptlevel", "+1") // scale down the arrow
	}
	return append_new(node, leaf(.Mover, {accent}, {{"accent", "true"}}, true), rest)
}

// ``_cmd_over``: the accent node is "textstyle", the dots on i and j are kept.
@(private = "file")
cmd_over :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	mo := token(.Mo, value(OVER[:], name), {{"accent", "true"}})
	return append_new(node, leaf(.Mover, {mo}, {{"accent", "false"}}, true), rest)
}

@(private = "file")
cmd_overset :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	return append_new(node, leaf(.Mover, switch_ = true), rest)
}

@(private = "file")
cmd_under :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	mo := token(.Mo, value(UNDER[:], name))
	return append_new(node, leaf(.Munder, {mo}, switch_ = true), rest)
}

@(private = "file")
cmd_underset :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	return append_new(node, leaf(.Munder, switch_ = true), rest)
}

// ``_cmd_limits``: ``\limits`` and co. before a script (else ignored).
@(private = "file")
cmd_limits :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	arg, remainder := tex_token(rest)
	if !strings.contains("_^", arg) {
		return {node, rest}, nil
	}
	result := handle_script_or_limit(node, arg, name) or_return
	return {result, remainder}, nil
}

@(private = "file")
cmd_begin :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	result, remainder := begin_environment(node, rest) or_return
	return {result, remainder}, nil
}

@(private = "file")
cmd_end :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	result, remainder := end_environment(node, rest) or_return
	return {result, remainder}, nil
}

@(private = "file")
value :: proc(table: []Str_Entry, name: string) -> string {
	result, _ := lookup(table, name)
	return result
}

@(private = "file")
space :: proc(width: string) -> ^Element {
	return leaf(.Mspace, attrs = {{"width", width}})
}

// ``node.append(new_node), string``.
@(private = "file")
appended :: proc(node: ^Element, new_node: ^Element, rest: string) -> (res: Handled, err: Error) {
	current := append_child(node, new_node) or_return
	return {current, rest}, nil
}

// ``_append_new``: append `new_node` and make it the insertion point.
@(private = "file")
append_new :: proc(node, new_node: ^Element, rest: string) -> (res: Handled, err: Error) {
	append_child(node, new_node) or_return
	return {new_node, rest}, nil
}

// ``_cmd_function``: a function name followed by the function application.
@(private = "file")
cmd_function :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	rest := rest
	new_node: ^Element
	if name == "operatorname" {
		arg: string
		arg, rest = tex_token_or_group(rest) or_return
		new_node = token(.Mi, arg, {{"mathvariant", "normal"}})
	} else {
		new_node = token(.Mi, value(FUNCTIONS[:], name))
	}
	switch name {
	case "varliminf":
		new_node = element(.Munder, {new_node, token(.Mo, "_")}) or_return
	case "varlimsup":
		new_node = element(.Mover, {new_node, token(.Mo, "¯")}, {{"accent", "false"}}) or_return
	case "varprojlim":
		new_node = element(.Munder, {new_node, token(.Mo, "←")}) or_return
	case "varinjlim":
		new_node = element(.Munder, {new_node, token(.Mo, "→")}) or_return
	}
	current := append_child(node, new_node) or_return
	if len(rest) > 0 && rest[0] != '^' && rest[0] != '_' {
		current = append_child(current, token(.Mo, APPLY_FUNCTION)) or_return
	}
	return {current, rest}, nil
}

// ``_cmd_modulo``: ``\bmod``, ``\pmod``, ``\mod`` and ``\pod``.
@(private = "file")
cmd_modulo :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	entry: Modulo_Entry
	for candidate in MODULO_FUNCTIONS {
		if candidate.name == name {
			entry = candidate
		}
	}
	if entry.binary {
		mo := token(.Mo, "mod", {{"lspace", entry.padding}, {"rspace", entry.padding}})
		return appended(node, mo, rest)
	}
	if node == nil {
		return {}, none_attribute("in_block")
	}
	padding := in_block(node) ? "1em" : entry.padding
	current := append_child(node, space(padding)) or_return
	if entry.parentheses {
		current = append_child(current, token(.Mo, "(", {{"stretchy", "false"}})) or_return
	}
	if entry.named {
		current = append_child(current, token(.Mi, "mod")) or_return
		current = append_child(current, space("0.333em")) or_return
	}
	arg, remainder := tex_token_or_group(rest) or_return
	current = parse_latex_math(current, arg) or_return
	if entry.parentheses {
		current = append_child(current, token(.Mo, ")", {{"stretchy", "false"}})) or_return
	}
	return {current, remainder}, nil
}

// ``_cmd_operator``: movable limits for big operators before scripts.
@(private = "file")
cmd_operator :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	attrs: []Attr
	if has_name(MOVABLE_LIMITS[:], name) && len(rest) > 0 &&
	   (rest[0] == ' ' || rest[0] == '_' || rest[0] == '^') {
		attrs = {{"movablelimits", "true"}}
	} else if name == "lvert" || name == "lVert" {
		attrs = {{"class", "mathopen"}}
	}
	return appended(node, token(.Mo, value(OPERATORS[:], name), attrs), rest)
}

// ``_cmd_bigdelimiter``: ``\left``, ``\right`` and the sized delimiters.
@(private = "file")
cmd_bigdelim :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	size := value(BIG_DELIMITERS[:], name)
	delimiter, remainder := tex_token_or_group(rest) or_return
	if !strings.contains("()[]/|.", delimiter) {
		stretchable, found := lookup(STRETCHABLES[:], strings.trim_left(delimiter, "\\"))
		if !found {
			message := strings.concatenate({
				`Unsupported "\`, name, `" delimiter "`, delimiter, `"!`,
			})
			return {}, Exception{.Math_Error, message}
		}
		delimiter = stretchable
	}
	attrs: []Attr
	if len(size) > 0 {
		attrs = {{"maxsize", size}, {"minsize", size}, {"symmetric", "true"}}
	}
	current := node
	if name == "left" || strings.has_suffix(name, "l") {
		row := leaf(.Mrow)
		append_child(current, row) or_return
		current = row
	}
	if delimiter != "." {
		append_child(current, token(.Mo, delimiter, attrs)) or_return
	}
	if name == "right" || strings.has_suffix(name, "r") {
		current = close(current) or_return
	}
	return {current, remainder}, nil
}

// ``_cmd_not``: negation overlays the next symbol with a slash.
@(private = "file")
cmd_not :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	arg, remainder := tex_token(rest)
	if arg == "{" {
		return {node, strings.concatenate({"{\\not ", remainder})}, nil
	}
	if strings.has_prefix(arg, "\\") {
		operator, found := lookup(OPERATORS[:], arg[1:])
		if !found {
			message := strings.concatenate({`"\not" cannot negate: "`, arg, `"!`})
			return {}, Exception{.Math_Error, message}
		}
		arg = operator
	}
	return appended(node, token(.Mo, nfc(strings.concatenate({arg, "\u0338"}))), remainder)
}

// ``_cmd_text``: text, with inline math between dollars.
@(private = "file")
cmd_text :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	arg, remainder := tex_token_or_group(rest) or_return
	current := node
	parts := strings.split(arg, "$")
	for part, index in parts {
		if index % 2 == 0 {
			current = append_child(current, token(.Mtext, text_margins(part))) or_return
		} else {
			parse_latex_math(current, part) or_return
		}
	}
	return {current, remainder}, nil
}

// ``re.sub("(^[ \n]|[ \n]$)", "\xa0", part)``: marginal spaces become no-break
// spaces (``$`` also matches before a final newline).
@(private = "file")
text_margins :: proc(part: string) -> string {
	runes := utf8.string_to_runes(part)
	is_margin :: proc(r: rune) -> bool {return r == ' ' || r == '\n'}
	n := len(runes)
	if n == 0 {
		return part
	}
	if is_margin(runes[0]) {
		runes[0] = 0xA0
	}
	if n > 1 && runes[n - 1] == '\n' && is_margin(runes[n - 2]) {
		runes[n - 2] = 0xA0
	}
	if is_margin(runes[n - 1]) {
		runes[n - 1] = 0xA0
	}
	return utf8.runes_to_string(runes)
}

// ``_cmd_hspace``: a space of the given width (``mu`` converted to em).
@(private = "file")
cmd_hspace :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	arg, remainder := tex_group(rest) or_return
	if strings.has_suffix(arg, "mu") {
		number := arg[:len(arg) - 2]
		parsed, ok := py_float(number)
		if !ok {
			b := strings.builder_make()
			strings.write_string(&b, "could not convert string to float: ")
			write_repr(&b, number)
			return {}, Exception{.Value_Error, strings.to_string(b)}
		}
		b := strings.builder_make()
		write_float_repr(&b, parsed / 18)
		strings.write_string(&b, "em")
		arg = strings.to_string(b)
	}
	return appended(node, space(arg), remainder)
}
