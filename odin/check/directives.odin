package check

import "core:strconv"
import "core:strings"

import rst "../rst"

// Standard docutils directives whose content or arguments contain
// reStructuredText.  The checker parses those parts the way the directive
// does, so markup errors inside them are reported; other directives are
// opaque (their diagnostics come from the directive implementation).
//
// Argument and option specifications are docutils 0.22's.  Option values are
// only checked as far as needed to know whether docutils runs the directive
// (a directive with invalid options is not run, so its content is not
// parsed).

Directive_Kind :: enum u8 {
	Admonition,         // attention, caution, ... warning: content
	Generic_Admonition, // admonition: title, content
	Topic,              // title, content
	Sidebar,            // optional title, subtitle option, content
	Rubric,             // title only
	Block_Quote,        // epigraph, highlights, pull-quote
	Body,               // compound, container, header, footer: content
	Parsed_Literal,     // inline markup in the content
	Class,              // optional content
	Replace,            // content (substitution definitions only)
	Table,              // title, content (table, list-table)
	Figure,             // content (caption and legend)
	Contents,           // optional title
}

Option_Kind :: enum u8 {
	Any,      // ``unchanged``
	Required, // a value is required (converter not checked further)
	Class,    // ``class_option``
	Align,    // ``align``: left, center, right
	Nonnegative_Int,
	Flag,      // no value
	Backlinks, // entry, top, none
}

Option_Spec :: struct {
	name: string,
	kind: Option_Kind,
}

Directive_Spec :: struct {
	kind:        Directive_Kind,
	required:    int,
	optional:    int,
	final_ws:    bool, // final_argument_whitespace
	has_content: bool,
	options:     []Option_Spec,
}

@(rodata)
CLASS_NAME := [?]Option_Spec{{"class", .Class}, {"name", .Any}}
@(rodata)
SIDEBAR_OPTIONS := [?]Option_Spec{{"class", .Class}, {"name", .Any}, {"subtitle", .Required}}
@(rodata)
NAME_ONLY := [?]Option_Spec{{"name", .Any}}
@(rodata)
TABLE_OPTIONS := [?]Option_Spec {
	{"class", .Class}, {"name", .Any}, {"align", .Align},
	{"width", .Required}, {"widths", .Required},
}
@(rodata)
LIST_TABLE_OPTIONS := [?]Option_Spec {
	{"header-rows", .Nonnegative_Int}, {"stub-columns", .Nonnegative_Int}, {"width", .Required},
	{"widths", .Required}, {"class", .Class}, {"name", .Any}, {"align", .Align},
}
@(rodata)
FIGURE_OPTIONS := [?]Option_Spec {
	{"alt", .Any}, {"height", .Required}, {"width", .Required}, {"scale", .Required},
	{"align", .Align}, {"target", .Required}, {"loading", .Required}, {"class", .Class},
	{"name", .Any}, {"figwidth", .Required}, {"figclass", .Class}, {"figname", .Any},
}

@(rodata)
CONTENTS_OPTIONS := [?]Option_Spec {
	{"depth", .Nonnegative_Int}, {"local", .Flag}, {"backlinks", .Backlinks}, {"class", .Class},
}

// Directive names are matched case-insensitively (English names).
directive_spec :: proc(name: string) -> (spec: Directive_Spec, ok: bool) {
	switch strings.to_lower(name, context.temp_allocator) {
	case "attention", "caution", "danger", "error", "hint", "important", "note", "tip",
	     "warning":
		return {.Admonition, 0, 0, true, true, CLASS_NAME[:]}, true
	case "admonition":     return {.Generic_Admonition, 1, 0, true, true, CLASS_NAME[:]}, true
	case "topic":          return {.Topic, 1, 0, true, true, CLASS_NAME[:]}, true
	case "sidebar":        return {.Sidebar, 0, 1, true, true, SIDEBAR_OPTIONS[:]}, true
	case "rubric":         return {.Rubric, 1, 0, true, false, CLASS_NAME[:]}, true
	case "epigraph", "highlights", "pull-quote":
		return {.Block_Quote, 0, 0, false, true, nil}, true
	case "compound":       return {.Body, 0, 0, false, true, CLASS_NAME[:]}, true
	case "container":      return {.Body, 0, 1, true, true, NAME_ONLY[:]}, true
	case "header", "footer":
		return {.Body, 0, 0, false, true, nil}, true
	case "parsed-literal": return {.Parsed_Literal, 0, 0, false, true, CLASS_NAME[:]}, true
	case "class":          return {.Class, 1, 0, true, true, nil}, true
	case "replace":        return {.Replace, 0, 0, false, true, nil}, true
	case "table":          return {.Table, 0, 1, true, true, TABLE_OPTIONS[:]}, true
	case "list-table":     return {.Table, 0, 1, true, true, LIST_TABLE_OPTIONS[:]}, true
	case "figure":         return {.Figure, 1, 0, true, true, FIGURE_OPTIONS[:]}, true
	case "contents":       return {.Contents, 0, 1, true, false, CONTENTS_OPTIONS[:]}, true
	}
	return
}

// Parent context of a directive (``state_machine.node``), for the topic
// and sidebar placement rule.
Context :: enum u8 {
	Root,      // document or section
	Sidebar,
	Anonymous, // anonymous ``nodes.Element`` container (table, figure, class content)
	Other,     // body, part or other elements
}

// Parsed directive block (``Body.parse_directive_block``).
Directive_Block :: struct {
	arguments:      []string,
	options:        [dynamic]Option_Value,
	content:        []string,
	content_offset: int,
}

Option_Value :: struct {
	name:  string,
	value: string,
	given: bool, // false: field without body (``None``)
}

// ``Body.parse_directive_block``; ``ok`` is false where docutils raises a
// MarkupError (the directive is not run).
parse_directive_block :: proc(
	info: ^rst.Directive_Info,
	spec: Directive_Spec,
) -> (
	b: Directive_Block,
	ok: bool,
) {
	indented, line_offset := trimmed_block(info)
	takes_args := spec.required > 0 || spec.optional > 0
	arg_block: []string
	i := 0
	if len(indented) > 0 && (takes_args || len(spec.options) > 0) {
		for i < len(indented) && !is_blank(indented[i]) do i += 1
		arg_block = indented[:i]
		b.content = indented[min(i + 1, len(indented)):]
		b.content_offset = line_offset + i + 1
	} else {
		b.content = indented
		b.content_offset = line_offset
	}
	if len(spec.options) > 0 {
		opt_start := options_start(arg_block)
		parse_options(arg_block[opt_start:], spec, &b) or_return
		arg_block = arg_block[:opt_start]
	}
	if len(arg_block) > 0 && !takes_args {
		// docutils joins the argument lines and the rest of the block; the
		// option lines between them are dropped (rare, and then the source
		// lines of the content are approximate)
		joined := make([]string, len(arg_block) + len(indented) - i, context.temp_allocator)
		copy(joined, arg_block)
		copy(joined[len(arg_block):], indented[i:])
		b.content = joined
		b.content_offset = line_offset
		arg_block = nil
	}
	for len(b.content) > 0 && is_blank(b.content[0]) {
		b.content = b.content[1:]
		b.content_offset += 1
	}
	if takes_args {
		b.arguments = parse_arguments(arg_block, spec) or_return
	}
	if len(b.content) > 0 && !spec.has_content do return b, false
	return b, true
}

// The directive block without a leading blank line and trailing blank lines.
@(private = "file")
trimmed_block :: proc(info: ^rst.Directive_Info) -> (indented: []string, line_offset: int) {
	indented = info.lines
	line_offset = info.line_offset
	if len(indented) > 0 && is_blank(indented[0]) {
		indented = indented[1:]
		line_offset += 1
	}
	for len(indented) > 0 && is_blank(indented[len(indented) - 1]) {
		indented = indented[:len(indented) - 1]
	}
	return
}

// Index of the first option (field marker) line of the argument block.
@(private = "file")
options_start :: proc(arg_block: []string) -> int {
	for line, j in arg_block {
		if _, _, is_field := rst.match_field_marker(line); is_field do return j
	}
	return len(arg_block)
}

// ``Body.parse_directive_arguments``
@(private = "file")
parse_arguments :: proc(arg_block: []string, spec: Directive_Spec) -> (args: []string, ok: bool) {
	text := strings.join(arg_block, "\n", context.temp_allocator)
	args = rst.split_whitespace(text, context.temp_allocator)
	total := spec.required + spec.optional
	if len(args) < spec.required do return nil, false
	if len(args) > total {
		if !spec.final_ws do return nil, false
		args = split_max(text, total - 1)
	}
	return args, true
}

// ``str.split(None, maxsplit)``
@(private = "file")
split_max :: proc(s: string, maxsplit: int) -> []string {
	out := make([dynamic]string, 0, maxsplit + 1, context.temp_allocator)
	rest := rst.lstrip(s)
	for len(rest) > 0 {
		if len(out) == maxsplit {
			append(&out, rst.rstrip(rest))
			break
		}
		end := len(rest)
		for r, i in rest {
			if rst.is_space(r) {
				end = i
				break
			}
		}
		append(&out, rest[:end])
		rest = rst.lstrip(rest[end:])
	}
	return out[:]
}

// ``Body.parse_extension_options`` (field list in the ExtensionOptions state).
@(private = "file")
parse_options :: proc(lines: []string, spec: Directive_Spec, b: ^Directive_Block) -> bool {
	b.options = make([dynamic]Option_Value, 0, 4, context.temp_allocator)
	i := 0
	for i < len(lines) {
		name, end, is_field := rst.match_field_marker(lines[i])
		if !is_field do return false // invalid option block
		body := make([dynamic]string, 0, 2, context.temp_allocator)
		if first := rst.strip(lines[i][end:]); len(first) > 0 do append(&body, first)
		i += 1
		for i < len(lines) && is_continuation(lines[i]) {
			append(&body, rst.strip(lines[i]))
			i += 1
		}
		fname := rst.strip(rst.unescape(name, context.temp_allocator))
		if len(rst.split_whitespace(fname, context.temp_allocator)) != 1 do return false
		opt := Option_Value {
			name  = strings.to_lower(fname, context.temp_allocator),
			value = strings.join(body[:], "\n", context.temp_allocator),
			given = len(body) > 0,
		}
		for o in b.options do if o.name == opt.name do return false // duplicate option
		kind, known := option_kind(spec, opt.name)
		if !known || !valid_option_value(kind, opt) do return false
		append(&b.options, opt)
	}
	return true
}

// An indented line continuing a field body.
@(private = "file")
is_continuation :: #force_inline proc(line: string) -> bool {
	return len(line) > 0 && (line[0] == ' ' || line[0] == '\t')
}

@(private = "file")
option_kind :: proc(spec: Directive_Spec, name: string) -> (Option_Kind, bool) {
	for o in spec.options do if o.name == name do return o.kind, true
	return .Any, false
}

@(private = "file")
valid_option_value :: proc(kind: Option_Kind, opt: Option_Value) -> bool {
	switch kind {
	case .Any:      return true
	case .Required: return opt.given
	case .Class:    return opt.given && valid_class_value(opt.value)
	case .Align:
		switch strings.to_lower(rst.strip(opt.value), context.temp_allocator) {
		case "left", "center", "right": return opt.given
		}
		return false
	case .Nonnegative_Int:
		n, ok := strconv.parse_int(rst.strip(opt.value), 10)
		return opt.given && ok && n >= 0
	case .Flag:     return len(rst.strip(opt.value)) == 0
	case .Backlinks:
		switch strings.to_lower(rst.strip(opt.value), context.temp_allocator) {
		case "entry", "top", "none": return opt.given
		}
		return false
	}
	return false
}

// ``directives.class_option``: every class name must yield an identifier.
valid_class_value :: proc(value: string) -> bool {
	names := rst.split_whitespace(value, context.temp_allocator)
	if len(names) == 0 do return false
	for name in names {
		has_alnum := false
		for r in name {
			// ``make_id`` keeps ASCII letters and digits (non-ASCII letters
			// are transliterated, so they count as well)
			ascii_alnum :=
				(r >= '0' && r <= '9') || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')
			if r >= 0x80 || ascii_alnum {
				has_alnum = true
				break
			}
		}
		if !has_alnum do return false
	}
	return true
}

option_value :: proc(b: ^Directive_Block, name: string) -> (string, bool) {
	for o in b.options do if o.name == name do return o.value, true
	return "", false
}

@(private = "file")
is_blank :: #force_inline proc(line: string) -> bool {
	return len(rst.strip(line)) == 0
}
