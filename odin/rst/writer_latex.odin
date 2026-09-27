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

write_latex :: proc(doc: ^Node, p: ^Parser, config: Latex_Config) -> string {
	w := Latex_Writer{
		p            = p,
		config       = config,
		title_styles = make([dynamic]Title_Style, p.allocator),
	}
	w.buf = strings.builder_make(p.allocator)

	title := config.title
	if len(title) == 0 {
		for n := doc.first; n != nil; n = n.next {
			if n.kind == .Section_Title && n.first != nil {
				title = n.first.raw if len(n.first.raw) > 0 else n.first.text
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

	for n := doc.first; n != nil; n = n.next {
		latex_render_block(&w, n)
	}

	if config.standalone {
		strings.write_string(&w.buf, "\n\\end{document}\n")
	}

	return strings.to_string(w.buf)
}

@(private = "file")
latex_render_block :: proc(w: ^Latex_Writer, n: ^Node) {
	#partial switch n.kind {
	case .Section_Title:
		latex_section_title(w, n)

	case .Paragraph:
		for ch := n.first; ch != nil; ch = ch.next {
			latex_render_inline(w, ch)
		}
		strings.write_string(&w.buf, "\n\n")

	case .Bullet_List:
		strings.write_string(&w.buf, "\\begin{itemize}\n")
		for ch := n.first; ch != nil; ch = ch.next {
			if ch.kind == .List_Item {
				strings.write_string(&w.buf, "  \\item ")
				for item_ch := ch.first; item_ch != nil; item_ch = item_ch.next {
					if item_ch.kind == .Paragraph {
						for p_ch := item_ch.first; p_ch != nil; p_ch = p_ch.next {
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
		for ch := n.first; ch != nil; ch = ch.next {
			if ch.kind == .List_Item {
				strings.write_string(&w.buf, "  \\item ")
				for item_ch := ch.first; item_ch != nil; item_ch = item_ch.next {
					if item_ch.kind == .Paragraph {
						for p_ch := item_ch.first; p_ch != nil; p_ch = p_ch.next {
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
		for ch := n.first; ch != nil; ch = ch.next {
			if ch.kind == .Definition_List_Item {
				term := ""
				for item_ch := ch.first; item_ch != nil; item_ch = item_ch.next {
					if item_ch.kind == .Term {
						term = item_ch.raw if len(item_ch.raw) > 0 else item_ch.text
						break
					}
				}
				strings.write_string(&w.buf, "  \\item[")
				escape_latex_text(&w.buf, term)
				strings.write_string(&w.buf, "] ")
				for item_ch := ch.first; item_ch != nil; item_ch = item_ch.next {
					if item_ch.kind == .Definition {
						for d_ch := item_ch.first; d_ch != nil; d_ch = d_ch.next {
							if d_ch.kind == .Paragraph {
								for p_ch := d_ch.first; p_ch != nil; p_ch = p_ch.next {
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
		for ch := n.first; ch != nil; ch = ch.next {
			if ch.kind == .Field {
				name := ""
				for item_ch := ch.first; item_ch != nil; item_ch = item_ch.next {
					if item_ch.kind == .Field_Name {
						name = item_ch.raw if len(item_ch.raw) > 0 else item_ch.text
						break
					}
				}
				strings.write_string(&w.buf, "  \\item[")
				escape_latex_text(&w.buf, name)
				strings.write_string(&w.buf, ":] ")
				for item_ch := ch.first; item_ch != nil; item_ch = item_ch.next {
					if item_ch.kind == .Field_Body {
						for d_ch := item_ch.first; d_ch != nil; d_ch = d_ch.next {
							if d_ch.kind == .Paragraph {
								for p_ch := d_ch.first; p_ch != nil; p_ch = p_ch.next {
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
		strings.write_string(&w.buf, n.text)
		strings.write_string(&w.buf, "\n\\end{verbatim}\n\\end{quote}\n\n")

	case .Line_Block:
		strings.write_string(&w.buf, "\\begin{quote}\n")
		for ch := n.first; ch != nil; ch = ch.next {
			if ch.kind == .Line {
				for l_ch := ch.first; l_ch != nil; l_ch = l_ch.next do latex_render_inline(w, l_ch)
				strings.write_string(&w.buf, "\\\\\n")
			}
		}
		strings.write_string(&w.buf, "\\end{quote}\n\n")

	case .Block_Quote:
		strings.write_string(&w.buf, "\\begin{quote}\n")
		for ch := n.first; ch != nil; ch = ch.next {
			latex_render_block(w, ch)
		}
		strings.write_string(&w.buf, "\\end{quote}\n\n")

	case .Attribution:
		strings.write_string(&w.buf, "\\begin{flushright}\n--- \\emph{")
		escape_latex_text(&w.buf, n.text)
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
		for ch := n.first; ch != nil; ch = ch.next {
			latex_render_block(w, ch)
		}
	}
}

@(private = "file")
latex_section_title :: proc(w: ^Latex_Writer, n: ^Node) {
	style := Title_Style{n = len(n.name)}
	for i in 0 ..< min(len(n.name), 2) do style.chars[i] = n.name[i]

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

	title_node := n.first
	title_text := ""
	if title_node != nil {
		title_text = title_node.raw if len(title_node.raw) > 0 else title_node.text
	}

	strings.write_string(&w.buf, cmd)
	strings.write_byte(&w.buf, '{')
	if title_node != nil {
		for ch := title_node.first; ch != nil; ch = ch.next {
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
latex_render_table :: proc(w: ^Latex_Writer, n: ^Node) {
	cols := 1
	for ch := n.first; ch != nil; ch = ch.next {
		if ch.kind == .TGroup {
			c_count := 0
			for tg := ch.first; tg != nil; tg = tg.next {
				if tg.kind == .Colspec do c_count += 1
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

	for ch := n.first; ch != nil; ch = ch.next {
		if ch.kind == .TGroup {
			for tg := ch.first; tg != nil; tg = tg.next {
				if tg.kind == .THead {
					for row := tg.first; row != nil; row = row.next {
						if row.kind == .Row do latex_render_table_row(w, row)
					}
					strings.write_string(&w.buf, "\\midrule\n")
				} else if tg.kind == .TBody {
					for row := tg.first; row != nil; row = row.next {
						if row.kind == .Row do latex_render_table_row(w, row)
					}
				}
			}
		}
	}

	strings.write_string(&w.buf, "\\bottomrule\n\\end{longtable}\n\n")
}

@(private = "file")
latex_render_table_row :: proc(w: ^Latex_Writer, row: ^Node) {
	first := true
	for entry := row.first; entry != nil; entry = entry.next {
		if entry.kind == .Entry {
			if !first do strings.write_string(&w.buf, " & ")
			first = false
			for ech := entry.first; ech != nil; ech = ech.next {
				if ech.kind == .Paragraph {
					for pch := ech.first; pch != nil; pch = pch.next do latex_render_inline(w, pch)
				} else {
					latex_render_block(w, ech)
				}
			}
		}
	}
	strings.write_string(&w.buf, " \\\\\n")
}

@(private = "file")
latex_render_directive :: proc(w: ^Latex_Writer, n: ^Node) {
	name := strings.to_lower(n.name, context.temp_allocator)
	info, has_info := n.extra.(^Directive_Info)
	if !has_info || info == nil do return

	switch name {
	case "attention", "caution", "danger", "error", "hint", "important", "note", "tip", "warning", "admonition":
		fmt.sbprintf(&w.buf, "\\begin{{quote}}\n\\textbf{{%s:}}\\newline\n", strings.to_upper(name, context.temp_allocator))
		if len(info.lines) > 0 {
			nested := new_node(.Block_Quote, 0, w.p.allocator)
			sm := make_state_machine(w.p, nil, 0, nested)
			nested_parse(&sm, info.lines, info.line_offset, nested)
			for ch := nested.first; ch != nil; ch = ch.next {
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
			nested := new_node(.Block_Quote, 0, w.p.allocator)
			sm := make_state_machine(w.p, nil, 0, nested)
			nested_parse(&sm, info.lines, info.line_offset, nested)
			for ch := nested.first; ch != nil; ch = ch.next {
				latex_render_block(w, ch)
			}
		}
	}
}

@(private = "file")
latex_render_inline :: proc(w: ^Latex_Writer, n: ^Node) {
	#partial switch n.kind {
	case .Text:
		escape_latex_text(&w.buf, n.text)

	case .Emphasis:
		strings.write_string(&w.buf, "\\emph{")
		if n.first != nil {
			for ch := n.first; ch != nil; ch = ch.next do latex_render_inline(w, ch)
		} else {
			escape_latex_text(&w.buf, n.text)
		}
		strings.write_string(&w.buf, "}")

	case .Strong:
		strings.write_string(&w.buf, "\\textbf{")
		if n.first != nil {
			for ch := n.first; ch != nil; ch = ch.next do latex_render_inline(w, ch)
		} else {
			escape_latex_text(&w.buf, n.text)
		}
		strings.write_string(&w.buf, "}")

	case .Literal:
		strings.write_string(&w.buf, "\\texttt{")
		escape_latex_text(&w.buf, n.text)
		strings.write_string(&w.buf, "}")

	case .Reference:
		url := ""
		ref_kind := Ref_Kind(n.num[0])
		switch ref_kind {
		case .Uri:
			url = n.name
		case .Pep:
			url = fmt.tprintf("https://peps.python.org/pep-%04s", n.name)
		case .Rfc:
			url = fmt.tprintf("https://datatracker.ietf.org/doc/html/rfc%s", n.name)
		case .Phrase:
			if info, ok := n.extra.(^Phrase_Info); ok && info != nil {
				url = info.alias
			}
			if len(url) == 0 do url = fmt.tprintf("#%s", slugify(n.name, context.temp_allocator))
		case .Simple:
			url = fmt.tprintf("#%s", slugify(n.name, context.temp_allocator))
		}
		fmt.sbprintf(&w.buf, "\\href{{%s}}{{", url)
		if n.first != nil {
			for ch := n.first; ch != nil; ch = ch.next do latex_render_inline(w, ch)
		} else {
			escape_latex_text(&w.buf, n.text if len(n.text) > 0 else n.name)
		}
		strings.write_string(&w.buf, "}")

	case .Footnote_Reference:
		fmt.sbprintf(&w.buf, "\\footnote{{%s}}", n.name)

	case .Citation_Reference:
		fmt.sbprintf(&w.buf, "\\cite{{%s}}", n.name)

	case .Inline_Target:
		fmt.sbprintf(&w.buf, "\\label{{%s}}", slugify(n.name, context.temp_allocator))
		for ch := n.first; ch != nil; ch = ch.next do latex_render_inline(w, ch)

	case:
		if len(n.text) > 0 do escape_latex_text(&w.buf, n.text)
		for ch := n.first; ch != nil; ch = ch.next do latex_render_inline(w, ch)
	}
}
