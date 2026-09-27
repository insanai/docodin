"""Docutils parsers drop-in implementation for docodin."""

from __future__ import annotations

from typing import Any


class Parser:
    """Base docutils parser interface."""

    settings_spec: tuple[Any, ...] = ()
    supported: tuple[str, ...] = ("restructuredtext", "rst")

    def __init__(self) -> None:
        self.inputstring: Any = None
        self.document: Any = None

    def setup_parse(self, inputstring: Any, document: Any) -> None:
        self.inputstring = inputstring
        self.document = document

    def finish_parse(self) -> None:
        pass

    def parse(self, inputstring: Any, document: Any) -> None:
        raise NotImplementedError


def get_parser_class(parser_name: str) -> type[Parser]:
    if parser_name.lower() in ("restructuredtext", "rst", "docodin"):
        from docodin.shim.parsers.rst import Parser as RSTParser

        return RSTParser
    raise ImportError(f"No parser available for {parser_name!r}")
