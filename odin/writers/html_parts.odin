package writers

import "core:strings"

import dt "../doctree"

// The document node, the ``publish_parts`` parts and the template of the
// HTML5 writer (``visit_document``, ``depart_document``,
// ``Writer.apply_template`` and ``Writer.assemble_parts``).

html_visit_document :: proc(t: ^Html, n: dt.Node) -> Visit {
	title := attr(t.doc, n, "title")
	if title == "" do title = path_name(attr(t.doc, n, "source"))
	if title == "" do title = "untitled Docutils document"
	begin(&t.head)
	w(&t.head, "<title>")
	write_encoded(&t.head, title)
	w(&t.head, "</title>\n")
	return .Continue
}

html_depart_document :: proc(t: ^Html, n: dt.Node) {
	put(&t.head_prefix, HTML_DOCTYPE)
	begin(&t.head_prefix)
	w(&t.head_prefix, "<html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"")
	w(&t.head_prefix, t.s.language_code)
	w(&t.head_prefix, "\" lang=\"")
	w(&t.head_prefix, t.s.language_code)
	w(&t.head_prefix, "\">\n<head>\n")
	put(&t.html_prolog, HTML_DOCTYPE)
	head := out_make(context.temp_allocator)
	put_out(&head, &t.meta)
	put_out(&head, &t.head)
	if strings.contains(text_of(&t.meta), "name=\"dcterms.") {
		put(&head, "<link rel=\"schema.dcterms\" href=\"http://purl.org/dc/terms/\"/>")
	}
	if chunks(&t.math_header) > 0 {
		put_out(&head if t.math_output == "mathjax" else &t.stylesheet, &t.math_header)
	}
	t.head = head
	put_range(&t.html_head, &t.head, 1 if encoding_declared(t.s) else 0)
	starttag(t, n, "main", o = &t.body_prefix)
	suffix := out_make(context.temp_allocator)
	put(&suffix, "</main>\n")
	put_out(&suffix, &t.body_suffix)
	t.body_suffix = suffix
	put_out(&t.fragment, &t.body)
	put_range(&t.html_body, &t.body_prefix, 1)
	put_out(&t.html_body, &t.body_pre_docinfo)
	put_out(&t.html_body, &t.docinfo)
	put_out(&t.html_body, &t.body)
	put_range(&t.html_body, &t.body_suffix, 0, -1)
	if len(t.stack) != 0 do t.err = "AssertionError: len(context) != 0"
}

@(private = "file")
Html_Part :: struct {
	name: string,
	out:  proc(t: ^Html) -> ^Out,
}

// ``Writer.visitor_attributes`` of the HTML writers.
@(private = "file")
HTML_PARTS := [?]Html_Part {
	{"head_prefix", proc(t: ^Html) -> ^Out {return &t.head_prefix}},
	{"head", proc(t: ^Html) -> ^Out {return &t.head}},
	{"stylesheet", proc(t: ^Html) -> ^Out {return &t.stylesheet}},
	{"body_prefix", proc(t: ^Html) -> ^Out {return &t.body_prefix}},
	{"body_pre_docinfo", proc(t: ^Html) -> ^Out {return &t.body_pre_docinfo}},
	{"docinfo", proc(t: ^Html) -> ^Out {return &t.docinfo}},
	{"body", proc(t: ^Html) -> ^Out {return &t.body}},
	{"body_suffix", proc(t: ^Html) -> ^Out {return &t.body_suffix}},
	{"title", proc(t: ^Html) -> ^Out {return &t.title}},
	{"subtitle", proc(t: ^Html) -> ^Out {return &t.subtitle}},
	{"header", proc(t: ^Html) -> ^Out {return &t.header}},
	{"footer", proc(t: ^Html) -> ^Out {return &t.footer}},
	{"meta", proc(t: ^Html) -> ^Out {return &t.meta}},
	{"fragment", proc(t: ^Html) -> ^Out {return &t.fragment}},
	{"html_prolog", proc(t: ^Html) -> ^Out {return &t.html_prolog}},
	{"html_head", proc(t: ^Html) -> ^Out {return &t.html_head}},
	{"html_title", proc(t: ^Html) -> ^Out {return &t.html_title}},
	{"html_subtitle", proc(t: ^Html) -> ^Out {return &t.html_subtitle}},
	{"html_body", proc(t: ^Html) -> ^Out {return &t.html_body}},
}

// ``Writer.assemble_parts``: the visitor attributes after the base parts.
html_parts :: proc(t: ^Html, res: ^Result) {
	for p in HTML_PARTS do append(&res.parts, Part{p.name, text_of(p.out(t))})
}

// ``Writer.apply_template``: ``template % interpolation_dict()``.
apply_html_template :: proc(t: ^Html) -> string {
	template := t.s.template
	text, found := data_file(.Html5, "template.txt")
	if template != "" {
		err: string
		text, err = read_text(template, context.temp_allocator)
		found = err == ""
		if !found {
			t.err = cat("FileNotFoundError: ", err)
			return ""
		}
	}
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(text); i += 1 {
		c := text[i]
		if c != '%' || i + 1 >= len(text) {
			strings.write_byte(&b, c)
			continue
		}
		if text[i + 1] == '%' {
			strings.write_byte(&b, '%')
			i += 1
			continue
		}
		end := strings.index(text[i:], ")s")
		if text[i + 1] != '(' || end < 0 {
			t.err = "ValueError: unsupported format character in the template"
			return ""
		}
		value, ok := interpolation(t, text[i + 2:i + end])
		if !ok {
			t.err = cat("KeyError: ", text[i + 2:i + end])
			return ""
		}
		strings.write_string(&b, value)
		i += end + 1
	}
	return strings.to_string(b)
}

// An item of ``Writer.interpolation_dict()``.
@(private = "file")
interpolation :: proc(t: ^Html, key: string) -> (string, bool) {
	switch key {
	case "encoding":
		return t.s.output_encoding, true
	case "version":
		return DOCUTILS_VERSION, true
	}
	for p in HTML_PARTS {
		if p.name == key do return strings.trim_right(text_of(p.out(t)), "\n"), true
	}
	return "", false
}
