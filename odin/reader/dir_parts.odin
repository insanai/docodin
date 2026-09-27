package reader

import "core:fmt"

import dt "../doctree"

// Document part directives (``directives.parts``, ``directives.references``):
// they create ``pending`` elements for the transforms.

@(private = "file")
CONTENTS_OPTIONS := [?]Option_Spec {
	{"depth", nonnegative_int},
	{"local", flag},
	{"backlinks", backlinks},
	{"class", class_option},
}
@(private = "file")
SECTNUM_OPTIONS := [?]Option_Spec {
	{"depth", int_option},
	{"start", int_option},
	{"prefix", unchanged_required},
	{"suffix", unchanged_required},
}
@(private = "file")
CLASS_ONLY := [?]Option_Spec{{"class", class_option}}

CONTENTS := Directive_Spec {
	optional_arguments        = 1,
	final_argument_whitespace = true,
	option_spec               = CONTENTS_OPTIONS[:],
	run                       = run_contents,
}
SECTNUM := Directive_Spec {
	option_spec = SECTNUM_OPTIONS[:],
	run         = run_sectnum,
}
HEADER := Directive_Spec {
	has_content = true,
	run         = run_header,
}
FOOTER := Directive_Spec {
	has_content = true,
	run         = run_footer,
}
TARGET_NOTES := Directive_Spec {
	option_spec = CLASS_ONLY[:],
	run         = run_target_notes,
}

// ``languages.en.labels['contents']``.
CONTENTS_LABEL :: "Contents"

// ``pending.details.update(options)``.
@(private = "file")
update_details :: proc(c: ^Context, pending: dt.Node, options: ^Options) {
	for o in options {
		value: dt.Detail_Value
		switch v in o.value {
		case string:
			value = v
		case int:
			value = v
		case []string:
			value = v
		case []int:
			value = fmt.aprint(v) // not used by these directives
		case Opt_None:
			value = dt.Detail_None{}
		}
		dt.set_detail(c.doc, pending, o.name, value)
	}
}

@(private = "file")
run_contents :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	doc := c.doc
	if pseudo_section_invalid(c, d.sm.node) {
		msg := "\" directive may not be used within topics or body elements."
		return nil, directive_error(.ERROR, "The \"", d.name, msg)
	}
	local := options_has(&d.options, "local")
	title: dt.Node
	messages := make([dynamic]dt.Node, c.allocator)
	if len(d.arguments) > 0 {
		title_text := d.arguments[0]
		text_nodes, msgs := d_inline_text(c, d, title_text, d.lineno)
		title = element(c, .title, title_text, text_nodes[:])
		messages = msgs
	} else if !local {
		title = dt.new_element(doc, .title, "", CONTENTS_LABEL)
	}
	topic := dt.new_element(doc, .topic)
	dt.list_append(doc, topic, dt.K_CLASSES, "contents")
	for cl in options_list(&d.options, "class") do dt.list_append(doc, topic, dt.K_CLASSES, cl)
	// the latex2e writer needs source and line for a warning
	src, ln, _ := get_source_and_line(c, d.sm, nil)
	dt.set_source(doc, topic, src)
	dt.set_line(doc, topic, (ln.? or_else 0) - 1)
	if local do dt.list_append(doc, topic, dt.K_CLASSES, "local")
	name := CONTENTS_LABEL
	if title != 0 && dt.child_count(doc, title) > 0 { 	// ``if title:``
		name = dt.astext(doc, title)
		dt.append_child(doc, topic, title)
	}
	name = normalize_name(name)
	if !dt.has_name(doc, name) do dt.list_append(doc, topic, dt.K_NAMES, name)
	dt.note_implicit_target(doc, topic)
	pending := dt.new_pending(doc, "docutils.transforms.parts.Contents", 720, nil, d.block_text)
	update_details(c, pending, &d.options)
	dt.note_pending(doc, pending)
	dt.append_child(doc, topic, pending)
	out := result_of(c, topic)
	append(&out, ..messages[:])
	return out, nil
}

@(private = "file")
run_sectnum :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	pending := dt.new_pending(c.doc, "docutils.transforms.parts.SectNum", 710)
	update_details(c, pending, &d.options)
	dt.note_pending(c.doc, pending)
	return result_of(c, pending), nil
}

@(private = "file")
run_header :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	if err := assert_has_content(d); err != nil do return nil, err
	header := dt.get_header(c.doc, dt.get_decoration(c.doc))
	d_nested_parse(c, d, header)
	return nil, nil
}

@(private = "file")
run_footer :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	if err := assert_has_content(d); err != nil do return nil, err
	footer := dt.get_footer(c.doc, dt.get_decoration(c.doc))
	d_nested_parse(c, d, footer)
	return nil, nil
}

@(private = "file")
run_target_notes :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	pending := dt.new_pending(c.doc, "docutils.transforms.references.TargetNotes", 540)
	add_name(c, d, pending)
	update_details(c, pending, &d.options)
	dt.note_pending(c.doc, pending)
	return result_of(c, pending), nil
}
