"""Bibliographic fields (docinfo) for the Docutils HTML writers.

Private auxiliary module of `docutils.writers._html_base`: the mixin class
`DocinfoTranslatorMixin` provides the `HTMLTranslator` methods for the docinfo element and
bibliographic field nodes.
"""

from __future__ import annotations

from docutils import nodes

__docformat__ = "reStructuredText"


class DocinfoTranslatorMixin:
    """`HTMLTranslator` methods for the docinfo element and bibliographic fields.

    Relies on the attributes and methods of `docutils.writers._html_base.HTMLTranslator`.
    """

    def visit_address(self, node: nodes.Element) -> None:
        self.visit_docinfo_item(node, "address", meta=False)
        self.body.append(self.starttag(node, "pre", suffix="", CLASS="address"))

    def depart_address(self, node: nodes.Element) -> None:
        self.body.append("\n</pre>\n")
        self.depart_docinfo_item()

    def visit_author(self, node: nodes.Element) -> None:
        if not isinstance(node.parent, nodes.authors):
            self.visit_docinfo_item(node, "author")
        self.body.append("<p>")

    def depart_author(self, node: nodes.Element) -> None:
        self.body.append("</p>")
        if isinstance(node.parent, nodes.authors):
            self.body.append("\n")
        else:
            self.depart_docinfo_item()

    def visit_authors(self, node: nodes.Element) -> None:
        self.visit_docinfo_item(node, "authors")

    def depart_authors(self, node: nodes.Element) -> None:
        self.depart_docinfo_item()

    def visit_contact(self, node: nodes.Element) -> None:
        self.visit_docinfo_item(node, "contact", meta=False)

    def depart_contact(self, node: nodes.Element) -> None:
        self.depart_docinfo_item()

    def visit_copyright(self, node: nodes.Element) -> None:
        self.visit_docinfo_item(node, "copyright")

    def depart_copyright(self, node: nodes.Element) -> None:
        self.depart_docinfo_item()

    def visit_date(self, node: nodes.Element) -> None:
        self.visit_docinfo_item(node, "date")

    def depart_date(self, node: nodes.Element) -> None:
        self.depart_docinfo_item()

    def visit_docinfo(self, node: nodes.Element) -> None:
        self.context.append(len(self.body))
        classes = ["docinfo"]
        if self.is_compactable(node):
            classes.append("simple")
        self.body.append(self.starttag(node, "dl", classes=classes))

    def depart_docinfo(self, node: nodes.Element) -> None:
        self.body.append("</dl>\n")
        start = self.context.pop()
        self.docinfo = self.body[start:]
        self.body = []

    def visit_docinfo_item(self, node: nodes.Element, name: str, meta: bool = True) -> None:
        if meta:
            self.meta.append(f'<meta name="{name}" '
                             f'content="{self.attval(node.astext())}" />\n')
        self.body.append(f'<dt class="{name}">{self.language.labels[name]}'
                         '<span class="colon">:</span></dt>\n')
        self.body.append(self.starttag(node, "dd", "", CLASS=name))

    def depart_docinfo_item(self) -> None:
        self.body.append("</dd>\n")

    def visit_organization(self, node: nodes.Element) -> None:
        self.visit_docinfo_item(node, "organization")

    def depart_organization(self, node: nodes.Element) -> None:
        self.depart_docinfo_item()

    def visit_revision(self, node: nodes.Element) -> None:
        self.visit_docinfo_item(node, "revision", meta=False)

    def depart_revision(self, node: nodes.Element) -> None:
        self.depart_docinfo_item()

    def visit_status(self, node: nodes.Element) -> None:
        self.visit_docinfo_item(node, "status", meta=False)

    def depart_status(self, node: nodes.Element) -> None:
        self.depart_docinfo_item()

    def visit_version(self, node: nodes.Element) -> None:
        self.visit_docinfo_item(node, "version", meta=False)

    def depart_version(self, node: nodes.Element) -> None:
        self.depart_docinfo_item()
