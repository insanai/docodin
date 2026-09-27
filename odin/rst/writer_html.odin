package rst

import "core:fmt"
import "core:strings"

// Native semantic HTML5 emitter (``docodin_render_html``, ``docodin html``).

Html_Config :: struct {
	title:      string,
	author:     string,
	standalone: bool,
	embed_css:  bool,
}

Html_Writer :: struct {
	using ctx:    Render_Context,
	buf:          strings.Builder,
	config:       Html_Config,
	title_styles: [dynamic]Title_Style,
	in_thead:     bool,
}

// A block element whose children are written between ``open`` and
// ``close`` (as inline markup when ``inline``).
@(private = "file")
Html_Wrap :: struct {
	open, close: string,
	inline:      bool,
}

@(private = "file")
HTML_WRAPS := #partial [Node_Kind]Html_Wrap {
	.Paragraph       = {"<p>", "</p>\n", true},
	.Bullet_List     = {"<ul>\n", "</ul>\n", false},
	.Enumerated_List = {"<ol>\n", "</ol>\n", false},
	.Definition_List = {"<dl class=\"docutils\">\n", "</dl>\n", false},
	.Term            = {"<dt>", "</dt>\n", true},
	.Classifier      = {" <span class=\"classifier\">", "</span>", true},
	.Definition      = {"<dd>\n", "</dd>\n", false},
	.Field_List      = {"<dl class=\"docutils field-list\">\n", "</dl>\n", false},
	.Field_Name      = {"<dt class=\"field-name\">", "</dt>\n", true},
	.Field_Body      = {"<dd class=\"field-body\">\n", "</dd>\n", false},
	.Line_Block      = {"<div class=\"line-block\">\n", "</div>\n", false},
	.Line            = {"<div class=\"line\">", "</div>\n", true},
	.Block_Quote     = {"<blockquote>\n", "</blockquote>\n", false},
	.Attribution     = {"<p class=\"attribution\">— <cite>", "</cite></p>\n", true},
	.Transition      = {"<hr class=\"docutils\" />\n", "", false},
	.Table           = {"<table class=\"docutils align-default\">\n", "</table>\n", false},
	.TBody           = {"<tbody>\n", "</tbody>\n", false},
	.Row             = {"<tr>\n", "</tr>\n", false},
}

DEFAULT_HTML_CSS :: `
:root {
  --primary: #1d4ed8;
  --bg: #ffffff;
  --text: #1f2937;
  --code-bg: #f3f4f6;
  --border: #e5e7eb;
}
* { box-sizing: border-box; }
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
    "Helvetica Neue", Arial, sans-serif;
  color: var(--text);
  background: var(--bg);
  line-height: 1.6;
  max-width: 860px;
  margin: 0 auto;
  padding: 2.5rem 1.5rem;
}
h1, h2, h3, h4, h5, h6 {
  margin-top: 1.8em;
  margin-bottom: 0.6em;
  font-weight: 600;
  line-height: 1.25;
}
h1 { font-size: 2.25rem; border-bottom: 2px solid var(--border); padding-bottom: 0.3em; }
h2 { font-size: 1.65rem; border-bottom: 1px solid var(--border); padding-bottom: 0.25em; }
h3 { font-size: 1.35rem; }
h4 { font-size: 1.15rem; }
p { margin: 1em 0; }
a { color: var(--primary); text-decoration: none; }
a:hover { text-decoration: underline; }
code {
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 0.88em;
  background-color: var(--code-bg);
  padding: 0.2em 0.4em;
  border-radius: 4px;
}
pre {
  background-color: var(--code-bg);
  padding: 1rem 1.2rem;
  border-radius: 6px;
  overflow-x: auto;
  border: 1px solid var(--border);
  line-height: 1.45;
}
pre code { background-color: transparent; padding: 0; }
blockquote {
  margin: 1.2em 0;
  padding: 0.6em 1.2rem;
  border-left: 4px solid #cbd5e1;
  color: #475569;
  background: #f8fafc;
  border-radius: 0 4px 4px 0;
}
table {
  border-collapse: collapse;
  width: 100%;
  margin: 1.5em 0;
}
th, td {
  border: 1px solid var(--border);
  padding: 0.65em 1em;
  text-align: left;
}
th {
  background-color: #f8fafc;
  font-weight: 600;
}
tr:nth-child(even) { background-color: #fbfcfd; }
.admonition {
  margin: 1.5em 0;
  padding: 1rem 1.2rem;
  border-radius: 6px;
  border-left: 4px solid var(--primary);
  background: #eff6ff;
}
.admonition.warning { border-color: #f59e0b; background: #fffbeb; }
.admonition.danger, .admonition.error { border-color: #ef4444; background: #fef2f2; }
.admonition.tip, .admonition.hint { border-color: #10b981; background: #ecfdf5; }
.admonition-title {
  font-weight: 600;
  margin-top: 0;
  margin-bottom: 0.5em;
  text-transform: capitalize;
}
ul, ol { padding-left: 2em; margin: 1em 0; }
li { margin: 0.35em 0; }
hr { border: none; border-top: 1px solid var(--border); margin: 2em 0; }
.footnote, .citation {
  font-size: 0.9em;
  color: #64748b;
  border-top: 1px solid var(--border);
  padding-top: 0.5em;
  margin-top: 1.5em;
}
`

// Text content: ``& < > "`` escaped.
escape_html_text :: proc(b: ^strings.Builder, s: string) {
	for i := 0; i < len(s); i += 1 {
		switch c := s[i]; c {
		case '&': strings.write_string(b, "&amp;")
		case '<': strings.write_string(b, "&lt;")
		case '>': strings.write_string(b, "&gt;")
		case '"': strings.write_string(b, "&quot;")
		case:     strings.write_byte(b, c)
		}
	}
}

// Attribute values (always double-quoted): ``& < > " '`` escaped.
escape_html_attr :: proc(b: ^strings.Builder, s: string) {
	for i := 0; i < len(s); i += 1 {
		switch c := s[i]; c {
		case '&':  strings.write_string(b, "&amp;")
		case '<':  strings.write_string(b, "&lt;")
		case '>':  strings.write_string(b, "&gt;")
		case '"':  strings.write_string(b, "&quot;")
		case '\'': strings.write_string(b, "&#x27;")
		case:      strings.write_byte(b, c)
		}
	}
}

write_html :: proc(doc: Node, p: ^Parser, config: Html_Config) -> string {
	w := Html_Writer {
		ctx          = render_context_make(p, doc),
		buf          = strings.builder_make(p.allocator),
		config       = config,
		title_styles = make([dynamic]Title_Style, p.allocator),
	}
	if config.standalone do html_head(&w, document_title(&w.ctx, doc, config.title))
	it := children(w.t, doc)
	for n in iterate(&it) do html_block(&w, n)
	if config.standalone do strings.write_string(&w.buf, "</main>\n</body>\n</html>\n")
	return strings.to_string(w.buf)
}

@(private = "file")
html_head :: proc(w: ^Html_Writer, title: string) {
	b := &w.buf
	strings.write_string(b, "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n")
	strings.write_string(b, "<meta charset=\"utf-8\">\n")
	strings.write_string(b, "<meta name=\"viewport\" ")
	strings.write_string(b, "content=\"width=device-width, initial-scale=1.0\">\n")
	if w.config.author != "" {
		strings.write_string(b, "<meta name=\"author\" content=\"")
		escape_html_attr(b, w.config.author)
		strings.write_string(b, "\">\n")
	}
	strings.write_string(b, "<title>")
	escape_html_text(b, title)
	strings.write_string(b, "</title>\n")
	if w.config.embed_css {
		strings.write_string(b, "<style>\n")
		strings.write_string(b, DEFAULT_HTML_CSS)
		strings.write_string(b, "</style>\n")
	}
	strings.write_string(b, "</head>\n<body>\n<main class=\"document\">\n")
}

// `` attr="value"`` with the value escaped.
@(private = "file")
html_attr :: proc(w: ^Html_Writer, attr, value: string) {
	fmt.sbprintf(&w.buf, " %s=\"", attr)
	escape_html_attr(&w.buf, value)
	strings.write_byte(&w.buf, '"')
}

@(private = "file")
html_children :: proc(w: ^Html_Writer, n: Node, inline := false) {
	it := children(w.t, n)
	for c in iterate(&it) {
		if inline {
			html_inline(w, c)
		} else {
			html_block(w, c)
		}
	}
}

@(private = "file")
html_block :: proc(w: ^Html_Writer, n: Node) {
	d := node_data(w.t, n)
	#partial switch d.kind {
	case .Section_Title:
		html_section_title(w, n)
	case .List_Item:
		html_list_item(w, n)
	case .Literal_Block, .Doctest_Block:
		html_pre(w, "<pre class=\"literal-block\"><code>", d.text)
	case .THead:
		w.in_thead = true
		strings.write_string(&w.buf, "<thead>\n")
		html_children(w, n)
		strings.write_string(&w.buf, "</thead>\n")
		w.in_thead = false
	case .Entry:
		html_entry(w, n, d)
	case .Directive:
		html_directive(w, n)
	case .Footnote, .Citation:
		prefix := "footnote" if d.kind == .Footnote else "citation"
		strings.write_string(&w.buf, "<aside")
		html_attr(w, "class", prefix)
		html_attr(w, "id", note_id(w.ctx.a, prefix, d.name))
		strings.write_string(&w.buf, ">\n")
		html_children(w, n)
		strings.write_string(&w.buf, "</aside>\n")
	case .Label:
		strings.write_string(&w.buf, "<span class=\"label\">")
		escape_html_text(&w.buf, d.text)
		strings.write_string(&w.buf, "</span> ")
	case .Target:
		if id, ok := target_anchor(&w.ctx, d); ok {
			strings.write_string(&w.buf, "<span")
			html_attr(w, "id", id)
			strings.write_string(&w.buf, "></span>\n")
		}
	case .Comment, .Substitution_Definition:
	case:
		wrap := HTML_WRAPS[d.kind]
		strings.write_string(&w.buf, wrap.open)
		html_children(w, n, wrap.inline)
		strings.write_string(&w.buf, wrap.close)
	}
}

// A list item whose only child is a paragraph is written compactly.
@(private = "file")
html_list_item :: proc(w: ^Html_Writer, n: Node) {
	t := w.t
	strings.write_string(&w.buf, "<li>")
	first := t.nodes[n].first
	if first != NO_NODE && first == t.nodes[n].last && t.nodes[first].kind == .Paragraph {
		html_children(w, first, inline = true)
	} else {
		html_children(w, n)
	}
	strings.write_string(&w.buf, "</li>\n")
}

@(private = "file")
html_pre :: proc(w: ^Html_Writer, open: string, text: string) {
	strings.write_string(&w.buf, open)
	escape_html_text(&w.buf, text)
	strings.write_string(&w.buf, "</code></pre>\n")
}

// A table cell; ``num`` holds docutils' ``morerows`` and ``morecols``.
@(private = "file")
html_entry :: proc(w: ^Html_Writer, n: Node, d: Node_Data) {
	tag := "th" if w.in_thead else "td"
	fmt.sbprintf(&w.buf, "<%s", tag)
	if d.num[1] > 0 do fmt.sbprintf(&w.buf, " colspan=\"%d\"", d.num[1] + 1)
	if d.num[0] > 0 do fmt.sbprintf(&w.buf, " rowspan=\"%d\"", d.num[0] + 1)
	strings.write_byte(&w.buf, '>')
	html_children(w, n)
	fmt.sbprintf(&w.buf, "</%s>\n", tag)
}

@(private = "file")
html_section_title :: proc(w: ^Html_Writer, n: Node) {
	level := section_level(&w.title_styles, w.t.nodes[n].name)
	title := w.t.nodes[n].first
	if title == NO_NODE do return
	tag := clamp(level, 1, 6)
	name := fully_normalize_name(node_astext(&w.ctx, title), w.ctx.a)
	fmt.sbprintf(&w.buf, "<h%d", tag)
	html_attr(w, "id", anchor_id(name, w.ctx.a))
	strings.write_byte(&w.buf, '>')
	html_children(w, title, inline = true)
	fmt.sbprintf(&w.buf, "</h%d>\n", tag)
}

@(private = "file")
html_directive :: proc(w: ^Html_Writer, n: Node) {
	b := w.blocks[n]
	name := strings.to_lower(w.t.nodes[n].name, w.ctx.a)
	switch directive_kind(name) {
	case .Admonition, .Generic_Admonition:
		html_admonition(w, name, b)
	case .Code:
		lang := code_language(b, w.ctx.a)
		strings.write_string(&w.buf, "<div class=\"highlight\"><pre>")
		if lang == "" {
			strings.write_string(&w.buf, "<code>")
		} else {
			strings.write_string(&w.buf, "<code")
			html_attr(w, "class", concat("language-", lang, allocator = w.ctx.a))
			strings.write_byte(&w.buf, '>')
		}
		escape_html_text(&w.buf, join_lines(b.content, w.ctx.a))
		strings.write_string(&w.buf, "</code></pre></div>\n")
	case .Image, .Figure:
		html_figure(w, b)
	case .Raw:
		if strings.to_lower(directive_argument(b, w.ctx.a), w.ctx.a) != "html" do return
		for line in b.content {
			strings.write_string(&w.buf, line)
			strings.write_byte(&w.buf, '\n')
		}
	case .Other:
		if b.body != NO_NODE do html_children(w, b.body)
	}
}

@(private = "file")
html_admonition :: proc(w: ^Html_Writer, name: string, b: Directive_Block) {
	strings.write_string(&w.buf, "<div")
	html_attr(w, "class", concat("admonition ", name, allocator = w.ctx.a))
	strings.write_string(&w.buf, ">\n")
	strings.write_string(&w.buf, "<p class=\"admonition-title\">")
	if label, named := admonition_label(name); named {
		escape_html_text(&w.buf, label)
	} else {
		title := parse_inline(w.p, directive_argument(b, w.ctx.a), 0)
		it := chain(w.t, title.first)
		for c in iterate(&it) do html_inline(w, c)
	}
	strings.write_string(&w.buf, "</p>\n")
	if b.body != NO_NODE do html_children(w, b.body)
	strings.write_string(&w.buf, "</div>\n")
}

@(private = "file")
html_figure :: proc(w: ^Html_Writer, b: Directive_Block) {
	uri := directive_uri(b, w.ctx.a)
	alt, has_alt := directive_option(b, "alt")
	if !has_alt do alt = uri
	strings.write_string(&w.buf, "<figure class=\"figure\"><img")
	html_attr(w, "src", uri)
	html_attr(w, "alt", alt)
	strings.write_string(&w.buf, " />")
	if b.body != NO_NODE {
		strings.write_string(&w.buf, "\n<figcaption>\n")
		html_children(w, b.body)
		strings.write_string(&w.buf, "</figcaption>\n")
	}
	strings.write_string(&w.buf, "</figure>\n")
}

@(private = "file")
html_inline :: proc(w: ^Html_Writer, n: Node) {
	d := node_data(w.t, n)
	a := w.ctx.a
	#partial switch d.kind {
	case .Emphasis:
		html_wrapped(w, "<em>", unescape(d.text, a), "</em>")
	case .Strong:
		html_wrapped(w, "<strong>", unescape(d.text, a), "</strong>")
	case .Literal:
		html_wrapped(w, "<code>", d.text, "</code>")
	case .Reference:
		link := resolve_reference(&w.ctx, n)
		href := link.value if link.kind == .External else concat("#", link.value, allocator = a)
		strings.write_string(&w.buf, "<a")
		html_attr(w, "href", href)
		strings.write_string(&w.buf, " class=\"reference\">")
		html_wrapped(w, "", reference_text(&w.ctx, n), "</a>")
	case .Footnote_Reference, .Citation_Reference:
		html_note_reference(w, d)
	case .Inline_Target:
		name := fully_normalize_name(unescape(d.text, a), a)
		strings.write_string(&w.buf, "<span")
		html_attr(w, "id", anchor_id(name, a))
		strings.write_byte(&w.buf, '>')
		html_wrapped(w, "", unescape(d.text, a), "</span>")
	case .Problematic:
		html_wrapped(w, "<span class=\"problematic\">", d.text, "</span>")
	case:
		escape_html_text(&w.buf, unescape(d.text, a))
		html_children(w, n, inline = true)
	}
}

@(private = "file")
html_wrapped :: proc(w: ^Html_Writer, open, text, close: string) {
	strings.write_string(&w.buf, open)
	escape_html_text(&w.buf, text)
	strings.write_string(&w.buf, close)
}

@(private = "file")
html_note_reference :: proc(w: ^Html_Writer, d: Node_Data) {
	prefix := "footnote" if d.kind == .Footnote_Reference else "citation"
	id := note_id(w.ctx.a, prefix, d.text)
	strings.write_string(&w.buf, "<sup><a")
	html_attr(w, "href", concat("#", id, allocator = w.ctx.a))
	fmt.sbprintf(&w.buf, " class=\"%s-reference\">[", prefix)
	escape_html_text(&w.buf, d.text)
	strings.write_string(&w.buf, "]</a></sup>")
}
