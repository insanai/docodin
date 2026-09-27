package writers

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"

import dt "../doctree"

// The LaTeX writer (``writers.latex2e``) and its XeTeX variant
// (``writers.xetex``): ``LaTeXTranslator``, its parts and the template.
//
// The translator's output collectors are ``Out`` buffers: ``t.out`` points
// at the current one (``push_collector`` / ``pop_collector``).  The head
// parts are lists of lines; ``requirements`` and ``fallbacks`` are maps
// written sorted by key.

// ``sep.join(items)`` in the temp allocator.
ljoin :: proc(items: []string, sep: string) -> string {
	return strings.join(items, sep, context.temp_allocator)
}

// A value of the heterogeneous ``context`` stack.
Latex_Ctx :: union {
	string,
	int,
}

Bibitem :: struct {
	label:    string,
	text:     string,
	has_text: bool,
}

Latex :: struct {
	doc:                             ^dt.Doc,
	s:                               ^Settings,
	err:                             string,
	is_xetex:                        bool,
	// latex_encode() flags
	inside_citation_reference_label: bool,
	verbatim:                        bool,
	insert_non_breaking_blanks:      bool,
	insert_newline:                  bool,
	literal:                         bool,
	alltt:                           bool,
	// state
	has_latex_toc:                   bool,
	section_level:                   int,
	thead_depth:                     int,
	latex_encoding:                  string,
	use_latex_citations:             bool,
	legacy_column_widths:            bool,
	section_enumerator_separator:    string,
	literal_block_env:               string,
	literal_block_options:           string,
	lang:                            ^Language_Module,
	babel:                           Babel,
	author_separator:                string,
	documentoptions:                 string,
	d_class:                         Document_Class,
	graphicx_package:                string,
	fallback_stylesheet:             bool,
	hyperref_options:                string,
	// head parts
	head_prefix:                     [dynamic]string,
	requirements:                    map[string]string,
	latex_preamble:                  [dynamic]string,
	stylesheet:                      [dynamic]string,
	fallbacks:                       map[string]string,
	pdfsetup:                        [dynamic]string,
	titledata:                       [dynamic]string,
	// body parts
	title:                           Out,
	subtitle:                        Out,
	body_pre_docinfo:                Out,
	docinfo:                         Out,
	dedication:                      Out,
	abstract:                        Out,
	body:                            Out,
	out:                             ^Out,
	out_stack:                       [dynamic]^Out,
	ctx:                             [dynamic]Latex_Ctx,
	title_labels:                    [dynamic]string,
	subtitle_labels:                 [dynamic]string,
	author_stack:                    [dynamic][dynamic]string,
	date:                            [dynamic]string,
	pdfauthor:                       [dynamic]string,
	pdfinfo:                         [dynamic]string,
	section_number:                  [dynamic]int,
	enumeration_counters:            [dynamic]string,
	bibitems:                        [dynamic]Bibitem,
	table_stack:                     [dynamic]^Table,
	active_table:                    ^Table,
}

// Docutils' output-encoding => TeX input encoding.
@(rodata)
LATEX_ENCODINGS := [?][2]string {
	{"iso-8859-1", "latin1"},
	{"iso-8859-2", "latin2"},
	{"iso-8859-3", "latin3"},
	{"iso-8859-4", "latin4"},
	{"iso-8859-5", "iso88595"},
	{"iso-8859-9", "latin5"},
	{"iso-8859-15", "latin9"},
	{"mac_cyrillic", "maccyr"},
	{"windows-1251", "cp1251"},
	{"koi8-r", "koi8-r"},
	{"koi8-u", "koi8-u"},
	{"windows-1250", "cp1250"},
	{"windows-1252", "cp1252"},
	{"us-ascii", "ascii"},
}

LATEX_HEAD_PARTS := [?]string {
	"head_prefix",
	"requirements",
	"latex_preamble",
	"stylesheet",
	"fallbacks",
	"pdfsetup",
	"titledata",
}

write_latex :: proc(
	doc: ^dt.Doc,
	s: Settings,
	xetex: bool,
	allocator: runtime.Allocator,
) -> Result {
	settings := s
	t := new(Latex, allocator)
	t.doc = doc
	t.s = &settings
	t.is_xetex = xetex
	latex_init(t)
	walkabout(t, &latex_dispatch, doc.root)
	res := Result {
		err = t.err,
	}
	if t.err != "" do return res
	assemble_latex_parts(t, &res, allocator)
	return res
}

@(private = "file")
latex_init :: proc(t: ^Latex) {
	a := context.temp_allocator
	t.requirements = make(map[string]string, 32, a)
	t.fallbacks = make(map[string]string, 32, a)
	for o in ([]^Out{&t.title, &t.subtitle, &t.body_pre_docinfo, &t.docinfo, &t.dedication,
		&t.abstract, &t.body}) {
		o^ = out_make(a)
	}
	t.out = &t.body
	init_latex_settings(t)
	init_latex_parts(t)
	init_font_requirements(t)
	if t.is_xetex {
		if t.latex_encoding == "utf8" {
			delete_key(&t.requirements, "_inputenc")
		} else {
			t.requirements["_inputenc"] = cat("\\XeTeXinputencoding ", t.latex_encoding, " ")
		}
	}
	init_stylesheets(t)
	init_hyperref(t)
}

@(private = "file")
init_latex_settings :: proc(t: ^Latex) {
	s := t.s
	t.latex_encoding = to_latex_encoding(s.output_encoding)
	// ``_check_deprecated_settings``: None defaults
	t.use_latex_citations = s.use_latex_citations.? or_else false
	t.legacy_column_widths = s.legacy_column_widths.? or_else true
	s.legacy_column_widths = t.legacy_column_widths
	t.section_enumerator_separator, _ = strings.replace_all(
		s.section_enumerator_separator,
		"_",
		"\\_",
		context.temp_allocator,
	)
	if s.literal_block_env != "" {
		t.literal_block_env, t.literal_block_options = split_literal_block_env(s.literal_block_env)
	} else if s.use_verbatim_when_possible.? or_else false {
		t.literal_block_env = "verbatim"
	}
	if len(s.use_bibtex) > 0 do t.use_latex_citations = true
	t.lang = get_language(s.language_code)
	t.babel = make_babel(t.doc, s.language_code, t.is_xetex)
	t.author_separator = t.lang.author_separators[0]
	opts := make([dynamic]string, 0, 2, context.temp_allocator)
	if s.documentoptions != "" do append(&opts, s.documentoptions)
	if t.babel.language != "english" && t.babel.language != "" do append(&opts, t.babel.language)
	t.documentoptions = strings.join(opts[:], ",", context.temp_allocator)
	t.d_class = make_document_class(s.documentclass, s.use_part_section)
	if s.graphicx_option == "" {
		t.graphicx_package = "\\usepackage{graphicx}"
	} else {
		t.graphicx_package = cat("\\usepackage[", s.graphicx_option, "]{graphicx}")
	}
}

// ``re.split(r"(\w+)(.*)", env)``: the environment name and its options.
@(private = "file")
split_literal_block_env :: proc(env: string) -> (name, options: string) {
	start := -1
	for i in 0 ..< len(env) {
		if is_word_byte(env[i]) {
			start = i
			break
		}
	}
	if start < 0 do return env, ""
	end := start
	for end < len(env) && is_word_byte(env[end]) do end += 1
	rest := env[end:]
	if nl := strings.index_byte(rest, '\n'); nl >= 0 do rest = rest[:nl]
	return env[start:end], rest
}

is_word_byte :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

@(private = "file")
init_latex_parts :: proc(t: ^Latex) {
	a := context.temp_allocator
	s := t.s
	t.head_prefix = make([dynamic]string, a)
	append(&t.head_prefix, cat("\\documentclass[", t.documentoptions, "]{", s.documentclass, "}"))
	t.latex_preamble = make([dynamic]string, a)
	append(&t.latex_preamble, s.latex_preamble)
	t.author_stack = make([dynamic][dynamic]string, a)
	first := make([dynamic]string, a)
	append(&first, "")
	append(&t.author_stack, first)
	t.pdfinfo = make([dynamic]string, a)
	if s.language_code != "en" do append(&t.pdfinfo, cat("  pdflang={", s.language_code, "},"))
	t.section_number = make([dynamic]int, a)
	append(&t.section_number, 0)
	t.active_table = new_table("longtable")
}

@(private = "file")
TEXTQUOTEDBL_OT1 :: "\\DeclareTextSymbol{\\textquotedbl}{OT1}{`\\\"}"

@(private = "file")
init_font_requirements :: proc(t: ^Latex) {
	enc := t.latex_encoding
	if enc != "ascii" && enc != "unicode" && enc != "utf8" {
		t.requirements["_inputenc"] = cat("\\usepackage[", enc, "]{inputenc}")
	}
	if !t.is_xetex {
		fe := t.s.font_encoding
		if fe != "" do t.requirements["_fontenc"] = cat("\\usepackage[", fe, "]{fontenc}")
		for part in strings.split(fe, ",", context.temp_allocator) {
			e := strings.trim_space(part)
			switch e {
			case "OT1":
				t.requirements["_textquotedblOT1"] = TEXTQUOTEDBL_OT1
			case "T1", "T2A", "T2B", "T2C", "T4", "T5":
			case:
				t.requirements["_textquotedbl"] = "\\DeclareTextSymbolDefault{\\textquotedbl}{T1}"
			}
		}
	}
	opts := t.documentoptions
	if !strings.has_prefix(t.s.documentclass, "scr") &&
	   (strings.contains(opts, "DIV") || strings.contains(opts, "BCOR")) {
		t.requirements["typearea"] = "\\usepackage{typearea}"
	}
}

// ``utils.get_stylesheet_list(settings)``.
stylesheet_list :: proc(s: ^Settings) -> [dynamic]string {
	items := s.stylesheet_path if len(s.stylesheet_path) > 0 else s.stylesheet
	out := make([dynamic]string, 0, len(items), context.temp_allocator)
	for p in items {
		append(&out, find_file_in_dirs(p, s.stylesheet_dirs) if len(s.stylesheet_path) > 0 else p)
	}
	return out
}

@(private = "file")
init_stylesheets :: proc(t: ^Latex) {
	list := stylesheet_list(t.s)
	if i, found := slice.linear_search(list[:], "docutils"); found {
		ordered_remove(&list, i)
		t.fallback_stylesheet = !t.s.legacy_class_functions
		if t.fallback_stylesheet {
			t.fallbacks["_docutils.sty"] = "\\usepackage{docutils}[2025-08-06]"
		}
	}
	t.stylesheet = make([dynamic]string, 0, len(list), context.temp_allocator)
	for p in list do append(&t.stylesheet, latex_stylesheet_call(t, p))
}

@(private = "file")
latex_stylesheet_call :: proc(t: ^Latex, path: string) -> string {
	suffix := path_suffix(path)
	is_package := suffix == ".sty" || suffix == ""
	if t.s.embed_stylesheet do return embed_latex_stylesheet(t, path, is_package)
	p := pure_path(path)
	cmd_open := "\\input{"
	if is_package {
		p = pure_path(path_parent(path), path_stem(path))
		cmd_open = "\\usepackage{"
	}
	if len(t.s.stylesheet_path) > 0 do p = relative_path(t.s.output_path, p)
	return cat(cmd_open, p, "}")
}

@(private = "file")
embed_latex_stylesheet :: proc(t: ^Latex, path: string, is_package: bool) -> string {
	p := pure_path(path)
	if is_package do p = cat(p[:len(p) - len(path_suffix(p))], ".sty")
	content, err := read_text(p, context.temp_allocator)
	if err != "" {
		msg, _ := strings.replace_all(cat("Cannot embed stylesheet:\n ", err), "\\\\", "/",
			context.temp_allocator)
		dt.error(t.doc, msg)
		quoted, _ := strings.replace_all(msg, "\n", "\n% ", context.temp_allocator)
		return cat("% ", quoted)
	}
	if is_package do content = cat("\\makeatletter\n", content, "\n\\makeatother")
	return cat("% embedded stylesheet: ", p, "\n", content)
}

@(private = "file")
init_hyperref :: proc(t: ^Latex) {
	opts := make([dynamic]string, 0, 3, context.temp_allocator)
	append(&opts, "hyperfootnotes=false")
	color := t.s.hyperlink_color
	switch strings.to_lower(color, context.temp_allocator) {
	case "0", "off", "no", "false", "":
	case:
		append(&opts, cat("colorlinks=true,linkcolor=", color, ",urlcolor=", color))
	}
	if t.s.hyperref_options != "" do append(&opts, t.s.hyperref_options)
	t.hyperref_options = strings.join(opts[:], ",\n              ", context.temp_allocator)
}

// ``LaTeXTranslator.to_latex_encoding``.
to_latex_encoding :: proc(encoding: string) -> string {
	e := strings.to_lower(encoding, context.temp_allocator)
	if i := strings.index_byte(e, ':'); i >= 0 do e = e[:i]
	for m in LATEX_ENCODINGS {
		if m[0] == e do return m[1]
	}
	e, _ = strings.remove_all(e, "_", context.temp_allocator)
	e, _ = strings.remove_all(e, "-", context.temp_allocator)
	return e
}

// --- output collectors ------------------------------------------------------------------

push_collector :: proc(t: ^Latex, o: ^Out) {
	append(&t.out_stack, t.out)
	t.out = o
}

// ``push_output_collector([])``.
push_new_collector :: proc(t: ^Latex) {
	o := new(Out, context.temp_allocator)
	o^ = out_make(context.temp_allocator, 64)
	push_collector(t, o)
}

pop_collector :: proc(t: ^Latex) -> ^Out {
	old := t.out
	t.out = pop(&t.out_stack)
	return old
}

o :: proc(t: ^Latex, s: string) {
	put(t.out, s)
}

ctx_push :: proc(t: ^Latex, c: Latex_Ctx) {
	append(&t.ctx, c)
}

ctx_pop_str :: proc(t: ^Latex) -> string {
	s, _ := pop(&t.ctx).(string)
	return s
}

// Insert a chunk at the start of ``out`` (``out.insert(0, s)``).
put_front :: proc(out: ^Out, s: string) {
	n := len(s)
	resize(&out.buf, len(out.buf) + n)
	copy(out.buf[n:], out.buf[:len(out.buf) - n])
	copy(out.buf[:n], s)
	for &st in out.starts do st += n
	inject_at(&out.starts, 0, 0)
}

// --- parts and template -----------------------------------------------------------------

@(private = "file")
head_part :: proc(lines: []string) -> string {
	if len(lines) == 0 do return ""
	b := strings.builder_make(context.temp_allocator)
	for l in lines {
		strings.write_string(&b, l)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

@(private = "file")
sorted_values :: proc(m: map[string]string) -> []string {
	keys := make([dynamic]string, 0, len(m), context.temp_allocator)
	for k in m do append(&keys, k)
	slice.sort(keys[:])
	out := make([]string, len(keys), context.temp_allocator)
	for k, i in keys do out[i] = m[k]
	return out
}

@(private = "file")
assemble_latex_parts :: proc(t: ^Latex, res: ^Result, allocator: runtime.Allocator) {
	values := [?]string {
		head_part(t.head_prefix[:]),
		head_part(sorted_values(t.requirements)),
		head_part(t.latex_preamble[:]),
		head_part(t.stylesheet[:]),
		head_part(sorted_values(t.fallbacks)),
		head_part(t.pdfsetup[:]),
		head_part(t.titledata[:]),
		text_of(&t.title),
		text_of(&t.subtitle),
		text_of(&t.body_pre_docinfo),
		text_of(&t.docinfo),
		text_of(&t.dedication),
		text_of(&t.abstract),
		text_of(&t.body),
	}
	names := [?]string {
		"head_prefix",
		"requirements",
		"latex_preamble",
		"stylesheet",
		"fallbacks",
		"pdfsetup",
		"titledata",
		"title",
		"subtitle",
		"body_pre_docinfo",
		"docinfo",
		"dedication",
		"abstract",
		"body",
	}
	template, ok := latex_template(t)
	if !ok {
		res.err = template
		return
	}
	lookup := make(map[string]string, 32, context.temp_allocator)
	for n, i in names do lookup[n] = values[i]
	lookup["template"] = template
	output, serr := substitute_template(template, lookup)
	if serr != "" {
		res.err = serr
		return
	}
	res.output = output
	base_parts(res, t.s, allocator)
	for n, i in names do append(&res.parts, Part{n, values[i]})
	append(&res.parts, Part{"template", template})
}

// The template text: the file ``settings.template`` if it exists, else the
// writer's template of that name.
@(private = "file")
latex_template :: proc(t: ^Latex) -> (string, bool) {
	path := t.s.template
	if path == "" do path = "xelatex.tex" if t.is_xetex else "default.tex"
	if os.is_file(path) {
		text, err := read_text(path, context.temp_allocator)
		if err == "" do return text, true
		return err, false
	}
	if text, ok := data_file(.Latex, path_name(path)); ok do return text, true
	return cat("FileNotFoundError: ", path), false
}

// ``string.Template(template).substitute(parts)``.
substitute_template :: proc(template: string, parts: map[string]string) -> (string, string) {
	b := strings.builder_make(context.temp_allocator)
	s := template
	for i := 0; i < len(s); {
		c := s[i]
		if c != '$' {
			strings.write_byte(&b, c)
			i += 1
			continue
		}
		if i + 1 < len(s) && s[i + 1] == '$' {
			strings.write_byte(&b, '$')
			i += 2
			continue
		}
		braced := i + 1 < len(s) && s[i + 1] == '{'
		j := i + 2 if braced else i + 1
		k := j
		for k < len(s) && is_word_byte(s[k]) && !(k == j && s[k] >= '0' && s[k] <= '9') do k += 1
		if k == j || (braced && (k >= len(s) || s[k] != '}')) {
			return "", "ValueError: Invalid placeholder in string"
		}
		value, found := parts[s[j:k]]
		if !found do return "", cat("KeyError: '", s[j:k], "'")
		strings.write_string(&b, value)
		i = k + 1 if braced else k
	}
	return strings.to_string(b), ""
}
