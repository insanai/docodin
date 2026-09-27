package reader

import "core:strings"

import dt "../doctree"
import rst "../rst"

// The ``meta`` directive (``directives.misc.Meta`` with its ``MetaBody``
// state): ``meta`` elements inserted at the start of the document.

META := Directive_Spec {
	has_content = true,
	run         = run_meta,
}

@(private = "file")
run_meta :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	doc := c.doc
	if err := assert_has_content(d); err != nil do return nil, err
	node := dt.new_element(doc, .Element)
	stop, complete := meta_body(c, d, node)
	// where the nested state machine left the document: past the end, or
	// back on the line before the first line that is not a field
	if complete {
		n := sl_len(d.content)
		doc.current_source, doc.current_line = d.content.items[n - 1].source, nil
	} else {
		info, _, _ := sl_info(d.content, stop - 1)
		doc.current_source, doc.current_line = info.source, info.offset + 1
	}
	if !complete {
		lit := dt.new_element(doc, .literal_block, d.block_text, d.block_text)
		msg := dt.error(doc, "Invalid meta directive.", {children = {lit}, line = d.lineno})
		dt.append_child(doc, node, msg)
	}
	// insert at the beginning of the document
	index := dt.first_child_not_matching_class(doc, doc.root, dt.tags_of(.Titular) + {.meta})
	dt.insert_children(doc, doc.root, max(index, 0), dt.children(doc, node, c.allocator))
	return nil, nil
}

// The ``MetaBody`` state over the content: field markers become ``meta``
// elements (or messages); ``complete`` is false when a line (``stop``)
// is not a field.
@(private = "file")
meta_body :: proc(c: ^Context, d: ^Directive, node: dt.Node) -> (stop: int, complete: bool) {
	lines := d.content.data[:]
	for i := 0; i < len(lines); {
		line := lines[i]
		if is_blank(line) {
			i += 1
			continue
		}
		name, mend, ok := rst.match_field_marker(line)
		if line[0] == ' ' || !ok do return i, false
		end, indent, _ := field_block(lines, i + 1)
		block := make([dynamic]string, c.allocator)
		append(&block, line[mend:])
		for ln in lines[i + 1:end] do append(&block, cp_slice(ln, indent))
		// strip_top: leading blank lines are dropped
		first := 0
		for first < len(block) && is_blank(block[first]) do first += 1
		// ``state_machine.line``: the last line of the field
		dt.append_child(c.doc, node, parse_meta(c, name, block[first:], lines[end - 1]))
		i = end
	}
	return len(lines), true
}

// ``MetaBody.parsemeta``: a ``meta`` element or a message.
@(private = "file")
parse_meta :: proc(c: ^Context, raw_name: string, indented: []string, line: string) -> dt.Node {
	doc := c.doc
	name := dt.unescape(rst.escape2null(raw_name, c.allocator))
	meta := dt.new_element(doc, .meta)
	content := strings.join(indented, " ", c.allocator)
	dt.set_attr(doc, meta, "content", dt.unescape(rst.escape2null(content, c.allocator)))
	if len(indented) == 0 {
		lit := dt.new_element(doc, .literal_block, line, line)
		return dt.info(doc, concat("No content for meta tag \"", name, "\"."), {children = {lit}})
	}
	tokens := dt.py_split(name, c.allocator)
	for token, i in tokens {
		attname, value, err := extract_name_value(c, token)
		switch {
		case err == "":
			dt.set_attr(doc, meta, dt.py_lower(attname, c.allocator), value)
		case i == 0:
			dt.set_attr(doc, meta, "name", token)
		case:
			lit := dt.new_element(doc, .literal_block, line, line)
			text := concat("Error parsing meta tag attribute \"", token, "\": ", err, ".")
			return dt.error(doc, text, {children = {lit}})
		}
	}
	return meta
}

// The first pair of ``utils.extract_name_value(text)``, or the
// ``NameValueError`` text.
@(private = "file")
extract_name_value :: proc(c: ^Context, text: string) -> (name, value, err: string) {
	line := text
	pairs := 0
	for line != "" {
		eq := strings.index_byte(line, '=')
		if eq < 0 do return "", "", "missing \"=\""
		attname := strip(line[:eq])
		if eq == 0 || attname == "" do return "", "", "missing attribute name before \"=\""
		line = lstrip(line[eq + 1:])
		if line == "" do return "", "", concat("missing value after \"", attname, "=\"")
		data: string
		data, line, err = name_value_data(attname, line)
		if err != "" do return "", "", err
		if pairs == 0 do name, value = dt.py_lower(attname, c.allocator), data
		pairs += 1
	}
	return
}

// The value at the start of ``line`` (quoted or up to a space) and the rest.
@(private = "file")
name_value_data :: proc(attname, line: string) -> (data, rest, err: string) {
	quote := line[0]
	if quote != '\'' && quote != '"' {
		space := strings.index_byte(line, ' ')
		if space < 0 do return line, "", ""
		return line[:space], lstrip(line[space + 1:]), ""
	}
	end := strings.index_byte(line[1:], quote)
	q := string([]u8{quote})
	if end < 0 do return "", "", concat("attribute \"", attname, "\" missing end quote (", q, ")")
	end += 1
	if end + 1 < len(line) && !is_blank(line[end + 1:end + 2]) {
		return "", "", concat(
			"attribute \"", attname, "\" end quote (", q, ") not followed by whitespace",
		)
	}
	return line[1:end], lstrip(line[end + 1:]), ""
}

// ``get_first_known_indented`` over the lines after a field marker: the
// end of the field, the common indent and whether a blank line ends it.
@(private = "file")
field_block :: proc(lines: []string, start: int) -> (end: int, indent: int, blank_finish: bool) {
	end = start
	indent = -1
	for end < len(lines) {
		ln := lines[end]
		if len(ln) > 0 && ln[0] != ' ' do return end, max(indent, 0), is_blank(lines[end - 1])
		if stripped := lstrip(ln); stripped != "" {
			li := cp_len(ln) - cp_len(stripped)
			indent = li if indent < 0 else min(indent, li)
		}
		end += 1
	}
	return end, max(indent, 0), true
}
