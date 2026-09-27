"""Docutils rst parser drop-in implementation for docodin."""

from __future__ import annotations

from typing import Any, Callable

from docodin.shim.parsers import Parser as BaseParser


class DirectiveError(Exception):
    """Exception for directive errors."""

    def __init__(self, level: int = 3, message: str = "") -> None:
        super().__init__(message)
        self.level = level
        self.msg = message


class Directive:
    """Base class for reStructuredText directives."""

    required_arguments = 0
    optional_arguments = 0
    final_argument_whitespace = False
    option_spec: dict[str, Callable[[str], Any]] | None = None
    has_content = False

    def __init__(
        self,
        name: str,
        arguments: list[str],
        options: dict[str, Any],
        content: Any,
        lineno: int,
        content_offset: int,
        block_text: str,
        state: Any,
        state_machine: Any,
    ) -> None:
        self.name = name
        self.arguments = arguments
        self.options = options
        self.content = content
        self.lineno = lineno
        self.content_offset = content_offset
        self.block_text = block_text
        self.state = state
        self.state_machine = state_machine

    def run(self) -> list[Any]:
        raise NotImplementedError

    def assert_has_content(self) -> None:
        if not self.content:
            raise self.error(f'Content block expected for the "{self.name}" directive; none found.')

    def error(self, message: str) -> DirectiveError:
        return DirectiveError(3, message)

    def warning(self, message: str) -> DirectiveError:
        return DirectiveError(2, message)

    def info(self, message: str) -> DirectiveError:
        return DirectiveError(1, message)

    def debug(self, message: str) -> DirectiveError:
        return DirectiveError(0, message)


def convert_directive_function(fn: Any) -> type[Directive]:
    """Convert an old-style directive function into a Directive class."""
    class CustomDirective(Directive):
        required_arguments = getattr(fn, "arguments", (0, 0, False))[0]
        optional_arguments = getattr(fn, "arguments", (0, 0, False))[1]
        final_argument_whitespace = getattr(fn, "arguments", (0, 0, False))[2]
        option_spec = getattr(fn, "options", None)
        has_content = getattr(fn, "content", False)

        def run(self) -> list[Any]:
            return fn(
                self.name,
                self.arguments,
                self.options,
                self.content,
                self.lineno,
                self.content_offset,
                self.block_text,
                self.state,
                self.state_machine,
            )

    return CustomDirective


class Parser(BaseParser):
    """The standard docutils rst parser, natively accelerated by docodin."""

    supported: tuple[str, ...] = ("restructuredtext", "rst")
    settings_spec: tuple[Any, ...] = ()
    state_classes: tuple[type, ...] | None = None
    inliner: Any = None
    initial_state = "Body"

    def parse(self, inputstring: Any, document: Any) -> None:
        from docodin.builder import parse_string, parse_string_list
        from docodin.shim.statemachine import StringList

        self.setup_parse(inputstring, document)
        document.settings.setdefault("tab_width", 8)
        document.settings.setdefault("syntax_highlight", "long")
        rfc2822 = getattr(self, "initial_state", "Body") == "RFC2822Body"
        if isinstance(inputstring, str):
            parse_string(inputstring, document, self.inliner, rfc2822=rfc2822)
        else:
            if not isinstance(inputstring, StringList):
                inputstring = StringList(list(inputstring), document.get("source", ""))
            parse_string_list(inputstring, document, self.inliner, rfc2822=rfc2822)
        self.finish_parse()
