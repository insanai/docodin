"""A do-nothing Writer.

`self.output` will change from ``None`` to the empty string in Docutils 0.22.
"""

from __future__ import annotations

from docutils import writers

__docformat__ = "reStructuredText"


class Writer(writers.UnfilteredWriter):
    supported = ("null",)
    """Formats this writer supports."""

    config_section = "null writer"
    config_section_dependencies = ("writers",)

    def translate(self) -> None:
        self.output = ""
