"""A do-nothing parser."""

from __future__ import annotations

from typing import Any

from docutils import parsers

__docformat__ = "reStructuredText"


class Parser(parsers.Parser):
    """A do-nothing parser."""

    supported = ("null",)
    config_section = "null parser"
    config_section_dependencies = ("parsers",)

    def parse(self, inputstring: str, document: Any) -> None:
        pass
