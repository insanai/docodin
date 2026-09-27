package site

import "core:os"
import "core:strconv"
import "core:strings"

import dt "../doctree"
import rd "../reader"

// ``code-block``, ``literalinclude`` and ``highlight`` without Pygments: a
// ``literal_block`` with the classes "code" and the language, as the
// docutils ``code`` directive writes it with ``syntax_highlight`` "none";
// line numbers are ``inline`` "ln" tokens and emphasized lines ``inline``
// "hll" elements.  A caption makes a ``container`` "literal-block-wrapper"
// with a paragraph "caption code-block-caption".

@(private = "file")
CODE_OPTIONS := [?]rd.Option_Spec {
	{"force", rd.flag},
	{"linenos", rd.flag},
	{"dedent", optional_int},
	{"lineno-start", rd.int_option},
	{"emphasize-lines", rd.unchanged_required},
	{"caption", rd.unchanged_required},
	{"class", rd.class_option},
	{"name", rd.unchanged},
}
CODE_BLOCK := rd.Directive_Spec {
	optional_arguments = 1,
	option_spec        = CODE_OPTIONS[:],
	has_content        = true,
	run                = run_code_block,
}
@(private = "file")
INCLUDE_OPTIONS := [?]rd.Option_Spec {
	{"dedent", optional_int},
	{"linenos", rd.flag},
	{"lineno-start", rd.int_option},
	{"lineno-match", rd.flag},
	{"tab-width", rd.int_option},
	{"language", rd.unchanged_required},
	{"force", rd.flag},
	{"encoding", rd.encoding},
	{"lines", rd.unchanged_required},
	{"start-after", rd.unchanged_required},
	{"start-at", rd.unchanged_required},
	{"end-before", rd.unchanged_required},
	{"end-at", rd.unchanged_required},
	{"prepend", rd.unchanged_required},
	{"append", rd.unchanged_required},
	{"emphasize-lines", rd.unchanged_required},
	{"caption", rd.unchanged},
	{"class", rd.class_option},
	{"name", rd.unchanged},
}
LITERALINCLUDE := rd.Directive_Spec {
	required_arguments        = 1,
	final_argument_whitespace = true,
	option_spec               = INCLUDE_OPTIONS[:],
	run                       = run_literalinclude,
}
@(private = "file")
HIGHLIGHT_OPTIONS := [?]rd.Option_Spec {
	{"linenothreshold", rd.int_option},
	{"force", rd.flag},
}
HIGHLIGHT := rd.Directive_Spec {
	required_arguments = 1,
	option_spec        = HIGHLIGHT_OPTIONS[:],
	run                = run_highlight,
}

@(private = "file")
optional_int :: proc(c: ^rd.Context, argument: Maybe(string)) -> (rd.Option_Value, string) {
	a, ok := argument.?
	if !ok || strings.trim_space(a) == "" do return rd.Opt_None{}, ""
	return rd.int_option(c, a)
}

@(private = "file")
run_highlight :: proc(c: ^rd.Context, d: ^rd.Directive) -> (rd.Nodes, rd.Failure) {
	b := build_of(c)
	b.pages[b.current].highlight = strings.clone(d.arguments[0], b.allocator)
	return rd.result_of(c), nil
}

// A code block's text and presentation.
@(private = "file")
Code :: struct {
	text:       string,
	language:   string,
	linenos:    bool,
	start:      int, // the number of the first line
	emphasized: []bool, // by line index (nil: none)
}

@(private = "file")
run_code_block :: proc(c: ^rd.Context, d: ^rd.Directive) -> (rd.Nodes, rd.Failure) {
	if err := rd.assert_has_content(d); err != nil do return nil, err
	b := build_of(c)
	code := Code {
		text     = rd.content_text(c, d),
		language = d.arguments[0] if len(d.arguments) > 0 else b.pages[b.current].highlight,
		start    = option_int(d, "lineno-start", 1),
	}
	code.linenos = has_linenos(d)
	if v, has := rd.options_get(&d.options, "dedent"); has do code.text = dedent(c, code.text, v)
	return code_nodes(c, d, &code)
}

@(private = "file")
run_literalinclude :: proc(c: ^rd.Context, d: ^rd.Directive) -> (rd.Nodes, rd.Failure) {
	b := build_of(c)
	rel := d.arguments[0]
	path := join(b.site.srcdir, rel[1:]) if strings.has_prefix(rel, "/") else
		join(doc_source_dir(b), rel)
	data, err := os.read_entire_file_from_path(path, c.allocator)
	if err != nil {
		return nil, rd.directive_error(.WARNING, "Include file '", path,
			"' not found or reading it failed")
	}
	text, ferr := filter_lines(c, d, string(data))
	if ferr != "" do return nil, rd.directive_error(.WARNING, ferr)
	code := Code {
		text     = text,
		language = rd.options_string(&d.options, "language"),
		start    = option_int(d, "lineno-start", 1),
	}
	if code.language == "" do code.language = b.pages[b.current].highlight
	code.linenos = has_linenos(d)
	if v, has := rd.options_get(&d.options, "dedent"); has do code.text = dedent(c, code.text, v)
	return code_nodes(c, d, &code)
}

@(private = "file")
has_linenos :: proc(d: ^rd.Directive) -> bool {
	return rd.options_has(&d.options, "linenos") || rd.options_has(&d.options, "lineno-start")
}

// The directory of the document being read.
doc_source_dir :: proc(b: ^Build) -> string {
	return join(b.site.srcdir, doc_dir(current_name(b)))
}

// The literal block (in its caption wrapper) of ``code``.
@(private = "file")
code_nodes :: proc(c: ^rd.Context, d: ^rd.Directive, code: ^Code) -> (rd.Nodes, rd.Failure) {
	doc := c.doc
	nlines := strings.count(code.text, "\n") + 1
	if spec := rd.options_string(&d.options, "emphasize-lines"); spec != "" {
		ok: bool
		code.emphasized, ok = parse_line_spec(c, spec, nlines)
		if !ok do directive_warning(c, d.lineno, "Line spec '", spec, "': no lines selected")
	}
	node := dt.new_element(doc, .literal_block, code.text)
	dt.list_append(doc, node, dt.K_CLASSES, "code")
	lang := code.language
	if lang != "" && lang != "default" && lang != "none" {
		dt.list_append(doc, node, dt.K_CLASSES, lang)
	}
	for cl in rd.options_list(&d.options, "class") do dt.list_append(doc, node, dt.K_CLASSES, cl)
	if code.linenos do dt.list_append(doc, node, dt.K_CLASSES, "linenos")
	add_code_lines(c, node, code)
	rd.d_set_source_line(c, d, node, d.lineno)
	caption := rd.options_string(&d.options, "caption")
	if caption == "" {
		rd.add_name(c, d, node)
		return rd.result_of(c, node), nil
	}
	wrapper := dt.new_element(doc, .container)
	dt.list_append(doc, wrapper, dt.K_CLASSES, "literal-block-wrapper")
	rd.d_set_source_line(c, d, wrapper, d.lineno)
	nodes, msgs := rd.d_inline_text(c, d, caption, d.lineno)
	para := rd.element(c, .paragraph, caption, nodes[:])
	dt.list_append(doc, para, dt.K_CLASSES, "caption")
	dt.list_append(doc, para, dt.K_CLASSES, "code-block-caption")
	dt.append_child(doc, wrapper, para)
	dt.append_child(doc, wrapper, node)
	rd.add_name(c, d, wrapper)
	out := rd.result_of(c, wrapper)
	append(&out, ..msgs[:])
	return out, nil
}

// The text of the block, line by line, with the line numbers and the
// emphasized lines.
@(private = "file")
add_code_lines :: proc(c: ^rd.Context, node: dt.Node, code: ^Code) {
	doc := c.doc
	if !code.linenos && code.emphasized == nil {
		dt.append_child(doc, node, dt.new_text(doc, code.text))
		return
	}
	lines := strings.split(code.text, "\n", c.allocator)
	width := len(rd.itoa(code.start + len(lines) - 1))
	for line, i in lines {
		target := node
		if i < len(code.emphasized) && code.emphasized[i] {
			target = dt.new_element(doc, .inline)
			dt.list_append(doc, target, dt.K_CLASSES, "hll")
			dt.append_child(doc, node, target)
		}
		if code.linenos {
			digits := rd.itoa(code.start + i)
			pad := strings.repeat(" ", width - len(digits), c.allocator)
			number := strings.concatenate({pad, digits, " "}, c.allocator)
			dt.append_child(doc, target, text_element(c, .inline, number, number, "ln"))
		}
		text := line if i == len(lines) - 1 else strings.concatenate({line, "\n"}, c.allocator)
		if text != "" do dt.append_child(doc, target, dt.new_text(doc, text))
	}
}

// ``parse_line_num_spec``: "1,3-5,8-" (1-based) as flags by line index.
@(private = "file")
parse_line_spec :: proc(c: ^rd.Context, spec: string, total: int) -> ([]bool, bool) {
	flags := make([]bool, total, c.allocator)
	any := false
	rest := spec
	for part in strings.split_iterator(&rest, ",") {
		p := strings.trim_space(part)
		if p == "" do continue
		lo, hi: int
		ok := true
		if dash := strings.index_byte(p, '-'); dash >= 0 {
			lo, ok = strconv.parse_int(strings.trim_space(p[:dash]))
			hi = total
			if tail := strings.trim_space(p[dash + 1:]); tail != "" {
				h, ok2 := strconv.parse_int(tail)
				hi, ok = h, ok && ok2
			}
		} else {
			lo, ok = strconv.parse_int(p)
			hi = lo
		}
		if !ok do return nil, false
		for n in max(lo, 1) ..= min(hi, total) {
			flags[n - 1] = true
			any = true
		}
	}
	return flags, any
}

// The literalinclude filters: ``start-*``/``end-*``, ``lines``,
// ``prepend``/``append``.
@(private = "file")
filter_lines :: proc(c: ^rd.Context, d: ^rd.Directive, text: string) -> (string, string) {
	t := strings.trim_suffix(text, "\n")
	lines := strings.split(t, "\n", c.allocator)
	if spec := rd.options_string(&d.options, "lines"); spec != "" {
		flags, ok := parse_line_spec(c, spec, len(lines))
		if !ok {
			msg := []string{"Line spec '", spec, "': no lines pulled from include file"}
			return "", strings.concatenate(msg, c.allocator)
		}
		kept := make([dynamic]string, c.allocator)
		for keep, i in flags do if keep do append(&kept, lines[i])
		lines = kept[:]
	}
	lines = cut_start(d, lines)
	lines = cut_end(d, lines)
	out := make([dynamic]string, c.allocator)
	if p := rd.options_string(&d.options, "prepend"); p != "" do append(&out, p)
	append(&out, ..lines)
	if a := rd.options_string(&d.options, "append"); a != "" do append(&out, a)
	return strings.join(out[:], "\n", c.allocator), ""
}

@(private = "file")
cut_start :: proc(d: ^rd.Directive, lines: []string) -> []string {
	for name in ([]string{"start-after", "start-at"}) {
		marker := rd.options_string(&d.options, name)
		if marker == "" do continue
		for line, i in lines {
			if !strings.contains(line, marker) do continue
			return lines[i + 1:] if name == "start-after" else lines[i:]
		}
	}
	return lines
}

@(private = "file")
cut_end :: proc(d: ^rd.Directive, lines: []string) -> []string {
	for name in ([]string{"end-before", "end-at"}) {
		marker := rd.options_string(&d.options, name)
		if marker == "" do continue
		for line, i in lines {
			if !strings.contains(line, marker) do continue
			return lines[:i] if name == "end-before" else lines[:i + 1]
		}
	}
	return lines
}

// ``:dedent:``: remove ``n`` columns (all common indentation without a
// value).
@(private = "file")
dedent :: proc(c: ^rd.Context, text: string, v: rd.Option_Value) -> string {
	lines := strings.split(text, "\n", c.allocator)
	n, given := v.(int)
	if !given {
		n = max(int)
		for line in lines {
			if strings.trim_space(line) == "" do continue
			n = min(n, len(line) - len(strings.trim_left(line, " ")))
		}
		if n == max(int) do n = 0
	}
	for &line in lines {
		k := 0
		for k < n && k < len(line) && line[k] == ' ' do k += 1
		line = line[k:]
	}
	return strings.join(lines, "\n", c.allocator)
}
