package rst

import "base:runtime"
import "core:fmt"
import "core:strings"

Html_Config :: struct {
	title:      string,
	author:     string,
	standalone: bool,
	embed_css:  bool,
}

Title_Style :: struct {
	chars: [2]u8,
	n:     int,
}

Html_Writer :: struct {
	p:             ^Parser,
	buf:           strings.Builder,
	config:        Html_Config,
	title_styles:  [dynamic]Title_Style,
	section_depth: int,
	in_thead:      bool,
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
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
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

escape_html_text :: proc(b: ^strings.Builder, s: string) {
	for i := 0; i < len(s); i += 1 {
		b_byte := s[i]
		switch b_byte {
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case '"':
			strings.write_string(b, "&quot;")
		case:
			strings.write_byte(b, b_byte)
		}
	}
}

write_html :: proc(doc: Node, p: ^Parser, config: Html_Config) -> string {
	t := &p.tree
	w := Html_Writer{
		p            = p,
		config       = config,
		title_styles = make([dynamic]Title_Style, p.allocator),
	}
	w.buf = strings.builder_make(p.allocator)

	title := config.title
	if len(title) == 0 {
		// look for first Title in doc
		for n := t.nodes[doc].first; n != NO_NODE; n = t.nodes[n].next {
			if t.nodes[n].kind == .Section_Title && t.nodes[n].first != NO_NODE {
				title = t.nodes[t.nodes[n].first].raw if len(t.nodes[t.nodes[n].first].raw) > 0 else t.nodes[t.nodes[n].first].text
				break
			}
		}
	}
	if len(title) == 0 do title = "Document"

	if config.standalone {
		strings.write_string(&w.buf, "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n")
		strings.write_string(&w.buf, "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n")
		strings.write_string(&w.buf, "<title>")
		escape_html_text(&w.buf, title)
		strings.write_string(&w.buf, "</title>\n")
		if config.embed_css {
			strings.write_string(&w.buf, "<style>\n")
			strings.write_string(&w.buf, DEFAULT_HTML_CSS)
			strings.write_string(&w.buf, "</style>\n")
		}
		strings.write_string(&w.buf, "</head>\n<body>\n<main class=\"document\">\n")
	}

	for n := t.nodes[doc].first; n != NO_NODE; n = t.nodes[n].next {
		html_render_block(&w, n)
	}

	if config.standalone {
		strings.write_string(&w.buf, "</main>\n</body>\n</html>\n")
	}

	return strings.to_string(w.buf)
}

@(private = "file")
html_render_block :: proc(w: ^Html_Writer, n: Node) {
	t := &w.p.tree
	#partial switch t.nodes[n].kind {
	case .Section_Title:
		html_section_title(w, n)

	case .Paragraph:
		strings.write_string(&w.buf, "<p>")
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			html_render_inline(w, ch)
		}
		strings.write_string(&w.buf, "</p>\n")

	case .Bullet_List:
		strings.write_string(&w.buf, "<ul>\n")
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			html_render_block(w, ch)
		}
		strings.write_string(&w.buf, "</ul>\n")

	case .Enumerated_List:
		strings.write_string(&w.buf, "<ol>\n")
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			html_render_block(w, ch)
		}
		strings.write_string(&w.buf, "</ol>\n")

	case .List_Item:
		strings.write_string(&w.buf, "<li>")
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			if t.nodes[ch].kind == .Paragraph && t.nodes[n].first == t.nodes[n].last {
				for p_ch := t.nodes[ch].first; p_ch != NO_NODE; p_ch = t.nodes[p_ch].next {
					html_render_inline(w, p_ch)
				}
			} else {
				html_render_block(w, ch)
			}
		}
		strings.write_string(&w.buf, "</li>\n")

	case .Definition_List:
		strings.write_string(&w.buf, "<dl class=\"docutils\">\n")
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			html_render_block(w, ch)
		}
		strings.write_string(&w.buf, "</dl>\n")

	case .Definition_List_Item:
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			#partial switch t.nodes[ch].kind {
			case .Term:
				strings.write_string(&w.buf, "<dt>")
				for tc := t.nodes[ch].first; tc != NO_NODE; tc = t.nodes[tc].next do html_render_inline(w, tc)
				strings.write_string(&w.buf, "</dt>\n")
			case .Classifier:
				strings.write_string(&w.buf, " <span class=\"classifier\">")
				for tc := t.nodes[ch].first; tc != NO_NODE; tc = t.nodes[tc].next do html_render_inline(w, tc)
				strings.write_string(&w.buf, "</span>")
			case .Definition:
				strings.write_string(&w.buf, "<dd>\n")
				for d := t.nodes[ch].first; d != NO_NODE; d = t.nodes[d].next do html_render_block(w, d)
				strings.write_string(&w.buf, "</dd>\n")
			case:
				html_render_block(w, ch)
			}
		}

	case .Field_List:
		strings.write_string(&w.buf, "<dl class=\"docutils field-list\">\n")
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			html_render_block(w, ch)
		}
		strings.write_string(&w.buf, "</dl>\n")

	case .Field:
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			if t.nodes[ch].kind == .Field_Name {
				strings.write_string(&w.buf, "<dt class=\"field-name\">")
				for tc := t.nodes[ch].first; tc != NO_NODE; tc = t.nodes[tc].next do html_render_inline(w, tc)
				strings.write_string(&w.buf, "</dt>\n")
			} else if t.nodes[ch].kind == .Field_Body {
				strings.write_string(&w.buf, "<dd class=\"field-body\">\n")
				for d := t.nodes[ch].first; d != NO_NODE; d = t.nodes[d].next do html_render_block(w, d)
				strings.write_string(&w.buf, "</dd>\n")
			}
		}

	case .Literal_Block, .Doctest_Block:
		strings.write_string(&w.buf, "<pre class=\"literal-block\"><code>")
		escape_html_text(&w.buf, t.nodes[n].text)
		strings.write_string(&w.buf, "</code></pre>\n")

	case .Line_Block:
		strings.write_string(&w.buf, "<div class=\"line-block\">\n")
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			html_render_block(w, ch)
		}
		strings.write_string(&w.buf, "</div>\n")

	case .Line:
		strings.write_string(&w.buf, "<div class=\"line\">")
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			html_render_inline(w, ch)
		}
		strings.write_string(&w.buf, "</div>\n")

	case .Block_Quote:
		strings.write_string(&w.buf, "<blockquote>\n")
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			html_render_block(w, ch)
		}
		strings.write_string(&w.buf, "</blockquote>\n")

	case .Attribution:
		strings.write_string(&w.buf, "<p class=\"attribution\">— <cite>")
		escape_html_text(&w.buf, t.nodes[n].text)
		strings.write_string(&w.buf, "</cite></p>\n")

	case .Transition:
		strings.write_string(&w.buf, "<hr class=\"docutils\" />\n")

	case .Table:
		strings.write_string(&w.buf, "<table class=\"docutils align-default\">\n")
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			html_render_block(w, ch)
		}
		strings.write_string(&w.buf, "</table>\n")

	case .TGroup:
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			html_render_block(w, ch)
		}

	case .THead:
		w.in_thead = true
		strings.write_string(&w.buf, "<thead>\n")
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			html_render_block(w, ch)
		}
		strings.write_string(&w.buf, "</thead>\n")
		w.in_thead = false

	case .TBody:
		strings.write_string(&w.buf, "<tbody>\n")
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			html_render_block(w, ch)
		}
		strings.write_string(&w.buf, "</tbody>\n")

	case .Row:
		strings.write_string(&w.buf, "<tr>\n")
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			html_render_block(w, ch)
		}
		strings.write_string(&w.buf, "</tr>\n")

	case .Entry:
		tag := "th" if w.in_thead else "td"
		fmt.sbprintf(&w.buf, "<%s", tag)
		if t.nodes[n].num[0] > 1 do fmt.sbprintf(&w.buf, " colspan=\"%d\"", t.nodes[n].num[0])
		if t.nodes[n].num[1] > 1 do fmt.sbprintf(&w.buf, " rowspan=\"%d\"", t.nodes[n].num[1])
		strings.write_byte(&w.buf, '>')
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			html_render_block(w, ch)
		}
		fmt.sbprintf(&w.buf, "</%s>\n", tag)

	case .Directive:
		html_render_directive(w, n)

	case .Footnote, .Citation:
		fmt.sbprintf(&w.buf, "<aside class=\"%s\" id=\"%s\">\n", "footnote" if t.nodes[n].kind == .Footnote else "citation", t.nodes[n].name)
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			html_render_block(w, ch)
		}
		strings.write_string(&w.buf, "</aside>\n")

	case .Label:
		strings.write_string(&w.buf, "<span class=\"label\">")
		escape_html_text(&w.buf, t.nodes[n].text)
		strings.write_string(&w.buf, "</span> ")

	case .Comment:
		// Comments are omitted from HTML output

	case:
		// Fallback: render children
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			html_render_block(w, ch)
		}
	}
}

@(private = "file")
html_section_title :: proc(w: ^Html_Writer, n: Node) {
	t := &w.p.tree
	style := Title_Style{n = len(t.nodes[n].name)}
	for i in 0 ..< min(len(t.nodes[n].name), 2) do style.chars[i] = t.nodes[n].name[i]

	level := len(w.title_styles) + 1
	for s, i in w.title_styles {
		if s == style {
			level = i + 1
			break
		}
	}
	if level > len(w.title_styles) do append(&w.title_styles, style)
	w.section_depth = level

	tag_num := clamp(level, 1, 6)
	title_node := t.nodes[n].first
	title_text := ""
	if title_node != NO_NODE {
		title_text = t.nodes[title_node].raw if len(t.nodes[title_node].raw) > 0 else t.nodes[title_node].text
	}

	slug := slugify(title_text, w.p.allocator)
	fmt.sbprintf(&w.buf, "<h%d id=\"%s\">", tag_num, slug)
	if title_node != NO_NODE {
		for ch := t.nodes[title_node].first; ch != NO_NODE; ch = t.nodes[ch].next {
			html_render_inline(w, ch)
		}
	}
	fmt.sbprintf(&w.buf, "</h%d>\n", tag_num)
}

@(private = "file")
html_render_directive :: proc(w: ^Html_Writer, n: Node) {
	t := &w.p.tree
	name := strings.to_lower(t.nodes[n].name, context.temp_allocator)
	info, has_info := directive_info(t, n)
	if !has_info do return

	switch name {
	case "attention", "caution", "danger", "error", "hint", "important", "note", "tip", "warning", "admonition":
		fmt.sbprintf(&w.buf, "<div class=\"admonition %s\">\n<p class=\"admonition-title\">%s</p>\n", name, name)
		if len(info.lines) > 0 {
			nested := new_node(t, .Block_Quote, 0)
			sm := make_state_machine(w.p, nil, 0, nested)
			nested_parse(&sm, info.lines, info.line_offset, nested)
			for ch := t.nodes[nested].first; ch != NO_NODE; ch = t.nodes[ch].next {
				html_render_block(w, ch)
			}
		}
		strings.write_string(&w.buf, "</div>\n")

	case "code", "code-block", "sourcecode":
		lang := ""
		start_line := 0
		if len(info.lines) > 0 && len(strings.trim_space(info.lines[0])) > 0 {
			lang = strings.trim_space(info.lines[0])
			start_line = 1
		}
		code_text := ""
		if start_line < len(info.lines) {
			code_text = strings.join(info.lines[start_line:], "\n", context.temp_allocator)
		}
		if len(lang) > 0 {
			fmt.sbprintf(&w.buf, "<div class=\"highlight\"><pre><code class=\"language-%s\">", lang)
		} else {
			strings.write_string(&w.buf, "<div class=\"highlight\"><pre><code>")
		}
		escape_html_text(&w.buf, code_text)
		strings.write_string(&w.buf, "</code></pre></div>\n")

	case "image", "figure":
		uri := ""
		if len(info.lines) > 0 do uri = strings.trim_space(info.lines[0])
		fmt.sbprintf(&w.buf, "<figure class=\"figure\"><img src=\"%s\" alt=\"%s\" /></figure>\n", uri, uri)

	case "raw":
		if len(info.lines) > 0 && strings.trim_space(info.lines[0]) == "html" {
			if len(info.lines) > 1 {
				for line in info.lines[1:] {
					strings.write_string(&w.buf, line)
					strings.write_byte(&w.buf, '\n')
				}
			}
		}

	case:
		// Generic directive: if has content lines, render as nested block
		if len(info.lines) > 0 {
			nested := new_node(t, .Block_Quote, 0)
			sm := make_state_machine(w.p, nil, 0, nested)
			nested_parse(&sm, info.lines, info.line_offset, nested)
			for ch := t.nodes[nested].first; ch != NO_NODE; ch = t.nodes[ch].next {
				html_render_block(w, ch)
			}
		}
	}
}

@(private = "file")
html_render_inline :: proc(w: ^Html_Writer, n: Node) {
	t := &w.p.tree
	#partial switch t.nodes[n].kind {
	case .Text:
		escape_html_text(&w.buf, t.nodes[n].text)

	case .Emphasis:
		strings.write_string(&w.buf, "<em>")
		if t.nodes[n].first != NO_NODE {
			for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next do html_render_inline(w, ch)
		} else {
			escape_html_text(&w.buf, t.nodes[n].text)
		}
		strings.write_string(&w.buf, "</em>")

	case .Strong:
		strings.write_string(&w.buf, "<strong>")
		if t.nodes[n].first != NO_NODE {
			for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next do html_render_inline(w, ch)
		} else {
			escape_html_text(&w.buf, t.nodes[n].text)
		}
		strings.write_string(&w.buf, "</strong>")

	case .Literal:
		strings.write_string(&w.buf, "<code>")
		escape_html_text(&w.buf, t.nodes[n].text)
		strings.write_string(&w.buf, "</code>")

	case .Reference:
		url := ""
		ref_kind := Ref_Kind(t.nodes[n].num[0])
		switch ref_kind {
		case .Uri:
			url = t.nodes[n].name
		case .Pep:
			url = fmt.tprintf("https://peps.python.org/pep-%04s", t.nodes[n].name)
		case .Rfc:
			url = fmt.tprintf("https://datatracker.ietf.org/doc/html/rfc%s", t.nodes[n].name)
		case .Phrase:
			if info, ok := phrase_info(t, n); ok {
				url = info.alias
			}
			if len(url) == 0 do url = fmt.tprintf("#%s", slugify(t.nodes[n].name, context.temp_allocator))
		case .Simple:
			url = fmt.tprintf("#%s", slugify(t.nodes[n].name, context.temp_allocator))
		}
		fmt.sbprintf(&w.buf, "<a href=\"%s\" class=\"reference\">", url)
		if t.nodes[n].first != NO_NODE {
			for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next do html_render_inline(w, ch)
		} else {
			escape_html_text(&w.buf, t.nodes[n].text if len(t.nodes[n].text) > 0 else t.nodes[n].name)
		}
		strings.write_string(&w.buf, "</a>")

	case .Footnote_Reference:
		fmt.sbprintf(&w.buf, "<sup><a href=\"#%s\" class=\"footnote-reference\">[%s]</a></sup>", t.nodes[n].name, t.nodes[n].text if len(t.nodes[n].text) > 0 else t.nodes[n].name)

	case .Citation_Reference:
		fmt.sbprintf(&w.buf, "<sup><a href=\"#%s\" class=\"citation-reference\">[%s]</a></sup>", t.nodes[n].name, t.nodes[n].text if len(t.nodes[n].text) > 0 else t.nodes[n].name)

	case .Inline_Target:
		fmt.sbprintf(&w.buf, "<span id=\"%s\">", slugify(t.nodes[n].name, context.temp_allocator))
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next do html_render_inline(w, ch)
		strings.write_string(&w.buf, "</span>")

	case .Problematic:
		strings.write_string(&w.buf, "<span class=\"problematic\">")
		escape_html_text(&w.buf, t.nodes[n].text)
		strings.write_string(&w.buf, "</span>")

	case:
		if len(t.nodes[n].text) > 0 do escape_html_text(&w.buf, t.nodes[n].text)
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next do html_render_inline(w, ch)
	}
}

slugify :: proc(s: string, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(allocator)
	in_dash := false
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') {
			strings.write_byte(&b, c)
			in_dash = false
		} else if c >= 'A' && c <= 'Z' {
			strings.write_byte(&b, c + 32)
			in_dash = false
		} else if !in_dash && (c == ' ' || c == '-' || c == '_' || c == '.') {
			strings.write_byte(&b, '-')
			in_dash = true
		}
	}
	res := strings.to_string(b)
	return strings.trim_right(res, "-")
}
