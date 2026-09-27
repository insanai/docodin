"""Document class details and table management for the LaTeX writer."""

from __future__ import annotations

from typing import Any

from docutils import nodes

__docformat__ = "reStructuredText"


class DocumentClass:
    """Details of a LaTeX document class."""

    def __init__(self, document_class: str, with_part: bool = False) -> None:
        self.document_class = document_class
        self._with_part = with_part
        self.sections = ["section", "subsection", "subsubsection",
                         "paragraph", "subparagraph"]
        if (self.document_class.endswith("book")
            or self.document_class.endswith("report")
            or self.document_class in ("ctexrep", "memoir", "mwbk",
                                       "mwrep", "scrreprt")):
            self.sections.insert(0, "chapter")
        if self._with_part:
            self.sections.insert(0, "part")

    def section(self, level: int) -> str:
        """Return the LaTeX section name for section `level`.

        The name depends on the specific document class.
        Level is 1,2,3..., as level 0 is the title.
        """
        if level <= len(self.sections):
            return self.sections[level-1]
        # unsupported levels
        return "DUtitle"

    def latex_section_depth(self, depth: int) -> int:
        """
        Return LaTeX equivalent of Docutils section level `depth`.

        Given the value of the ``:depth:`` option of the "contents" or
        "sectnum" directive, return the corresponding value for the
        LaTeX ``tocdepth`` or ``secnumdepth`` counters.

        LaTeX section depth values:
          :-1|0: part (optional, 0 with "article"-like document classes)
          :0:    chapter (missing in "article"-like document classes)
          :1:    section
          :2:    subsection
          :3:    subsubsection
          :4:    paragraph
          :5:    subparagraph
        """
        depth = min(depth, len(self.sections))  # limit to supported levels
        if "chapter" in self.sections:
            depth -= 1
        if self.sections[0] == "part":
            depth -= 1
        return depth


class Table:
    """Manage a table while traversing.

    Table style might be

    :standard:   horizontal and vertical lines
    :booktabs:   only horizontal lines (requires "booktabs" LaTeX package)
    :borderless: no borders around table cells
    :nolines:    alias for borderless

    :colwidths-auto:  column widths determined by LaTeX
    """
    def __init__(self, translator: Any, latex_type: str) -> None:
        self._translator = translator
        self._latex_type = latex_type
        self.legacy_column_widths = False

        self.close()
        self._colwidths = []
        self._rowspan = []
        self._in_thead = 0

    def open(self) -> None:
        self._open = True
        self._col_specs = []
        self.caption = []
        self._attrs = {}
        self._in_head = False  # maybe context with search

    def close(self) -> None:
        self._open = False
        self._col_specs = None
        self.caption = []
        self._attrs = {}
        self.stubs = []
        self.colwidths_auto = False

    def is_open(self) -> bool:
        return self._open

    def set_table_style(self, node: nodes.Element, settings: Any) -> None:
        self.legacy_column_widths = settings.legacy_column_widths
        if "align" in node:
            self.set("align", node["align"])
        # TODO: elif 'align' in classes/settings.table-style:
        #           self.set('align', ...)
        borders = [cls.replace("nolines", "borderless")
                   for cls in (["standard"]
                               + settings.table_style
                               + node["classes"])
                   if cls in ("standard", "booktabs", "borderless", "nolines")]
        self.borders = borders[-1]
        self.colwidths_auto = (("colwidths-auto" in node["classes"]
                                or "colwidths-auto" in settings.table_style)
                               and "colwidths-given" not in node["classes"]
                               and "width" not in node)

    def get_latex_type(self) -> str:
        if self._latex_type == "longtable" and not self.caption:
            # do not advance the "table" counter (requires "ltcaption" package)
            return "longtable*"
        return self._latex_type

    def set(self, attr: str, value: Any) -> None:
        self._attrs[attr] = value

    def get(self, attr: str) -> Any:
        if attr in self._attrs:
            return self._attrs[attr]
        return None

    def get_vertical_bar(self) -> str:
        if self.borders == "standard":
            return "|"
        return ""

    def get_opening(self, width: str = r"\linewidth") -> str:
        opening = []
        nr_of_cols = len(self._col_specs)
        align_map = {"left": "[l]",
                     "center": "[c]",
                     "right": "[r]",
                     None: ""}
        align = align_map.get(self.get("align"))
        latex_type = self.get_latex_type()
        if align and not latex_type.startswith("longtable"):
            opening.append(r"\noindent\makebox[\linewidth]%s{%%" % align)
            align = ""
        if not self.colwidths_auto:
            if self.borders == "standard" and not self.legacy_column_widths:
                opening.append(r"\setlength{\DUtablewidth}"
                               r"{\dimexpr%s-%i\arrayrulewidth\relax}%%"
                               % (width, nr_of_cols+1))
            else:
                opening.append(r"\setlength{\DUtablewidth}{%s}%%" % width)
        opening.append(r"\begin{%s}%s" % (latex_type, align))
        return "\n".join(opening)

    def get_closing(self) -> str:
        closing = []
        if self.borders == "booktabs":
            closing.append(r"\bottomrule")
        closing.append(r"\end{%s}" % self.get_latex_type())
        if self.get("align") and not self.get_latex_type().startswith("longtable"):
            closing.append("}")
        return "\n".join(closing)

    def visit_colspec(self, node: nodes.colspec) -> None:
        self._col_specs.append(node)
        # "stubs" list is an attribute of the tgroup element:
        self.stubs.append(node.attributes.get("stub"))

    def get_colspecs(self, node: nodes.Element) -> str:
        """Return column specification for longtable.
        """
        bar = self.get_vertical_bar()
        self._rowspan = [0] * len(self._col_specs)
        if self.colwidths_auto:
            self._colwidths = []
            latex_colspecs = ["l"] * len(self._col_specs)
        elif self.legacy_column_widths:
            latex_colspecs = self._legacy_colspecs()
        else:
            latex_colspecs = self._new_colspecs(node)
        return bar + bar.join(latex_colspecs) + bar

    def _legacy_colspecs(self) -> list[str]:
        # use old algorithm for backwards compatibility
        width = 80  # assumed standard line length
        factor = 0.93  # do not make it full linewidth
        # first see if we get too wide.
        total_width = sum(node.propwidth()+1 for node in self._col_specs)
        if total_width > width:
            factor *= width / total_width
        self._colwidths = [(factor * (node.propwidth()+1)/width) + 0.005
                           for node in self._col_specs]
        return ["p{%.3f\\DUtablewidth}" % colwidth for colwidth in self._colwidths]

    def _new_colspecs(self, node: nodes.Element) -> list[str]:
        # No of characters corresponding to table width = 100%
        #   Characters/line with LaTeX article, A4, Times, default margins
        #   depends on character:  M: 40, A: 50, x: 70, i: 120.
        norm_length = 40
        # Allowance to prevent unpadded columns like
        #   === ==
        #   ABC DE
        #   === ==
        # getting too narrow:
        if "colwidths-given" not in node.parent.parent["classes"]:
            allowance = 1
        else:
            allowance = 0  # "widths" option specified, use exact ratio
        self._colwidths = [(colspec.propwidth()+allowance)/norm_length
                           for colspec in self._col_specs]
        total_width = sum(self._colwidths)
        # Limit to 100%, force 100% if table width is specified:
        if total_width > 1 or "width" in node.parent.parent.attributes:
            self._colwidths = [colwidth/total_width for colwidth in self._colwidths]
        return ["p{\\DUcolumnwidth{%.3f}}" % colwidth for colwidth in self._colwidths]

    def get_column_width(self) -> str:
        """Return columnwidth for current cell (not multicell)."""
        try:
            if self.legacy_column_widths:
                return "%.2f\\DUtablewidth" % self._colwidths[self._cell_in_row]
            return "\\DUcolumnwidth{%.2f}" % self._colwidths[self._cell_in_row]
        except IndexError:
            return "*"

    def get_multicolumn_width(self, start: int, len_: int) -> str:
        """Return sum of columnwidths for multicell."""
        try:
            multicol_width = sum(self._colwidths[start + co] for co in range(len_))
            if self.legacy_column_widths:
                return "p{%.2f\\DUtablewidth}" % multicol_width
            return "p{\\DUcolumnwidth{%.3f}}" % multicol_width
        except IndexError:
            return "l"

    def need_recurse(self) -> bool | int:
        if self._latex_type == "longtable":
            return 1 == self._translator.thead_depth()
        return 0

    def visit_thead(self) -> list[str]:
        self._in_thead += 1
        if self.borders == "standard":
            return ["\\hline\n"]
        elif self.borders == "booktabs":
            return ["\\toprule\n"]
        return []

    def depart_thead(self) -> list[str]:
        a = []
        if self.borders == "booktabs":
            a.append("\\midrule\n")
        if self._latex_type == "longtable":
            if 1 == self._translator.thead_depth():
                a.append("\\endfirsthead\n")
            else:
                a += self._longtable_continuation()
            # for longtable one could add firsthead, foot and lastfoot
        self._in_thead -= 1
        return a

    def _longtable_continuation(self) -> list[str]:
        n_c = len(self._col_specs)
        a = ["\\endhead\n"]
        # footer on all but last page (if it fits):
        t_width = sum(node.propwidth()+2 for node in self._col_specs)
        if t_width > 30 or (t_width > 12 and not self.colwidths_auto):
            a.append(r"\multicolumn{%d}{%s}"
                     % (n_c, self.get_multicolumn_width(0, n_c))
                     + r"{\raggedleft\ldots continued on next page}\\"
                     + "\n")
        a.append("\\endfoot\n\\endlastfoot\n")
        return a

    def visit_row(self) -> None:
        self._cell_in_row = 0

    def depart_row(self) -> list[str]:
        res = [" \\\\\n"]
        self._cell_in_row = None  # remove cell counter
        for i in range(len(self._rowspan)):
            if self._rowspan[i] > 0:
                self._rowspan[i] -= 1

        if self.borders == "standard":
            rowspans = [i+1 for i in range(len(self._rowspan))
                        if self._rowspan[i] <= 0]
            if len(rowspans) == len(self._rowspan):
                res.append("\\hline\n")
            else:
                # TODO merge clines
                res.append("".join("\\cline{%d-%d}\n" % (c_start, c_start)
                                   for c_start in rowspans))
        return res

    def set_rowspan(self, cell: int, value: int) -> None:
        try:
            self._rowspan[cell] = value
        except IndexError:
            pass

    def get_rowspan(self, cell: int) -> int:
        try:
            return self._rowspan[cell]
        except IndexError:
            return 0

    def get_entry_number(self) -> int:
        return self._cell_in_row

    def visit_entry(self) -> None:
        self._cell_in_row += 1

    def is_stub_column(self) -> Any:
        if len(self.stubs) >= self._cell_in_row:
            return self.stubs[self._cell_in_row]
        return False
