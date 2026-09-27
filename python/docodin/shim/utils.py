"""Docutils utils drop-in implementation for docodin."""

from __future__ import annotations

import os
import sys
from typing import Any, TextIO

from docodin.shim import nodes, smartquotes


class SystemMessage(Exception):
    """Exception raised by Reporter when halting or generating system messages."""

    def __init__(self, system_message: nodes.system_message, level: int = 4) -> None:
        super().__init__(system_message.astext())
        self.system_message = system_message
        self.level = level


class Reporter:
    """Error and message reporter for docutils documents."""

    levels = ["DEBUG", "INFO", "WARNING", "ERROR", "SEVERE"]
    DEBUG = 0
    INFO = 1
    WARNING = 2
    ERROR = 3
    SEVERE = 4

    def __init__(
        self,
        source: str | None = None,
        report_level: int = 2,
        halt_level: int = 4,
        stream: TextIO | None = None,
        debug: bool = False,
        encoding: str = "utf-8",
        error_handler: str = "replace",
    ) -> None:
        self.source = source
        self.report_level = report_level
        self.halt_level = halt_level
        self.stream = stream or sys.stderr
        self.debug_flag = debug
        self.encoding = encoding
        self.error_handler = error_handler
        self.messages: list[nodes.system_message] = []
        self.max_level = -1

    def get_source_and_line(self, lineno: int | None = None) -> tuple[str | None, int | None]:
        return (self.source, lineno)

    def system_message(self, level: int, message: str, *children: nodes.Node, **kwargs: Any) -> nodes.system_message:
        if level > self.max_level:
            self.max_level = level
        msg_node = nodes.system_message(message, *children, level=level, type=self.levels[min(max(level, 0), 4)], **kwargs)
        if "line" not in msg_node and "line" in kwargs:
            msg_node.line = kwargs["line"]
        if "source" not in msg_node and self.source:
            msg_node.source = self.source
        self.messages.append(msg_node)
        if level >= self.report_level and self.stream:
            try:
                src = f"{self.source}:{kwargs.get('line', '')}: " if self.source else ""
                self.stream.write(f"{src}({self.levels[level]}) {message}\n")
                self.stream.flush()
            except Exception:
                pass
        if level >= self.halt_level:
            raise SystemMessage(msg_node, level)
        return msg_node

    def debug(self, *args: Any, **kwargs: Any) -> nodes.system_message:
        return self.system_message(self.DEBUG, *args, **kwargs)

    def info(self, *args: Any, **kwargs: Any) -> nodes.system_message:
        return self.system_message(self.INFO, *args, **kwargs)

    def warning(self, *args: Any, **kwargs: Any) -> nodes.system_message:
        return self.system_message(self.WARNING, *args, **kwargs)

    def error(self, *args: Any, **kwargs: Any) -> nodes.system_message:
        return self.system_message(self.ERROR, *args, **kwargs)

    def severe(self, *args: Any, **kwargs: Any) -> nodes.system_message:
        return self.system_message(self.SEVERE, *args, **kwargs)


def new_reporter(source_path: str, settings: Any) -> Reporter:
    """Create a new Reporter instance configured with runtime settings.

    Args:
        source_path: Source text path or identifier.
        settings: Runtime configuration settings object.

    Returns:
        Configured Reporter instance.
    """
    return Reporter(
        source=source_path,
        report_level=getattr(settings, "report_level", 2),
        halt_level=getattr(settings, "halt_level", 4),
        stream=getattr(settings, "warning_stream", None),
        debug=getattr(settings, "debug", False),
        encoding=getattr(settings, "error_encoding", "utf-8"),
        error_handler=getattr(settings, "error_encoding_error_handler", "replace"),
    )


def new_document(source_path: str = "<string>", settings: Any = None) -> nodes.document:
    """Return a new empty docutils document object.

    Args:
        source_path: Source file or stream identifier. Defaults to "<string>".
        settings: Optional runtime settings object. Defaults to None.

    Returns:
        Newly created document object with initialized reporter.
    """
    from docodin.shim import frontend

    if settings is None:
        settings = frontend.get_default_settings()
    reporter = new_reporter(source_path, settings)
    doc = nodes.document(settings, reporter)
    doc.note_source(source_path, -1)
    return doc


def unescape(text: str, restore_backslashes: bool = False) -> str:
    return text


def find_file_in_dirs(path: str, dirs: list[str]) -> str | None:
    for d in dirs:
        cand = os.path.join(d, path)
        if os.path.exists(cand):
            return cand
    return None


def relative_path(source: str | None, target: str) -> str:
    if not source:
        return target
    try:
        return os.path.relpath(target, os.path.dirname(source))
    except (ValueError, TypeError):
        return target


def clean_ident(id_str: str) -> str:
    return nodes.make_id(id_str)


def get_source_line(node: nodes.Node) -> tuple[str | None, int | None]:
    curr: nodes.Node | None = node
    while curr is not None:
        if curr.source is not None or curr.line is not None:
            return (curr.source, curr.line)
        curr = curr.parent
    return (None, None)


class ExtensionOptionError(Exception): pass
class BadOptionError(ExtensionOptionError): pass
class BadOptionDataError(ExtensionOptionError): pass
class DuplicateOptionError(ExtensionOptionError): pass


def extract_options(field_list: nodes.field_list) -> list[tuple[str, str | None]]:
    option_list: list[tuple[str, str | None]] = []
    for field in field_list:
        if len(field[0].astext().split()) != 1:
            raise BadOptionError("extension option field name may not contain multiple words")
        name = str(field[0].astext().lower())
        body = field[1]
        if len(body) == 0:
            data = None
        elif len(body) > 1 or not isinstance(body[0], nodes.paragraph) or len(body[0]) != 1 or not isinstance(body[0][0], nodes.Text):
            raise BadOptionDataError(f"extension option field body may contain a single paragraph only (option {name!r})")
        else:
            data = body[0][0].astext()
        option_list.append((name, data))
    return option_list


def assemble_option_dict(option_list: list[tuple[str, str | None]], options_spec: dict[str, Any]) -> dict[str, Any]:
    options: dict[str, Any] = {}
    for name, value in option_list:
        convertor = options_spec.get(name)
        if convertor is None:
            raise KeyError(name)
        if name in options:
            raise DuplicateOptionError(f'duplicate option "{name}"')
        try:
            options[name] = convertor(value)
        except (ValueError, TypeError) as detail:
            raise detail.__class__(f'(option: "{name}"; value: {value!r})\n{" ".join(detail.args)}')
    return options


def extract_extension_options(field_list: nodes.field_list, options_spec: dict[str, Any]) -> dict[str, Any]:
    option_list = extract_options(field_list)
    return assemble_option_dict(option_list, options_spec)


def extract_name(node: nodes.Element) -> str:
    return node.astext().strip().lower()


class DependencyList:
    def __init__(self, output_file: str | None = None, dependencies: list[str] | None = None) -> None:
        self.output_file = output_file
        self.list = dependencies or []

    def add(self, *filenames: str) -> None:
        for f in filenames:
            if f not in self.list:
                self.list.append(f)
