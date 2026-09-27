package rst

import "core:fmt"
import "core:strings"

// Native LaTeX 2e emitter (``docodin_render_latex``, ``docodin latex``,
// ``docodin pdf``).

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
	using ctx:    Render_Context,
	buf:          strings.Builder,
	config:       Latex_Config,
	title_styles: [dynamic]Title_Style,
	// The section title shown by ``\maketitle`` (standalone documents without
	// a configured title): it gets no ``\section`` of its own, and the
	// sections below it move up a level.
	promoted:     Node,
}

@(private = "file")
LATEX_PREAMBLE :: `\usepackage[utf8]{inputenc}
\usepackage[T1]{fontenc}
\usepackage{lmodern}
\usepackage{amsmath,amssymb}
\usepackage{alltt}
\usepackage{graphicx}
\usepackage[export]{adjustbox}
\usepackage{booktabs}
\usepackage{longtable}
\usepackage{xcolor}
\usepackage{geometry}
\geometry{margin=1in}
\usepackage[colorlinks=true,linkcolor=blue,urlcolor=blue]{hyperref}

`

// Text: every character with a meaning in LaTeX is escaped.
escape_latex_text :: proc(b: ^strings.Builder, s: string) {
	for i := 0; i < len(s); i += 1 {
		switch c := s[i]; c {
		case '\\': strings.write_string(b, "\\textbackslash{}")
		case '&':  strings.write_string(b, "\\&")
		case '%':  strings.write_string(b, "\\%")
		case '$':  strings.write_string(b, "\\$")
		case '#':  strings.write_string(b, "\\#")
		case '_':  strings.write_string(b, "\\_")
		case '{':  strings.write_string(b, "\\{")
		case '}':  strings.write_string(b, "\\}")
		case '~':  strings.write_string(b, "\\textasciitilde{}")
		case '^':  strings.write_string(b, "\\textasciicircum{}")
		case 0:    // NUL bytes cannot be typeset
		case:      strings.write_byte(b, c)
		}
	}
}

// URLs and file names (``\href``, ``\includegraphics``), escaped for hyperref.
escape_latex_url :: proc(b: ^strings.Builder, s: string) {
	for i := 0; i < len(s); i += 1 {
		switch c := s[i]; c {
		case '\\': strings.write_string(b, "\\\\")
		case '#':  strings.write_string(b, "\\#")
		case '%':  strings.write_string(b, "\\%")
		case '{':  strings.write_string(b, "\\{")
		case '}':  strings.write_string(b, "\\}")
		case '~':  strings.write_string(b, "\\textasciitilde{}")
		case 0:
		case:      strings.write_byte(b, c)
		}
	}
}

write_latex :: proc(doc: Node, p: ^Parser, config: Latex_Config) -> string {
	w := Latex_Writer {
		ctx          = render_context_make(p, doc),
		buf          = strings.builder_make(p.allocator),
		config       = config,
		title_styles = make([dynamic]Title_Style, p.allocator),
	}
	if config.standalone {
		if config.title == "" do w.promoted = first_section_title(w.t, doc)
		latex_preamble(&w, document_title(&w.ctx, doc, config.title))
	}
	it := children(w.t, doc)
	for n in iterate(&it) do latex_block(&w, n)
	if config.standalone do strings.write_string(&w.buf, "\n\\end{document}\n")
	return strings.to_string(w.buf)
}

@(private = "file")
latex_preamble :: proc(w: ^Latex_Writer, title: string) {
	b := &w.buf
	c := w.config
	doc_class := c.doc_class if c.doc_class != "" else "article"
	papersize := c.papersize if c.papersize != "" else "a4paper"
	fontsize := c.fontsize if c.fontsize != "" else "11pt"
	strings.write_string(b, "\\documentclass[")
	escape_latex_text(b, fontsize)
	strings.write_byte(b, ',')
	escape_latex_text(b, papersize)
	strings.write_string(b, "]{")
	escape_latex_text(b, doc_class)
	strings.write_string(b, "}\n")
	strings.write_string(b, LATEX_PREAMBLE)
	latex_command(w, "\\title{", title, "}\n")
	if c.author != "" do latex_command(w, "\\author{", c.author, "}\n")
	if c.date != "" {
		latex_command(w, "\\date{", c.date, "}\n")
	} else {
		strings.write_string(b, "\\date{\\today}\n")
	}
	strings.write_string(b, "\n\\begin{document}\n\\maketitle\n\n")
}

// ``open`` + escaped ``text`` + ``close``.
@(private = "file")
latex_command :: proc(w: ^Latex_Writer, open, text, close: string) {
	strings.write_string(&w.buf, open)
	escape_latex_text(&w.buf, text)
	strings.write_string(&w.buf, close)
}

@(private = "file")
latex_children :: proc(w: ^Latex_Writer, n: Node, inline := false) {
	it := children(w.t, n)
	for c in iterate(&it) {
		if inline {
			latex_inline(w, c)
		} else {
			latex_block(w, c)
		}
	}
}

// Block children, paragraphs written compactly (list items, definitions).
@(private = "file")
latex_compact :: proc(w: ^Latex_Writer, n: Node) {
	it := children(w.t, n)
	for c in iterate(&it) {
		if w.t.nodes[c].kind == .Paragraph {
			latex_children(w, c, inline = true)
			strings.write_byte(&w.buf, '\n')
		} else {
			latex_block(w, c)
		}
	}
}

// A block element whose children are written between ``open`` and
// ``close`` (as inline markup when ``inline``).
@(private = "file")
Latex_Wrap :: struct {
	open, close: string,
	inline:      bool,
}

@(private = "file")
LATEX_WRAPS := #partial [Node_Kind]Latex_Wrap {
	.Paragraph       = {"", "\n\n", true},
	.Bullet_List     = {"\\begin{itemize}\n", "\\end{itemize}\n\n", false},
	.Enumerated_List = {"\\begin{enumerate}\n", "\\end{enumerate}\n\n", false},
	.Definition_List = {"\\begin{description}\n", "\\end{description}\n\n", false},
	.Field_List      = {"\\begin{description}\n", "\\end{description}\n\n", false},
	.Block_Quote     = {"\\begin{quote}\n", "\\end{quote}\n\n", false},
	.Attribution     = {"\\begin{flushright}\n--- \\emph{", "}\n\\end{flushright}\n\n", true},
	.Transition      = {"\\bigskip\\hrule\\bigskip\n\n", "", false},
}

@(private = "file")
latex_block :: proc(w: ^Latex_Writer, n: Node) {
	d := node_data(w.t, n)
	#partial switch d.kind {
	case .Section_Title:
		latex_section_title(w, n)
	case .List_Item:
		strings.write_string(&w.buf, "  \\item ")
		latex_compact(w, n)
	case .Definition_List_Item, .Field:
		latex_labelled_item(w, n)
	case .Literal_Block, .Doctest_Block:
		latex_verbatim(w, d.text)
	case .Line_Block:
		latex_line_block(w, n)
	case .Table:
		latex_table(w, n)
	case .Directive:
		latex_directive(w, n)
	case .Footnote, .Citation:
		latex_note(w, n, d)
	case .Target:
		if id, ok := target_anchor(&w.ctx, d); ok do latex_anchor(w, id)
	case .Label, .Comment, .Substitution_Definition:
	case:
		wrap := LATEX_WRAPS[d.kind]
		strings.write_string(&w.buf, wrap.open)
		latex_children(w, n, wrap.inline)
		strings.write_string(&w.buf, wrap.close)
	}
}

// ``\phantomsection\label{id}``: a hyperlink target here (``id`` is
// [a-z0-9-] only, see ``anchor_id``).
@(private = "file")
latex_anchor :: proc(w: ^Latex_Writer, id: string) {
	fmt.sbprintf(&w.buf, "\\phantomsection\\label{{%s}}", id)
}

// A definition list item or field: ``\item[term] definition``.
@(private = "file")
latex_labelled_item :: proc(w: ^Latex_Writer, n: Node) {
	t := w.t
	term, body := NO_NODE, NO_NODE
	it := children(t, n)
	for c in iterate(&it) {
		#partial switch t.nodes[c].kind {
		case .Term, .Field_Name:
			if term == NO_NODE do term = c
		case .Definition, .Field_Body:
			body = c
		}
	}
	strings.write_string(&w.buf, "  \\item[")
	if term != NO_NODE do escape_latex_text(&w.buf, node_astext(&w.ctx, term))
	if t.nodes[n].kind == .Field do strings.write_byte(&w.buf, ':')
	strings.write_string(&w.buf, "] ")
	if body != NO_NODE do latex_compact(w, body)
}

// Literal text: ``alltt`` keeps spaces and line breaks while the escapes
// keep every character literal.
@(private = "file")
latex_verbatim :: proc(w: ^Latex_Writer, text: string) {
	strings.write_string(&w.buf, "\\begin{quote}\n\\begin{alltt}\n")
	escape_latex_text(&w.buf, text)
	strings.write_string(&w.buf, "\n\\end{alltt}\n\\end{quote}\n\n")
}

@(private = "file")
latex_line_block :: proc(w: ^Latex_Writer, n: Node) {
	strings.write_string(&w.buf, "\\begin{quote}\n")
	it := children(w.t, n)
	for c in iterate(&it) {
		if w.t.nodes[c].kind != .Line do continue
		latex_children(w, c, inline = true)
		strings.write_string(&w.buf, "\\mbox{}\\\\\n")
	}
	strings.write_string(&w.buf, "\\end{quote}\n\n")
}

@(private = "file")
latex_note :: proc(w: ^Latex_Writer, n: Node, d: Node_Data) {
	prefix := "footnote" if d.kind == .Footnote else "citation"
	latex_anchor(w, note_id(w.ctx.a, prefix, d.name))
	latex_command(w, "\\textsuperscript{", d.name, "} ")
	latex_children(w, n)
}

@(private = "file")
LATEX_SECTIONS := [?]string {
	"\\section", "\\subsection", "\\subsubsection", "\\paragraph", "\\subparagraph",
}

@(private = "file")
latex_section_title :: proc(w: ^Latex_Writer, n: Node) {
	level := section_level(&w.title_styles, w.t.nodes[n].name)
	title := w.t.nodes[n].first
	if title == NO_NODE do return
	name := fully_normalize_name(node_astext(&w.ctx, title), w.ctx.a)
	id := anchor_id(name, w.ctx.a)
	if n == w.promoted {
		// shown by \maketitle
		latex_anchor(w, id)
		strings.write_string(&w.buf, "\n\n")
		return
	}
	if w.promoted != NO_NODE && level > 1 do level -= 1
	strings.write_string(&w.buf, LATEX_SECTIONS[clamp(level, 1, len(LATEX_SECTIONS)) - 1])
	strings.write_byte(&w.buf, '{')
	latex_children(w, title, inline = true)
	fmt.sbprintf(&w.buf, "}}\n\\label{{%s}}\n\n", id)
}

@(private = "file")
latex_table :: proc(w: ^Latex_Writer, n: Node) {
	t := w.t
	tgroup := t.nodes[n].first
	if tgroup == NO_NODE || t.nodes[tgroup].kind != .TGroup do return
	cols := max(int(t.nodes[tgroup].num[0]), 1)
	strings.write_string(&w.buf, "\\begin{longtable}{")
	for i in 0 ..< cols {
		if i > 0 do strings.write_byte(&w.buf, ' ')
		strings.write_byte(&w.buf, 'l')
	}
	strings.write_string(&w.buf, "}\n\\toprule\n")
	it := children(t, tgroup)
	for part in iterate(&it) {
		kind := t.nodes[part].kind
		if kind != .THead && kind != .TBody do continue
		rows := children(t, part)
		for row in iterate(&rows) do latex_table_row(w, row)
		if kind == .THead do strings.write_string(&w.buf, "\\midrule\n")
	}
	strings.write_string(&w.buf, "\\bottomrule\n\\end{longtable}\n\n")
}

@(private = "file")
latex_table_row :: proc(w: ^Latex_Writer, row: Node) {
	it := children(w.t, row)
	first := true
	for entry in iterate(&it) {
		if !first do strings.write_string(&w.buf, " & ")
		first = false
		cells := children(w.t, entry)
		for c in iterate(&cells) {
			if w.t.nodes[c].kind == .Paragraph {
				latex_children(w, c, inline = true)
			} else {
				latex_block(w, c)
			}
		}
	}
	strings.write_string(&w.buf, " \\\\\n")
}

@(private = "file")
latex_directive :: proc(w: ^Latex_Writer, n: Node) {
	b := w.blocks[n]
	name := strings.to_lower(w.t.nodes[n].name, w.ctx.a)
	switch directive_kind(name) {
	case .Admonition, .Generic_Admonition:
		latex_admonition(w, name, b)
	case .Code:
		latex_verbatim(w, join_lines(b.content, w.ctx.a))
	case .Image, .Figure:
		strings.write_string(&w.buf, "\\begin{figure}[htbp]\n\\centering\n")
		strings.write_string(&w.buf, "\\includegraphics[max width=\\textwidth]{")
		escape_latex_url(&w.buf, directive_uri(b, w.ctx.a))
		strings.write_string(&w.buf, "}\n")
		if b.body != NO_NODE do latex_children(w, b.body)
		strings.write_string(&w.buf, "\\end{figure}\n\n")
	case .Raw:
		if strings.to_lower(directive_argument(b, w.ctx.a), w.ctx.a) != "latex" do return
		for line in b.content {
			strings.write_string(&w.buf, line)
			strings.write_byte(&w.buf, '\n')
		}
	case .Other:
		if b.body != NO_NODE do latex_children(w, b.body)
	}
}

@(private = "file")
latex_admonition :: proc(w: ^Latex_Writer, name: string, b: Directive_Block) {
	strings.write_string(&w.buf, "\\begin{quote}\n\\textbf{")
	if label, named := admonition_label(name); named {
		escape_latex_text(&w.buf, label)
	} else {
		title := parse_inline(w.p, directive_argument(b, w.ctx.a), 0)
		it := chain(w.t, title.first)
		for c in iterate(&it) do latex_inline(w, c)
	}
	strings.write_string(&w.buf, ":}\\newline\n")
	if b.body != NO_NODE do latex_children(w, b.body)
	strings.write_string(&w.buf, "\\end{quote}\n\n")
}

@(private = "file")
latex_inline :: proc(w: ^Latex_Writer, n: Node) {
	d := node_data(w.t, n)
	a := w.ctx.a
	#partial switch d.kind {
	case .Emphasis: latex_command(w, "\\emph{", unescape(d.text, a), "}")
	case .Strong:   latex_command(w, "\\textbf{", unescape(d.text, a), "}")
	case .Literal:  latex_command(w, "\\texttt{", d.text, "}")
	case .Reference:
		latex_reference(w, n)
	case .Footnote_Reference, .Citation_Reference:
		latex_note_reference(w, d)
	case .Inline_Target:
		latex_anchor(w, anchor_id(fully_normalize_name(unescape(d.text, a), a), a))
		escape_latex_text(&w.buf, unescape(d.text, a))
	case .Problematic:
		escape_latex_text(&w.buf, d.text)
	case:
		escape_latex_text(&w.buf, unescape(d.text, a))
		latex_children(w, n, inline = true)
	}
}

// ``\href{URL}{text}`` or, for targets in the document, ``\hyperref[id]{text}``.
@(private = "file")
latex_reference :: proc(w: ^Latex_Writer, n: Node) {
	link := resolve_reference(&w.ctx, n)
	if link.kind == .External {
		strings.write_string(&w.buf, "\\href{")
		escape_latex_url(&w.buf, link.value)
		strings.write_string(&w.buf, "}{")
	} else {
		fmt.sbprintf(&w.buf, "\\hyperref[%s]{{", link.value)
	}
	latex_command(w, "", reference_text(&w.ctx, n), "}")
}

// A link to the footnote (superscript label) or citation (``[label]``).
@(private = "file")
latex_note_reference :: proc(w: ^Latex_Writer, d: Node_Data) {
	is_footnote := d.kind == .Footnote_Reference
	id := note_id(w.ctx.a, "footnote" if is_footnote else "citation", d.text)
	fmt.sbprintf(&w.buf, "\\hyperref[%s]{{", id)
	if is_footnote {
		latex_command(w, "\\textsuperscript{", d.text, "}}")
	} else {
		latex_command(w, "[", d.text, "]}")
	}
}
