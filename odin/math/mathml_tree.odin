package texmath

// MathML elements (``docutils.utils.math.mathml_elements``): an element tree
// with the insertion-point logic of the converter.  An element expects a number of
// children (`nchildren`); appending to a full element raises, and an element
// becoming full closes: the insertion point moves to the first ancestor that
// is not full.  Serialization is ``xml.etree.ElementTree``'s, after ``indent``.
//
// Python's None is nil: a method called on it raises an AttributeError.

import "core:strings"

Tag :: enum u8 {
	Math,
	Mtext,
	Mi,
	Mn,
	Mo,
	Mspace,
	Mrow,
	Mfrac,
	Msqrt,
	Mroot,
	Mstyle,
	Merror,
	Menclose,
	Mpadded,
	Mphantom,
	Msub,
	Msup,
	Msubsup,
	Munder,
	Mover,
	Munderover,
	Mtable,
	Mtr,
	Mtd,
}

@(rodata)
TAG_NAMES := [Tag]string {
	.Math       = "math",
	.Mtext      = "mtext",
	.Mi         = "mi",
	.Mn         = "mn",
	.Mo         = "mo",
	.Mspace     = "mspace",
	.Mrow       = "mrow",
	.Mfrac      = "mfrac",
	.Msqrt      = "msqrt",
	.Mroot      = "mroot",
	.Mstyle     = "mstyle",
	.Merror     = "merror",
	.Menclose   = "menclose",
	.Mpadded    = "mpadded",
	.Mphantom   = "mphantom",
	.Msub       = "msub",
	.Msup       = "msup",
	.Msubsup    = "msubsup",
	.Munder     = "munder",
	.Mover      = "mover",
	.Munderover = "munderover",
	.Mtable     = "mtable",
	.Mtr        = "mtr",
	.Mtd        = "mtd",
}

// ``MathRow`` subclasses: the contents form one row.
ROW_TAGS :: bit_set[Tag]{
	.Math,
	.Mrow,
	.Msqrt,
	.Mstyle,
	.Merror,
	.Menclose,
	.Mpadded,
	.Mphantom,
	.Mtr,
	.Mtd,
}
// ``MathSchema`` subclasses: two or more children.
SCHEMA_TAGS :: bit_set[Tag]{.Mfrac, .Mroot, .Msub, .Msup, .Msubsup, .Munder, .Mover, .Munderover}
// ``MathToken`` subclasses: text instead of children.
TOKEN_TAGS :: bit_set[Tag]{.Mtext, .Mi, .Mn, .Mo}

NO_LIMIT :: -1 // ``nchildren = None``

Attr :: struct {
	key, value: string,
}

Element :: struct {
	tag:       Tag,
	switch_:   bool, // the last two children are reversed (``switch``)
	nchildren: int, // expected number of children, or NO_LIMIT
	text:      string,
	tail:      string,
	attrs:     [dynamic]Attr, // in insertion order
	children:  [dynamic]^Element,
	parent:    ^Element,
}

@(private = "file")
default_nchildren :: proc(tag: Tag) -> int {
	switch {
	case tag in TOKEN_TAGS || tag == .Mspace:
		return 0
	case tag == .Msqrt || tag == .Menclose || tag == .Mphantom:
		return 1
	case tag == .Msubsup || tag == .Munderover:
		return 3
	case tag in SCHEMA_TAGS:
		return 2
	}
	return NO_LIMIT
}

// A new element with `children` appended and `attrs` set (the constructor).
element :: proc(
	tag: Tag,
	children: []^Element = nil,
	attrs: []Attr = nil,
	switch_ := false,
) -> (
	e: ^Element,
	err: Error,
) {
	e = new(Element)
	e.tag = tag
	e.nchildren = default_nchildren(tag)
	e.switch_ = switch_
	for attr in attrs {
		set(e, attr.key, attr.value)
	}
	for child in children {
		append_child(e, child) or_return
	}
	return e, nil
}

// `element` where the construction cannot fail (at most a full set of children).
leaf :: proc(
	tag: Tag,
	children: []^Element = nil,
	attrs: []Attr = nil,
	switch_ := false,
) -> ^Element {
	e, _ := element(tag, children, attrs, switch_)
	return e
}

// A new token element with `text`.
token :: proc(tag: Tag, text: string, attrs: []Attr = nil) -> ^Element {
	e, _ := element(tag, attrs = attrs)
	e.text = text
	return e
}

// ``element.set(key, value)``: replace a value in place or add it at the end.
set :: proc(e: ^Element, key, value: string) {
	for &attr in e.attrs {
		if attr.key == key {
			attr.value = value
			return
		}
	}
	append(&e.attrs, Attr{key, value})
}

// ``element.get(key)``.
get :: proc(e: ^Element, key: string) -> (string, bool) {
	for attr in e.attrs {
		if attr.key == key {
			return attr.value, true
		}
	}
	return "", false
}

is_full :: proc(e: ^Element) -> bool {
	return e.nchildren != NO_LIMIT && len(e.children) >= e.nchildren
}

// ``MathElement.append``: append `child` and return the new insertion point.
append_child :: proc(e: ^Element, child: ^Element) -> (current: ^Element, err: Error) {
	if e == nil {
		return nil, none_attribute("append")
	}
	if is_full(e) {
		status := "does not take children"
		if e.nchildren > 0 {
			status = strings.concatenate({"takes only ", int_string(e.nchildren), " children"})
		}
		message := strings.concatenate({`Element "`, describe_element(e), `" `, status, "."})
		return nil, Exception{.Type_Error, message}
	}
	append(&e.children, child)
	child.parent = e
	current = e
	if is_full(e) {
		current = close(e) or_return
	}
	if e.switch_ && e.tag in SCHEMA_TAGS && is_full(e) {
		n := len(e.children)
		e.children[n - 1], e.children[n - 2] = e.children[n - 2], e.children[n - 1]
		e.switch_ = false
	}
	return current, nil
}

// ``MathElement.close``, or ``mrow.close`` (which replaces a row of one child
// by the child): mark `e` full, return the first ancestor that is not full.
close :: proc(e: ^Element) -> (res: ^Element, err: Error) {
	if e == nil {
		return nil, none_attribute("close")
	}
	if e.tag == .Mrow && e.parent != nil && len(e.children) == 1 {
		index := -1
		for sibling, position in e.parent.children {
			if sibling == e {
				index = position
				break
			}
		}
		if index < 0 {
			return nil, nil // ValueError, caught
		}
		child := e.children[0]
		e.parent.children[index] = child
		child.parent = e.parent
		transfer_attributes(e, child)
	}
	e.nchildren = len(e.children)
	parent := e.parent
	for parent != nil && is_full(parent) {
		parent = parent.parent
	}
	return parent, nil
}

// ``mrow.transfer_attributes``: class and style values are appended.
@(private = "file")
transfer_attributes :: proc(e: ^Element, other: ^Element) {
	for attr in e.attrs {
		value := attr.value
		existing, found := get(other, attr.key)
		if (attr.key == "class" || attr.key == "style") && len(value) > 0 && found &&
		   len(existing) > 0 {
			delimiter := attr.key == "class" ? " " : "; "
			existing = strings.trim_right(existing, delimiter)
			value = strings.concatenate({existing, delimiter, value})
		}
		set(other, attr.key, value)
	}
}

// ``element.pop()``: remove the last child.
pop :: proc(e: ^Element) -> (res: ^Element, err: Error) {
	if e == nil {
		return nil, none_attribute("pop")
	}
	if len(e.children) == 0 {
		return nil, Exception{.Index_Error, "child index out of range"}
	}
	return pop_safe(&e.children)
}

@(private = "file")
pop_safe :: proc(children: ^[dynamic]^Element) -> (res: ^Element, err: Error) {
	child := children[len(children) - 1]
	resize(children, len(children) - 1)
	return child, nil
}

// ``len(element)``.
length :: proc(e: ^Element) -> (int, Error) {
	if e == nil {
		return 0, Exception{.Type_Error, "object of type 'NoneType' has no len()"}
	}
	return len(e.children), nil
}

// ``MathElement.in_block``: is `e` or an ancestor ``display="block"``?
in_block :: proc(e: ^Element) -> bool {
	for node := e; node != nil; node = node.parent {
		if display, found := get(node, "display"); found {
			return display == "block"
		}
	}
	return false
}

// The depth of the tree under `e` (without recursion).
tree_depth :: proc(e: ^Element) -> int {
	Item :: struct {
		element: ^Element,
		depth:   int,
	}
	stack := make([dynamic]Item)
	append(&stack, Item{e, 1})
	deepest := 0
	for len(stack) > 0 {
		item := pop_safe_item(&stack)
		deepest = max(deepest, item.depth)
		for child in item.element.children {
			append(&stack, Item{child, item.depth + 1})
		}
	}
	return deepest
}

@(private = "file")
pop_safe_item :: proc(stack: ^[dynamic]$T) -> T {
	item := stack[len(stack) - 1]
	resize(stack, len(stack) - 1)
	return item
}

// ``str(element)``: like ``mi('x')`` or ``mfrac(mi('a'), mi('b'))``.
describe_element :: proc(e: ^Element) -> string {
	b := strings.builder_make()
	write_description(&b, e, 0)
	return strings.to_string(b)
}

@(private = "file")
write_description :: proc(b: ^strings.Builder, e: ^Element, depth: int) {
	strings.write_string(b, TAG_NAMES[e.tag])
	strings.write_byte(b, '(')
	if depth > MAX_DEPTH {
		strings.write_string(b, "...") // (docutils raises a RecursionError)
	} else if len(e.text) > 0 {
		write_repr(b, e.text)
	} else {
		for child, index in e.children {
			if index > 0 {
				strings.write_string(b, ", ")
			}
			write_description(b, child, depth + 1)
		}
	}
	strings.write_byte(b, ')')
}

// XML output
// ----------

// ``ElementTree.indent(e)``: line breaks and two spaces per level.
indent_xml :: proc(e: ^Element) {
	if len(e.children) > 0 {
		indent_children(e, 0)
	}
}

@(private = "file")
indentation :: proc(level: int) -> string {
	b := strings.builder_make()
	strings.write_byte(&b, '\n')
	for _ in 0 ..< level {
		strings.write_string(&b, "  ")
	}
	return strings.to_string(b)
}

@(private = "file")
indent_children :: proc(e: ^Element, level: int) {
	child_indentation := indentation(level + 1)
	if len(py_strip(e.text)) == 0 {
		e.text = child_indentation
	}
	for child in e.children {
		if len(child.children) > 0 {
			indent_children(child, level + 1)
		}
		if len(py_strip(child.tail)) == 0 {
			child.tail = child_indentation
		}
	}
	last := e.children[len(e.children) - 1]
	if len(py_strip(last.tail)) == 0 {
		last.tail = indentation(level)
	}
}

// ``MathElement.toxml()``: ``ElementTree.tostring`` without short empty
// elements; the function application character is shown as an entity.
to_xml :: proc(e: ^Element, b: ^strings.Builder) {
	strings.write_byte(b, '<')
	strings.write_string(b, TAG_NAMES[e.tag])
	for attr in e.attrs {
		strings.write_byte(b, ' ')
		strings.write_string(b, attr.key)
		strings.write_string(b, `="`)
		write_escaped(b, attr.value, true)
		strings.write_byte(b, '"')
	}
	strings.write_byte(b, '>')
	write_escaped(b, e.text, false)
	for child in e.children {
		to_xml(child, b)
	}
	strings.write_string(b, "</")
	strings.write_string(b, TAG_NAMES[e.tag])
	strings.write_byte(b, '>')
	write_escaped(b, e.tail, false)
}

// ElementTree's ``_escape_cdata`` and ``_escape_attrib``.
@(private = "file")
write_escaped :: proc(b: ^strings.Builder, text: string, attribute: bool) {
	for r in text {
		switch r {
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case '\u2061':
			strings.write_string(b, "&ApplyFunction;")
		case '"', '\r', '\n', '\t':
			if !attribute {
				strings.write_rune(b, r)
			} else if r == '"' {
				strings.write_string(b, "&quot;")
			} else {
				strings.write_string(b, r == '\r' ? "&#13;" : r == '\n' ? "&#10;" : "&#09;")
			}
		case:
			strings.write_rune(b, r)
		}
	}
}
