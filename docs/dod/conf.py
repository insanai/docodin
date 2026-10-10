# DocOdin Discussions (DODs): the design records of docodin.  A Sphinx project, also built
# natively by `docodin book build docs/dod`; `docodin dod` creates, lists, indexes and checks
# the records.
#
# The native builder reads the simple module-level assignments below (project, author,
# copyright, version, release, html_title, language, root_doc, exclude_patterns, numfig,
# today_fmt and the docodin_* values); everything else is for Sphinx only.

project = "DocOdin Discussions"
author = "Vikrant Rathore"
copyright = "2026, Vikrant Rathore and the docodin contributors"
version = "1.0"
release = "1.0.0b1"
html_title = "DocOdin Discussions"
language = "en"
root_doc = "index"
master_doc = "index"
exclude_patterns = ["_build", "0000-template.rst", "Thumbs.db", ".DS_Store"]
numfig = False
today_fmt = "%d %B %Y"

docodin_tagline = "The design records of docodin"
docodin_part_labels = False
docodin_pdf_filename = "docodin-dod.pdf"

# --- Sphinx ------------------------------------------------------------------------------

extensions = ["sphinx.ext.graphviz"]
graphviz_output_format = "svg"
smartquotes = True
highlight_language = "text"
pygments_style = "friendly"

html_theme = "furo"
html_static_path = ["../theme", "_static"]
html_css_files = ["docodin.css"]
html_logo = "_static/docodin_logo.png"
html_favicon = "_static/docodin-mark.svg"
html_show_sourcelink = False

# --- LaTeX (lualatex) --------------------------------------------------------------------

latex_engine = "lualatex"
latex_use_xindy = False
latex_toplevel_sectioning = "chapter"
latex_show_urls = "no"
latex_documents = [
    ("index", "docodin-dod.tex", "DocOdin Discussions", author, "manual"),
]

_LATEX_FONTS = r"""
\setmainfont{TeX Gyre Pagella}
\setsansfont{Fira Sans}[Scale=MatchLowercase]
\setmonofont{DejaVu Sans Mono}[Scale=0.84]
"""

_LATEX_PREAMBLE = r"""
\usepackage{tikz}
\definecolor{DocodinInk}{HTML}{16263A}
\definecolor{DocodinBlue}{HTML}{1F5F99}
\definecolor{DocodinAmber}{HTML}{D98A1F}
\definecolor{DocodinMist}{HTML}{EDF2F7}
\definecolor{DocodinSlate}{HTML}{5B6B7D}

% Each record is a chapter: an amber "record" label, the title and a blue rule.
\titleformat{\chapter}[display]
  {\normalfont\sffamily\color{DocodinInk}}
  {\large\bfseries\color{DocodinAmber}RECORD\enspace\thechapter}
  {4pt}
  {\raggedright\fontsize{24}{28}\selectfont\bfseries}
  [\vspace{6pt}{\color{DocodinBlue}\titlerule[1.4pt]}]
\titlespacing*{\chapter}{0pt}{-10pt}{26pt}
\titleformat{\section}
  {\normalfont\sffamily\Large\bfseries\color{DocodinInk}}{\color{DocodinBlue}\thesection}{0.8em}{}
\titleformat{\subsection}
  {\normalfont\sffamily\large\bfseries\color{DocodinInk}}{\color{DocodinBlue}\thesubsection}{0.8em}{}

\makeatletter
\fancypagestyle{normal}{%
  \fancyhf{}%
  \fancyhead[LE]{\sffamily\small\color{DocodinSlate}\nouppercase{\leftmark}}%
  \fancyhead[RO]{\sffamily\small\color{DocodinSlate}DocOdin Discussions}%
  \fancyfoot[LE,RO]{\sffamily\small\bfseries\color{DocodinBlue}\thepage}%
  \renewcommand{\headrulewidth}{0.4pt}%
  \renewcommand{\footrulewidth}{0pt}%
}
\fancypagestyle{plain}{%
  \fancyhf{}%
  \fancyfoot[LE,RO]{\sffamily\small\bfseries\color{DocodinBlue}\thepage}%
  \renewcommand{\headrulewidth}{0pt}%
}
\makeatother
"""

_LATEX_TITLE = r"""
\makeatletter
\begin{titlepage}
  \begin{tikzpicture}[remember picture,overlay]
    \fill[DocodinInk] (current page.north west) rectangle
      ([yshift=-0.45\paperheight]current page.north east);
    \fill[DocodinAmber] ([yshift=-0.45\paperheight]current page.north west) rectangle
      ([yshift=-0.462\paperheight]current page.north east);
    \node[anchor=north west, text width=0.8\paperwidth, align=left]
      at ([xshift=0.1\paperwidth, yshift=-0.15\paperheight]current page.north west) {%
      {\sffamily\bfseries\large\color{DocodinAmber}DOCODIN \py@release}\\[14pt]
      {\sffamily\bfseries\fontsize{40}{46}\selectfont\color{white}DocOdin Discussions}\\[16pt]
      {\sffamily\Large\color{DocodinMist}The design records of docodin}};
    \node[anchor=south west, text width=0.8\paperwidth, align=left]
      at ([xshift=0.1\paperwidth, yshift=0.1\paperheight]current page.south west) {%
      {\sffamily\large\color{DocodinInk}\@author}\\[6pt]
      {\sffamily\small\color{DocodinSlate}\@date}};
  \end{tikzpicture}
\end{titlepage}
\makeatother
\setcounter{page}{1}
"""

latex_elements = {
    "papersize": "a4paper",
    "pointsize": "11pt",
    "fontpkg": _LATEX_FONTS,
    "fncychap": "",
    "preamble": _LATEX_PREAMBLE,
    "maketitle": _LATEX_TITLE,
    "sphinxsetup": (
        "TitleColor={HTML}{16263A}, InnerLinkColor={HTML}{1F5F99}, "
        "OuterLinkColor={HTML}{1F5F99}, VerbatimColor={HTML}{F4F7FA}, "
        "VerbatimBorderColor={HTML}{D3DCE6}, hmargin={2.4cm,2.4cm}, vmargin={2.6cm,2.8cm}"
    ),
    "printindex": "",
    "tableofcontents": r"\renewcommand{\contentsname}{Contents}\sphinxtableofcontents",
}
