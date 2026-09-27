"""HTML5 polyglot writer."""

from __future__ import annotations

import html
from typing import Any

from docodin.shim import nodes
from docodin.shim.writers import Writer as BaseWriter


class HTMLTranslator(nodes.NodeVisitor):
    """Translates docutils document tree into semantic HTML5."""

    def __init__(self, document: nodes.document) -> None:
        super().__init__(document)
        self.body: list[str] = []
        self.head: list[str] = []
        self.title: list[str] = []
        self.section_level = 0
        self.in_title = False

    def astext(self) -> str:
        return "".join(self.body)

    def visit_document(self, node: nodes.Node) -> None:
        pass

    def depart_document(self, node: nodes.Node) -> None:
        pass

    def visit_section(self, node: nodes.Node) -> None:
        self.section_level += 1
        ids = " ".join(node.get("ids", []))
        id_attr = f' id="{ids}"' if ids else ""
        self.body.append(f"<section{id_attr}>\n")

    def depart_section(self, node: nodes.Node) -> None:
        self.section_level = max(0, self.section_level - 1)
        self.body.append("</section>\n")

    def visit_title(self, node: nodes.Node) -> None:
        self.in_title = True
        lvl = min(max(self.section_level, 1), 6)
        ids = " ".join(node.parent.get("ids", []) if node.parent else [])
        id_attr = f' id="{ids}"' if ids else ""
        self.body.append(f"<h{lvl}{id_attr}>")

    def depart_title(self, node: nodes.Node) -> None:
        lvl = min(max(self.section_level, 1), 6)
        self.body.append(f"</h{lvl}>\n")
        self.in_title = False

    def visit_paragraph(self, node: nodes.Node) -> None:
        self.body.append("<p>")

    def depart_paragraph(self, node: nodes.Node) -> None:
        self.body.append("</p>\n")

    def visit_bullet_list(self, node: nodes.Node) -> None:
        self.body.append("<ul>\n")

    def depart_bullet_list(self, node: nodes.Node) -> None:
        self.body.append("</ul>\n")

    def visit_enumerated_list(self, node: nodes.Node) -> None:
        self.body.append("<ol>\n")

    def depart_enumerated_list(self, node: nodes.Node) -> None:
        self.body.append("</ol>\n")

    def visit_list_item(self, node: nodes.Node) -> None:
        self.body.append("<li>")

    def depart_list_item(self, node: nodes.Node) -> None:
        self.body.append("</li>\n")

    def visit_literal_block(self, node: nodes.Node) -> None:
        classes = " ".join(node.get("classes", []))
        cls_attr = f' class="{classes}"' if classes else ""
        self.body.append(f"<pre{cls_attr}><code>")

    def depart_literal_block(self, node: nodes.Node) -> None:
        self.body.append("</code></pre>\n")

    def visit_block_quote(self, node: nodes.Node) -> None:
        self.body.append("<blockquote>\n")

    def depart_block_quote(self, node: nodes.Node) -> None:
        self.body.append("</blockquote>\n")

    def visit_emphasis(self, node: nodes.Node) -> None:
        self.body.append("<em>")

    def depart_emphasis(self, node: nodes.Node) -> None:
        self.body.append("</em>")

    def visit_strong(self, node: nodes.Node) -> None:
        self.body.append("<strong>")

    def depart_strong(self, node: nodes.Node) -> None:
        self.body.append("</strong>")

    def visit_literal(self, node: nodes.Node) -> None:
        self.body.append("<code>")

    def depart_literal(self, node: nodes.Node) -> None:
        self.body.append("</code>")

    def visit_reference(self, node: nodes.Node) -> None:
        refuri = node.get("refuri")
        refid = node.get("refid")
        if refuri:
            self.body.append(f'<a href="{html.escape(refuri)}">')
        elif refid:
            self.body.append(f'<a href="#{html.escape(refid)}">')
        else:
            self.body.append("<a>")

    def depart_reference(self, node: nodes.Node) -> None:
        self.body.append("</a>")

    def visit_table(self, node: nodes.Node) -> None:
        self.body.append("<table>\n")

    def depart_table(self, node: nodes.Node) -> None:
        self.body.append("</table>\n")

    def visit_tgroup(self, node: nodes.Node) -> None:
        pass

    def depart_tgroup(self, node: nodes.Node) -> None:
        pass

    def visit_colspec(self, node: nodes.Node) -> None:
        pass

    def depart_colspec(self, node: nodes.Node) -> None:
        pass

    def visit_thead(self, node: nodes.Node) -> None:
        self.body.append("<thead>\n")

    def depart_thead(self, node: nodes.Node) -> None:
        self.body.append("</thead>\n")

    def visit_tbody(self, node: nodes.Node) -> None:
        self.body.append("<tbody>\n")

    def depart_tbody(self, node: nodes.Node) -> None:
        self.body.append("</tbody>\n")

    def visit_row(self, node: nodes.Node) -> None:
        self.body.append("<tr>\n")

    def depart_row(self, node: nodes.Node) -> None:
        self.body.append("</tr>\n")

    def visit_entry(self, node: nodes.Node) -> None:
        tag = "th" if isinstance(node.parent, nodes.thead) or (node.parent and isinstance(node.parent.parent, nodes.thead)) else "td"
        self.body.append(f"<{tag}>")

    def depart_entry(self, node: nodes.Node) -> None:
        tag = "th" if isinstance(node.parent, nodes.thead) or (node.parent and isinstance(node.parent.parent, nodes.thead)) else "td"
        self.body.append(f"</{tag}>\n")

    def visit_Text(self, node: nodes.Node) -> None:
        t = html.escape(str(node))
        self.body.append(t)
        if self.in_title:
            self.title.append(t)

    def depart_Text(self, node: nodes.Node) -> None:
        pass

    def visit_admonition(self, node: nodes.Node) -> None:
        tag = node.__class__.__name__
        self.body.append(f'<div class="admonition {tag}">\n<p class="admonition-title">{tag.title()}</p>\n')

    def depart_admonition(self, node: nodes.Node) -> None:
        self.body.append("</div>\n")

    # Delegate specific admonitions
    visit_attention = visit_admonition
    depart_attention = depart_admonition
    visit_caution = visit_admonition
    depart_caution = depart_admonition
    visit_danger = visit_admonition
    depart_danger = depart_admonition
    visit_error = visit_admonition
    depart_error = depart_admonition
    visit_hint = visit_admonition
    depart_hint = depart_admonition
    visit_important = visit_admonition
    depart_important = depart_admonition
    visit_note = visit_admonition
    depart_note = depart_admonition
    visit_tip = visit_admonition
    depart_tip = depart_admonition
    visit_warning = visit_admonition
    depart_warning = depart_admonition

    def unknown_visit(self, node: nodes.Node) -> None:
        pass

    def unknown_departure(self, node: nodes.Node) -> None:
        pass


class Writer(BaseWriter):
    supported = ("html", "html5", "html5_polyglot")

    def translate(self) -> None:
        visitor = HTMLTranslator(self.document)
        self.document.walkabout(visitor)
        body = "".join(visitor.body)
        title = "".join(visitor.title) or "DocOdin Document"
        head = "".join(visitor.head)
        whole = (
            f"<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\" />\n"
            f"<title>{title}</title>\n{head}</head>\n<body>\n{body}</body>\n</html>\n"
        )
        self.output = whole
        self.parts = {
            "whole": whole,
            "body": body,
            "title": title,
            "html_title": f"<title>{title}</title>",
            "head": head,
        }
