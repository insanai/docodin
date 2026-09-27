package site

import "core:slice"
import "core:strings"

import dt "../doctree"
import rd "../reader"

// The Sphinx directives but the code blocks (see code.odin).

@(private = "file")
TOCTREE_OPTIONS := [?]rd.Option_Spec {
	{"maxdepth", rd.int_option},
	{"name", rd.unchanged},
	{"class", rd.class_option},
	{"caption", rd.unchanged_required},
	{"glob", rd.flag},
	{"hidden", rd.flag},
	{"includehidden", rd.flag},
	{"numbered", int_or_nothing},
	{"titlesonly", rd.flag},
	{"reversed", rd.flag},
}
TOCTREE := rd.Directive_Spec {
	has_content = true,
	option_spec = TOCTREE_OPTIONS[:],
	run         = run_toctree,
}
@(private = "file")
SORTED := [?]rd.Option_Spec{{"sorted", rd.flag}}
GLOSSARY := rd.Directive_Spec {
	has_content = true,
	option_spec = SORTED[:],
	run         = run_glossary,
}
SEEALSO := rd.Directive_Spec {
	optional_arguments        = 1,
	final_argument_whitespace = true,
	has_content               = true,
	run                       = run_seealso,
}
VERSIONADDED := rd.Directive_Spec {
	required_arguments        = 1,
	optional_arguments        = 1,
	final_argument_whitespace = true,
	has_content               = true,
	run                       = run_versionmodified,
}
VERSIONCHANGED := VERSIONADDED
DEPRECATED := VERSIONADDED
VERSIONREMOVED := VERSIONADDED
ONLY := rd.Directive_Spec {
	required_arguments        = 1,
	final_argument_whitespace = true,
	has_content               = true,
	run                       = run_only,
}
INDEX := rd.Directive_Spec {
	required_arguments        = 1,
	final_argument_whitespace = true,
	option_spec               = NAME_OPTION[:],
	run                       = run_nothing,
}
@(private = "file")
NAME_OPTION := [?]rd.Option_Spec{{"name", rd.unchanged}}
IGNORED := rd.Directive_Spec {
	required_arguments        = 1,
	final_argument_whitespace = true,
	run                       = run_nothing,
}
IGNORED_ARG := IGNORED
CENTERED := rd.Directive_Spec {
	required_arguments        = 1,
	final_argument_whitespace = true,
	run                       = run_centered,
}
@(private = "file")
HLIST_OPTIONS := [?]rd.Option_Spec{{"columns", rd.nonnegative_int}}
HLIST := rd.Directive_Spec {
	has_content = true,
	option_spec = HLIST_OPTIONS[:],
	run         = run_hlist,
}
PRODUCTIONLIST := rd.Directive_Spec {
	required_arguments        = 1,
	final_argument_whitespace = true,
	run                       = run_productionlist,
}

// ``:numbered:`` with an optional depth (999 when none is given).
@(private = "file")
int_or_nothing :: proc(c: ^rd.Context, argument: Maybe(string)) -> (rd.Option_Value, string) {
	a, ok := argument.?
	if !ok || strings.trim_space(a) == "" do return 999, ""
	return rd.int_option(c, a)
}

@(private = "file")
run_nothing :: proc(c: ^rd.Context, d: ^rd.Directive) -> (rd.Nodes, rd.Failure) {
	return rd.result_of(c), nil
}

// --- toctree -------------------------------------------------------------------------------

// ``sphinx.directives.other.TocTree``: a placeholder ``compound``
// (class "toctree-wrapper") for the toctree recorded in the build.
@(private = "file")
run_toctree :: proc(c: ^rd.Context, d: ^rd.Directive) -> (rd.Nodes, rd.Failure) {
	b := build_of(c)
	t := Toctree {
		doc      = b.current,
		maxdepth = option_int(d, "maxdepth", -1),
		numbered = option_int(d, "numbered", 0),
		first    = len(b.entries),
	}
	t.hidden = rd.options_has(&d.options, "hidden")
	t.titlesonly = rd.options_has(&d.options, "titlesonly")
	t.caption = strings.clone(rd.options_string(&d.options, "caption"), b.allocator)
	glob := rd.options_has(&d.options, "glob")
	if d.content != nil {
		for line, i in d.content.data {
			entry := strings.trim_space(line)
			if entry == "" || strings.has_prefix(entry, ".. ") do continue
			toctree_entry(c, b, entry, glob, d.content_offset + i + 1)
		}
	}
	t.count = len(b.entries) - t.first
	if rd.options_has(&d.options, "reversed") do slice.reverse(b.entries[t.first:])
	append(&b.toctrees, t)
	node := dt.new_element(c.doc, .compound, rd.content_text(c, d))
	dt.list_append(c.doc, node, dt.K_CLASSES, "toctree-wrapper")
	for cl in rd.options_list(&d.options, "class") do dt.list_append(c.doc, node, dt.K_CLASSES, cl)
	dt.set_attr(c.doc, node, ATTR_TOCTREE, len(b.toctrees) - 1)
	rd.d_set_source_line(c, d, node, d.lineno)
	rd.add_name(c, d, node)
	return rd.result_of(c, node), nil
}

@(private = "file")
toctree_entry :: proc(c: ^rd.Context, b: ^Build, entry: string, glob: bool, lineno: int) {
	title, target, explicit := split_explicit_title(entry)
	if !explicit do title = ""
	title = strings.clone(title, b.allocator)
	switch {
	case glob && !explicit && has_glob_chars(target):
		matched := glob_docs(b.site, docname_join(current_name(b), target))
		for m in matched {
			if m != b.current do append(&b.entries, Toc_Entry{doc = m})
		}
		if len(matched) == 0 {
			directive_warning(c, lineno, "toctree glob pattern '", target,
				"' didn't match any documents")
		}
	case target == "self":
		append(&b.entries, Toc_Entry{title = title, doc = b.current})
	case strings.contains(target, "://") || strings.has_prefix(target, "mailto:"):
		append(&b.entries, Toc_Entry{title = title, url = strings.clone(target, b.allocator)})
	case:
		toctree_document(c, b, title, target, lineno)
	}
}

// A toctree entry naming a document.
@(private = "file")
toctree_document :: proc(c: ^rd.Context, b: ^Build, title, target: string, lineno: int) {
	s := b.site
	docname := docname_join(current_name(b), strings.trim_suffix(target, SOURCE_SUFFIX))
	if id, ok := s.by_name[docname]; ok {
		append(&b.entries, Toc_Entry{title = title, doc = id})
	} else if excluded(s, strings.concatenate({docname, SOURCE_SUFFIX})) {
		directive_warning(c, lineno, "toctree contains reference to excluded document '",
			docname, "'")
	} else {
		directive_warning(c, lineno, "toctree contains reference to nonexisting document '",
			docname, "'")
	}
}

// An integer option, or ``default``.
option_int :: proc(d: ^rd.Directive, name: string, default: int) -> int {
	v, ok := rd.options_get(&d.options, name)
	if !ok do return default
	n, is_int := v.(int)
	return n if is_int else default
}

// --- glossary ------------------------------------------------------------------------------

// A glossary entry: its term lines and definition lines (indices into the
// directive content).
@(private = "file")
Glossary_Entry :: struct {
	terms:      [dynamic]int,
	definition: [dynamic]int,
	indent:     int,
}

// ``sphinx.domains.std.Glossary``: a ``definition_list`` (class
// "glossary") whose terms get the ids "term-..." of the ``term`` role.
@(private = "file")
run_glossary :: proc(c: ^rd.Context, d: ^rd.Directive) -> (rd.Nodes, rd.Failure) {
	entries := glossary_entries(c, d)
	dlist := dt.new_element(c.doc, .definition_list)
	dt.list_append(c.doc, dlist, dt.K_CLASSES, "glossary")
	items := make([dynamic]dt.Node, c.allocator)
	keys := make([dynamic]string, c.allocator)
	for &e in entries {
		item, key := glossary_item(c, d, &e)
		append(&items, item)
		append(&keys, key)
	}
	if rd.options_has(&d.options, "sorted") {
		order := make([]int, len(items), c.allocator)
		for i in 0 ..< len(order) do order[i] = i
		sort_by_keys(order, keys[:])
		for i in order do dt.append_child(c.doc, dlist, items[i])
	} else {
		for item in items do dt.append_child(c.doc, dlist, item)
	}
	rd.d_set_source_line(c, d, dlist, d.lineno)
	return rd.result_of(c, dlist), nil
}

@(private = "file")
sort_by_keys :: proc(order: []int, keys: []string) {
	for i in 1 ..< len(order) {
		for j := i; j > 0 && keys[order[j]] < keys[order[j - 1]]; j -= 1 {
			order[j], order[j - 1] = order[j - 1], order[j]
		}
	}
}

// Split the glossary content into entries (Sphinx's algorithm and
// warnings).
@(private = "file")
glossary_entries :: proc(c: ^rd.Context, d: ^rd.Directive) -> [dynamic]Glossary_Entry {
	g := Glossary_Split {
		entries       = make([dynamic]Glossary_Entry, c.allocator),
		in_definition = true,
		was_empty     = true,
	}
	if d.content == nil do return g.entries
	for line, i in d.content.data {
		lineno := d.content_offset + i + 1
		switch {
		case strings.trim_space(line) == "":
			if g.in_definition && len(g.entries) > 0 {
				append(&g.entries[len(g.entries) - 1].definition, i)
			}
			g.was_empty = true
			continue
		case line[0] != ' ' && line[0] != '\t':
			g.in_comment = strings.has_prefix(line, ".. ")
			if !g.in_comment do glossary_term_line(c, &g, i, lineno)
		case !g.in_comment:
			glossary_definition_line(c, &g, line, i, lineno)
		}
		g.was_empty = false
	}
	return g.entries
}

// The state of ``glossary_entries``.
@(private = "file")
Glossary_Split :: struct {
	entries:                              [dynamic]Glossary_Entry,
	in_definition, in_comment, was_empty: bool,
}

// A term line: a new entry after a definition, else another term.
@(private = "file")
glossary_term_line :: proc(c: ^rd.Context, g: ^Glossary_Split, i, lineno: int) {
	if !g.in_definition {
		if g.was_empty {
			directive_warning(c, lineno, "glossary terms must not be separated by empty lines")
		}
		if len(g.entries) > 0 do append(&g.entries[len(g.entries) - 1].terms, i)
		return
	}
	if !g.was_empty do directive_warning(c, lineno, "glossary term must be preceded by empty line")
	append(&g.entries, Glossary_Entry {
		terms = make([dynamic]int, c.allocator),
		definition = make([dynamic]int, c.allocator),
	})
	append(&g.entries[len(g.entries) - 1].terms, i)
	g.in_definition = false
}

// An indented line: the definition of the last entry.
@(private = "file")
glossary_definition_line :: proc(
	c: ^rd.Context,
	g: ^Glossary_Split,
	line: string,
	i, lineno: int,
) {
	if len(g.entries) == 0 {
		directive_warning(c, lineno, "glossary seems to be misformatted, check indentation")
		return
	}
	last := &g.entries[len(g.entries) - 1]
	if !g.in_definition {
		g.in_definition = true
		last.indent = len(line) - len(strings.trim_left_space(line))
	}
	append(&last.definition, i)
}

// The ``definition_list_item`` of an entry and its sort key.
@(private = "file")
glossary_item :: proc(c: ^rd.Context, d: ^rd.Directive, e: ^Glossary_Entry) -> (dt.Node, string) {
	doc := c.doc
	b := build_of(c)
	item := dt.new_element(doc, .definition_list_item)
	key := ""
	for i in e.terms {
		line := d.content.data[i]
		lineno := d.content_offset + i + 1
		text, _, _ := strings.partition(line, " : ")
		text = strings.trim_space(text)
		nodes, msgs := rd.d_inline_text(c, d, text, lineno)
		term := rd.element(c, .term, line, nodes[:])
		termtext := dt.astext(doc, term)
		if key == "" do key = strings.to_lower(termtext, c.allocator)
		add_term_id(c, b, term, termtext, lineno)
		dt.append_child(doc, item, term)
		rd.extend(c, item, msgs[:])
	}
	defnode := dt.new_element(doc, .definition)
	if len(e.definition) > 0 {
		lines := make([dynamic]string, c.allocator)
		infos := make([dynamic]rd.Line_Info, c.allocator)
		for i in e.definition {
			line := d.content.data[i]
			append(&lines, line[min(e.indent, len(line)):])
			append(&infos, d.content.items[i])
		}
		block := rd.sl_make_items(lines[:], infos[:], c.allocator)
		rd.nested_parse(c, d.sm, block, d.content_offset + e.definition[0], defnode)
	}
	dt.append_child(doc, item, defnode)
	return item, key
}

// ``make_glossary_term``: the id "term-<text>" (made unique) and the term
// in the build's glossary.
@(private = "file")
add_term_id :: proc(c: ^rd.Context, b: ^Build, term: dt.Node, termtext: string, lineno: int) {
	doc := c.doc
	base := strings.concatenate({"term-", dt.make_id(termtext)}, c.allocator)
	if base == "term-" do base = "term-0"
	id := base
	for n := 0; dt.om_has(&doc.ids, dt.intern(doc, id)); n += 1 {
		id = strings.concatenate({base, "-", rd.itoa(n)}, c.allocator)
	}
	dt.list_append(doc, term, dt.K_IDS, id)
	dt.set_id(doc, term)
	key := strings.to_lower(termtext, b.allocator)
	if old, dup := b.terms[key]; dup && old.doc != b.current {
		directive_warning(c, lineno, "duplicate term description of ", termtext,
			", other instance in ", b.site.docs[old.doc].name)
	}
	b.terms[key] = Target{doc = b.current, id = strings.clone(id, b.allocator), node = term}
}

// --- admonition-like directives ----------------------------------------------------------

// ``seealso``: an admonition (class "seealso") titled "See also"; the
// argument is its first paragraph.
@(private = "file")
run_seealso :: proc(c: ^rd.Context, d: ^rd.Directive) -> (rd.Nodes, rd.Failure) {
	doc := c.doc
	node := dt.new_element(doc, .admonition, rd.content_text(c, d))
	dt.list_append(doc, node, dt.K_CLASSES, "seealso")
	rd.d_set_source_line(c, d, node, d.lineno)
	title := dt.new_element(doc, .title, "See also", "See also")
	dt.append_child(doc, node, title)
	if len(d.arguments) > 0 {
		nodes, msgs := rd.d_inline_text(c, d, d.arguments[0], d.lineno)
		dt.append_child(doc, node, rd.element(c, .paragraph, d.arguments[0], nodes[:]))
		rd.extend(c, node, msgs[:])
	}
	if d.content != nil && rd.sl_len(d.content) > 0 do rd.d_nested_parse(c, d, node)
	if dt.child_count(doc, node) == 1 {
		return nil, rd.directive_error(.ERROR, "The \"seealso\" directive needs content.")
	}
	return rd.result_of(c, node), nil
}

// ``versionadded`` and the others: a container (class "versionadded"...)
// whose first paragraph starts with "Added in version X" (Sphinx 7.3).
@(private = "file")
run_versionmodified :: proc(c: ^rd.Context, d: ^rd.Directive) -> (rd.Nodes, rd.Failure) {
	doc := c.doc
	label, kind := version_label(d.name)
	node := dt.new_element(doc, .container, rd.content_text(c, d))
	dt.list_append(doc, node, dt.K_CLASSES, d.name)
	rd.d_set_source_line(c, d, node, d.lineno)
	text := strings.concatenate({label, " ", d.arguments[0]}, c.allocator)
	has_more := len(d.arguments) > 1 || (d.content != nil && rd.sl_len(d.content) > 0)
	span := text_element(c, .inline, "", strings.concatenate({text, ": " if has_more else "."}),
		"versionmodified", kind)
	para := dt.new_element(doc, .paragraph)
	dt.append_child(doc, para, span)
	dt.append_child(doc, node, para)
	if len(d.arguments) > 1 {
		nodes, msgs := rd.d_inline_text(c, d, d.arguments[1], d.lineno + 1)
		rd.extend(c, para, nodes[:])
		rd.extend(c, node, msgs[:])
	}
	if d.content != nil && rd.sl_len(d.content) > 0 {
		rd.d_nested_parse(c, d, node)
		// the first paragraph of the content continues the label's
		second := dt.next_sibling(doc, para)
		if len(d.arguments) == 1 && second != 0 && dt.is(doc, second, {.paragraph}) {
			for ch := dt.first_child(doc, second); ch != 0; ch = dt.first_child(doc, second) {
				dt.remove_child(doc, second, ch)
				dt.append_child(doc, para, ch)
			}
			dt.remove_child(doc, node, second)
		}
	}
	return rd.result_of(c, node), nil
}

@(private = "file")
version_label :: proc(name: string) -> (label, kind: string) {
	switch name {
	case "versionadded":
		return "Added in version", "added"
	case "versionchanged":
		return "Changed in version", "changed"
	case "versionremoved":
		return "Removed in version", "removed"
	}
	return "Deprecated since version", "deprecated"
}

// ``centered``: a bold centered paragraph.
@(private = "file")
run_centered :: proc(c: ^rd.Context, d: ^rd.Directive) -> (rd.Nodes, rd.Failure) {
	nodes, msgs := rd.d_inline_text(c, d, d.arguments[0], d.lineno)
	strong := rd.element(c, .strong, d.arguments[0], nodes[:])
	para := rd.element(c, .paragraph, "", {strong})
	dt.list_append(c.doc, para, dt.K_CLASSES, "centered")
	out := rd.result_of(c, para)
	append(&out, ..msgs[:])
	return out, nil
}

// ``only``: the content when the expression holds for the build's format
// ("html" or "latex", also the builder and format names).
@(private = "file")
run_only :: proc(c: ^rd.Context, d: ^rd.Directive) -> (rd.Nodes, rd.Failure) {
	b := build_of(c)
	if !eval_tags(d.arguments[0], b.format) do return rd.result_of(c), nil
	holder := dt.new_element(c.doc, .container)
	rd.d_set_source_line(c, d, holder, d.lineno)
	rd.nested_parse(c, d.sm, d.content, d.content_offset, holder, match_titles_in = false)
	out := rd.result_of(c)
	for ch := dt.first_child(c.doc, holder); ch != 0; ch = dt.first_child(c.doc, holder) {
		dt.remove_child(c.doc, holder, ch)
		append(&out, ch)
	}
	return out, nil
}

// ``hlist``: the bullet list of the content split into columns
// (containers of class "hlist" and "hlist-col").
@(private = "file")
run_hlist :: proc(c: ^rd.Context, d: ^rd.Directive) -> (rd.Nodes, rd.Failure) {
	doc := c.doc
	ncolumns := option_int(d, "columns", 2)
	holder := dt.new_element(doc, .container)
	rd.d_nested_parse(c, d, holder)
	list := dt.first_child(doc, holder)
	if dt.child_count(doc, holder) != 1 || !dt.is(doc, list, {.bullet_list}) {
		return nil, rd.directive_error(.ERROR,
			".. hlist content is not a list")
	}
	node := dt.new_element(doc, .container)
	dt.list_append(doc, node, dt.K_CLASSES, "hlist")
	rd.d_set_source_line(c, d, node, d.lineno)
	items := dt.children(doc, list)
	nitems := len(items)
	per, extra := nitems / max(ncolumns, 1), nitems % max(ncolumns, 1)
	index := 0
	for col in 0 ..< max(ncolumns, 1) {
		size := per + (1 if col < extra else 0)
		column := dt.new_element(doc, .container)
		dt.list_append(doc, column, dt.K_CLASSES, "hlist-col")
		sub := dt.new_element(doc, .bullet_list)
		dt.set_attr(doc, sub, "bullet", dt.get_string(doc, list, "bullet", "*"))
		for item in items[index:index + size] {
			dt.remove_child(doc, list, item)
			dt.append_child(doc, sub, item)
		}
		index += size
		dt.append_child(doc, column, sub)
		dt.append_child(doc, node, column)
	}
	return rd.result_of(c, node), nil
}

// ``productionlist``: the grammar as a literal block (class
// "productionlist").
@(private = "file")
run_productionlist :: proc(c: ^rd.Context, d: ^rd.Directive) -> (rd.Nodes, rd.Failure) {
	text := d.arguments[0]
	lines := strings.split_lines(text, c.allocator)
	b := strings.builder_make(c.allocator)
	for line, i in lines {
		if i > 0 do strings.write_byte(&b, '\n')
		strings.write_string(&b, strings.trim_space(line))
	}
	code := strings.to_string(b)
	node := text_element(c, .literal_block, code, code, "productionlist")
	rd.d_set_source_line(c, d, node, d.lineno)
	return rd.result_of(c, node), nil
}

// --- tag expressions ---------------------------------------------------------------------

// ``sphinx.util.tags.Tags.eval_condition``: names joined with ``and``,
// ``or``, ``not`` and parentheses; the names true for a format are its
// tag ("html", "latex") and the builder/format names that go with it.
eval_tags :: proc(expr: string, format: Format) -> bool {
	tokens := tag_tokens(expr)
	pos := 0
	value := eval_or(tokens, &pos, format)
	return value
}

@(private = "file")
tag_tokens :: proc(expr: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	i := 0
	for i < len(expr) {
		ch := expr[i]
		switch {
		case ch == ' ' || ch == '\t':
			i += 1
		case ch == '(' || ch == ')':
			append(&out, expr[i:i + 1])
			i += 1
		case:
			j := i
			for j < len(expr) && !strings.contains_rune(" \t()", rune(expr[j])) do j += 1
			append(&out, expr[i:j])
			i = j
		}
	}
	return out[:]
}

@(private = "file")
eval_or :: proc(tokens: []string, pos: ^int, format: Format) -> bool {
	v := eval_and(tokens, pos, format)
	for pos^ < len(tokens) && tokens[pos^] == "or" {
		pos^ += 1
		w := eval_and(tokens, pos, format)
		v = v || w
	}
	return v
}

@(private = "file")
eval_and :: proc(tokens: []string, pos: ^int, format: Format) -> bool {
	v := eval_not(tokens, pos, format)
	for pos^ < len(tokens) && tokens[pos^] == "and" {
		pos^ += 1
		w := eval_not(tokens, pos, format)
		v = v && w
	}
	return v
}

@(private = "file")
eval_not :: proc(tokens: []string, pos: ^int, format: Format) -> bool {
	if pos^ >= len(tokens) do return false
	tok := tokens[pos^]
	pos^ += 1
	switch tok {
	case "not":
		return !eval_not(tokens, pos, format)
	case "(":
		v := eval_or(tokens, pos, format)
		if pos^ < len(tokens) && tokens[pos^] == ")" do pos^ += 1
		return v
	}
	return tag_is_set(tok, format)
}

@(private = "file")
tag_is_set :: proc(tag: string, format: Format) -> bool {
	switch format {
	case .Html:
		return tag == "html" || tag == "format_html" || tag == "builder_html" || tag == "docodin"
	case .Latex:
		return tag == "latex" || tag == "format_latex" || tag == "builder_latex" ||
			tag == "docodin"
	}
	return false
}
