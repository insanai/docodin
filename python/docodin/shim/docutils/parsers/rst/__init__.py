"""The reStructuredText parser (``docutils.parsers.rst``), backed by docodin.

`Parser.parse` runs docodin's native parser; directives and roles are
the registries of :mod:`docutils.parsers.rst.directives` and
:mod:`docutils.parsers.rst.roles`.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

import docutils.parsers
import docutils.statemachine
from docutils import frontend, nodes
from docutils.parsers.rst import roles, states
from docutils.transforms import universal

__docformat__ = "reStructuredText"


class Parser(docutils.parsers.Parser):
    """The reStructuredText parser."""

    supported = ("rst", "restructuredtext", "rest", "restx", "rtxt", "rstx")
    settings_spec = docutils.parsers.Parser.settings_spec + (
        "reStructuredText Parser Options", None, (
            ('Recognize and link to standalone PEP references (like "PEP 258").',
             ["--pep-references"],
             {"action": "store_true", "validator": frontend.validate_boolean}),
            ('Base URL for PEP references (default "https://peps.python.org/").',
             ["--pep-base-url"],
             {"metavar": "<URL>", "default": "https://peps.python.org/",
              "validator": frontend.validate_url_trailing_slash}),
            ('Template for PEP file part of URL. (default "pep-%04d")',
             ["--pep-file-url-template"], {"metavar": "<URL>", "default": "pep-%04d"}),
            ('Recognize and link to standalone RFC references (like "RFC 822").',
             ["--rfc-references"],
             {"action": "store_true", "validator": frontend.validate_boolean}),
            ('Base URL for RFC references (default "https://tools.ietf.org/html/").',
             ["--rfc-base-url"],
             {"metavar": "<URL>", "default": "https://tools.ietf.org/html/",
              "validator": frontend.validate_url_trailing_slash}),
            ("Set number of spaces for tab expansion (default 8).", ["--tab-width"],
             {"metavar": "<width>", "type": "int", "default": 8,
              "validator": frontend.validate_nonnegative_int}),
            ("Remove spaces before footnote references.", ["--trim-footnote-reference-space"],
             {"action": "store_true", "validator": frontend.validate_boolean}),
            ("Leave spaces before footnote references.", ["--leave-footnote-reference-space"],
             {"action": "store_false", "dest": "trim_footnote_reference_space"}),
            ('Token name set for parsing code with Pygments: one of "long", "short", or "none" '
             '(no parsing). Default is "long".', ["--syntax-highlight"],
             {"choices": ["long", "short", "none"], "default": "long", "metavar": "<format>"}),
            ('Change straight quotation marks to typographic form: one of "yes", "no", '
             '"alt[ernative]" (default "no").', ["--smart-quotes"],
             {"default": False, "metavar": "<yes/no/alt>",
              "validator": frontend.validate_ternary}),
            ('Characters to use as "smart quotes" for <language>. ', ["--smartquotes-locales"],
             {"metavar": "<language:quotes[,language:quotes,...]>", "action": "append",
              "validator": frontend.validate_smartquotes_locales}),
            ("Inline markup recognized at word boundaries only (adjacent to punctuation or "
             'whitespace). Force character-level inline markup recognition with "\\ " '
             "(backslash + space). Default.", ["--word-level-inline-markup"],
             {"action": "store_false", "dest": "character_level_inline_markup"}),
            ("Inline markup recognized anywhere, regardless of surrounding characters. "
             "Backslash-escapes must be used to avoid unwanted markup recognition. Useful for "
             "East Asian languages. Experimental.", ["--character-level-inline-markup"],
             {"action": "store_true", "default": False,
              "dest": "character_level_inline_markup"}),
        ))
    config_section = "restructuredtext parser"
    config_section_dependencies = ("parsers",)

    def __init__(self, rfc2822: bool = False, inliner: Any = None) -> None:
        self.initial_state = "RFC2822Body" if rfc2822 else "Body"
        self.state_classes = states.state_classes
        self.inliner = inliner

    def get_transforms(self) -> list[type]:
        return [*super().get_transforms(), universal.SmartQuotes]

    def parse(self, inputstring: Any, document: nodes.document) -> None:
        """Parse `inputstring` (str or StringList) and populate `document`.

        The native engine parses unless the grammar differs from the stock one
        (see `states.python_parser_needed`); then the Python state machine does.
        """
        self.setup_parse(inputstring, document)
        document.settings.setdefault("tab_width", 8)
        document.settings.setdefault("syntax_highlight", "long")
        if states.python_parser_needed(self.state_classes, self.initial_state, self.inliner):
            self._parse_with_states(inputstring, document)
        else:
            self._parse_natively(inputstring, document)
        # restore the "default" default role after parsing a document
        roles._roles.pop("", None)
        self.finish_parse()

    def _parse_natively(self, inputstring: Any, document: nodes.document) -> None:
        from docodin import builder

        rfc2822 = self.initial_state == "RFC2822Body"
        if isinstance(inputstring, str):
            builder.parse_string(inputstring, document, self.inliner, rfc2822=rfc2822)
            return
        lines = inputstring
        if not isinstance(lines, docutils.statemachine.StringList):
            lines = docutils.statemachine.StringList(list(lines), document.get("source", ""))
        builder.parse_string_list(lines, document, self.inliner, rfc2822=rfc2822)

    def _parse_with_states(self, inputstring: Any, document: nodes.document) -> None:
        self.statemachine = states.RSTStateMachine(state_classes=self.state_classes,
                                                   initial_state=self.initial_state,
                                                   debug=document.reporter.debug_flag)
        if isinstance(inputstring, str):
            inputlines = docutils.statemachine.string2lines(
                inputstring, tab_width=document.settings.tab_width, convert_whitespace=True)
        else:
            inputlines = inputstring
        limit = document.settings.line_length_limit
        for i, line in enumerate(inputlines):
            if len(line) > limit:
                document.append(document.reporter.error(
                    "Line %d exceeds the line-length-limit." % (i + 1)))
                return
        self.statemachine.run(inputlines, document, inliner=self.inliner)


class DirectiveError(Exception):
    """Store a message and a system message level (raised by directives)."""

    def __init__(self, level: int, message: str) -> None:
        Exception.__init__(self)
        self.level = level
        self.msg = message


class Directive:
    """Base class for reStructuredText directives."""

    required_arguments = 0
    optional_arguments = 0
    final_argument_whitespace = False
    option_spec: dict[str, Callable[[Any], Any]] | None = None
    has_content = False

    def __init__(self, name: str, arguments: list[str], options: dict[str, Any], content: Any,
                 lineno: int, content_offset: int, block_text: str, state: Any,
                 state_machine: Any) -> None:
        self.name = name
        self.arguments = arguments
        self.options = options
        self.content = content
        self.lineno = lineno
        self.content_offset = content_offset
        self.block_text = block_text
        self.state = state
        self.state_machine = state_machine
        self.reporter = state_machine.reporter

    def run(self) -> list[nodes.Node]:
        raise NotImplementedError("Must override run() in subclass.")

    def directive_error(self, level: int, message: str) -> DirectiveError:
        """Return a DirectiveError suitable for being thrown as an exception."""
        return DirectiveError(level, message)

    def debug(self, message: str) -> DirectiveError:
        return self.directive_error(0, message)

    def info(self, message: str) -> DirectiveError:
        return self.directive_error(1, message)

    def warning(self, message: str) -> DirectiveError:
        return self.directive_error(2, message)

    def error(self, message: str) -> DirectiveError:
        return self.directive_error(3, message)

    def severe(self, message: str) -> DirectiveError:
        return self.directive_error(4, message)

    def assert_has_content(self) -> None:
        """Throw an ERROR-level DirectiveError if the directive has no content."""
        if not self.content:
            raise self.error('Content block expected for the "%s" directive; none found.'
                             % self.name)

    def add_name(self, node: nodes.Element) -> None:
        """Append self.options["name"] to node["names"] if it exists."""
        if "name" in self.options:
            name = nodes.fully_normalize_name(self.options.pop("name"))
            if "name" in node:
                del node["name"]
            node["names"].append(name)
            self.state.document.note_explicit_target(node, node)


def convert_directive_function(directive_fn: Callable[..., Any]) -> type[Directive]:
    """Define & return a directive class wrapping a directive function."""

    class FunctionalDirective(Directive):
        option_spec = getattr(directive_fn, "options", None)
        has_content = getattr(directive_fn, "content", False)
        _argument_spec = getattr(directive_fn, "arguments", (0, 0, False))
        required_arguments, optional_arguments, final_argument_whitespace = _argument_spec

        def run(self) -> list[nodes.Node]:
            return directive_fn(self.name, self.arguments, self.options, self.content,
                                self.lineno, self.content_offset, self.block_text, self.state,
                                self.state_machine)

    return FunctionalDirective
