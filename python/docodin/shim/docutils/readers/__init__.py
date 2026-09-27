"""Docutils Reader modules."""

from __future__ import annotations

import importlib
import warnings
from typing import Any

from docutils import Component, parsers, utils
from docutils.transforms import universal

__docformat__ = "reStructuredText"


class Reader(Component):
    """Abstract base class for docutils Readers: read input and parse it."""

    component_type = "reader"
    config_section = "readers"

    def get_transforms(self) -> list[type]:
        return [*super().get_transforms(), universal.Decorations, universal.ExposeInternals,
                universal.StripComments]

    def __init__(self, parser: Any = None, parser_name: str | None = None) -> None:
        self.parser = parser
        if isinstance(parser, str):
            self.set_parser(parser)
        if parser_name is not None:
            warnings.warn('Argument "parser_name" will be removed in Docutils 2.0.\n'
                          '  Specify parser name in the "parser" argument.',
                          PendingDeprecationWarning, stacklevel=2)
            if self.parser is None:
                self.set_parser(parser_name)
        self.source: Any = None
        self.input: Any = None

    def set_parser(self, parser_name: str) -> None:
        """Set `self.parser` by name."""
        self.parser = parsers.get_parser_class(parser_name)()

    def read(self, source: Any, parser: Any, settings: Any) -> Any:
        self.source = source
        if not self.parser:
            self.parser = parser
        self.settings = settings
        self.input = self.source.read()
        self.parse()
        return self.document

    def parse(self) -> None:
        """Parse `self.input` into a document tree."""
        document = self.new_document()
        self.parser.parse(self.input, document)
        document.current_source = document.current_line = None
        self.document = document

    def new_document(self) -> Any:
        """Create and return a new empty document tree (root node)."""
        return utils.new_document(self.source.source_path, self.settings)


class ReReader(Reader):
    """A reader which rereads an existing document tree (no standard transforms)."""

    def get_transforms(self) -> list[type]:
        return Component.get_transforms(self)


def get_reader_class(reader_name: str) -> type[Reader]:
    """Return the Reader class from the `reader_name` module."""
    name = reader_name.lower()
    try:
        module = importlib.import_module("docutils.readers." + name)
    except ImportError:
        try:
            module = importlib.import_module(name)
        except ImportError as err:
            raise ImportError(f'Reader "{reader_name}" not found.') from err
    return module.Reader
