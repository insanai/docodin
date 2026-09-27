"""Docutils writers drop-in implementation for docodin."""

from __future__ import annotations

import importlib
from typing import Any


class Writer:
    """Base docutils writer class."""

    supported: tuple[str, ...] = ()
    settings_spec: tuple[Any, ...] = ()
    settings_defaults: dict[str, Any] | None = None

    def __init__(self) -> None:
        self.document: Any = None
        self.output: Any = None
        self.destination: Any = None
        self.parts: dict[str, Any] = {}

    def write(self, document: Any, destination: Any = None) -> Any:
        self.document = document
        self.destination = destination
        self.translate()
        if destination is not None and hasattr(destination, "write"):
            output = self.output
            if isinstance(output, str) and hasattr(destination, "mode") and "b" in destination.mode:
                output = output.encode("utf-8")
            destination.write(output)
        return self.output

    def translate(self) -> None:
        pass

    def assemble_parts(self) -> None:
        self.parts["whole"] = self.output


_WRITER_ALIASES = {
    "html": "html5_polyglot",
    "html5": "html5_polyglot",
    "html5_polyglot": "html5_polyglot",
    "latex": "latex2e",
    "latex2e": "latex2e",
    "pseudoxml": "pseudoxml",
}


def get_writer_class(writer_name: str) -> type[Writer]:
    canonical = _WRITER_ALIASES.get(writer_name.lower(), writer_name.lower())
    try:
        mod = importlib.import_module(f"docutils.writers.{canonical}")
        return getattr(mod, "Writer")
    except (ImportError, AttributeError):
        pass
    try:
        mod = importlib.import_module(f"docodin.shim.writers.{canonical}")
        return getattr(mod, "Writer")
    except (ImportError, AttributeError) as err:
        raise ImportError(f"Cannot find writer {writer_name!r}: {err}") from err
