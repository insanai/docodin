"""reStructuredText parser states (``docutils.parsers.rst.states``).

docodin's native engine recognizes the markup; the classes here provide the
API that directives, roles and extensions use (``RSTState.nested_parse``,
``Body.parse_directive_block``, ``Inliner`` ...).  `RSTStateMachine.run` and
nested parses are delegated to the native engine; list-like states (field
lists, directive options, custom states of extensions) run on the generic
`docutils.statemachine` with the Python helpers below, and hand block markup
back to the native engine.
"""

from __future__ import annotations

import re
import warnings
from types import SimpleNamespace as Struct
from typing import Any

# F401: names of the docutils.parsers.rst.states namespace used by directives and extensions
from docutils import ApplicationError, DataError, nodes, statemachine, utils  # noqa: F401
from docutils.nodes import fully_normalize_name as normalize_name
from docutils.nodes import unescape, whitespace_normalize_name  # noqa: F401
from docutils.parsers.rst import directives, languages, roles, tableparser  # noqa: F401
from docutils.statemachine import StateMachineWS, StateWS, StringList
from docutils.utils import (  # noqa: F401
    column_width,
    escape2null,
    punctuation_chars,
    split_escaped_whitespace,
    strip_combining_chars,
    urischemes,
)
from docutils.utils._roman_numerals import (
    InvalidRomanNumeralError,  # noqa: F401
    RomanNumeral,
)

from ._body import FIELD_MARKER, BodyHelpers, MarkupError
from ._inliner import Inliner, MarkupMismatch, build_regexp

__docformat__ = "reStructuredText"
__all__ = [
    "Body", "BulletList", "Definition", "DefinitionList", "EnumeratedList", "Explicit",
    "ExtensionOptions", "FieldList", "Inliner", "InterpretedRoleNotImplementedError", "Line",
    "LineBlock", "MarkupError", "MarkupMismatch", "NestedStateMachine", "OptionList",
    "ParserError", "QuotedLiteralBlock", "RFC2822Body", "RFC2822List", "RSTState",
    "RSTStateMachine", "SpecializedBody", "SpecializedText", "Struct", "SubstitutionDef", "Text",
    "UnknownInterpretedRoleError", "build_regexp", "state_classes",
]


class UnknownInterpretedRoleError(DataError):
    pass


class InterpretedRoleNotImplementedError(DataError):
    pass


class ParserError(ApplicationError):
    pass


def _native() -> Any:
    from docodin import builder

    return builder


class RSTStateMachine(StateMachineWS):
    """reStructuredText's master state machine (parsing runs natively)."""

    section_level_offset = 0

    def run(self, input_lines: Any, document: nodes.document, input_offset: int = 0,
            match_titles: bool = True, inliner: Any = None) -> None:
        """Parse `input_lines` into `document`."""
        if not isinstance(input_lines, StringList):
            input_lines = StringList(list(input_lines), document.get("source", ""))
        rfc2822 = getattr(self, "initial_state", "Body") == "RFC2822Body"
        _native().parse_string_list(input_lines, document, inliner, input_offset, match_titles,
                                    rfc2822=rfc2822)
        self.node = self.memo = None


class NestedStateMachine(RSTStateMachine):
    """State machine for nested parses of list-like states and extensions."""

    def __init__(self, state_classes: Any, initial_state: str, debug: bool = False,
                 parent_state_machine: Any = None) -> None:
        self.parent_state_machine = parent_state_machine
        super().__init__(state_classes, initial_state, debug)

    def run(self, input_lines: Any, input_offset: int, memo: Any,  # type: ignore[override]
            node: nodes.Element, match_titles: bool = True) -> list:
        """Run the Python state machine over `input_lines` into `node`."""
        self.match_titles = match_titles
        self.memo = memo
        self.document = memo.document
        self.attach_observer(self.document.note_source)
        self.language = memo.language
        self.reporter = self.document.reporter
        self.node = node
        results = StateMachineWS.run(self, input_lines, input_offset)
        assert results == [], "NestedStateMachine.run() results should be empty!"
        return results


class RSTState(StateWS):
    """reStructuredText State superclass."""

    nested_sm = NestedStateMachine
    nested_sm_cache: list = []

    def __init__(self, state_machine: Any, debug: bool = False) -> None:
        self.nested_sm_kwargs = {"state_classes": state_classes, "initial_state": "Body"}
        StateWS.__init__(self, state_machine, debug)

    def runtime_init(self) -> None:
        StateWS.runtime_init(self)
        memo = self.state_machine.memo
        self.memo = memo
        self.document = memo.document
        self.inliner = memo.inliner
        self.reporter = self.document.reporter
        if not hasattr(self.reporter, "get_source_and_line"):
            self.reporter.get_source_and_line = self.state_machine.get_source_and_line

    @property
    def parent(self) -> nodes.Element | None:
        return self.state_machine.node

    @parent.setter
    def parent(self, value: nodes.Element) -> None:
        self.state_machine.node = value

    def goto_line(self, abs_line_offset: int) -> None:
        """Jump to input line `abs_line_offset`, ignoring jumps past the end."""
        try:
            self.state_machine.goto_line(abs_line_offset)
        except EOFError:
            pass

    def no_match(self, context: Any, transitions: Any) -> tuple:
        self.reporter.severe('Internal error: no transition pattern match.  State: "%s"; '
                             "transitions: %s; context: %s; current line: %r."
                             % (self.__class__.__name__, transitions, context,
                                self.state_machine.line))
        return context, None, []

    def bof(self, context: Any) -> tuple:
        return [], []

    def nested_parse(self, block: StringList, input_offset: int,
                     node: nodes.Element | None = None, match_titles: bool = False,
                     state_machine_class: Any = None, state_machine_kwargs: Any = None) -> int:
        """Parse `block` (natively) into `node`; return the new input offset."""
        if state_machine_class is not None or state_machine_kwargs is not None:
            return self._custom_nested_parse(block, input_offset, node, match_titles,
                                             state_machine_class, state_machine_kwargs)
        return _native().nested_parse(self, block, input_offset, node, match_titles)

    def _custom_nested_parse(self, block: StringList, input_offset: int,
                             node: nodes.Element | None, match_titles: bool,
                             state_machine_class: Any, state_machine_kwargs: Any) -> int:
        """Nested parse with an extension's own state machine or state classes."""
        if node is None:
            node = self.state_machine.node
        machine = (state_machine_class or self.nested_sm)(
            debug=self.debug, parent_state_machine=self.state_machine,
            **(state_machine_kwargs or self.nested_sm_kwargs))
        block_length = len(block)
        machine.run(block, input_offset, self.memo, node, match_titles)
        new_offset = machine.abs_line_offset()
        machine.unlink()
        if block.parent and len(block) - block_length != 0:
            self.state_machine.next_line(len(block) - block_length)
        return new_offset

    def nested_list_parse(self, block: StringList, input_offset: int, node: nodes.Element,
                          initial_state: str, blank_finish: bool,
                          blank_finish_state: str | None = None,
                          extra_settings: dict[str, Any] | None = None,
                          match_titles: bool = False, state_machine_class: Any = None,
                          state_machine_kwargs: Any = None) -> tuple[int, bool]:
        """Parse `block` with the list-like state `initial_state` into `node`."""
        if match_titles:
            warnings.warn('The "match_titles" argument of parsers.rst.states.RSTState.'
                          "nested_list_parse() will be ignored in Docutils 1.0 and removed in "
                          "Docutils 2.0.", PendingDeprecationWarning, stacklevel=2)
        if state_machine_kwargs is None:
            state_machine_kwargs = self.nested_sm_kwargs.copy()
        state_machine_kwargs["initial_state"] = initial_state
        machine = (state_machine_class or self.nested_sm)(
            debug=self.debug, parent_state_machine=self.state_machine, **state_machine_kwargs)
        blank_finish_state = blank_finish_state or initial_state
        machine.states[blank_finish_state].blank_finish = blank_finish
        for key, value in (extra_settings or {}).items():
            setattr(machine.states[initial_state], key, value)
        machine.run(block, input_offset, memo=self.memo, node=node, match_titles=match_titles)
        blank_finish = machine.states[blank_finish_state].blank_finish
        machine.unlink()
        return machine.abs_line_offset(), blank_finish

    def section(self, title: str, source: str, style: Any, lineno: int, messages: list) -> None:
        """Check for a valid subsection and create one if it checks out."""
        if self.check_subsection(source, style, lineno):
            self.new_subsection(title, lineno, messages)

    def check_subsection(self, source: str, style: Any, lineno: int) -> bool:
        """Check for a valid subsection header; update section data in `memo`."""
        title_styles = self.memo.title_styles
        parent_sections = self.parent.section_hierarchy()
        oldlevel = len(parent_sections) + self.state_machine.section_level_offset
        try:
            newlevel = title_styles.index(style) + 1
        except ValueError:
            newlevel = len(title_styles) + 1
        if newlevel > oldlevel + 1:
            self.parent += self.reporter.error(
                f"Inconsistent title style: skip from level {oldlevel} to {newlevel}.",
                nodes.literal_block("", source),
                nodes.paragraph("", f"Established title styles: {_styles(title_styles)}"),
                line=lineno)
            return False
        if newlevel <= oldlevel:
            try:
                new_parent = parent_sections[newlevel - oldlevel - 1].parent
            except IndexError:
                self._unreachable_level(source, newlevel, oldlevel, parent_sections, lineno)
                return False
            self.parent = new_parent
            self.memo.section_level = newlevel - 1
        if newlevel > len(title_styles):
            title_styles.append(style)
        return True

    def _unreachable_level(self, source: str, newlevel: int, oldlevel: int,
                           parent_sections: list, lineno: int) -> None:
        details = (f"The parent of level {newlevel} sections cannot be reached. The parser is "
                   f"at section level {oldlevel} but the current node has only "
                   f"{len(parent_sections)} parent section(s).\nOne reason may be a high "
                   "level section used in a directive that parses its content into a base "
                   "node not attached to the document\n(up to Docutils 0.21, these sections "
                   "were silently dropped).")
        self.parent += self.reporter.error(
            f"A level {newlevel} section cannot be used here.",
            nodes.literal_block("", source),
            nodes.paragraph("", f"Established title styles: {_styles(self.memo.title_styles)}"),
            nodes.paragraph("", details), line=lineno)

    def title_inconsistent(self, sourcetext: str, lineno: int) -> nodes.system_message:
        return self.reporter.error("Title level inconsistent:",
                                   nodes.literal_block("", sourcetext), line=lineno)

    def new_subsection(self, title: str, lineno: int, messages: list) -> None:
        """Append new subsection to document tree."""
        section_node = nodes.section()
        self.parent += section_node
        textnodes, title_messages = self.inline_text(title, lineno)
        titlenode = nodes.title(title, "", *textnodes)
        section_node["names"].append(normalize_name(titlenode.astext()))
        section_node += titlenode
        section_node += messages
        section_node += title_messages
        self.document.note_implicit_target(section_node, section_node)
        self.parent = section_node
        self.memo.section_level += 1

    def paragraph(self, lines: list[str], lineno: int) -> tuple[list, int]:
        """Return a list (paragraph & messages) & a boolean: literal_block next?"""
        data = "\n".join(lines).rstrip()
        literalnext = 0
        text = data
        if re.search(r"(?<!\\)(\\\\)*::$", data):
            if len(data) == 2:
                return [], 1
            text = data[:-3].rstrip() if data[-3] in " \n" else data[:-1]
            literalnext = 1
        textnodes, messages = self.inline_text(text, lineno)
        p = nodes.paragraph(data, "", *textnodes)
        p.source, p.line = self.state_machine.get_source_and_line(lineno)
        return [p, *messages], literalnext

    def inline_text(self, text: str, lineno: int) -> tuple[list, list]:
        """Return 2 lists: nodes (text and inline elements), and system_messages."""
        return self.inliner.parse(text, lineno, self.memo, self.parent)

    def unindent_warning(self, node_name: str) -> nodes.system_message:
        lineno = self.state_machine.abs_line_number() + 1
        return self.reporter.warning("%s ends without a blank line; unexpected unindent."
                                     % node_name, line=lineno)


def _styles(title_styles: list) -> str:
    return " ".join("/".join(style) for style in title_styles)


def _loweralpha_to_int(s: str, _zero: int = ord("a") - 1) -> int:
    return ord(s) - _zero


def _upperalpha_to_int(s: str, _zero: int = ord("A") - 1) -> int:
    return ord(s) - _zero


def _enum() -> Struct:
    enum = Struct()
    enum.formatinfo = {"parens": Struct(prefix="(", suffix=")", start=1, end=-1),
                       "rparen": Struct(prefix="", suffix=")", start=0, end=-1),
                       "period": Struct(prefix="", suffix=".", start=0, end=-1)}
    enum.formats = enum.formatinfo.keys()
    enum.sequences = ["arabic", "loweralpha", "upperalpha", "lowerroman", "upperroman"]
    enum.sequencepats = {"arabic": "[0-9]+", "loweralpha": "[a-z]", "upperalpha": "[A-Z]",
                         "lowerroman": "[ivxlcdm]+", "upperroman": "[IVXLCDM]+"}
    enum.converters = {"arabic": int, "loweralpha": _loweralpha_to_int,
                       "upperalpha": _upperalpha_to_int,
                       "lowerroman": RomanNumeral.from_string,
                       "upperroman": RomanNumeral.from_string}
    enum.sequenceregexps = {sequence: re.compile(enum.sequencepats[sequence] + "$")
                            for sequence in enum.sequences}
    return enum


def _body_patterns(enum: Struct) -> tuple[dict[str, str], dict[str, Any]]:
    pats = {"nonalphanum7bit": "[!-/:-@[-`{-~]", "alpha": "[a-zA-Z]",
            "alphanum": "[a-zA-Z0-9]", "alphanumplus": "[a-zA-Z0-9_-]"}
    pats["enum"] = ("(%(arabic)s|%(loweralpha)s|%(upperalpha)s|%(lowerroman)s"
                    "|%(upperroman)s|#)" % enum.sequencepats)
    pats["optname"] = "%(alphanum)s%(alphanumplus)s*" % pats
    pats["optarg"] = "(%(alpha)s%(alphanumplus)s*|<[^<>]+>)" % pats
    pats["shortopt"] = r"(-|\+)%(alphanum)s( ?%(optarg)s)?" % pats
    pats["longopt"] = r"(--|/)%(optname)s([ =]%(optarg)s)?" % pats
    pats["option"] = r"(%(shortopt)s|%(longopt)s)" % pats
    for format in enum.formats:
        info = enum.formatinfo[format]
        pats[format] = "(?P<%s>%s%s%s)" % (format, re.escape(info.prefix), pats["enum"],
                                          re.escape(info.suffix))
    patterns = {
        "bullet": "[-+*•‣⁃]( +|$)",
        "enumerator": r"(%(parens)s|%(rparen)s|%(period)s)( +|$)" % pats,
        "field_marker": FIELD_MARKER,
        "option_marker": r"%(option)s(, %(option)s)*(  +| ?$)" % pats,
        "doctest": r">>>( +|$)",
        "line_block": r"\|( +|$)",
        "grid_table_top": re.compile(r"\+-[-+]+-\+ *$"),
        "simple_table_top": re.compile("=+( +=+)+ *$"),
        "explicit_markup": r"\.\.( +|$)",
        "anonymous": r"__( +|$)",
        "line": r"(%(nonalphanum7bit)s)\1* *$" % pats,
        "text": r"",
    }
    return pats, patterns


_ENUM = _enum()
_PATS, _PATTERNS = _body_patterns(_ENUM)


class Body(BodyHelpers, RSTState):
    """Generic classifier of the first line of a block.

    In Python-run state machines, block markup is handed to the native
    parser (`_to_native`); the directive helpers come from `BodyHelpers`.
    """

    enum = _ENUM
    grid_table_top_pat = _PATTERNS["grid_table_top"]
    simple_table_top_pat = _PATTERNS["simple_table_top"]
    simple_table_border_pat = re.compile("=+[ =]*$")
    pats = _PATS
    patterns = _PATTERNS
    initial_transitions = ("bullet", "enumerator", "field_marker", "option_marker", "doctest",
                           "line_block", "grid_table_top", "simple_table_top",
                           "explicit_markup", "anonymous", "line", "text")

    def _to_native(self, match: Any = None, context: Any = None, next_state: Any = None) -> Any:
        """Parse the rest of the input natively (block markup), then stop."""
        machine = self.state_machine
        start = max(machine.line_offset - (len(context) if context else 0), 0)
        rest = machine.input_lines[start:]
        self.nested_parse(rest, machine.input_offset + start, self.parent)
        machine.line_offset = len(machine.input_lines) - 1
        raise EOFError

    def _replayable(self, match: Any = None, context: Any = None, next_state: Any = None) -> Any:
        """A transition that extensions replace or wrap (``doctest``, ``Text.indent``).

        For a construct the native parser has built, `docodin.builder` runs the
        replacement with ``_docodin_replay`` holding the built nodes; the original
        then adds them to the parent, like the docutils transition method.
        """
        replay = getattr(self, "_docodin_replay", None)
        if replay is None:
            return Body._to_native(self, match, context, next_state)
        for node in replay:
            self.parent += node
        return [], next_state, []

    bullet = enumerator = field_marker = option_marker = _to_native
    doctest = _replayable
    line_block = grid_table_top = simple_table_top = explicit_markup = _to_native
    anonymous = line = text = _to_native

    def indent(self, match: Any, context: Any, next_state: Any) -> tuple:
        """Block quote."""
        indented, _indent, line_offset, blank_finish = self.state_machine.get_indented()
        self.parent += self.block_quote(indented, line_offset)
        if not blank_finish:
            self.parent += self.unindent_warning("Block quote")
        return context, next_state, []


class RFC2822Body(Body):
    """RFC2822 headers are only valid as the first constructs in documents."""

    patterns = {**Body.patterns, "rfc2822": r"[!-9;-~]+:( +|$)"}
    initial_transitions = [(name, "Body") for name in Body.initial_transitions]
    initial_transitions.insert(-1, ("rfc2822", "Body"))
    rfc2822 = Body._to_native


class SpecializedBody(Body):
    """Superclass for second and subsequent compound element members."""

    def invalid_input(self, match: Any = None, context: Any = None,
                      next_state: Any = None) -> Any:
        """Not a compound element member.  Abort this state machine."""
        self.state_machine.previous_line()
        raise EOFError

    indent = bullet = enumerator = field_marker = option_marker = doctest = invalid_input
    line_block = grid_table_top = simple_table_top = explicit_markup = invalid_input
    anonymous = line = text = invalid_input


class BulletList(SpecializedBody):
    """Second and subsequent bullet_list list_items."""


class DefinitionList(SpecializedBody):
    """Second and subsequent definition_list_items."""


class EnumeratedList(SpecializedBody):
    """Second and subsequent enumerated_list list_items."""


class FieldList(SpecializedBody):
    """Second and subsequent field_list fields."""

    def field_marker(self, match: Any, context: Any, next_state: Any) -> tuple:
        """Field list field."""
        field, blank_finish = self.field(match)
        self.parent += field
        self.blank_finish = blank_finish
        return [], next_state, []


class OptionList(SpecializedBody):
    """Second and subsequent option_list option_list_items."""


class RFC2822List(SpecializedBody, RFC2822Body):
    """Second and subsequent RFC2822-style field_list fields."""

    patterns = RFC2822Body.patterns
    initial_transitions = RFC2822Body.initial_transitions
    blank = SpecializedBody.invalid_input


class ExtensionOptions(FieldList):
    """Parse field_list fields for extension options (no nested parsing)."""

    def parse_field_body(self, indented: StringList, offset: int, node: nodes.Element) -> None:
        """Paragraphs of the raw field body text (no inline markup)."""
        lines: list[str] = []
        for line in [*indented, ""]:
            if line.strip():
                lines.append(line)
            elif lines:
                text = "\n".join(lines)
                node += nodes.paragraph(text, text)
                lines = []


class LineBlock(SpecializedBody):
    """Second and subsequent lines of a line_block."""

    blank = SpecializedBody.invalid_input


class Explicit(SpecializedBody):
    """Second and subsequent explicit markup construct."""

    blank = SpecializedBody.invalid_input


class SubstitutionDef(Body):
    """Parser for the contents of a substitution_definition element."""

    patterns = {"embedded_directive": re.compile(r"(%s)::( +|$)" % Inliner.simplename),
                "text": r""}
    initial_transitions = ["embedded_directive", "text"]
    embedded_directive = Body._to_native

    def text(self, match: Any, context: Any, next_state: Any) -> Any:
        if not self.state_machine.at_eof():
            self.blank_finish = self.state_machine.is_next_line_blank()
        raise EOFError


class Text(RSTState):
    """Classifier of second line of a text block (handled natively)."""

    patterns = {"underline": Body.patterns["line"], "text": r""}
    initial_transitions = [("underline", "Body"), ("text", "Body")]
    underline = text = Body._to_native
    indent = Body._replayable

    def blank(self, match: Any, context: Any, next_state: Any) -> Any:
        return Body._to_native(self, match, context, next_state)

    def eof(self, context: Any) -> list:
        if context:
            self.blank(None, context, None)
        return []


class SpecializedText(Text):
    """Superclass for second and subsequent lines of Text-variants."""

    def eof(self, context: Any) -> list:
        return []

    def invalid_input(self, match: Any = None, context: Any = None,
                      next_state: Any = None) -> Any:
        raise EOFError

    blank = indent = underline = text = invalid_input


class Definition(SpecializedText):
    """Second line of potential definition_list_item."""


class Line(SpecializedText):
    """Second line of over- & underlined section title or transition marker."""


class QuotedLiteralBlock(RSTState):
    """Nested parse handler for quoted (unindented) literal blocks."""

    patterns = {"initial_quoted": r"(%(nonalphanum7bit)s)" % Body.pats, "text": r""}
    initial_transitions = ("initial_quoted", "text")
    initial_quoted = text = Body._to_native


state_classes = (Body, BulletList, DefinitionList, EnumeratedList, FieldList, OptionList,
                 LineBlock, ExtensionOptions, Explicit, Text, Definition, Line, SubstitutionDef,
                 RFC2822Body, RFC2822List)
"""Standard set of State classes used to start `RSTStateMachine`."""
