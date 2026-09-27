package texmath

// The handlers of ``latex2mathml`` for layout schemata and fonts: roots,
// fractions, extensible arrows, layout styles and math alphabets.

import "core:strings"

// ``_cmd_sqrt``: ``\sqrt[radix]{...}``.
cmd_sqrt :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	radix, remainder := tex_optarg(rest) or_return
	new_node: ^Element
	if len(radix) > 0 {
		index_node := leaf(.Mrow)
		new_node = leaf(.Mroot, {index_node}, switch_ = true)
		parse_latex_math(index_node, radix) or_return
		close(index_node) or_return
	} else {
		new_node = leaf(.Msqrt)
	}
	append_child(node, new_node) or_return
	return {new_node, remainder}, nil
}

// ``_cmd_fraction``: fractions and binomials (``\cfrac[l]`` aligns the numerator).
cmd_fraction :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	rest := rest
	attrs := fraction_attrs(name)
	if name == "cfrac" {
		optarg: string
		optarg, rest = tex_optarg(rest) or_return
		if optarg == "l" || optarg == "r" {
			align := optarg == "l" ? "left" : "right"
			copied := make([dynamic]Attr)
			for attr in attrs {
				value := attr.value
				if attr.key == "class" {
					value = strings.concatenate({value, " numalign-", align})
				}
				append(&copied, Attr{attr.key, value})
			}
			append(&copied, Attr{"numalign", align})
			attrs = copied[:]
		}
	}
	frac := leaf(.Mfrac, attrs = attrs)
	new_node := frac
	if strings.has_suffix(name, "binom") {
		children := []^Element{token(.Mo, "("), frac, token(.Mo, ")")}
		new_node = leaf(.Mrow, children, {{"class", "binom"}})
		new_node.nchildren = 3
	}
	append_child(node, new_node) or_return
	return {frac, rest}, nil
}

fraction_attrs :: proc(name: string) -> []Attr {
	for entry in FRACTIONS {
		if entry.name == name {
			return entry.attrs
		}
	}
	return nil
}

// ``_cmd_xarrow``: ``\xleftarrow[below]{above}``.
cmd_xarrow :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	subscript, remainder := tex_optarg(rest) or_return
	operator, _ := lookup(OPERATORS[:], strings.concatenate({"long", name[1:]}))
	base := token(.Mo, operator)
	new_node: ^Element
	if len(subscript) > 0 {
		new_node = leaf(.Munderover, {base})
		sub_node := parse_latex_math(leaf(.Mrow), subscript) or_return
		if len(sub_node.children) == 1 {
			sub_node = sub_node.children[0]
		}
		append_child(new_node, sub_node) or_return
	} else {
		new_node = leaf(.Mover, {base})
	}
	append_child(node, new_node) or_return
	return {new_node, remainder}, nil
}

// ``_cmd_layout_style``: ``\displaystyle`` and co. set attributes of the group.
cmd_layout :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	if (length(node) or_return) > 0 {
		message := strings.concatenate({
			`Declaration "\`, name, `" must be first command in a group!`,
		})
		return {}, Exception{.Math_Error, message}
	}
	for entry in LAYOUT_STYLES {
		if entry.name == name {
			for attr in entry.attrs {
				set(node, attr.key, attr.value)
			}
		}
	}
	return {node, rest}, nil
}

// ``handle_math_alphabet``: ``\mathbb{R}`` and co. map characters to the
// Mathematical Alphanumeric Symbols.
cmd_alphabet :: proc(name: string, node: ^Element, rest: string) -> (res: Handled, err: Error) {
	arg, remainder := tex_token_or_group(rest) or_return
	if name == "mathrm" && str_isalpha(arg) && cp_len(arg) > 1 {
		current := append_child(node, token(.Mi, arg)) or_return // "normal" font
		return {current, remainder}, nil
	}
	attrs: []Attr
	if name == "mathscr" {
		attrs = {{"class", "mathscr"}}
	}
	container := leaf(.Mrow, attrs = attrs)
	append_child(node, container) or_return
	parse_latex_math(container, arg) or_return
	table := alphabet(name)
	convert_alphabet(container, table, name == "mathrm")
	current := close(container) or_return
	return {current, remainder}, nil
}

// The ``mathalphabet2unichar`` table of a math alphabet command.
@(private = "file")
alphabet :: proc(name: string) -> []Str_Entry {
	key := name
	switch name {
	case "mathscr":
		key = "mathcal"
	case "mathbfsfit":
		key = "mathsfbfit"
	}
	for alphabet_name, index in ALPHABET_NAMES {
		if alphabet_name == key {
			return ALPHABET_TABLES[index]
		}
	}
	return nil
}

// Map the characters of numbers and single-letter identifiers (``iter()``).
@(private = "file")
convert_alphabet :: proc(e: ^Element, table: []Str_Entry, mathrm: bool) {
	#partial switch e.tag {
	case .Mn:
		b := strings.builder_make()
		for r, offset in e.text {
			char := e.text[offset:offset + cp_offset(e.text[offset:], 1)]
			mapped, found := lookup(table, char)
			strings.write_string(&b, found ? mapped : char)
			_ = r
		}
		e.text = strings.to_string(b)
	case .Mi:
		if mapped, found := lookup(table, e.text); found {
			e.text = mapped
		}
		if mathrm && str_isalpha(e.text) {
			set(e, "mathvariant", "normal")
		}
	}
	for child in e.children {
		convert_alphabet(child, table, mathrm)
	}
}
