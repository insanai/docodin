package writers

import "base:runtime"
import "core:slice"
import "core:strings"

// Language support (``Babel``, and ``polyglossia`` for XeTeX), the preamble
// building blocks (``PreambleCmds``) and ``DocumentClass``.

// TeX (babel) language names by (lower case) BCP 47 tag.
@(rodata)
BABEL_LANGUAGES := [?][2]string {
	{"af", "afrikaans"},
	{"ar", "arabic"},
	{"bg", "bulgarian"},
	{"br", "breton"},
	{"ca", "catalan"},
	{"cs", "czech"},
	{"cy", "welsh"},
	{"da", "danish"},
	{"de", "ngerman"},
	{"de-1901", "german"},
	{"de-at", "naustrian"},
	{"de-at-1901", "austrian"},
	{"dsb", "lowersorbian"},
	{"el", "greek"},
	{"el-polyton", "polutonikogreek"},
	{"en", "english"},
	{"en-au", "australian"},
	{"en-ca", "canadian"},
	{"en-gb", "british"},
	{"en-nz", "newzealand"},
	{"en-us", "american"},
	{"eo", "esperanto"},
	{"es", "spanish"},
	{"et", "estonian"},
	{"eu", "basque"},
	{"fi", "finnish"},
	{"fr", "french"},
	{"fr-ca", "canadien"},
	{"ga", "irish"},
	{"grc-ibycus", "ibycus"},
	{"gl", "galician"},
	{"he", "hebrew"},
	{"hr", "croatian"},
	{"hsb", "uppersorbian"},
	{"hu", "magyar"},
	{"ia", "interlingua"},
	{"id", "bahasai"},
	{"is", "icelandic"},
	{"it", "italian"},
	{"ja", "japanese"},
	{"kk", "kazakh"},
	{"la", "latin"},
	{"lt", "lithuanian"},
	{"lv", "latvian"},
	{"mn", "mongolian"},
	{"ms", "bahasam"},
	{"nb", "norsk"},
	{"nl", "dutch"},
	{"nn", "nynorsk"},
	{"no", "norsk"},
	{"pl", "polish"},
	{"pt", "portuges"},
	{"pt-br", "brazil"},
	{"ro", "romanian"},
	{"ru", "russian"},
	{"se", "samin"},
	{"sh-cyrl", "serbianc"},
	{"sh-latn", "serbian"},
	{"sk", "slovak"},
	{"sl", "slovene"},
	{"sq", "albanian"},
	{"sr", "serbianc"},
	{"sr-latn", "serbian"},
	{"sv", "swedish"},
	{"tr", "turkish"},
	{"uk", "ukrainian"},
	{"vi", "vietnam"},
}

// Polyglossia names that differ from or add to the babel names.
@(rodata)
POLYGLOSSIA_LANGUAGES := [?][2]string {
	{"cop", "coptic"},
	{"de", "german"},
	{"de-1901", "ogerman"},
	{"dv", "divehi"},
	{"dsb", "lsorbian"},
	{"el-polyton", "polygreek"},
	{"fa", "farsi"},
	{"grc", "ancientgreek"},
	{"ko", "korean"},
	{"hsb", "usorbian"},
	{"sh-cyrl", "serbian"},
	{"sh-latn", "croatian"},
	{"sq", "albanian"},
	{"sr", "serbian"},
	{"th", "thai"},
	{"vi", "vietnamese"},
}

// Languages without polyglossia support.
@(rodata)
NO_POLYGLOSSIA := [?]string {
	"af",
	"de-at",
	"de-at-1901",
	"en-ca",
	"en-gb",
	"en-nz",
	"en-us",
	"fr-ca",
	"grc-ibycus",
	"sr-latn",
}

Babel :: struct {
	xetex:          bool,
	language:       string,
	otherlanguages: map[string]bool,
}

make_babel :: proc(language_code: string, xetex: bool) -> Babel {
	b := Babel {
		xetex          = xetex,
		otherlanguages = make(map[string]bool, 4, context.temp_allocator),
	}
	b.language = babel_language_name(&b, language_code)
	return b
}

@(private = "file")
lookup_language :: proc(b: ^Babel, tag: string) -> (string, bool) {
	if b.xetex {
		if slice.contains(NO_POLYGLOSSIA[:], tag) do return "", false
		for m in POLYGLOSSIA_LANGUAGES do if m[0] == tag do return m[1], true
	}
	for m in BABEL_LANGUAGES do if m[0] == tag do return m[1], true
	return "", false
}

// ``Babel.language_name``: the TeX language name of a language code ("" if
// it is not supported).
babel_language_name :: proc(b: ^Babel, language_code: string) -> string {
	for tag in normalize_language_tag(language_code) {
		if name, ok := lookup_language(b, tag); ok do return name
	}
	return ""
}

// Active characters to deactivate per language.
@(private = "file")
active_chars :: proc(language: string) -> string {
	switch language {
	case "galician", "spanish":
		return ".<>"
	}
	return ""
}

// ``Babel.__call__``: the babel (or polyglossia) set-up.
babel_setup :: proc(b: ^Babel) -> string {
	others := make([dynamic]string, 0, len(b.otherlanguages), context.temp_allocator)
	for l in b.otherlanguages do append(&others, l)
	slice.sort(others[:])
	if b.xetex {
		setup := make([dynamic]string, 0, 3, context.temp_allocator)
		append(&setup, "\\usepackage{polyglossia}", cat("\\setdefaultlanguage{", b.language, "}"))
		if len(others) > 0 {
			joined := strings.join(others[:], ",", context.temp_allocator)
			append(&setup, cat("\\setotherlanguages{", joined, "}"))
		}
		return strings.join(setup[:], "\n", context.temp_allocator)
	}
	main := b.language if b.language != "" else "english"
	languages := others
	append(&languages, cat("main=", main) if len(others) > 0 else main)
	setup := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&setup, cat("\\usepackage[", ljoin(languages[:], ","), "]{babel}"))
	shorthands := strings.builder_make(context.temp_allocator)
	for l in languages {
		for c in active_chars(l) {
			if !strings.contains_rune(strings.to_string(shorthands), c) {
				strings.write_rune(&shorthands, c)
			}
		}
	}
	if strings.builder_len(shorthands) > 0 {
		off := strings.to_string(shorthands)
		append(&setup, cat("\\AtBeginDocument{\\shorthandoff{", off, "}}"))
	}
	if slice.contains(languages[:], "galician") {
		append(&setup, "\\deactivatetilden % restore ~ in Galician")
	}
	for lng in ([]string{"estonian", "basque"}) {
		if slice.contains(languages[:], lng) {
			append(&setup, "\\makeatletter")
			append(&setup, cat("  \\addto\\extras", lng, "{\\bbl@deactivate{~}}"))
			append(&setup, "\\makeatother")
		}
	}
	if languages[len(languages) - 1] == "main=english" && "french" in b.otherlanguages {
		append(&setup, "% Prevent side-effects if French hyphenation patterns are not loaded:")
		append(&setup, "\\frenchbsetup{StandardLayout}")
		select := cat("\\AtBeginDocument{\\selectlanguage{", b.language, "}\\noextrasfrench}")
		append(&setup, select)
	}
	return strings.join(setup[:], "\n", context.temp_allocator)
}

// --- PreambleCmds ------------------------------------------------------------------------

PREAMBLE_CH := `
\ifdefined\DUchdimen  % lengh unit "ch": width of a zero char
\else
  \newlength{\DUchdimen}
  \AtBeginDocument{\settowidth\DUchdimen{0}}  % set after font setup,
  % update with font changes (requires LaTeX > 2021-06-01, see lthooks-doc.pdf)
  \AddToHook{cmd/selectfont/after}{\settowidth\DUchdimen{0}}
\fi`

PREAMBLE_LINKING :: `%% hyperlinks:
\ifdefined\hypersetup
\else
  \usepackage[%s]{hyperref}
  \usepackage{bookmark}
  \urlstyle{same} %% normal text font (alternatives: tt, rm, sf)
\fi`

PREAMBLE_CMDS := [?][2]string {
	{"ch", PREAMBLE_CH},
	{"color", `\usepackage{color}`},
	{"float", "\\usepackage{float} % extended float configuration\n" +
		"\\floatplacement{figure}{H} % place figures here definitely"},
	{"linking", PREAMBLE_LINKING},
	{"minitoc", "%% local table of contents\n\\usepackage{minitoc}"},
	{"table", "\\usepackage{longtable,ltcaption,array}\n\\setlength{\\extrarowheight}{2pt}\n" +
		"\\newlength{\\DUtablewidth} % internal use in tables"},
	{
		"table_columnwidth",
		`\newcommand{\DUcolumnwidth}[1]{\dimexpr#1\DUtablewidth-2\tabcolsep\relax}`,
	},
	{"textcomp", `\usepackage{textcomp} % text symbol macros`},
	{"abstract_legacy", "\n% abstract title\n" +
		`\providecommand*{\DUtitleabstract}[1]{\centerline{\textbf{#1}}}`},
	{"admonition_legacy", `
% admonition (specially marked topic)
\providecommand{\DUadmonition}[2][class-arg]{%
  % try \DUadmonition#1{#2}:
  \ifcsname DUadmonition#1\endcsname%
    \csname DUadmonition#1\endcsname{#2}%
  \else
    \begin{center}
      \fbox{\parbox{0.9\linewidth}{#2}}
    \end{center}
  \fi
}`},
	{"error_legacy", "\n% error admonition title\n" +
		`\providecommand*{\DUtitleerror}[1]{\DUtitle{\color{red}#1}}`},
	{"title_legacy", `
% title for topics, admonitions, unsupported section levels, and sidebar
\providecommand*{\DUtitle}[2][class-arg]{%
  % call \DUtitle#1{#2} if it exists:
  \ifcsname DUtitle#1\endcsname%
    \csname DUtitle#1\endcsname{#2}%
  \else
    \smallskip\noindent\textbf{#2}\smallskip%
  \fi
}`},
	{"toc_list", `
\providecommand*{\DUCLASScontents}{%
  \renewenvironment{itemize}%
    {\begin{list}{}{\setlength{\partopsep}{0pt}
                    \setlength{\parsep}{0pt}}
                   }%
    {\end{list}}%
}`},
	{"ttem", "\n% character width in monospaced font\n\\newlength{\\ttemwidth}\n" +
		"\\settowidth{\\ttemwidth}{\\ttfamily M}"},
}

// The code blocks marked with "<name>::" in docutils.sty.
@(private = "file")
sty_blocks: map[string]string

@(private = "file")
load_docutils_sty :: proc() {
	// a process-wide cache: not in the writer's scratch arena
	context.allocator = runtime.heap_allocator()
	sty_blocks = make(map[string]string, 64)
	text, _ := data_file(.Latex, "docutils.sty")
	lines := strings.split_lines_after(text)
	for i := 0; i < len(lines); {
		line := strings.trim(lines[i], "% \n")
		i += 1
		if !strings.has_suffix(line, "::") do continue
		name := strings.trim_right(line, ":")
		if name == "" || i >= len(lines) do continue
		b := strings.builder_make()
		strings.write_string(&b, lines[i]) // first line (empty)
		i += 1
		for i < len(lines) {
			l := lines[i]
			i += 1
			if strings.trim_space(l) == "" do break
			strings.write_string(&b, l)
		}
		block := strings.trim_right_space(strings.to_string(b))
		switch name {
		case "color", "float", "table", "textcomp":
			block = strings.trim_space(block)
		}
		sty_blocks[name] = block
	}
}

// A ``PreambleCmds`` attribute; ``ok`` is false if there is none.
preamble_lookup :: proc(name: string) -> (string, bool) {
	if sty_blocks == nil do load_docutils_sty()
	if s, ok := sty_blocks[name]; ok do return s, true
	for c in PREAMBLE_CMDS do if c[0] == name do return c[1], true
	return "", false
}

preamble_cmd :: proc(name: string) -> string {
	s, _ := preamble_lookup(name)
	return s
}

// --- DocumentClass -----------------------------------------------------------------------

Document_Class :: struct {
	sections: [dynamic]string,
}

make_document_class :: proc(document_class: string, with_part: bool) -> Document_Class {
	d := Document_Class {
		sections = make([dynamic]string, 0, 7, context.temp_allocator),
	}
	if with_part do append(&d.sections, "part")
	switch {
	case strings.has_suffix(document_class, "book"), strings.has_suffix(document_class, "report"):
		append(&d.sections, "chapter")
	case:
		switch document_class {
		case "ctexrep", "memoir", "mwbk", "mwrep", "scrreprt":
			append(&d.sections, "chapter")
		}
	}
	append(&d.sections, "section", "subsection", "subsubsection", "paragraph", "subparagraph")
	return d
}

// The LaTeX section name for section ``level`` (1, 2, ...).
section_name :: proc(d: ^Document_Class, level: int) -> string {
	if level > len(d.sections) do return "DUtitle"
	// Python indexing: level 0 is the last section name
	return d.sections[level - 1] if level >= 1 else d.sections[len(d.sections) + level - 1]
}

// ``DocumentClass.latex_section_depth(depth)``.
latex_section_depth :: proc(d: ^Document_Class, depth: int) -> int {
	res := min(depth, len(d.sections))
	if slice.contains(d.sections[:], "chapter") do res -= 1
	if d.sections[0] == "part" do res -= 1
	return res
}

has_chapter :: proc(d: ^Document_Class) -> bool {
	return slice.contains(d.sections[:], "chapter")
}

// ``str(RomanNumeral(n))``: upper case Roman numeral.
roman :: proc(n: int, lower := false) -> string {
	values := [?]int{1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1}
	upper := [?]string{"M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"}
	low := [?]string{"m", "cm", "d", "cd", "c", "xc", "l", "xl", "x", "ix", "v", "iv", "i"}
	b := strings.builder_make(context.temp_allocator)
	v := n
	for val, i in values {
		for v >= val {
			strings.write_string(&b, low[i] if lower else upper[i])
			v -= val
		}
	}
	return strings.to_string(b)
}
