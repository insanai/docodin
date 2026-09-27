"""Auxiliary transforms mainly to be used by Writer components."""

from __future__ import annotations

from docutils import languages, nodes
from docutils.transforms import Transform

__docformat__ = "reStructuredText"


class Admonitions(Transform):
    """Transform specific admonitions into generic ones with a title."""

    default_priority = 920

    def apply(self) -> None:
        language = languages.get_language(self.document.settings.language_code,
                                          self.document.reporter)
        for node in self.document.findall(nodes.Admonition):
            node_name = node.__class__.__name__
            node["classes"].append(node_name)
            if not isinstance(node, nodes.admonition):
                admonition = nodes.admonition(node.rawsource, *node.children, **node.attributes)
                admonition.insert(0, nodes.title("", language.labels[node_name]))
                node.replace_self(admonition)
