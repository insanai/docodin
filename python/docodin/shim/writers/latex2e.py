"""LaTeX 2e writer."""

from __future__ import annotations

from typing import Any

from docodin.shim import nodes
from docodin.shim.writers import Writer as BaseWriter


class LaTeXTranslator(nodes.NodeVisitor):
    def __init__(self, document: nodes.document) -> None:
        super().__init__(document)
        self.body: list[str] = []
        self.title: list[str] = []
        self.section_level = 0
        self.in_title = False

    def astext(self) -> str:
        return "".join(self.body)

    def visit_document(self, node: nodes.Node) -> None: pass
    def depart_document(self, node: nodes.Node) -> None: pass

    def visit_section(self, node: nodes.Node) -> None:
        self.section_level += 1

    def depart_section(self, node: nodes.Node) -> None:
        self.section_level = max(0, self.section_level - 1)

    def visit_title(self, node: nodes.Node) -> None:
        self.in_title = True
        sec_cmds = ["\\section{", "\\subsection{", "\\subsubsection{", "\\paragraph{"]
        cmd = sec_cmds[min(self.section_level - 1, len(sec_cmds) - 1)] if self.section_level > 0 else "\\title{"
        self.body.append(cmd)

    def depart_title(self, node: nodes.Node) -> None:
        self.body.append("}\n\n")
        self.in_title = False

    def visit_paragraph(self, node: nodes.Node) -> None:
        pass

    def depart_paragraph(self, node: nodes.Node) -> None:
        self.body.append("\n\n")

    def visit_emphasis(self, node: nodes.Node) -> None:
        self.body.append("\\emph{")

    def depart_emphasis(self, node: nodes.Node) -> None:
        self.body.append("}")

    def visit_strong(self, node: nodes.Node) -> None:
        self.body.append("\\textbf{")

    def depart_strong(self, node: nodes.Node) -> None:
        self.body.append("}")

    def visit_literal(self, node: nodes.Node) -> None:
        self.body.append("\\texttt{")

    def depart_literal(self, node: nodes.Node) -> None:
        self.body.append("}")

    def visit_literal_block(self, node: nodes.Node) -> None:
        self.body.append("\\begin{quote}\\ttfamily\n")

    def depart_literal_block(self, node: nodes.Node) -> None:
        self.body.append("\\end{quote}\n\n")

    def visit_bullet_list(self, node: nodes.Node) -> None:
        self.body.append("\\begin{itemize}\n")

    def depart_bullet_list(self, node: nodes.Node) -> None:
        self.body.append("\\end{itemize}\n\n")

    def visit_enumerated_list(self, node: nodes.Node) -> None:
        self.body.append("\\begin{enumerate}\n")

    def depart_enumerated_list(self, node: nodes.Node) -> None:
        self.body.append("\\end{enumerate}\n\n")

    def visit_list_item(self, node: nodes.Node) -> None:
        self.body.append("\\item ")

    def depart_list_item(self, node: nodes.Node) -> None:
        self.body.append("\n")

    def visit_Text(self, node: nodes.Node) -> None:
        text = str(node)
        repl = {
            "\\": "\\textbackslash{}",
            "&": "\\&",
            "%": "\\%",
            "$": "\\$",
            "#": "\\#",
            "_": "\\_",
            "{": "\\{",
            "}": "\\}",
            "~": "\\textasciitilde{}",
            "^": "\\textasciicircum{}",
        }
        for k, v in repl.items():
            text = text.replace(k, v)
        self.body.append(text)
        if self.in_title:
            self.title.append(text)

    def depart_Text(self, node: nodes.Node) -> None: pass
    def unknown_visit(self, node: nodes.Node) -> None: pass
    def unknown_departure(self, node: nodes.Node) -> None: pass


class Writer(BaseWriter):
    supported = ("latex", "latex2e")

    def translate(self) -> None:
        visitor = LaTeXTranslator(self.document)
        self.document.walkabout(visitor)
        body = "".join(visitor.body)
        title = "".join(visitor.title) or "DocOdin Document"
        whole = (
            "\\documentclass{article}\n"
            "\\usepackage[utf8]{inputenc}\n"
            "\\usepackage{hyperref}\n"
            f"\\title{{{title}}}\n"
            "\\begin{document}\n"
            f"{body}"
            "\\end{document}\n"
        )
        self.output = whole
        self.parts = {"whole": whole, "body": body, "title": title}
