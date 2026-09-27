package rst

import "core:fmt"
import "core:strings"

Latex_Config :: struct {
	title:      string,
	author:     string,
	date:       string,
	doc_class:  string, // default "article"
	papersize:  string, // default "a4paper"
	fontsize:   string, // default "11pt"
	standalone: bool,
}

Latex_Writer :: struct {
	p:             ^Parser,
	buf:           strings.Builder,
	config:        Latex_Config,
	title_styles:  [dynamic]Title_Style,
	section_depth: int,
	in_table:      bool,
}

escape_latex_text :: proc(b: ^strings.Builder, s: string) {
	for i := 0; i < len(s); i += 1 {
		b_byte := s[i]
		switch b_byte {
		case '\\':
			strings.write_string(b, "\\textbackslash{}")
		case '&':
			strings.write_string(b, "\\&")
		case '%':
			strings.write_string(b, "\\%")
		case '$':
			strings.write_string(b, "\\$")
		case '#':
			strings.write_string(b, "\\#")
		case '_':
			strings.write_string(b, "\\_")
		case '{':
			strings.write_string(b, "\\{")
		case '}':
			strings.write_string(b, "\\}")
		case '~':
			strings.write_string(b, "\\textasciitilde{}")
		case '^':
			strings.write_string(b, "\\textasciicircum{}")
		case:
			strings.write_byte(b, b_byte)
		}
	}
}

write_latex :: proc(doc: Node, p: ^Parser, config: Latex_Config) -> string {
	t := &p.tree
	w := Latex_Writer{
		p            = p,
		config       = config,
		title_styles = make([dynamic]Title_Style, p.allocator),
	}
	w.buf = strings.builder_make(p.allocator)

	title := config.title
	if len(title) == 0 {
		for n := t.nodes[doc].first; n != NO_NODE; n = t.nodes[n].next {
			if t.nodes[n].kind == .Section_Title && t.nodes[n].first != NO_NODE {
				title = t.nodes[t.nodes[n].first].raw if len(t.nodes[t.nodes[n].first].raw) > 0 else t.nodes[t.nodes[n].first].text
				break
			}
		}
	}
	if len(title) == 0 do title = "Document"

	doc_class := config.doc_class if len(config.doc_class) > 0 else "article"
	papersize := config.papersize if len(config.papersize) > 0 else "a4paper"
	fontsize := config.fontsize if len(config.fontsize) > 0 else "11pt"

	if config.standalone {
		fmt.sbprintf(&w.buf, "\\documentclass[%s,%s]{{%s}}\n", fontsize, papersize, doc_class)
		strings.write_string(&w.buf, "\\usepackage[utf8]{inputenc}\n")
		strings.write_string(&w.buf, "\\usepackage[T1]{fontenc}\n")
		strings.write_string(&w.buf, "\\usepackage{lmodern}\n")
		strings.write_string(&w.buf, "\\usepackage{amsmath,amssymb}\n")
		strings.write_string(&w.buf, "\\usepackage{graphicx}\n")
		strings.write_string(&w.buf, "\\usepackage{booktabs}\n")
		strings.write_string(&w.buf, "\\usepackage{longtable}\n")
		strings.write_string(&w.buf, "\\usepackage{xcolor}\n")
		strings.write_string(&w.buf, "\\usepackage{geometry}\n")
		strings.write_string(&w.buf, "\\geometry{margin=1in}\n")
		strings.write_string(&w.buf, "\\usepackage[colorlinks=true,linkcolor=blue,urlcolor=blue]{hyperref}\n\n")

		strings.write_string(&w.buf, "\\title{")
		escape_latex_text(&w.buf, title)
		strings.write_string(&w.buf, "}\n")

		if len(config.author) > 0 {
			strings.write_string(&w.buf, "\\author{")
			escape_latex_text(&w.buf, config.author)
			strings.write_string(&w.buf, "}\n")
		}
		if len(config.date) > 0 {
			strings.write_string(&w.buf, "\\date{")
			escape_latex_text(&w.buf, config.date)
			strings.write_string(&w.buf, "}\n")
		} else {
			strings.write_string(&w.buf, "\\date{\\today}\n")
		}

		strings.write_string(&w.buf, "\n\\begin{document}\n\\maketitle\n\n")
	}

	for n := t.nodes[doc].first; n != NO_NODE; n = t.nodes[n].next {
		latex_render_block(&w, n)
	}

	if config.standalone {
		strings.write_string(&w.buf, "\n\\end{document}\n")
	}

	return strings.to_string(w.buf)
}

@(private = "file")
latex_render_block :: proc(w: ^Latex_Writer, n: Node) {
	t := &w.p.tree
	#partial switch t.nodes[n].kind {
	case .Section_Title:
		latex_section_title(w, n)

	case .Paragraph:
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			latex_render_inline(w, ch)
		}
		strings.write_string(&w.buf, "\n\n")

	case .Bullet_List:
		strings.write_string(&w.buf, "\\begin{itemize}\n")
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			if t.nodes[ch].kind == .List_Item {
				strings.write_string(&w.buf, "  \\item ")
				for item_ch := t.nodes[ch].first; item_ch != NO_NODE; item_ch = t.nodes[item_ch].next {
					if t.nodes[item_ch].kind == .Paragraph {
						for p_ch := t.nodes[item_ch].first; p_ch != NO_NODE; p_ch = t.nodes[p_ch].next {
							latex_render_inline(w, p_ch)
						}
						strings.write_byte(&w.buf, '\n')
					} else {
						latex_render_block(w, item_ch)
					}
				}
			}
		}
		strings.write_string(&w.buf, "\\end{itemize}\n\n")

	case .Enumerated_List:
		strings.write_string(&w.buf, "\\begin{enumerate}\n")
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			if t.nodes[ch].kind == .List_Item {
				strings.write_string(&w.buf, "  \\item ")
				for item_ch := t.nodes[ch].first; item_ch != NO_NODE; item_ch = t.nodes[item_ch].next {
					if t.nodes[item_ch].kind == .Paragraph {
						for p_ch := t.nodes[item_ch].first; p_ch != NO_NODE; p_ch = t.nodes[p_ch].next {
							latex_render_inline(w, p_ch)
						}
						strings.write_byte(&w.buf, '\n')
					} else {
						latex_render_block(w, item_ch)
					}
				}
			}
		}
		strings.write_string(&w.buf, "\\end{enumerate}\n\n")

	case .Definition_List:
		strings.write_string(&w.buf, "\\begin{description}\n")
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			if t.nodes[ch].kind == .Definition_List_Item {
				term := ""
				for item_ch := t.nodes[ch].first; item_ch != NO_NODE; item_ch = t.nodes[item_ch].next {
					if t.nodes[item_ch].kind == .Term {
						term = t.nodes[item_ch].raw if len(t.nodes[item_ch].raw) > 0 else t.nodes[item_ch].text
						break
					}
				}
				strings.write_string(&w.buf, "  \\item[")
				escape_latex_text(&w.buf, term)
				strings.write_string(&w.buf, "] ")
				for item_ch := t.nodes[ch].first; item_ch != NO_NODE; item_ch = t.nodes[item_ch].next {
					if t.nodes[item_ch].kind == .Definition {
						for d_ch := t.nodes[item_ch].first; d_ch != NO_NODE; d_ch = t.nodes[d_ch].next {
							if t.nodes[d_ch].kind == .Paragraph {
								for p_ch := t.nodes[d_ch].first; p_ch != NO_NODE; p_ch = t.nodes[p_ch].next {
									latex_render_inline(w, p_ch)
								}
								strings.write_byte(&w.buf, '\n')
							} else {
								latex_render_block(w, d_ch)
							}
						}
					}
				}
			}
		}
		strings.write_string(&w.buf, "\\end{description}\n\n")

	case .Field_List:
		strings.write_string(&w.buf, "\\begin{description}\n")
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			if t.nodes[ch].kind == .Field {
				name := ""
				for item_ch := t.nodes[ch].first; item_ch != NO_NODE; item_ch = t.nodes[item_ch].next {
					if t.nodes[item_ch].kind == .Field_Name {
						name = t.nodes[item_ch].raw if len(t.nodes[item_ch].raw) > 0 else t.nodes[item_ch].text
						break
					}
				}
				strings.write_string(&w.buf, "  \\item[")
				escape_latex_text(&w.buf, name)
				strings.write_string(&w.buf, ":] ")
				for item_ch := t.nodes[ch].first; item_ch != NO_NODE; item_ch = t.nodes[item_ch].next {
					if t.nodes[item_ch].kind == .Field_Body {
						for d_ch := t.nodes[item_ch].first; d_ch != NO_NODE; d_ch = t.nodes[d_ch].next {
							if t.nodes[d_ch].kind == .Paragraph {
								for p_ch := t.nodes[d_ch].first; p_ch != NO_NODE; p_ch = t.nodes[p_ch].next {
									latex_render_inline(w, p_ch)
								}
								strings.write_byte(&w.buf, '\n')
							} else {
								latex_render_block(w, d_ch)
							}
						}
					}
				}
			}
		}
		strings.write_string(&w.buf, "\\end{description}\n\n")

	case .Literal_Block, .Doctest_Block:
		strings.write_string(&w.buf, "\\begin{quote}\n\\begin{verbatim}\n")
		strings.write_string(&w.buf, t.nodes[n].text)
		strings.write_string(&w.buf, "\n\\end{verbatim}\n\\end{quote}\n\n")

	case .Line_Block:
		strings.write_string(&w.buf, "\\begin{quote}\n")
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			if t.nodes[ch].kind == .Line {
				for l_ch := t.nodes[ch].first; l_ch != NO_NODE; l_ch = t.nodes[l_ch].next do latex_render_inline(w, l_ch)
				strings.write_string(&w.buf, "\\\\\n")
			}
		}
		strings.write_string(&w.buf, "\\end{quote}\n\n")

	case .Block_Quote:
		strings.write_string(&w.buf, "\\begin{quote}\n")
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			latex_render_block(w, ch)
		}
		strings.write_string(&w.buf, "\\end{quote}\n\n")

	case .Attribution:
		strings.write_string(&w.buf, "\\begin{flushright}\n--- \\emph{")
		escape_latex_text(&w.buf, t.nodes[n].text)
		strings.write_string(&w.buf, "}\n\\end{flushright}\n\n")

	case .Transition:
		strings.write_string(&w.buf, "\\bigskip\\hrule\\bigskip\n\n")

	case .Table:
		latex_render_table(w, n)

	case .Directive:
		latex_render_directive(w, n)

	case .Comment:
		// Comments are omitted from LaTeX output

	case:
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
			latex_render_block(w, ch)
		}
	}
}

@(private = "file")
latex_section_title :: proc(w: ^Latex_Writer, n: Node) {
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

	cmd := "\\section"
	switch level {
	case 1: cmd = "\\section"
	case 2: cmd = "\\subsection"
	case 3: cmd = "\\subsubsection"
	case 4: cmd = "\\paragraph"
	case:   cmd = "\\subparagraph"
	}

	title_node := t.nodes[n].first
	title_text := ""
	if title_node != NO_NODE {
		title_text = t.nodes[title_node].raw if len(t.nodes[title_node].raw) > 0 else t.nodes[title_node].text
	}

	strings.write_string(&w.buf, cmd)
	strings.write_byte(&w.buf, '{')
	if title_node != NO_NODE {
		for ch := t.nodes[title_node].first; ch != NO_NODE; ch = t.nodes[ch].next {
			latex_render_inline(w, ch)
		}
	} else {
		escape_latex_text(&w.buf, title_text)
	}
	strings.write_string(&w.buf, "}\n")

	slug := slugify(title_text, context.temp_allocator)
	if len(slug) > 0 {
		fmt.sbprintf(&w.buf, "\\label{{%s}}\n", slug)
	}
	strings.write_byte(&w.buf, '\n')
}

@(private = "file")
latex_render_table :: proc(w: ^Latex_Writer, n: Node) {
	t := &w.p.tree
	cols := 1
	for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
		if t.nodes[ch].kind == .TGroup {
			c_count := 0
			for tg := t.nodes[ch].first; tg != NO_NODE; tg = t.nodes[tg].next {
				if t.nodes[tg].kind == .Colspec do c_count += 1
			}
			if c_count > 0 do cols = c_count
			break
		}
	}

	strings.write_string(&w.buf, "\\begin{longtable}{")
	for i := 0; i < cols; i += 1 {
		if i > 0 do strings.write_byte(&w.buf, ' ')
		strings.write_string(&w.buf, "l")
	}
	strings.write_string(&w.buf, "}\n\\toprule\n")

	for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next {
		if t.nodes[ch].kind == .TGroup {
			for tg := t.nodes[ch].first; tg != NO_NODE; tg = t.nodes[tg].next {
				if t.nodes[tg].kind == .THead {
					for row := t.nodes[tg].first; row != NO_NODE; row = t.nodes[row].next {
						if t.nodes[row].kind == .Row do latex_render_table_row(w, row)
					}
					strings.write_string(&w.buf, "\\midrule\n")
				} else if t.nodes[tg].kind == .TBody {
					for row := t.nodes[tg].first; row != NO_NODE; row = t.nodes[row].next {
						if t.nodes[row].kind == .Row do latex_render_table_row(w, row)
					}
				}
			}
		}
	}

	strings.write_string(&w.buf, "\\bottomrule\n\\end{longtable}\n\n")
}

@(private = "file")
latex_render_table_row :: proc(w: ^Latex_Writer, row: Node) {
	t := &w.p.tree
	first := true
	for entry := t.nodes[row].first; entry != NO_NODE; entry = t.nodes[entry].next {
		if t.nodes[entry].kind == .Entry {
			if !first do strings.write_string(&w.buf, " & ")
			first = false
			for ech := t.nodes[entry].first; ech != NO_NODE; ech = t.nodes[ech].next {
				if t.nodes[ech].kind == .Paragraph {
					for pch := t.nodes[ech].first; pch != NO_NODE; pch = t.nodes[pch].next do latex_render_inline(w, pch)
				} else {
					latex_render_block(w, ech)
				}
			}
		}
	}
	strings.write_string(&w.buf, " \\\\\n")
}

@(private = "file")
latex_render_directive :: proc(w: ^Latex_Writer, n: Node) {
	t := &w.p.tree
	name := strings.to_lower(t.nodes[n].name, context.temp_allocator)
	info, has_info := directive_info(t, n)
	if !has_info do return

	switch name {
	case "attention", "caution", "danger", "error", "hint", "important", "note", "tip", "warning", "admonition":
		fmt.sbprintf(&w.buf, "\\begin{{quote}}\n\\textbf{{%s:}}\\newline\n", strings.to_upper(name, context.temp_allocator))
		if len(info.lines) > 0 {
			nested := new_node(t, .Block_Quote, 0)
			sm := make_state_machine(w.p, nil, 0, nested)
			nested_parse(&sm, info.lines, info.line_offset, nested)
			for ch := t.nodes[nested].first; ch != NO_NODE; ch = t.nodes[ch].next {
				latex_render_block(w, ch)
			}
		}
		strings.write_string(&w.buf, "\\end{quote}\n\n")

	case "code", "code-block", "sourcecode":
		start_line := 0
		if len(info.lines) > 0 && len(strings.trim_space(info.lines[0])) > 0 {
			start_line = 1
		}
		code_text := ""
		if start_line < len(info.lines) {
			code_text = strings.join(info.lines[start_line:], "\n", context.temp_allocator)
		}
		strings.write_string(&w.buf, "\\begin{quote}\n\\begin{verbatim}\n")
		strings.write_string(&w.buf, code_text)
		strings.write_string(&w.buf, "\n\\end{verbatim}\n\\end{quote}\n\n")

	case "image", "figure":
		uri := ""
		if len(info.lines) > 0 do uri = strings.trim_space(info.lines[0])
		fmt.sbprintf(&w.buf, "\\begin{{figure}}[htbp]\n\\centering\n\\includegraphics[max width=\\textwidth]{{%s}}\n\\end{{figure}}\n\n", uri)

	case "raw":
		if len(info.lines) > 0 && strings.trim_space(info.lines[0]) == "latex" {
			if len(info.lines) > 1 {
				for line in info.lines[1:] {
					strings.write_string(&w.buf, line)
					strings.write_byte(&w.buf, '\n')
				}
			}
		}

	case:
		if len(info.lines) > 0 {
			nested := new_node(t, .Block_Quote, 0)
			sm := make_state_machine(w.p, nil, 0, nested)
			nested_parse(&sm, info.lines, info.line_offset, nested)
			for ch := t.nodes[nested].first; ch != NO_NODE; ch = t.nodes[ch].next {
				latex_render_block(w, ch)
			}
		}
	}
}

@(private = "file")
latex_render_inline :: proc(w: ^Latex_Writer, n: Node) {
	t := &w.p.tree
	#partial switch t.nodes[n].kind {
	case .Text:
		escape_latex_text(&w.buf, t.nodes[n].text)

	case .Emphasis:
		strings.write_string(&w.buf, "\\emph{")
		if t.nodes[n].first != NO_NODE {
			for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next do latex_render_inline(w, ch)
		} else {
			escape_latex_text(&w.buf, t.nodes[n].text)
		}
		strings.write_string(&w.buf, "}")

	case .Strong:
		strings.write_string(&w.buf, "\\textbf{")
		if t.nodes[n].first != NO_NODE {
			for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next do latex_render_inline(w, ch)
		} else {
			escape_latex_text(&w.buf, t.nodes[n].text)
		}
		strings.write_string(&w.buf, "}")

	case .Literal:
		strings.write_string(&w.buf, "\\texttt{")
		escape_latex_text(&w.buf, t.nodes[n].text)
		strings.write_string(&w.buf, "}")

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
		fmt.sbprintf(&w.buf, "\\href{{%s}}{{", url)
		if t.nodes[n].first != NO_NODE {
			for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next do latex_render_inline(w, ch)
		} else {
			escape_latex_text(&w.buf, t.nodes[n].text if len(t.nodes[n].text) > 0 else t.nodes[n].name)
		}
		strings.write_string(&w.buf, "}")

	case .Footnote_Reference:
		fmt.sbprintf(&w.buf, "\\footnote{{%s}}", t.nodes[n].name)

	case .Citation_Reference:
		fmt.sbprintf(&w.buf, "\\cite{{%s}}", t.nodes[n].name)

	case .Inline_Target:
		fmt.sbprintf(&w.buf, "\\label{{%s}}", slugify(t.nodes[n].name, context.temp_allocator))
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next do latex_render_inline(w, ch)

	case:
		if len(t.nodes[n].text) > 0 do escape_latex_text(&w.buf, t.nodes[n].text)
		for ch := t.nodes[n].first; ch != NO_NODE; ch = t.nodes[ch].next do latex_render_inline(w, ch)
	}
}
