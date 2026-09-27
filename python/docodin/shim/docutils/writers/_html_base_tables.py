"""Tables for the Docutils HTML writers.

Private auxiliary module of `docutils.writers._html_base`: the mixin class
`TableTranslatorMixin` provides the `HTMLTranslator` methods for table nodes.
"""

from __future__ import annotations

from docutils import nodes

__docformat__ = "reStructuredText"


class TableTranslatorMixin:
    """`HTMLTranslator` methods for tables.

    Relies on the attributes and methods of `docutils.writers._html_base.HTMLTranslator`.
    """

    def visit_colspec(self, node: nodes.Element) -> None:
        self.colspecs.append(node)
        # "stubs" list is an attribute of the tgroup element:
        node.parent.stubs.append(node.attributes.get("stub"))

    def depart_colspec(self, node: nodes.Element) -> None:
        # write out <colgroup> when all colspecs are processed
        if isinstance(node.next_node(descend=False, siblings=True), nodes.colspec):
            return
        if "colwidths-auto" in node.parent.parent["classes"] or (
                "colwidths-grid" not in self.settings.table_style
                and "colwidths-given" not in node.parent.parent["classes"]):
            return
        self.body.append(self.starttag(node, "colgroup"))
        total_width = sum(colspec.propwidth() for colspec in self.colspecs)
        for colspec in self.colspecs:
            colwidth = colspec.propwidth() / total_width
            self.body.append(self.emptytag(colspec, "col", style=f"width: {colwidth:.1%}"))
        self.body.append("</colgroup>\n")

    def visit_entry(self, node: nodes.Element) -> None:
        atts = {"classes": []}
        if isinstance(node.parent.parent, nodes.thead):
            atts["classes"].append("head")
        if node.parent.parent.parent.stubs[node.parent.column]:
            # "stubs" list is an attribute of the tgroup element
            atts["classes"].append("stub")
        tagname = "th" if atts["classes"] else "td"
        node.parent.column += 1
        if "morerows" in node:
            atts["rowspan"] = node["morerows"] + 1
        if "morecols" in node:
            atts["colspan"] = node["morecols"] + 1
            node.parent.column += node["morecols"]
        self.body.append(self.starttag(node, tagname, "", **atts))
        self.context.append("</%s>\n" % tagname.lower())

    def depart_entry(self, node: nodes.Element) -> None:
        self.body.append(self.context.pop())

    def visit_row(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "tr", ""))
        node.column = 0

    def depart_row(self, node: nodes.Element) -> None:
        self.body.append("</tr>\n")

    def visit_table(self, node: nodes.Element) -> None:
        atts = {"classes": self.settings.table_style.replace(",", " ").split()}
        if "align" in node:
            atts["classes"].append("align-%s" % node["align"])
        if "width" in node:
            width = node["width"]
            if width[-1:] in "0123456789.":  # unitless value
                width += "px"  # add default length unit
            atts["style"] = f"width: {width};"
        self.body.append(self.starttag(node, "table", **atts))

    def depart_table(self, node: nodes.Element) -> None:
        self.body.append("</table>\n")
        self.report_messages(node)

    # no hard-coded vertical alignment in table body
    def visit_tbody(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "tbody"))

    def depart_tbody(self, node: nodes.Element) -> None:
        self.body.append("</tbody>\n")

    def visit_tgroup(self, node: nodes.Element) -> None:
        self.colspecs = []
        node.stubs = []

    def depart_tgroup(self, node: nodes.Element) -> None:
        pass

    def visit_thead(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "thead"))

    def depart_thead(self, node: nodes.Element) -> None:
        self.body.append("</thead>\n")
