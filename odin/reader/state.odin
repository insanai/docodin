package reader

import dt "../doctree"

// Methods of docutils' ``Body`` state that directives call on
// ``self.state``: ``block_quote`` with the attribution rules.

// ``Body.block_quote(indented, line_offset)``: the block quotes (with
// attributions) and messages.
block_quote :: proc(
	c: ^Context,
	sm: ^Machine,
	indented_in: ^String_List,
	line_offset_in: int,
) -> [dynamic]dt.Node {
	doc := c.doc
	elements := make([dynamic]dt.Node, c.allocator)
	indented := indented_in
	line_offset := line_offset_in
	for indented != nil && sl_len(indented) > 0 {
		bq := dt.new_element(doc, .block_quote, sl_join(indented, c.allocator))
		src, ln, _ := get_source_and_line(c, sm, line_offset + 1)
		dt.set_source(doc, bq, src)
		dt.set_line(doc, bq, ln)
		split := split_attribution(indented, line_offset)
		nested_parse(c, sm, split.quote, line_offset, bq)
		append(&elements, bq)
		if split.attribution != nil {
			attribution, messages := parse_attribution(
				c, sm, split.attribution, line_offset + split.attribution_offset,
			)
			dt.append_child(doc, bq, attribution)
			append(&elements, ..messages[:])
		}
		line_offset = split.new_line_offset
		indented = split.rest
		for indented != nil && sl_len(indented) > 0 && indented.data[0] == "" {
			indented = sl_slice(indented, 1)
			line_offset += 1
		}
	}
	return elements
}

@(private = "file")
Attribution_Split :: struct {
	quote:              ^String_List,
	attribution:        ^String_List, // nil: none
	attribution_offset: int,
	rest:               ^String_List, // nil: none
	new_line_offset:    int,
}

// ``Body.split_attribution``.
@(private = "file")
split_attribution :: proc(indented: ^String_List, line_offset: int) -> Attribution_Split {
	blank := -2
	nonblank_seen := false
	for i in 0 ..< sl_len(indented) {
		line := rstrip(indented.data[i])
		if line == "" {
			blank = i
			continue
		}
		if nonblank_seen && blank == i - 1 { 	// last line blank
			if mend, ok := match_attribution(line); ok {
				attribution_end, indent, shaped := check_attribution(indented, i)
				if shaped {
					a_lines := sl_slice(indented, i, attribution_end)
					sl_trim_left(a_lines, mend, end = 1)
					sl_trim_left(a_lines, indent, start = 1)
					return {
						quote = sl_slice(indented, 0, i),
						attribution = a_lines,
						attribution_offset = i,
						rest = sl_slice(indented, attribution_end),
						new_line_offset = line_offset + attribution_end,
					}
				}
			}
		}
		nonblank_seen = true
	}
	return {quote = indented}
}

// ``attribution_pattern``: ``(---?(?!-)|—) *(?=[^ \n])``; the end of
// the match (in code points).
@(private = "file")
match_attribution :: proc(line: string) -> (end: int, ok: bool) {
	i := 0
	cps := 0
	switch {
	case has_prefix(line, "—"):
		i, cps = len("—"), 1
	case has_prefix(line, "---") && !has_prefix(line, "----"):
		i, cps = 3, 3
	case has_prefix(line, "--") && !has_prefix(line, "---"):
		i, cps = 2, 2
	case:
		return 0, false
	}
	for i < len(line) && line[i] == ' ' {
		i += 1
		cps += 1
	}
	if i >= len(line) || line[i] == '\n' do return 0, false
	return cps, true
}

// ``Body.check_attribution``: the index past the end of the attribution
// and its indent (``shaped`` false: not an attribution).
@(private = "file")
check_attribution :: proc(
	indented: ^String_List,
	start: int,
) -> (end: int, indent: int, shaped: bool) {
	indent = -1
	i := start + 1
	// Python's for-else leaves ``i`` one further when the loop is empty
	if i >= sl_len(indented) do return i + 1, 0, true
	for ; i < sl_len(indented); i += 1 {
		line := rstrip(indented.data[i])
		if line == "" do return i, max(indent, 0), true
		li := cp_len(line) - cp_len(lstrip(line))
		if indent < 0 {
			indent = li
		} else if li != indent {
			return 0, 0, false // bad shape; not an attribution
		}
	}
	return i, max(indent, 0), true
}

// ``Body.parse_attribution``.
@(private = "file")
parse_attribution :: proc(
	c: ^Context,
	sm: ^Machine,
	lines: ^String_List,
	line_offset: int,
) -> (
	dt.Node,
	[dynamic]dt.Node,
) {
	text := rstrip(sl_join(lines, c.allocator))
	lineno := 1 + line_offset
	textnodes, messages := inline_text(c, text, lineno, sm.node)
	node := element(c, .attribution, text, textnodes[:])
	src, ln, _ := get_source_and_line(c, sm, lineno)
	dt.set_source(c.doc, node, src)
	dt.set_line(c.doc, node, ln)
	return node, messages
}
