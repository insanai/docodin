package texmath

// Template-defined commands with several parameters, like ``\frac`` or ``\sqrt``
// (``_math2html_hybrid``).  The read template of an entry lists the parameters
// (``{$1}`` mandatory, ``[$0]`` optional, ``{$p!}`` literal); the write template,
// compiled by the generator into `Write_Node`s, builds the output from parameters,
// the tags ``f0``, ``f1`` ..., brackets and text.

import "core:strconv"
import "core:strings"

Param_Def :: struct {
	name:     string, // one character: "$" + name in templates
	literal:  bool,
	optional: bool,
}

Write_Kind :: enum u8 {
	Param, // `text` is the name like "$1"; `typename` (if `typed`) sets its type
	Function, // tag `index` around the next `count` nodes
	Self_Closing, // tag `index`, self-closing
	Bracket, // `text` is "(" or ")"
	Text, // `text` is one character
}

Write_Node :: struct {
	kind:     Write_Kind,
	text:     string,
	typename: string,
	typed:    bool,
	index:    int,
	count:    int,
}

Hybrid_Entry :: struct {
	name:   string,
	size:   string, // ``hybridsizes``: like "$1+$2" ("" if none)
	params: []Param_Def,
	write:  []Write_Node,
	tags:   []string, // of f0, f1, ...
}

// A parameter value read (``ParameterDefinition``).
@(private = "file")
Param :: struct {
	def:     Param_Def,
	name:    string, // "$" + def.name
	value:   ^Node,
	literal: string,
}

@(private = "file")
Hybrid :: struct {
	bit:    ^Node,
	entry:  ^Hybrid_Entry,
	params: [dynamic]Param,
}

@(private = "file")
hybrid_entry :: proc(name: string) -> ^Hybrid_Entry {
	lo, hi := 0, len(HYBRID_FUNCTIONS)
	for lo < hi {
		mid := (lo + hi) / 2
		if HYBRID_FUNCTIONS[mid].name < name {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return &HYBRID_FUNCTIONS[lo]
}

// ``HybridFunction.parsebit``.
parse_hybrid :: proc(m: ^M2h, bit: ^Node) {
	h := Hybrid {
		bit   = bit,
		entry = hybrid_entry(bit.command),
	}
	for def in h.entry.params {
		read_param(m, &h, def)
	}
	contents := write_nodes(m, &h, h.entry.write)
	clear(&bit.contents)
	append(&bit.contents, ..contents[:])
	compute_hybrid_size(m, &h)
}

// ``ParameterDefinition.read``.
@(private = "file")
read_param :: proc(m: ^M2h, h: ^Hybrid, def: Param_Def) {
	param := Param {
		def  = def,
		name = concat("$", def.name),
	}
	switch {
	case def.literal:
		found: bool
		if def.optional {
			param.literal, found = parse_square_literal(m, h.bit)
		} else {
			param.literal, found = parse_literal(m, h.bit)
		}
		if len(param.literal) > 0 {
			param.value = new_constant(param.literal)
		}
	case def.optional:
		param.value = parse_square(m, h.bit)
	case:
		param.value = parse_parameter(m, h.bit)
	}
	append(&h.params, param)
}

@(private = "file")
find_param :: proc(h: ^Hybrid, name: string) -> ^Param {
	for &param in h.params {
		if param.name == name {
			return &param
		}
	}
	return nil
}

// ``HybridFunction.writenodes``: missing parameters and empty tags are left out.
@(private = "file")
write_nodes :: proc(m: ^M2h, h: ^Hybrid, nodes: []Write_Node) -> [dynamic]^Node {
	result := make([dynamic]^Node)
	for index := 0; index < len(nodes); index += 1 {
		node := nodes[index]
		bit: ^Node
		switch node.kind {
		case .Param:
			bit = write_param(m, h, node)
		case .Function:
			bit = write_function(m, h, node.index, nodes[index + 1:][:node.count], false)
			index += node.count
		case .Self_Closing:
			bit = write_function(m, h, node.index, nil, true)
		case .Bracket:
			bit = new_bracket_command(node.text == "(" ? "left" : "right", node.text)
		case .Text:
			bit = new_constant(node.text)
		}
		if bit != nil {
			append(&result, bit)
		}
	}
	return result
}

// ``HybridFunction.writeparam``: the value of a parameter, typed if asked.
@(private = "file")
write_param :: proc(m: ^M2h, h: ^Hybrid, node: Write_Node) -> ^Node {
	param := find_param(h, node.text)
	if param == nil {
		trace_error(m, "Unknown parameter ", node.text)
		return nil
	}
	if node.typed {
		if param.value == nil {
			raise(m, none_attribute_set("type"))
			return nil
		}
		param.value.type = node.typename
	}
	return param.value
}

// ``HybridFunction.writefunction``: the bits of `contents` in tag `index`.
@(private = "file")
write_function :: proc(
	m: ^M2h,
	h: ^Hybrid,
	index: int,
	contents: []Write_Node,
	self_closing: bool,
) -> ^Node {
	tag := read_tag(m, h, index)
	if len(tag) == 0 {
		return nil
	}
	if self_closing {
		bit := new_node(.Tagged_Bit)
		set_tag(bit, tag, self_closing = true)
		return bit
	}
	bits := write_nodes(m, h, contents)
	if len(bits) == 0 {
		return nil
	}
	return tagged_complete(bits[:], tag)
}

// ``HybridFunction.readtag``: the tag of function `index`, with the literal
// parameters substituted.
@(private = "file")
read_tag :: proc(m: ^M2h, h: ^Hybrid, index: int) -> string {
	if index >= len(h.entry.tags) {
		trace_error(m, "Function f", int_string(index), " is not defined")
		return ""
	}
	tag := h.entry.tags[index]
	for param in h.params {
		if !strings.contains(tag, param.name) {
			continue
		}
		if !param.def.literal {
			trace_error(m, "Parameters in tag ", tag, " should be literal: {", param.name, "!}")
			continue
		}
		tag, _ = strings.replace_all(tag, param.name, param.literal)
	}
	return tag
}

int_string :: proc(value: int) -> string {
	buf: [24]byte
	return strings.clone(strconv.write_int(buf[:], i64(value), 10))
}

// ``HybridFunction.computehybridsize``: stacking functions give their size to
// all their top-level bits.
@(private = "file")
compute_hybrid_size :: proc(m: ^M2h, h: ^Hybrid) {
	if len(h.entry.size) == 0 {
		compute_size(h.bit)
		return
	}
	size := hybrid_size(m, h)
	h.bit.size = size
	for element in h.bit.contents {
		element.size = size
	}
}

// ``HybridSize.getsize``: evaluate a size expression like ``$1+$2+1``.
@(private = "file")
hybrid_size :: proc(m: ^M2h, h: ^Hybrid) -> int {
	expression := h.entry.size
	for param in h.params {
		if !strings.contains(expression, param.name) {
			continue
		}
		if param.value == nil {
			raise(m, none_attribute("computesize"))
			return 1
		}
		size := int_string(compute_size(param.value))
		expression, _ = strings.replace_all(expression, param.name, size)
	}
	if strings.contains_rune(expression, '$') {
		trace_error(m, "Unconverted variable in hybrid size: ", expression)
		return 1
	}
	total := 0
	for term in strings.split_iterator(&expression, "+") {
		value, _ := strconv.parse_int(term)
		total += value
	}
	return total
}
