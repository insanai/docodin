"""Building blocks for the LaTeX preamble."""

from __future__ import annotations

import warnings
from collections.abc import Iterator
from pathlib import Path

__docformat__ = "reStructuredText"

LATEX_WRITER_DIR = Path(__file__).parent


class SortableDict(dict):
    """Dictionary with additional sorting methods

    Deprecated. Will be removed in Docutils 0.24.
    """

    def __init__(self, *args, **kwargs) -> None:
        warnings.warn("`writers.latex2e.SortableDict` is obsolete"
                      " and will be removed in Docutils 0.24.",
                      DeprecationWarning, stacklevel=2)
        super().__init__(*args, **kwargs)

    def sortedkeys(self) -> list:
        """Return sorted list of keys"""
        return sorted(self.keys())

    def sortedvalues(self) -> list:
        """Return list of values sorted by keys"""
        return [self[key] for key in self.sortedkeys()]


# PreambleCmds
# `````````````
# A container for LaTeX code snippets that can be
# inserted into the preamble if required in the document.
#
# .. The package 'makecmds' would enable shorter definitions using the
#    \providelength and \provideenvironment commands.
#    However, it is pretty non-standard (texlive-latex-extra).

class PreambleCmds:
    """Building blocks for the latex preamble."""


# Requirements and Setup

# Not in docutils.sty because of the overhead for every font change:
PreambleCmds.ch = r"""
\ifdefined\DUchdimen  % lengh unit "ch": width of a zero char
\else
  \newlength{\DUchdimen}
  \AtBeginDocument{\settowidth\DUchdimen{0}}  % set after font setup,
  % update with font changes (requires LaTeX > 2021-06-01, see lthooks-doc.pdf)
  \AddToHook{cmd/selectfont/after}{\settowidth\DUchdimen{0}}
\fi"""

PreambleCmds.color = r"""\usepackage{color}"""

PreambleCmds.float = r"""\usepackage{float} % extended float configuration
\floatplacement{figure}{H} % place figures here definitely"""

PreambleCmds.linking = r"""%% hyperlinks:
\ifdefined\hypersetup
\else
  \usepackage[%s]{hyperref}
  \usepackage{bookmark}
  \urlstyle{same} %% normal text font (alternatives: tt, rm, sf)
\fi"""

PreambleCmds.minitoc = r"""%% local table of contents
\usepackage{minitoc}"""

PreambleCmds.table = r"""\usepackage{longtable,ltcaption,array}
\setlength{\extrarowheight}{2pt}
\newlength{\DUtablewidth} % internal use in tables"""

PreambleCmds.table_columnwidth = (
    r"\newcommand{\DUcolumnwidth}[1]"
    r"{\dimexpr#1\DUtablewidth-2\tabcolsep\relax}")

PreambleCmds.textcomp = r"""\usepackage{textcomp} % text symbol macros"""
# TODO? Options [force,almostfull] prevent spurious error messages,
# see de.comp.text.tex/2005-12/msg01855

# backwards compatibility definitions

PreambleCmds.abstract_legacy = r"""
% abstract title
\providecommand*{\DUtitleabstract}[1]{\centerline{\textbf{#1}}}"""

# see https://sourceforge.net/p/docutils/bugs/339/
PreambleCmds.admonition_legacy = r"""
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
}"""

PreambleCmds.error_legacy = r"""
% error admonition title
\providecommand*{\DUtitleerror}[1]{\DUtitle{\color{red}#1}}"""

PreambleCmds.title_legacy = r"""
% title for topics, admonitions, unsupported section levels, and sidebar
\providecommand*{\DUtitle}[2][class-arg]{%
  % call \DUtitle#1{#2} if it exists:
  \ifcsname DUtitle#1\endcsname%
    \csname DUtitle#1\endcsname{#2}%
  \else
    \smallskip\noindent\textbf{#2}\smallskip%
  \fi
}"""

PreambleCmds.toc_list = r"""
\providecommand*{\DUCLASScontents}{%
  \renewenvironment{itemize}%
    {\begin{list}{}{\setlength{\partopsep}{0pt}
                    \setlength{\parsep}{0pt}}
                   }%
    {\end{list}}%
}"""

PreambleCmds.ttem = r"""
% character width in monospaced font
\newlength{\ttemwidth}
\settowidth{\ttemwidth}{\ttfamily M}"""


# Definitions from docutils.sty::

def _read_block(fp: Iterator[str]) -> str:
    block = [next(fp)]  # first line (empty)
    for line in fp:
        if not line.strip():
            break
        block.append(line)
    return "".join(block).rstrip()


def _load_docutils_sty() -> None:
    """Add the code blocks marked with "<name>::" in docutils.sty to `PreambleCmds`."""
    with open(LATEX_WRITER_DIR / "docutils.sty", encoding="utf-8") as fp:
        for line in fp:
            line = line.strip("% \n")
            if not line.endswith("::"):
                continue
            block_name = line.rstrip(":")
            if not block_name:
                continue
            definitions = _read_block(fp)
            if block_name in ("color", "float", "table", "textcomp"):
                definitions = definitions.strip()
            setattr(PreambleCmds, block_name, definitions)


_load_docutils_sty()
