"""Reader for existing document trees."""

from __future__ import annotations

from docutils import readers, transforms, utils

__docformat__ = "reStructuredText"


class Reader(readers.ReReader):
    """Adapt the Reader API for an existing document tree."""

    supported = ("doctree",)
    config_section = "doctree reader"
    config_section_dependencies = ("readers",)

    def parse(self) -> None:
        """No parsing: reset the transformer, settings and reporter of the tree."""
        self.document = self.input
        self.document.transformer = transforms.Transformer(self.document)
        self.document.settings = self.settings
        self.document.reporter = utils.new_reporter(self.document.get("source", ""),
                                                    self.document.settings)
