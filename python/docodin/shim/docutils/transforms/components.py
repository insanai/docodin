"""Docutils component-related transforms."""

from __future__ import annotations

from docutils.transforms import Transform

__docformat__ = "reStructuredText"


class Filter(Transform):
    """Keep the pending element's nodes only if a component supports the format."""

    default_priority = 780

    def apply(self) -> None:
        pending = self.startnode
        component = self.document.transformer.components[pending.details["component"]]
        for format in pending.details["format"].split(","):
            if component.supports(format):
                pending.replace_self(pending.details["nodes"])
                return
        pending.parent.remove(pending)
