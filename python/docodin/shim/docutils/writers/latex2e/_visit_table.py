"""Visitor methods of the `LaTeXTranslator` for tables."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from docutils import nodes
from docutils.writers.latex2e._preamble import PreambleCmds
from docutils.writers.latex2e._tables import Table

if TYPE_CHECKING:
    from docutils.writers.latex2e._tables import DocumentClass

__docformat__ = "reStructuredText"


class _TableVisitors:
    """Visitor methods for table elements (mixin for `LaTeXTranslator`)."""

    # attributes provided by `LaTeXTranslator`:
    out: list
    context: list
    requirements: dict
    settings: Any
    d_class: DocumentClass
    active_table: Table
    table_stack: list[Table]

    def visit_colspec(self, node: nodes.Element) -> None:
        self.active_table.visit_colspec(node)

    def depart_colspec(self, node: nodes.Element) -> None:
        pass

    # Append column delimiters and advance column counter,
    # if the current cell is a multi-row continuation."""
    def insert_additional_table_colum_delimiters(self) -> None:
        while self.active_table.get_rowspan(self.active_table.get_entry_number()):
            self.out.append(" & ")
            self.active_table.visit_entry()  # increment cell count

    def visit_entry(self, node: nodes.Element):
        # cell separation
        if self.active_table.get_entry_number() == 0:
            self.insert_additional_table_colum_delimiters()
        else:
            self.out.append(" & ")

        # multirow, multicolumn
        if "morerows" in node and "morecols" in node:
            raise NotImplementedError("Cells that span multiple rows *and* "
                                      "columns currently not supported "
                                      "by the LaTeX writer")
            # TODO: should be possible with LaTeX, see e.g.
            # http://texblog.org/2012/12/21/multi-column-and-multi-row-cells-in-latex-tables/
        self._open_spanning_cell(node)

        # bold header/stub-column
        if len(node) and (isinstance(node.parent.parent, nodes.thead)
                          or self.active_table.is_stub_column()):
            self.out.append("\\textbf{")
            self.context.append("}")
        else:
            self.context.append("")

        # if line ends with '{', mask line break
        if (not self.active_table.colwidths_auto
            and self.out[-1].endswith("{")
            and node.astext()):
            self.out.append("%")

        self.active_table.visit_entry()  # increment cell count

    def _open_spanning_cell(self, node: nodes.Element) -> None:
        # multirow in LaTeX simply will enlarge the cell over several rows
        # (the following n if n is positive, the former if negative).
        table = self.active_table
        if "morerows" in node:
            self.requirements["multirow"] = r"\usepackage{multirow}"
            mrows = node["morerows"] + 1
            table.set_rowspan(table.get_entry_number(), mrows)
            self.out.append("\\multirow{%d}{%s}{" % (mrows, table.get_column_width()))
            self.context.append("}")
        elif "morecols" in node:
            # the vertical bar before column is missing if it is the first
            # column. the one after always.
            if table.get_entry_number() == 0:
                bar1 = table.get_vertical_bar()
            else:
                bar1 = ""
            mcols = node["morecols"] + 1
            self.out.append("\\multicolumn{%d}{%s%s%s}{" % (
                mcols,
                bar1,
                table.get_multicolumn_width(table.get_entry_number(), mcols),
                table.get_vertical_bar()))
            self.context.append("}")
        else:
            self.context.append("")

    def depart_entry(self, node: nodes.Element) -> None:
        self.out.append(self.context.pop())  # header / not header
        self.out.append(self.context.pop())  # multirow/column
        # insert extra "&"s, if following rows are spanned from above:
        self.insert_additional_table_colum_delimiters()

    def visit_row(self, node: nodes.Element) -> None:
        self.active_table.visit_row()

    def depart_row(self, node: nodes.Element) -> None:
        self.out.extend(self.active_table.depart_row())

    def visit_table(self, node: nodes.Element) -> None:
        self.requirements["table"] = PreambleCmds.table
        if not self.settings.legacy_column_widths:
            self.requirements["table1"] = PreambleCmds.table_columnwidth
        if self.active_table.is_open():
            self.table_stack.append(self.active_table)
            # nesting longtable does not work (e.g. 2007-04-18)
            self.active_table = Table(self, "tabular")
        # A longtable moves before \paragraph and \subparagraph
        # section titles if it immediately follows them:
        if (self.active_table._latex_type == "longtable"
            and isinstance(node.parent, nodes.section)
            and node.parent.index(node) == 1
            and "paragraph" in self.d_class.section(self.section_level)):
            self.out.append("\\leavevmode")
        self.active_table.open()
        self.active_table.set_table_style(node, self.settings)
        if self.active_table.borders == "booktabs":
            self.requirements["booktabs"] = r"\usepackage{booktabs}"
        self.push_output_collector([])

    def depart_table(self, node: nodes.Element) -> None:
        # complete and write the table
        content = self.pop_output_collector()
        try:
            width = self.to_latex_length(node["width"], node)
        except KeyError:
            width = r"\linewidth"
        # Insert hyperlabel and anchor before the table
        # if it has no caption/title.
        # See visit_thead() for tables with caption.
        if not self.active_table.caption:
            set_anchor = (len(self.table_stack) != 1)
            self.out += self.ids_to_labels(node, set_anchor, pre_nl=True)
        self.duclass_open(node)
        # TODO: Don't use a longtable or add \noindent before
        #       the next paragraph, when in a "compound paragraph".
        #       Start a new line or a new paragraph?
        #       if (isinstance(node.parent, nodes.compound)
        #       and self._latex_type != 'longtable')?
        self.out.append(self.active_table.get_opening(width))
        self.out += content
        self.out.append(self.active_table.get_closing() + "\n")
        self.active_table.close()
        if len(self.table_stack) > 0:
            self.active_table = self.table_stack.pop()
        self.duclass_close(node)

    def visit_tbody(self, node: nodes.Element) -> None:
        # BUG write preamble if not yet done (colspecs not [])
        # for tables without heads.
        if not self.active_table.get("preamble written"):
            self.visit_thead(node)
            self.depart_thead(None)

    def depart_tbody(self, node: nodes.Element) -> None:
        pass

    def visit_tgroup(self, node: nodes.Element) -> None:
        pass

    def depart_tgroup(self, node: nodes.Element) -> None:
        pass

    def visit_thead(self, node: nodes.Element) -> None:
        self._thead_depth += 1
        if 1 == self.thead_depth():
            self.out.append("{%s}\n" % self.active_table.get_colspecs(node))
            self.active_table.set("preamble written", 1)
        if self.active_table.caption:
            if self._thead_depth == 1:
                pre = [r"\caption{"]
                post = [*self.ids_to_labels(node.parent.parent, False), r"}\\"]
            else:
                pre = [r"\caption[]{"]
                post = [r" (... continued)}\\"]
            self.out.extend([*pre, *self.active_table.caption, *post, "\n"])
        self.out.extend(self.active_table.visit_thead())

    def depart_thead(self, node: nodes.Element | None) -> None:
        if node is not None:
            self.out.extend(self.active_table.depart_thead())
            if self.active_table.need_recurse():
                node.walkabout(self)
        self._thead_depth -= 1
