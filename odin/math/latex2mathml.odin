package texmath

// LaTeX math to presentational MathML: a port of
// ``docutils.utils.math.latex2mathml``.  The parser walks the source and keeps an
// insertion point in the element tree (`mathml_tree.odin`); commands are handled
// in `l2m_commands.odin`.  Errors are the exceptions of docutils: a ``MathError``
// with docutils' message for invalid input, or the Python error that some input
// provokes in docutils (like appending to None).

import "core:mem/virtual"
import "core:strings"
import "core:unicode/utf8"

MATHML_NAMESPACE :: "http://www.w3.org/1998/Math/MathML"

Modulo_Entry :: struct {
	name:                         string,
	binary, named, parentheses:   bool,
	padding:                      string,
}

Matrix_Entry :: struct {
	name, left, right: string,
}

Attrs_Entry :: struct {
	name:  string,
	attrs: []Attr,
}

// ``latex2mathml.tex2mathml``: the MathML code for `tex`, a ``<math>`` element
// (with ``display="block"`` if `as_block`).  On error, `mathml` is empty.
tex2mathml :: proc(
	tex: string,
	as_block := false,
	allocator := context.allocator,
) -> (
	mathml: string,
	err: Error,
) {
	scratch: Scratch
	if !scratch_begin(&scratch) {
		return "", nil
	}
	defer scratch_end(&scratch)
	context.allocator = virtual.arena_allocator(&scratch.arena)
	root, failure := build_mathml(tex, as_block)
	if failure != nil {
		return "", clone_error(failure, allocator)
	}
	indent_xml(root)
	b := strings.builder_make()
	to_xml(root, &b)
	return strings.clone(strings.to_string(b), allocator), nil
}

@(private = "file")
build_mathml :: proc(tex: string, as_block: bool) -> (root: ^Element, err: Error) {
	root = element(.Math, attrs = {{"xmlns", MATHML_NAMESPACE}}) or_return
	node := root
	if as_block {
		set(root, "display", "block")
		if strings.contains(toplevel_code(tex), "\\\\") {
			// emulate an "align*" environment with a math table
			node = element(.Mtd) or_return
			row := element(.Mtr, {node}) or_return
			attrs := []Attr{{"class", "ams-align"}, {"displaystyle", "true"}}
			append_child(root, element(.Mtable, {row}, attrs) or_return) or_return
		}
	}
	parse_latex_math(node, tex) or_return
	if tree_depth(root) > MAX_DEPTH {
		return nil, RECURSION_ERROR
	}
	return root, nil
}

// The nesting of `parse_latex_math` (for ``\text{$...$}`` and co.).
@(private = "file", thread_local)
nesting: int

// ``parse_latex_math``: append the MathML of `source` to `root` and return it.
parse_latex_math :: proc(root: ^Element, source: string) -> (result: ^Element, err: Error) {
	nesting += 1
	defer nesting -= 1
	if nesting > MAX_DEPTH {
		return nil, RECURSION_ERROR
	}
	rest := source // the part not yet handled
	node := root // the insertion point
	for len(rest) > 0 {
		c, size := utf8.decode_rune_in_string(rest)
		rest = rest[size:]
		if c == ' ' || c == '\n' {
			continue // white space is ignored in math mode
		}
		node, rest = parse_char(c, node, rest) or_return
		if node == nil {
			if len(rest) == 0 {
				return root, nil // ignore unbalanced braces
			}
			done := source[:cp_offset(source, max(cp_len(source) - cp_len(rest), 0))]
			message := strings.concatenate({
				`No insertion point for "`, rest, `". Unbalanced braces in "`, done, `"?`,
			})
			return nil, Exception{.Math_Error, message}
		}
	}
	if node == nil {
		return nil, none_attribute("nchildren")
	}
	if node.nchildren > 0 && len(node.children) < node.nchildren {
		return nil, Exception{.Math_Error, "Last node missing children. Source incomplete?"}
	}
	return root, nil
}

// ``_parse_char``: process character `c`; return the new insertion point and
// the remainder.
@(private = "file")
parse_char :: proc(c: rune, node: ^Element, rest: string) -> (^Element, string, Error) {
	current: ^Element
	err: Error
	switch {
	case c == '\\':
		name, remainder := tex_cmdname(rest)
		return handle_cmd(name, node, remainder)
	case c == '_' || c == '^':
		current, err = handle_script_or_limit(node, c == '_' ? "_" : "^")
	case c == '{':
		current, err = open_group(node)
	case c == '}':
		current, err = close(node)
	case c == '&':
		current, err = new_cell(node)
	case is_digit(c):
		number, remainder := tex_number(rest)
		text := strings.concatenate({utf8.runes_to_string({c}), number})
		current, err = append_child(node, token(.Mn, text))
		return current, remainder, err
	case:
		current, err = parse_symbol(c, node)
	}
	return current, rest, err
}

// ``_open_group``: a group; an element taking one argument takes the group.
@(private = "file")
open_group :: proc(node: ^Element) -> (res: ^Element, err: Error) {
	if node != nil && node.tag in ROW_TAGS && node.nchildren == 1 {
		node.nchildren = NO_LIMIT // allow appending until closed by '}'
		return node, nil
	}
	row, _ := element(.Mrow)
	append_child(node, row) or_return
	return row, nil
}

// ``_new_cell``: "&" starts a new table cell.
@(private = "file")
new_cell :: proc(node: ^Element) -> (res: ^Element, err: Error) {
	cell, _ := element(.Mtd)
	parent := close(node) or_return
	append_child(parent, cell) or_return
	return cell, nil
}

// ``_parse_symbol``: the element for a letter or symbol character.
@(private = "file")
parse_symbol :: proc(c: rune, node: ^Element) -> (res: ^Element, err: Error) {
	char := utf8.runes_to_string({c})
	if is_alpha(c) {
		return append_child(node, token(.Mi, char))
	}
	if _, anomalous := lookup(ANOMALOUS_CHARS[:], char); anomalous {
		return anomalous_char(char, node)
	}
	if strings.contains_rune("/()[]|", c) {
		return append_child(node, token(.Mo, char, {{"stretchy", "false"}}))
	}
	if strings.contains_rune("+*=<>,.!?`';@", c) {
		return append_child(node, token(.Mo, char))
	}
	message := strings.concatenate({`Unsupported character: "`, char, `"!`})
	return nil, Exception{.Math_Error, message}
}

// ``_anomalous_char``: a character with a preferred alternative in math (a
// minus after an opening bracket or relation is a prefix operator).
@(private = "file")
anomalous_char :: proc(char: string, node: ^Element) -> (res: ^Element, err: Error) {
	alternative, _ := lookup(ANOMALOUS_CHARS[:], char)
	attrs: []Attr
	if char == "-" && (length(node) or_return) > 0 {
		previous := node.children[len(node.children) - 1]
		text := previous.text
		class, _ := get(previous, "class")
		if (len(text) > 0 && strings.contains("([=", text)) || class == "mathopen" {
			attrs = {{"form", "prefix"}}
		}
	}
	return append_child(node, token(.Mo, alternative, attrs))
}

// ``handle_cmd``: process command `name` followed by `rest`.
@(private = "file")
handle_cmd :: proc(name: string, node: ^Element, rest: string) -> (^Element, string, Error) {
	handler, found := command_handler(name)
	if !found {
		if !strings.has_suffix(name, "limits") {
			message := strings.concatenate({`Unknown LaTeX command "\`, name, `".`})
			return nil, "", Exception{.Math_Error, message}
		}
		handler = .Limits
	}
	return run_handler(handler, name, node, rest)
}

@(private = "file")
command_handler :: proc(name: string) -> (L2m_Handler, bool) {
	lo, hi := 0, len(L2M_COMMANDS)
	for lo < hi {
		mid := (lo + hi) / 2
		if L2M_COMMANDS[mid].name < name {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(L2M_COMMANDS) && L2M_COMMANDS[lo].name == name {
		return L2M_COMMANDS[lo].handler, true
	}
	return nil, false
}

// ``handle_script_or_limit``: a script or limit element for the last child.
handle_script_or_limit :: proc(
	node: ^Element,
	c: string,
	limits := "",
) -> (
	new_node: ^Element,
	err: Error,
) {
	child := pop(node) or_return
	if limits == "limits" {
		set(child, "movablelimits", "false")
	} else if limits == "movablelimits" ||
	   (child.tag in TOKEN_TAGS && has_name(MOVABLE_LIMITS[:], child.text)) {
		set(child, "movablelimits", "true")
	}
	switch c {
	case "_":
		new_node = subscript(child, limits) or_return
	case "^":
		new_node = superscript(child, limits) or_return
	case:
		return nil, Exception{.Unbound_Local_Error, UNBOUND_NEW_NODE}
	}
	append_child(node, new_node) or_return
	return new_node, nil
}

@(private = "file")
UNBOUND_NEW_NODE ::
	"cannot access local variable 'new_node' where it is not associated with a value"

// The element for `child` with a subscript or limit below.
@(private = "file")
subscript :: proc(child: ^Element, limits: string) -> (^Element, Error) {
	switch {
	case child.tag == .Mover:
		return element(.Munderover, child.children[:], switch_ = true)
	case child.tag == .Msup:
		return element(.Msubsup, child.children[:], switch_ = true)
	case with_limits(child, limits):
		return element(.Munder, {child})
	}
	return element(.Msub, {child})
}

// The element for `child` with a superscript or limit above.
@(private = "file")
superscript :: proc(child: ^Element, limits: string) -> (^Element, Error) {
	switch {
	case child.tag == .Munder:
		return element(.Munderover, child.children[:])
	case child.tag == .Msub:
		return element(.Msubsup, child.children[:])
	case with_limits(child, limits):
		return element(.Mover, {child})
	}
	return element(.Msup, {child})
}

@(private = "file")
with_limits :: proc(child: ^Element, limits: string) -> bool {
	if limits == "limits" || limits == "movablelimits" {
		return true
	}
	value, found := get(child, "movablelimits")
	return limits == "" && found && len(value) > 0
}

// ``begin_environment``: a table for a matrix environment.
begin_environment :: proc(
	node: ^Element,
	rest: string,
) -> (
	res: ^Element,
	remainder: string,
	err: Error,
) {
	name: string
	name, remainder = tex_group(rest) or_return
	fences, found := matrix_entry(name)
	if !found {
		message := strings.concatenate({`Environment "`, name, `" not supported!`})
		return nil, "", Exception{.Math_Error, message}
	}
	node := node
	attrs := make([dynamic]Attr)
	if len(fences.left) > 0 {
		fence_attrs: []Attr
		if name == "cases" {
			fence_attrs = {{"rspace", "0.17em"}}
			append(&attrs, Attr{"columnalign", "left"}, Attr{"class", "cases"})
		}
		wrapper := element(.Mrow, {token(.Mo, fences.left, fence_attrs)}) or_return
		append_child(node, wrapper) or_return
		node = wrapper
	} else if name == "smallmatrix" {
		append(&attrs, Attr{"rowspacing", "0.02em"}, Attr{"columnspacing", "0.333em"})
		append(&attrs, Attr{"scriptlevel", "1"})
	} else if name == "aligned" {
		append(&attrs, Attr{"class", "ams-align"})
	}
	entry := element(.Mtd) or_return
	row := element(.Mtr, {entry}) or_return
	append_child(node, element(.Mtable, {row}, attrs[:]) or_return) or_return
	return entry, remainder, nil
}

// ``end_environment``: close the cell, row and table (and the fences).
end_environment :: proc(
	node: ^Element,
	rest: string,
) -> (
	res: ^Element,
	remainder: string,
	err: Error,
) {
	name: string
	name, remainder = tex_group(rest) or_return
	fences, found := matrix_entry(name)
	if !found {
		message := strings.concatenate({`Environment "`, name, `" not supported!`})
		return nil, "", Exception{.Math_Error, message}
	}
	current := close(close(close(node) or_return) or_return) or_return
	if len(fences.right) > 0 {
		current = append_child(current, token(.Mo, fences.right)) or_return
		current = close(current) or_return
	} else if name == "cases" {
		current = close(current) or_return
	}
	return current, remainder, nil
}

@(private = "file")
matrix_entry :: proc(name: string) -> (Matrix_Entry, bool) {
	for entry in MATRICES {
		if entry.name == name {
			return entry, true
		}
	}
	return {}, false
}
