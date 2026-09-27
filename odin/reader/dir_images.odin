package reader

import "core:strings"

import dt "../doctree"
import rst "../rst"

// The image and figure directives (``directives.images``), without PIL:
// ``:figwidth: image`` sets no width, as in docutils without PIL.

@(private = "file")
ALIGN_H_VALUES := [?]string{"left", "center", "right"}
@(private = "file")
ALIGN_V_VALUES := [?]string{"top", "middle", "bottom"}
@(private = "file")
ALIGN_VALUES := [?]string{"top", "middle", "bottom", "left", "center", "right"}
@(private = "file")
LOADING_VALUES := [?]string{"embed", "link", "lazy"}

@(private = "file")
image_align :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	return choice(c, argument, ALIGN_VALUES[:])
}

@(private = "file")
figure_align :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	return choice(c, argument, ALIGN_H_VALUES[:])
}

@(private = "file")
loading :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	return choice(c, argument, LOADING_VALUES[:])
}

@(private = "file")
figwidth_value :: proc(c: ^Context, argument: Maybe(string)) -> (Option_Value, string) {
	a := argument.? or_else ""
	if dt.py_lower(a, c.allocator) == "image" do return "image", ""
	return length_or_percentage(argument, "px")
}

@(private = "file")
IMAGE_OPTIONS := [?]Option_Spec {
	{"alt", unchanged},
	{"height", length_or_unitless},
	{"width", length_or_percentage_or_unitless},
	{"scale", percentage},
	{"align", image_align},
	{"target", unchanged_required},
	{"loading", loading},
	{"class", class_option},
	{"name", unchanged},
}

@(private = "file")
FIGURE_OPTIONS := [?]Option_Spec {
	{"alt", unchanged},
	{"height", length_or_unitless},
	{"width", length_or_percentage_or_unitless},
	{"scale", percentage},
	{"align", figure_align},
	{"target", unchanged_required},
	{"loading", loading},
	{"class", class_option},
	{"name", unchanged},
	{"figwidth", figwidth_value},
	{"figclass", class_option},
	{"figname", unchanged},
}

IMAGE := Directive_Spec {
	required_arguments        = 1,
	final_argument_whitespace = true,
	option_spec               = IMAGE_OPTIONS[:],
	run                       = run_image,
}

FIGURE := Directive_Spec {
	required_arguments        = 1,
	final_argument_whitespace = true,
	option_spec               = FIGURE_OPTIONS[:],
	has_content               = true,
	run                       = run_figure,
}

// ``Image.run``.
@(private = "file")
run_image :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	if err := check_image_align(d); err != nil do return nil, err
	doc := c.doc
	reference, _ := uri(c, d.arguments[0])
	options_set(&d.options, "uri", reference)
	reference_node: dt.Node
	if v, ok := options_pop(&d.options, "target"); ok {
		reference_node = image_target(c, v.(string) or_else "")
	}
	options := normalize_options(c, &d.options)
	image := dt.new_element(doc, .image, d.block_text)
	apply_options(c, image, &options)
	d_set_source_line(c, d, image, d.lineno)
	add_name(c, d, image)
	if reference_node == 0 do return result_of(c, image), nil
	dt.append_child(doc, reference_node, image)
	return result_of(c, reference_node), nil
}

// The "align" values allowed in a substitution definition and elsewhere.
@(private = "file")
check_image_align :: proc(d: ^Directive) -> Failure {
	v, ok := options_get(&d.options, "align")
	if !ok do return nil
	align := v.(string) or_else ""
	if d.subst {
		if contains(ALIGN_V_VALUES[:], align) do return nil
		return directive_error(
			.ERROR, "Error in \"", d.name, "\" directive: \"", align, "\" is not a valid value ",
			"for the \"align\" option within a substitution definition.  ",
			"Valid values for \"align\" are: \"top\", \"middle\", \"bottom\".",
		)
	}
	if contains(ALIGN_H_VALUES[:], align) do return nil
	return directive_error(
		.ERROR, "Error in \"", d.name, "\" directive: \"", align, "\" is not a valid value ",
		"for the \"align\" option.  Valid values for \"align\" are: ",
		"\"left\", \"center\", \"right\".",
	)
}

// The reference of the "target" option (``Body.parse_target``).
@(private = "file")
image_target :: proc(c: ^Context, target: string) -> dt.Node {
	doc := c.doc
	block := dt.py_splitlines(rst.escape2null(target, c.allocator))
	node := dt.new_element(doc, .reference)
	if len(block) > 0 && has_suffix(strip(block[len(block) - 1]), "_") {
		parts := make([]string, len(block), c.allocator)
		for l, i in block do parts[i] = strip(l)
		reference := strings.join(parts, " ", c.allocator)
		if refname, ok := rst.is_reference(reference, c.allocator); ok {
			dt.set_attr(doc, node, dt.K_REFNAME, normalize_name(refname))
			dt.set_attr(doc, node, "name", dt.whitespace_normalize_name(refname))
			set_indirect_reference_name(c, node, refname)
			dt.note_refname(doc, node)
			return node
		}
	}
	joined := strings.join(block, " ", c.allocator)
	dt.set_attr(doc, node, dt.K_REFURI, rst.normalize_uri(joined, c.allocator))
	return node
}

// ``Figure.run``.
@(private = "file")
run_figure :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	doc := c.doc
	figwidth, _ := options_pop(&d.options, "figwidth")
	figclasses, _ := options_pop(&d.options, "figclass")
	figname, _ := options_pop(&d.options, "figname")
	align, _ := options_pop(&d.options, "align")
	images, err := run_image(c, d)
	if err != nil do return nil, err
	figure := element(c, .figure, "", images[:])
	d_set_source_line(c, d, figure, d.lineno)
	if w, is_str := figwidth.(string); is_str && w != "image" {
		dt.set_attr(doc, figure, "width", w)
	}
	for cl in figclasses.([]string) or_else nil do dt.list_append(doc, figure, dt.K_CLASSES, cl)
	if name, is_str := figname.(string); is_str && name != "" {
		dt.list_append(doc, figure, dt.K_NAMES, normalize_name(name))
		dt.note_explicit_target(doc, figure, figure)
	}
	if a, is_str := align.(string); is_str && a != "" do dt.set_attr(doc, figure, "align", a)
	if sl_len(d.content) == 0 do return result_of(c, figure), nil
	if msg := figure_caption(c, d, figure); msg != 0 do return result_of(c, figure, msg), nil
	return result_of(c, figure), nil
}

// The caption and legend of a figure; the error message, if any.
@(private = "file")
figure_caption :: proc(c: ^Context, d: ^Directive, figure: dt.Node) -> dt.Node {
	doc := c.doc
	node := dt.new_element(doc, .Element) // anonymous container for parsing
	d_nested_parse(c, d, node)
	children := dt.children(doc, node, c.allocator)
	if len(children) == 0 {
		// ``if len(node) > i+1`` after a loop over no children
		msg := "UnboundLocalError: cannot access local variable 'i' where it is not " +
			"associated with a value"
		raise_exception(c, msg)
		return 0
	}
	rest := len(children)
	for child, i in children {
		if dt.is(doc, child, {.target, .pending}) {
			dt.append_child(doc, figure, child)
			continue
		}
		if dt.is(doc, child, {.paragraph}) {
			caption := element(
				c, .caption, dt.text(doc, child), dt.children(doc, child, c.allocator),
			)
			src, has_src := dt.source(doc, child)
			ln, has_line := dt.line(doc, child)
			dt.set_source(doc, caption, src if has_src else nil)
			dt.set_line(doc, caption, ln if has_line else nil)
			dt.append_child(doc, figure, caption)
			rest = i + 1
			break
		}
		if dt.is(doc, child, {.comment}) && dt.child_count(doc, child) == 0 {
			rest = i + 1
			break
		}
		lit := dt.new_element(doc, .literal_block, d.block_text, d.block_text)
		text := "Figure caption must be a paragraph or empty comment."
		return dt.error(doc, text, {children = {lit}, line = d.lineno})
	}
	if rest < len(children) {
		dt.append_child(doc, figure, element(c, .legend, "", children[rest:]))
	}
	return 0
}
