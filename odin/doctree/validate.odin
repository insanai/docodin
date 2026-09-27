package doctree

import "core:fmt"
import "core:strings"

// Doctree validation: ``Element.validate``, ``validate_attributes``,
// ``validate_content`` and the ``validate_position`` hooks, with the
// content models and valid attributes of the node classes
// (node_classes.odin) and ``ATTRIBUTE_VALIDATORS``.
//
// Validation errors (``ValidationError``) are returned as ``ok = false``
// with the docutils message and the problematic node.

// An item of a content model: ``(category, quantifier)``.
Model_Item :: struct {
	tags:  Tag_Set,
	cats:  Categories,
	name:  string, // for messages: ``category.__name__`` or "a> or <b"
	quant: u8, // '.', '?', '+' or '*'
}

@(private = "file")
Invalid :: struct {
	message:     string,
	problematic: Node,
}

@(private = "file")
instance_of :: proc(doc: ^Doc, n: Node, item: Model_Item) -> bool {
	if n == 0 do return false
	t := doc.nodes[n].tag
	return t in item.tags || TAG_CATEGORIES[t] & item.cats != {}
}

// The content model of a class.
content_model :: proc(t: Tag) -> []Model_Item {
	span := TAG_MODEL[t]
	return MODEL_ITEMS[span[0]:][:span[1]]
}

// The ``valid_attributes`` of a class.
valid_attributes :: proc(t: Tag) -> []string {
	span := TAG_VALID_ATTRS[t]
	return VALID_ATTR_NAMES[span[0]:][:span[1]]
}

// ``Element.validate(recursive)``.
validate :: proc(
	doc: ^Doc,
	n: Node,
	recursive := true,
) -> (
	ok: bool,
	message: string,
	problematic: Node,
) {
	if doc.nodes[n].tag == .Text do return true, "", 0
	if err, bad := validate_attributes(doc, n).?; bad do return false, err.message, err.problematic
	leftover, err := validate_children(doc, n)
	if e, bad := err.?; bad do return false, e.message, e.problematic
	if len(leftover) > 0 {
		c := leftover[0]
		head := element_invalid(doc, n)
		if doc.nodes[c].tag == .Text {
			return false, fmt.tprintf("%s  Spurious text: \"%s\".", head, astext(doc, c)), n
		}
		msg := "%s  Child element %s not allowed at this position."
		return false, fmt.tprintf(msg, head, starttag(doc, c)), c
	}
	if !recursive do return true, "", 0
	for c := doc.nodes[n].first; c != 0; c = doc.nodes[c].next {
		ok, message, problematic = validate(doc, c, true)
		if !ok do return
	}
	return true, "", 0
}

@(private = "file")
element_invalid :: proc(doc: ^Doc, n: Node) -> string {
	return fmt.tprintf("Element %s invalid:\n", starttag(doc, n))
}

// ``validate_content`` of the children (repeated for ``authors``).
@(private = "file")
validate_children :: proc(doc: ^Doc, n: Node) -> ([]Node, Maybe(Invalid)) {
	elements := children(doc, n)
	model := content_model(doc.nodes[n].tag)
	relics, err := validate_content(doc, n, model, elements)
	if doc.nodes[n].tag != .authors do return relics, err
	for err == nil && len(relics) > 0 {
		relics, err = validate_content(doc, n, model, relics)
	}
	return relics, err
}

// ``Element.validate_content(model, elements)``: the elements that do not
// fit in the model, or the error.
@(private = "file")
validate_content :: proc(
	doc: ^Doc,
	n: Node,
	model: []Model_Item,
	elements: []Node,
) -> (
	[]Node,
	Maybe(Invalid),
) {
	i := 0
	child := elements[0] if len(elements) > 0 else 0
	for item in model {
		if !instance_of(doc, child, item) {
			if item.quant == '.' || item.quant == '+' {
				return nil, Invalid{report_child(doc, n, child, item), child}
			}
			continue // optional child: try the same child with the next item
		}
		if err := validate_position(doc, child); err != nil do return nil, err
		if item.quant == '.' || item.quant == '?' {
			i += 1
			child = elements[i] if i < len(elements) else 0
			continue
		}
		err: Maybe(Invalid)
		if i, err = skip_matching(doc, item, elements, i); err != nil do return nil, err
		child = elements[i] if i < len(elements) else 0
	}
	return nil if child == 0 else elements[i:], nil
}

// Pass the elements after ``i`` matching a '*' or '+' item: the index of
// the first one that does not (``len(elements)`` if none).
@(private = "file")
skip_matching :: proc(
	doc: ^Doc,
	item: Model_Item,
	elements: []Node,
	i: int,
) -> (
	int,
	Maybe(Invalid),
) {
	for j in i + 1 ..< len(elements) {
		if !instance_of(doc, elements[j], item) do return j, nil
		if err := validate_position(doc, elements[j]); err != nil do return j, err
	}
	return len(elements), nil
}

@(private = "file")
report_child :: proc(doc: ^Doc, n, child: Node, item: Model_Item) -> string {
	head := element_invalid(doc, n)
	if child == 0 do return fmt.tprintf("%s  Missing child of type <%s>.", head, item.name)
	if doc.nodes[child].tag == .Text {
		msg := "%s  Expecting child of type <%s>, not text data \"%s\"."
		return fmt.tprintf(msg, head, item.name, astext(doc, child))
	}
	msg := "%s  Expecting child of type <%s>, not %s."
	return fmt.tprintf(msg, head, item.name, starttag(doc, child))
}

// ``subtitle.validate_position`` and ``transition.validate_position``.
@(private = "file")
validate_position :: proc(doc: ^Doc, n: Node) -> Maybe(Invalid) {
	p := doc.nodes[n].parent
	#partial switch doc.nodes[n].tag {
	case .subtitle:
		if p != 0 && index_identity(doc, p, n) == 0 {
			msg := "%s  <subtitle> only allowed after <title>."
			return Invalid{fmt.tprintf(msg, element_invalid(doc, p)), n}
		}
	case .transition:
		return transition_position(doc, n, p)
	}
	return nil
}

@(private = "file")
transition_position :: proc(doc: ^Doc, n, p: Node) -> Maybe(Invalid) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, fmt.tprintf("Element %s invalid:", starttag(doc, p)))
	pred := doc.nodes[n].prev
	count := 0
	opening := Tag_Set{.title, .subtitle, .meta, .decoration}
	if pred == 0 || doc.nodes[pred].tag in opening {
		// A transition following these elements still counts as
		// "at the beginning of a document or section".
		strings.write_string(&b, "\n  <transition> may not begin a section or document.")
		count += 1
	}
	if doc.nodes[n].next == 0 {
		strings.write_string(&b, "\n  <transition> may not end a section or document.")
		count += 1
	}
	if pred != 0 && doc.nodes[pred].tag == .transition {
		strings.write_string(&b, "\n  <transition> may not directly follow another transition.")
		count += 1
	}
	if count == 0 do return nil
	return Invalid{strings.to_string(b), n}
}

// ``Element.validate_attributes()``: normalize the attribute values and
// check them against the class's valid attributes and
// ``ATTRIBUTE_VALIDATORS``.
@(private = "file")
validate_attributes :: proc(doc: ^Doc, n: Node) -> Maybe(Invalid) {
	messages := make([dynamic]string, 0, 2, context.temp_allocator)
	valid := valid_attributes(doc.nodes[n].tag)
	for a in attributes(doc, n) {
		if strings.has_prefix(a.key, "internal:") do continue // see --expose-internals
		if !contains_string(valid, a.key) {
			va := strings.join(valid, "\", \"", context.temp_allocator)
			append(&messages, fmt.tprintf("Attribute \"%s\" not one of \"%s\".", a.key, va))
			continue
		}
		value, err := validate_value(doc, a.key, a.value)
		if err != "" {
			b := strings.builder_make(context.temp_allocator)
			write_py_str(&b, doc, a.value)
			msg := "Attribute \"%s\" has invalid value \"%s\".\n  %s"
			append(&messages, fmt.tprintf(msg, a.key, strings.to_string(b), err))
			continue
		}
		set_attr(doc, n, a.key, value)
	}
	if len(messages) == 0 do return nil
	joined := strings.join(messages[:], "\n  ", context.temp_allocator)
	return Invalid{fmt.tprintf("Element %s invalid:\n  %s", starttag(doc, n), joined), n}
}

@(private)
contains_string :: proc(list: []string, s: string) -> bool {
	for x in list do if x == s do return true
	return false
}
