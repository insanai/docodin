package writers

import "base:runtime"
import "core:strings"

import dt "../doctree"

// The HTML5 writer (``writers.html5_polyglot``): ``_html_base.HTMLTranslator``
// with the ``html5_polyglot.HTMLTranslator`` overrides.  This file holds the
// translator state, ``starttag`` and the encoding helpers; the visitors are
// in html_body.odin, html_inline.odin, html_docinfo.odin, html_tables.odin
// and html_media.odin, the parts and template in html_parts.odin.

// An item of the translator's heterogeneous ``context`` stack.
Ctx :: union {
	string, // a closing tag or suffix
	int, // a chunk index of ``body``
	bool, // the saved ``compact_simple`` flag
}

Html :: struct {
	doc:                  ^dt.Doc,
	s:                    ^Settings,
	err:                  string,
	language:             ^Language_Module,
	initial_header_level: int,
	image_loading:        string,
	math_output:          string, // "html", "latex", "mathjax" or "mathml"
	math_options:         string,
	mathjax_url:          string,
	// parts (``Writer.visitor_attributes``)
	head_prefix:          Out,
	head:                 Out,
	stylesheet:           Out,
	body_prefix:          Out,
	body_pre_docinfo:     Out,
	docinfo:              Out,
	body:                 Out,
	body_suffix:          Out,
	title:                Out,
	subtitle:             Out,
	header:               Out,
	footer:               Out,
	meta:                 Out,
	fragment:             Out,
	html_prolog:          Out,
	html_head:            Out,
	html_title:           Out,
	html_subtitle:        Out,
	html_body:            Out,
	math_header:          Out,
	// bookkeeping
	stack:                [dynamic]Ctx, // ``context``
	section_level:        int,
	colspecs:             [dynamic]dt.Node,
	stubs:                map[dt.Node][dynamic]bool, // ``tgroup.stubs``
	row_column:           map[dt.Node]int, // ``row.column``
	tagnames:             map[dt.Node]string, // ``node.html5tagname``
	compact_simple:       bool,
	in_document_title:    int,
	in_mailto:            bool,
	in_sidebar:           bool,
	messages:             [dynamic]dt.Node, // system messages of writing issues
	math_classes:         [Math_Format][dynamic]string,
}

HTML_DOCTYPE :: "<!DOCTYPE html>\n"
HTML_CONTENT_TYPE :: "<meta charset=\"%s\" />\n"
HTML_GENERATOR :: "<meta name=\"generator\" content=\"Docutils " + DOCUTILS_VERSION +
	": https://docutils.sourceforge.io/\" />\n"
HTML_VIEWPORT :: "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />\n"
HTML_BODY_PREFIX :: "</head>\n<body>\n"
HTML_BODY_SUFFIX :: "</body>\n</html>\n"

// An attribute of ``starttag`` (keyword arguments of the Python method).
Att :: struct {
	name:  string,
	value: string,
}

write_html5 :: proc(doc: ^dt.Doc, s: Settings, allocator: runtime.Allocator) -> Result {
	settings := s
	t := new(Html, allocator)
	html_init(t, doc, &settings, allocator)
	if t.err == "" do walkabout(t, &html_dispatch, doc.root)
	res := Result {
		err = t.err,
	}
	if t.err != "" do return res
	res.output = apply_html_template(t)
	base_parts(&res, &settings, allocator)
	html_parts(t, &res)
	return res
}

@(private = "file")
html_init :: proc(t: ^Html, doc: ^dt.Doc, s: ^Settings, a: runtime.Allocator) {
	t.doc = doc
	t.s = s
	t.language = get_language(s.language_code)
	outs := [?]^Out {
		&t.head_prefix, &t.head, &t.stylesheet, &t.body_prefix, &t.body_pre_docinfo,
		&t.docinfo, &t.body, &t.body_suffix, &t.title, &t.subtitle, &t.header, &t.footer,
		&t.meta, &t.fragment, &t.html_prolog, &t.html_head, &t.html_title, &t.html_subtitle,
		&t.html_body, &t.math_header,
	}
	for o in outs do o^ = out_make(a)
	t.stack = make([dynamic]Ctx, 0, 64, a)
	t.colspecs = make([dynamic]dt.Node, 0, 16, a)
	t.stubs = make(map[dt.Node][dynamic]bool, 8, a)
	t.row_column = make(map[dt.Node]int, 16, a)
	t.tagnames = make(map[dt.Node]string, 16, a)
	t.messages = make([dynamic]dt.Node, 0, 4, a)
	init_math_classes(t)
	html_init_settings(t)
	html_init_parts(t)
}

@(private = "file")
html_init_settings :: proc(t: ^Html) {
	s := t.s
	if s.initial_header_level == "auto" {
		first := dt.first_child(t.doc, t.doc.root)
		titled := first != 0 && dt.next_node(t.doc, first, dt.Tag_Set{.title}, true, false) != 0
		t.initial_header_level = 2 if titled else 1
	} else {
		level, ok := parse_int(s.initial_header_level)
		if !ok {
			t.err = "ValueError: invalid literal for int() with base 10"
			return
		}
		t.initial_header_level = level
	}
	// ``getattr(settings, "image_loading", default)``: the setting exists (None
	// by default), so the default from the legacy ``embed_images`` is unused.
	t.image_loading = s.image_loading
	format, _, options := strings.partition(strings.trim_left_space(s.math_output), " ")
	t.math_output = strings.to_lower(format, context.temp_allocator)
	t.math_options = strings.trim_space(options)
	t.mathjax_url = "file:/usr/share/javascript/mathjax/MathJax.js"
	switch t.math_output {
	case "html", "latex", "mathml", "mathjax":
	case "":
		t.err = "ValueError: not enough values to unpack (expected 2, got 0)"
	case:
		t.err = "LookupError: Unknown math output format"
	}
}

@(private = "file")
html_init_parts :: proc(t: ^Html) {
	s := t.s
	put(&t.body_prefix, HTML_BODY_PREFIX)
	put(&t.body_suffix, HTML_BODY_SUFFIX)
	put(&t.html_head, HTML_CONTENT_TYPE)
	if encoding_declared(s) do put(&t.meta, content_type(s.output_encoding))
	put(&t.meta, HTML_GENERATOR)
	for path in get_stylesheet_list(s) do stylesheet_call(t, &t.stylesheet, path)
	if s.xml_declaration {
		put(&t.head_prefix, xml_declaration(s.output_encoding))
		put(&t.html_prolog, xml_declaration("%s"))
	}
	put(&t.meta, HTML_VIEWPORT)
}

// Is the output encoding given (``output_encoding.lower() != "unicode"``)?
encoding_declared :: proc(s: ^Settings) -> bool {
	encoding := strings.to_lower(s.output_encoding, context.temp_allocator)
	return encoding != "" && encoding != "unicode"
}

@(private = "file")
content_type :: proc(encoding: string) -> string {
	return cat("<meta charset=\"", encoding, "\" />\n")
}

// ``int(s)`` of a decimal integer.
parse_int :: proc(s: string) -> (int, bool) {
	t := strings.trim_space(s)
	if len(t) == 0 do return 0, false
	n, sign, i := 0, 1, 0
	if t[0] == '-' || t[0] == '+' {
		sign = -1 if t[0] == '-' else 1
		i = 1
	}
	if i >= len(t) do return 0, false
	for ; i < len(t); i += 1 {
		if t[i] < '0' || t[i] > '9' do return 0, false
		n = n * 10 + int(t[i] - '0')
	}
	return sign * n, true
}

// ``utils.get_stylesheet_list(settings)``.
get_stylesheet_list :: proc(s: ^Settings) -> []string {
	if len(s.stylesheet_path) == 0 do return s.stylesheet
	out := make([]string, len(s.stylesheet_path), context.temp_allocator)
	for p, i in s.stylesheet_path do out[i] = find_file_in_dirs(p, s.stylesheet_dirs)
	return out
}

// ``stylesheet_call(path, adjust_path)``: embed or link a stylesheet.
stylesheet_call :: proc(t: ^Html, o: ^Out, path: string, adjust := Maybe(bool){}) {
	adjust_path := adjust.? or_else (len(t.s.stylesheet_path) > 0)
	if t.s.embed_stylesheet {
		content, err := read_text(path, context.temp_allocator)
		if err != "" {
			msg := cat("Cannot embed stylesheet: ", err)
			dt.error(t.doc, msg)
			begin(o)
			w(o, "<--- ")
			w(o, msg)
			w(o, " --->\n")
			return
		}
		begin(o)
		w(o, "<style type=\"text/css\">\n\n")
		w(o, content)
		w(o, "\n</style>\n")
		return
	}
	href := path
	if adjust_path do href = relative_path(t.s.output_path, path)
	begin(o)
	w(o, "<link rel=\"stylesheet\" href=\"")
	write_encoded(o, href)
	w(o, "\" type=\"text/css\" />\n")
}

// --- encoding ----------------------------------------------------------------------------

// ``HTMLTranslator.encode``: character references for "&<\">@".
write_encoded :: proc(o: ^Out, text: string) {
	start := 0
	for i in 0 ..< len(text) {
		rep: string
		switch text[i] {
		case '&':
			rep = "&amp;"
		case '<':
			rep = "&lt;"
		case '"':
			rep = "&quot;"
		case '>':
			rep = "&gt;"
		case '@':
			rep = "&#64;"
		case:
			continue
		}
		append(&o.buf, text[start:i])
		append(&o.buf, rep)
		start = i + 1
	}
	append(&o.buf, text[start:])
}

// ``encode(text)`` as a string (temp allocator).
encoded :: proc(text: string) -> string {
	o := out_make(context.temp_allocator, len(text) + 16)
	begin(&o)
	write_encoded(&o, text)
	return text_of(&o)
}

// ``attval(text)``: whitespace to spaces, encoded, and cloaked in mailto
// links.
write_attval :: proc(t: ^Html, o: ^Out, text: string) {
	b := make([]u8, len(text), context.temp_allocator)
	for i in 0 ..< len(text) {
		c := text[i]
		b[i] = ' ' if c == '\n' || c == '\r' || c == '\t' || c == '\v' || c == '\f' else c
	}
	if !(t.in_mailto && t.s.cloak_email_addresses) {
		write_encoded(o, string(b))
		return
	}
	enc := encoded(string(b))
	enc, _ = strings.replace_all(enc, "%40", "&#37;&#52;&#48;", context.temp_allocator)
	enc, _ = strings.replace_all(enc, ".", "&#46;", context.temp_allocator)
	w(o, enc)
}

// --- starttag ------------------------------------------------------------------------------

// ``starttag(node, tagname, suffix, empty, **attributes)`` into ``o``
// (default: ``body``) as one chunk.  ``class`` is the ``CLASS`` keyword
// (split at whitespace), ``classes`` and ``ids`` the list keywords; ``n``
// may be 0 for a start tag without node.  As in docutils, the classes of
// ``n`` are appended to the ``classes`` list: to the list of ``classes_of``
// (a node whose ``classes`` attribute is passed) or to ``classes_store``.
starttag :: proc(
	t: ^Html,
	n: dt.Node,
	tagname: string,
	suffix := "\n",
	empty := false,
	class := "",
	classes: []string = nil,
	ids: []string = nil,
	atts: []Att = nil,
	o: ^Out = nil,
	classes_of: dt.Node = 0,
	classes_store: ^[dynamic]string = nil,
) {
	out := o if o != nil else &t.body
	all := make([dynamic]Att, 0, len(atts) + 4, context.temp_allocator)
	append(&all, ..atts)
	class_list := make([dynamic]string, 0, len(classes) + 4, context.temp_allocator)
	switch {
	case classes_of != 0:
		append(&class_list, ..list_strings(t.doc, classes_of, dt.K_CLASSES))
	case classes_store != nil:
		append(&class_list, ..classes_store[:])
	case:
		append(&class_list, ..classes)
	}
	tag_classes(t, n, class, &class_list, &all)
	if classes_of != 0 do dt.set_list(t.doc, classes_of, dt.K_CLASSES, ..class_list[:])
	if classes_store != nil {
		clear(classes_store)
		append(classes_store, ..class_list[:])
	}
	id_list := make([dynamic]string, 0, 4, context.temp_allocator)
	if n != 0 do append(&id_list, ..list_strings(t.doc, n, dt.K_IDS))
	append(&id_list, ..ids)
	if len(id_list) > 0 do append(&all, Att{"id", id_list[0]})
	sort_atts(all[:])
	sequential := n != 0 && (dt.is_a(t.doc, n, .Sequential) || dt.is(t.doc, n, {.docinfo, .table}))
	outside := empty || sequential
	begin(out)
	if outside do write_id_spans(out, id_list[:])
	wb(out, '<')
	w(out, tagname)
	for a in all {
		wb(out, ' ')
		w(out, a.name)
		w(out, "=\"")
		write_attval(t, out, a.value)
		wb(out, '"')
	}
	w(out, " />" if empty else ">")
	w(out, suffix)
	if !outside do write_id_spans(out, id_list[:])
}

// ``emptytag``.
emptytag :: proc(
	t: ^Html,
	n: dt.Node,
	tagname: string,
	suffix := "\n",
	class := "",
	classes: []string = nil,
	atts: []Att = nil,
	o: ^Out = nil,
) {
	starttag(t, n, tagname, suffix, true, class, classes, nil, atts, o)
}

@(private = "file")
write_id_spans :: proc(o: ^Out, ids: []string) {
	if len(ids) < 2 do return
	for id in ids[1:] {
		w(o, "<span id=\"")
		w(o, id)
		w(o, "\"></span>")
	}
}

// ``_starttag_classes``: unify the class arguments and move a language
// class to the ``lang`` attribute.
@(private = "file")
tag_classes :: proc(
	t: ^Html,
	n: dt.Node,
	class: string,
	classes: ^[dynamic]string,
	all: ^[dynamic]Att,
) {
	lang := ""
	candidates := make([dynamic]string, 0, 8, context.temp_allocator)
	if n != 0 do append(&candidates, ..list_strings(t.doc, n, dt.K_CLASSES))
	rest := class
	for c in strings.fields_iterator(&rest) do append(&candidates, c)
	for c in candidates {
		if strings.has_prefix(c, "language-") {
			if lang == "" do lang = c[9:]
		} else if strings.trim_space(c) != "" && !contains(classes[:], c) {
			append(classes, c)
		}
	}
	if lang != "" do append(all, Att{"lang", lang})
	list := classes^
	if n != 0 && dt.tag(t.doc, n) == .table {
		kept := make([dynamic]string, 0, len(list), context.temp_allocator)
		for c in list {
			if c != "colwidths-auto" && c != "colwidths-given" && c != "colwidths-grid" {
				append(&kept, c)
			}
		}
		list = kept
	}
	if len(list) > 0 {
		append(all, Att{"class", strings.join(list[:], " ", context.temp_allocator)})
	}
}

@(private = "file")
sort_atts :: proc(atts: []Att) {
	for i in 1 ..< len(atts) {
		for j := i; j > 0 && atts[j].name < atts[j - 1].name; j -= 1 {
			atts[j], atts[j - 1] = atts[j - 1], atts[j]
		}
	}
}

// A one-attribute list (in the temp allocator).
one_att :: proc(name, value: string) -> []Att {
	a := make([]Att, 1, context.temp_allocator)
	a[0] = {name, value}
	return a
}

// A one-string list (in the temp allocator).
one_str :: proc(s: string) -> []string {
	a := make([]string, 1, context.temp_allocator)
	a[0] = s
	return a
}

contains :: proc(list: []string, s: string) -> bool {
	for x in list do if x == s do return true
	return false
}

// --- context stack ------------------------------------------------------------------------

push_ctx :: proc(t: ^Html, c: Ctx) {
	append(&t.stack, c)
}

pop_string :: proc(t: ^Html) -> string {
	s, _ := pop(&t.stack).(string)
	return s
}

pop_int :: proc(t: ^Html) -> int {
	i, _ := pop(&t.stack).(int)
	return i
}

// ``report_messages(node)``: write the queued system messages.
report_messages :: proc(t: ^Html, n: dt.Node) {
	if parent_is(t.doc, n, {.system_message, .entry}) do return
	for len(t.messages) > 0 {
		msg := t.messages[0]
		ordered_remove(&t.messages, 0)
		if t.s.report_level <= dt.get_int(t.doc, msg, dt.K_LEVEL) {
			walkabout(t, &html_dispatch, msg)
		}
	}
}

// ``set_class_on_child``.
set_class_on_child :: proc(t: ^Html, n: dt.Node, class: string, index := 0) {
	k := 0
	for c := dt.first_child(t.doc, n); c != 0; c = dt.next_sibling(t.doc, c) {
		if dt.is_a(t.doc, c, .Invisible) do continue
		if k == index {
			dt.list_append(t.doc, c, dt.K_CLASSES, class)
			return
		}
		k += 1
	}
}
