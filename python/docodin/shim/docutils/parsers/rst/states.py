"""reStructuredText parser states (``docutils.parsers.rst.states``).

The parser is a `StateMachineWS` whose states classify input lines by
regular expressions ("transitions") and build the document tree:

* `Body` recognizes the first line of every block construct; compound
  constructs (lists, field lists, explicit markup ...) continue in nested
  state machines whose initial state is a `SpecializedBody` subclass that
  accepts only further members of the construct;
* `Text` looks at the line after a text line (paragraph, section title,
  definition list); `Line` at the line after a title overline or transition;
* `Inliner` parses inline markup.

docodin's native engine implements this grammar.  `RSTStateMachine.run` and
nested parses use it unless the grammar in Python differs from the stock one
(custom state classes, extensions that replaced state methods, or
``DOCODIN_NATIVE=0``); see `docodin._grammar`.  The pure Python machine here then
parses exactly as docutils does.
"""

from __future__ import annotations

import re
import warnings
from types import FunctionType, MethodType  # noqa: F401
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

from docodin._grammar import Snapshot, python_forced

from ._body import FIELD_MARKER, BodyHelpers, MarkupError, ParserError
from ._explicit import ExplicitHelpers
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


def _native() -> Any:
    from docodin import builder

    return builder


# --- state machines -------------------------------------------------------------------


class RSTStateMachine(StateMachineWS):
    """reStructuredText's master state machine; `run` is the entry point."""

    section_level_offset: int = 0
    """Correction of the section level in nested parses whose base node's
    sections do not match the title styles in use (see `RSTState.nested_parse`)."""

    def run(self, input_lines: Any, document: nodes.document, input_offset: int = 0,
            match_titles: bool = True, inliner: Any = None) -> None:
        """Parse `input_lines` into `document`."""
        state_types = [type(state) for state in (self.states or {}).values()]
        if python_parser_needed(state_types, self.initial_state, inliner):
            self._run_python(input_lines, document, input_offset, match_titles, inliner)
            return
        if not isinstance(input_lines, StringList):
            input_lines = StringList(list(input_lines), document.get("source", ""))
        rfc2822 = self.initial_state == "RFC2822Body"
        _native().parse_string_list(input_lines, document, inliner, input_offset, match_titles,
                                    rfc2822=rfc2822)
        self.node = self.memo = None

    def _run_python(self, input_lines: Any, document: nodes.document, input_offset: int,
                    match_titles: bool, inliner: Any) -> None:
        """Run the Python state machine: set up the parse-global data first."""
        self.language = languages.get_language(document.settings.language_code,
                                               document.reporter)
        self.match_titles = match_titles
        if inliner is None:
            inliner = Inliner()
        inliner.init_customizations(document.settings)
        # objects shared with nested parsers; `reporter`, `section_level` and
        # `section_bubble_up_kludge` are kept for compatibility only
        self.memo = Struct(document=document, reporter=document.reporter,
                           language=self.language, title_styles=[], section_level=0,
                           section_bubble_up_kludge=False, inliner=inliner)
        self.document = document
        self.attach_observer(document.note_source)
        self.reporter = document.reporter
        self.node = document
        results = StateMachineWS.run(self, input_lines, input_offset,
                                     input_source=document["source"])
        assert results == [], "RSTStateMachine.run() results should be empty!"
        self.node = self.memo = None


class NestedStateMachine(RSTStateMachine):
    """State machine run from within other state machines (nested structures)."""

    def __init__(self, state_classes: Any, initial_state: str, debug: bool = False,
                 parent_state_machine: Any = None) -> None:
        self.parent_state_machine = parent_state_machine
        super().__init__(state_classes, initial_state, debug)

    def run(self, input_lines: Any, input_offset: int, memo: Any,  # type: ignore[override]
            node: nodes.Element, match_titles: bool = True) -> list:
        """Parse `input_lines` into `node` with the document-wide data of `memo`."""
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


# --- the state superclass ---------------------------------------------------------------


class RSTState(StateWS):
    """reStructuredText State superclass: methods used by all states."""

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
        """Report an internal error (every state has a catch-all transition)."""
        self.reporter.severe('Internal error: no transition pattern match.  State: "%s"; '
                             "transitions: %s; context: %s; current line: %r."
                             % (self.__class__.__name__, transitions, context,
                                self.state_machine.line))
        return context, None, []

    def bof(self, context: Any) -> tuple:
        """Called at beginning of file."""
        return [], []

    def nested_parse(self, block: StringList, input_offset: int,
                     node: nodes.Element | None = None, match_titles: bool = False,
                     state_machine_class: Any = None, state_machine_kwargs: Any = None) -> int:
        """Parse `block` with a nested state machine rooted at `node`.

        `node` defaults to the current node; `match_titles` allows sections
        (not in a detached custom node).  The machine is `state_machine_class`
        (default `nested_sm`) made with `state_machine_kwargs` (default
        `nested_sm_kwargs`).  Returns the new input offset.
        """
        use_default = state_machine_class is None and state_machine_kwargs is None
        if use_default and self._nests_natively():
            return _native().nested_parse(self, block, input_offset, node, match_titles)
        if node is None:
            node = self.state_machine.node
        machine = None
        if use_default and self.nested_sm_cache:
            machine = self.nested_sm_cache.pop()  # reserved while it runs
        if not machine:
            machine = (state_machine_class or self.nested_sm)(
                debug=self.debug, parent_state_machine=self.state_machine,
                **(self.nested_sm_kwargs if state_machine_kwargs is None
                   else state_machine_kwargs))
        if node is self.state_machine.node and not isinstance(
                node, (nodes.document, nodes.section)):
            match_titles = False  # no sections in a construct's own node
        if match_titles:
            # compensate for base nodes whose sections differ from the title styles
            l_node = len(node.section_hierarchy())
            l_start = min(len(self.parent.section_hierarchy()), len(self.memo.title_styles))
            machine.section_level_offset = l_start - l_node
        block_length = len(block)
        machine.run(block, input_offset, self.memo, node, match_titles)
        if match_titles and node is self.state_machine.node:
            self._pass_on_node(machine.node)
        new_offset = machine.abs_line_offset()
        if use_default:
            self.nested_sm_cache.append(machine)
        else:
            machine.unlink()
        if block.parent and len(block) - block_length != 0:
            # the nested parse changed the block (inserted input)
            self.state_machine.next_line(len(block) - block_length)
        return new_offset

    def _pass_on_node(self, node: nodes.Element) -> None:
        """Make `node` the current node of this and all enclosing machines."""
        machine = self.state_machine
        try:
            while True:
                machine.node = node
                machine = machine.parent_state_machine
        except AttributeError:
            pass

    def _nests_natively(self) -> bool:
        """Whether a default nested parse goes to the native engine: the
        document is parsed natively and this state nests the stock states."""
        memo = getattr(self, "memo", None)
        if getattr(memo, "docodin_ctx", None) is None:
            return False
        kwargs = self.nested_sm_kwargs
        return (self.nested_sm is NestedStateMachine and len(kwargs) == 2
                and kwargs.get("initial_state") == "Body"
                and _stock_classes(kwargs.get("state_classes", ())))

    def nested_list_parse(self, block: StringList, input_offset: int, node: nodes.Element,
                          initial_state: str, blank_finish: bool,
                          blank_finish_state: str | None = None,
                          extra_settings: dict[str, Any] | None = None,
                          match_titles: bool = False, state_machine_class: Any = None,
                          state_machine_kwargs: Any = None) -> tuple[int, bool]:
        """Parse `block` with a nested machine starting in state `initial_state`.

        Keeps track of the blank line required after the construct (in state
        `blank_finish_state`).  Returns (new offset, blank_finish).
        """
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
        """Check for a valid subsection header; update section data in `memo`.

        A section that is not a subsection of the current one makes its
        parent section (or the root) the current node.
        """
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
        # the actual problem is one line below the current line
        lineno = self.state_machine.abs_line_number() + 1
        return self.reporter.warning("%s ends without a blank line; unexpected unindent."
                                     % node_name, line=lineno)


def _styles(title_styles: list) -> str:
    return " ".join("/".join(style) for style in title_styles)


def _replay(state: RSTState) -> bool:
    """Add the nodes of a construct the native parser built (see
    `docodin._machine.replay_transition`); False outside such a replay."""
    replay = getattr(state, "_docodin_replay", None)
    if replay is None:
        return False
    for node in replay:
        state.parent += node
    return True


# --- Body -------------------------------------------------------------------------------


def _loweralpha_to_int(s: str, _zero: int = ord("a") - 1) -> int:
    return ord(s) - _zero


def _upperalpha_to_int(s: str, _zero: int = ord("A") - 1) -> int:
    return ord(s) - _zero


def _enum() -> Struct:
    """Enumerated list parsing information."""
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
    """(pattern fragments, transition patterns) of `Body`."""
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


class Body(ExplicitHelpers, BodyHelpers, RSTState):
    """Generic classifier of the first line of a block."""

    enum = _ENUM
    grid_table_top_pat = _PATTERNS["grid_table_top"]
    """Matches the top (& bottom) of a full table)."""
    simple_table_top_pat = _PATTERNS["simple_table_top"]
    """Matches the top of a simple table."""
    simple_table_border_pat = re.compile("=+[ =]*$")
    """Matches the bottom & header bottom of a simple table."""
    pats = _PATS
    patterns = _PATTERNS
    initial_transitions = ("bullet", "enumerator", "field_marker", "option_marker", "doctest",
                           "line_block", "grid_table_top", "simple_table_top",
                           "explicit_markup", "anonymous", "line", "text")

    def _list_continues(self, node: nodes.Element, initial_state: str, blank_finish: bool,
                        name: str, **kwargs: Any) -> None:
        """Parse the next members of a list-like construct from the next line on
        (state `initial_state`); warn when it ends without a blank line."""
        machine = self.state_machine
        new_offset, blank_finish = self.nested_list_parse(
            machine.input_lines[machine.line_offset + 1:],
            input_offset=machine.abs_line_offset() + 1, node=node,
            initial_state=initial_state, blank_finish=blank_finish, **kwargs)
        self.goto_line(new_offset)
        if not blank_finish:
            self.parent += self.unindent_warning(name)

    def indent(self, match: Any, context: Any, next_state: Any) -> tuple:
        """Block quote."""
        indented, _indent, line_offset, blank_finish = self.state_machine.get_indented()
        self.parent += self.block_quote(indented, line_offset)
        if not blank_finish:
            self.parent += self.unindent_warning("Block quote")
        return context, next_state, []

    def bullet(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Bullet list item."""
        ul = nodes.bullet_list()
        ul.source, ul.line = self.state_machine.get_source_and_line()
        self.parent += ul
        ul["bullet"] = match.string[0]
        item, blank_finish = self.list_item(match.end())
        ul += item
        self._list_continues(ul, "BulletList", blank_finish, "Bullet list")
        return [], next_state, []

    def enumerator(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Enumerated List Item"""
        format, sequence, text, ordinal = self.parse_enumerator(match)
        if not self.is_enumerated_list_item(ordinal, sequence, format):
            raise statemachine.TransitionCorrection("text")
        enumlist = nodes.enumerated_list()
        enumlist.source, enumlist.line = self.state_machine.get_source_and_line()
        self.parent += enumlist
        enumlist["enumtype"] = "arabic" if sequence == "#" else sequence
        enumlist["prefix"] = self.enum.formatinfo[format].prefix
        enumlist["suffix"] = self.enum.formatinfo[format].suffix
        if ordinal != 1:
            enumlist["start"] = ordinal
            self.parent += self.reporter.info(
                'Enumerated list start value not ordinal-1: "%s" (ordinal %s)'
                % (text, ordinal), base_node=enumlist)
        listitem, blank_finish = self.list_item(match.end())
        enumlist += listitem
        self._list_continues(enumlist, "EnumeratedList", blank_finish, "Enumerated list",
                             extra_settings={"lastordinal": ordinal, "format": format,
                                             "auto": sequence == "#"})
        return [], next_state, []

    def field_marker(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Field list item."""
        field_list = nodes.field_list()
        self.parent += field_list
        field, blank_finish = self.field(match)
        field_list += field
        self._list_continues(field_list, "FieldList", blank_finish, "Field list")
        return [], next_state, []

    def option_marker(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Option list item."""
        optionlist = nodes.option_list()
        optionlist.source, optionlist.line = self.state_machine.get_source_and_line()
        try:
            listitem, blank_finish = self.option_list_item(match)
        except MarkupError as error:
            # the pattern does not match invalid markers; kept for safety
            self.parent += self.reporter.error("Invalid option list marker: %s" % error)
            indented, _indent, line_offset, blank_finish = (
                self.state_machine.get_first_known_indented(match.end()))
            self.parent += self.block_quote(indented, line_offset)
            if not blank_finish:
                self.parent += self.unindent_warning("Option list")
            return [], next_state, []
        self.parent += optionlist
        optionlist += listitem
        self._list_continues(optionlist, "OptionList", blank_finish, "Option list")
        return [], next_state, []

    def doctest(self, match: Any, context: Any, next_state: Any) -> tuple:
        """Doctest block (Python interactive session)."""
        if not _replay(self):
            line = self.document.current_line
            data = "\n".join(self.state_machine.get_text_block())
            block = nodes.doctest_block(data, data)
            block.line = line
            self.parent += block
        return [], next_state, []

    def line_block(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """First line of a line block."""
        block = nodes.line_block()
        self.parent += block
        machine = self.state_machine
        lineno = machine.abs_line_number()
        block.source, block.line = machine.get_source_and_line(lineno)
        line, messages, blank_finish = self.line_block_line(match, lineno)
        block += line
        self.parent += messages
        if not blank_finish:
            new_offset, blank_finish = self.nested_list_parse(
                machine.input_lines[machine.line_offset + 1:],
                input_offset=machine.abs_line_offset() + 1, node=block,
                initial_state="LineBlock", blank_finish=False)
            self.goto_line(new_offset)
        if not blank_finish:
            self.parent += self.reporter.warning("Line block ends without a blank line.",
                                                 line=lineno + 1)
        if len(block):
            if block[0].indent is None:
                block[0].indent = 0
            self.nest_line_block_lines(block)
        return [], next_state, []

    def grid_table_top(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Top border of a full table."""
        return self.table_top(match, context, next_state, self.isolate_grid_table,
                              tableparser.GridTableParser)

    def simple_table_top(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Top border of a simple table."""
        return self.table_top(match, context, next_state, self.isolate_simple_table,
                              tableparser.SimpleTableParser)

    def explicit_markup(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Footnotes, hyperlink targets, directives, comments."""
        nodelist, blank_finish = self.explicit_construct(match)
        self.parent += nodelist
        self.explicit_list(blank_finish)
        return [], next_state, []

    def anonymous(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Anonymous hyperlink targets."""
        nodelist, blank_finish = self.anonymous_target(match)
        self.parent += nodelist
        self.explicit_list(blank_finish)
        return [], next_state, []

    def line(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Section title overline or transition marker."""
        machine = self.state_machine
        if machine.match_titles:
            return [match.string], "Line", []
        if match.string.strip() == "::":
            raise statemachine.TransitionCorrection("text")
        if len(match.string.strip()) < 4:
            self.parent += self.reporter.info(
                "Unexpected possible title overline or transition.\n"
                "Treating it as ordinary text because it's so short.",
                line=machine.abs_line_number())
            raise statemachine.TransitionCorrection("text")
        blocktext = machine.line
        self.parent += self.reporter.error(
            "Unexpected section title or transition.",
            nodes.literal_block(blocktext, blocktext), line=machine.abs_line_number())
        return [], next_state, []

    def text(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Titles, definition lists, paragraphs."""
        return [match.string], "Text", []


class RFC2822Body(Body):
    """RFC2822 headers are only valid as the first constructs in documents.

    As soon as anything else appears, the `Body` state takes over.
    """

    patterns = {**Body.patterns, "rfc2822": r"[!-9;-~]+:( +|$)"}
    initial_transitions = [(name, "Body") for name in Body.initial_transitions]
    initial_transitions.insert(-1, ("rfc2822", "Body"))  # just before "text"

    def rfc2822(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """RFC2822-style field list item."""
        fieldlist = nodes.field_list(classes=["rfc2822"])
        self.parent += fieldlist
        field, blank_finish = self.rfc2822_field(match)
        fieldlist += field
        self._list_continues(fieldlist, "RFC2822List", blank_finish,
                             "RFC2822-style field list")
        return [], next_state, []

    def rfc2822_field(self, match: re.Match[str]) -> tuple[nodes.field, bool]:
        name = match.string[:match.string.find(":")]
        indented, _indent, line_offset, blank_finish = (
            self.state_machine.get_first_known_indented(match.end(), until_blank=True))
        fieldnode = nodes.field()
        fieldnode += nodes.field_name(name, name)
        fieldbody = nodes.field_body("\n".join(indented))
        fieldnode += fieldbody
        if indented:
            self.nested_parse(indented, input_offset=line_offset, node=fieldbody)
        return fieldnode, blank_finish


# --- states of compound constructs ------------------------------------------------------


class SpecializedBody(Body):
    """Superclass for second and subsequent compound element members.

    Compound elements are lists and list-like constructs.  Every transition is
    `invalid_input`, which ends the nested state machine; subclasses re-enable
    the transition of their construct's members.
    """

    def invalid_input(self, match: Any = None, context: Any = None,
                      next_state: Any = None) -> Any:
        """Not a compound element member.  Abort this state machine."""
        self.state_machine.previous_line()  # back up so parent SM can reassess
        raise EOFError

    indent = bullet = enumerator = field_marker = option_marker = doctest = invalid_input
    line_block = grid_table_top = simple_table_top = explicit_markup = invalid_input
    anonymous = line = text = invalid_input


class BulletList(SpecializedBody):
    """Second and subsequent bullet_list list_items."""

    def bullet(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Bullet list item."""
        if match.string[0] != self.parent["bullet"]:
            self.invalid_input()  # different bullet: new list
        listitem, blank_finish = self.list_item(match.end())
        self.parent += listitem
        self.blank_finish = blank_finish
        return [], next_state, []


class DefinitionList(SpecializedBody):
    """Second and subsequent definition_list_items."""

    def text(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Definition lists."""
        return [match.string], "Definition", []


class EnumeratedList(SpecializedBody):
    """Second and subsequent enumerated_list list_items."""

    def enumerator(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Enumerated list item."""
        format, sequence, _text, ordinal = self.parse_enumerator(match, self.parent["enumtype"])
        same_sequence = sequence == "#" or (sequence == self.parent["enumtype"]
                                            and not self.auto
                                            and ordinal == self.lastordinal + 1)
        if (format != self.format or not same_sequence
                or not self.is_enumerated_list_item(ordinal, sequence, format)):
            self.invalid_input()  # different enumeration: new list
        if sequence == "#":
            self.auto = 1
        listitem, blank_finish = self.list_item(match.end())
        self.parent += listitem
        self.blank_finish = blank_finish
        self.lastordinal = ordinal
        return [], next_state, []


class FieldList(SpecializedBody):
    """Second and subsequent field_list fields."""

    def field_marker(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Field list field."""
        field, blank_finish = self.field(match)
        self.parent += field
        self.blank_finish = blank_finish
        return [], next_state, []


class OptionList(SpecializedBody):
    """Second and subsequent option_list option_list_items."""

    def option_marker(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Option list item."""
        try:
            option_list_item, blank_finish = self.option_list_item(match)
        except MarkupError:
            self.invalid_input()
        self.parent += option_list_item
        self.blank_finish = blank_finish
        return [], next_state, []


class RFC2822List(SpecializedBody, RFC2822Body):
    """Second and subsequent RFC2822-style field_list fields."""

    patterns = RFC2822Body.patterns
    initial_transitions = RFC2822Body.initial_transitions

    def rfc2822(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """RFC2822-style field list item."""
        field, blank_finish = self.rfc2822_field(match)
        self.parent += field
        self.blank_finish = blank_finish
        return [], "RFC2822List", []

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

    def line_block(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """New line of line block."""
        lineno = self.state_machine.abs_line_number()
        line, messages, blank_finish = self.line_block_line(match, lineno)
        self.parent += line
        self.parent.parent += messages
        self.blank_finish = blank_finish
        return [], next_state, []


class Explicit(SpecializedBody):
    """Second and subsequent explicit markup construct."""

    def explicit_markup(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Footnotes, hyperlink targets, directives, comments."""
        nodelist, blank_finish = self.explicit_construct(match)
        self.parent += nodelist
        self.blank_finish = blank_finish
        return [], next_state, []

    def anonymous(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Anonymous hyperlink targets."""
        nodelist, blank_finish = self.anonymous_target(match)
        self.parent += nodelist
        self.blank_finish = blank_finish
        return [], next_state, []

    blank = SpecializedBody.invalid_input


class SubstitutionDef(Body):
    """Parser for the contents of a substitution_definition element."""

    patterns = {"embedded_directive": re.compile(r"(%s)::( +|$)" % Inliner.simplename),
                "text": r""}
    initial_transitions = ["embedded_directive", "text"]

    def embedded_directive(self, match: re.Match[str], context: Any, next_state: Any) -> Any:
        nodelist, blank_finish = self.directive(match, alt=self.parent["names"][0])
        self.parent += nodelist
        if not self.state_machine.at_eof():
            self.blank_finish = blank_finish
        raise EOFError

    def text(self, match: re.Match[str], context: Any, next_state: Any) -> Any:
        if not self.state_machine.at_eof():
            self.blank_finish = self.state_machine.is_next_line_blank()
        raise EOFError


# --- Text and its variants ---------------------------------------------------------------


class Text(RSTState):
    """Classifier of second line of a text block.

    Could be a paragraph, a definition list item, or a title.
    """

    patterns = {"underline": Body.patterns["line"], "text": r""}
    initial_transitions = [("underline", "Body"), ("text", "Body")]
    classifier_delimiter = re.compile(" +: +")

    def blank(self, match: Any, context: Any, next_state: Any) -> tuple:
        """End of paragraph."""
        paragraph, literalnext = self.paragraph(context,
                                                self.state_machine.abs_line_number() - 1)
        self.parent += paragraph
        if literalnext:
            self.parent += self.literal_block()
        return [], "Body", []

    def eof(self, context: Any) -> list:
        if context:
            self.blank(None, context, None)
        return []

    def indent(self, match: Any, context: Any, next_state: Any) -> tuple:
        """Definition list item."""
        if _replay(self):
            return [], "Body", []
        machine = self.state_machine
        dl = nodes.definition_list()
        # the definition list starts on the line before the indent
        dl.source, dl.line = machine.get_source_and_line(machine.abs_line_number() - 1)
        dl_item, blank_finish = self.definition_list_item(context)
        dl += dl_item
        self.parent += dl
        new_offset, blank_finish = self.nested_list_parse(
            machine.input_lines[machine.line_offset + 1:],
            input_offset=machine.abs_line_offset() + 1, node=dl,
            initial_state="DefinitionList", blank_finish=blank_finish,
            blank_finish_state="Definition")
        self.goto_line(new_offset)
        if not blank_finish:
            self.parent += self.unindent_warning("Definition list")
        return [], "Body", []

    def underline(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Section title."""
        machine = self.state_machine
        lineno = machine.abs_line_number()
        title = context[0].rstrip()
        underline = match.string.rstrip()
        source = title + "\n" + underline
        messages = []
        if column_width(title) > len(underline):
            if len(underline) < 4:
                if machine.match_titles:
                    self.parent += self.reporter.info(
                        "Possible title underline, too short for the title.\n"
                        "Treating it as ordinary text because it's so short.", line=lineno)
                raise statemachine.TransitionCorrection("text")
            blocktext = context[0] + "\n" + machine.line
            messages.append(self.reporter.warning(
                "Title underline too short.", nodes.literal_block(blocktext, blocktext),
                line=lineno))
        if not machine.match_titles:
            blocktext = context[0] + "\n" + machine.line
            src, srcline = machine.get_source_and_line()
            msg = self.reporter.error("Unexpected section title.",
                                      nodes.literal_block(blocktext, blocktext),
                                      source=src, line=srcline)
            self.parent += messages
            self.parent += msg
            return [], next_state, []
        context[:] = []
        self.section(title, source, underline[0], lineno - 1, messages)
        return [], next_state, []

    def text(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Paragraph."""
        machine = self.state_machine
        startline = machine.abs_line_number() - 1
        msg = None
        try:
            block = machine.get_text_block(flush_left=True)
        except statemachine.UnexpectedIndentationError as err:
            block, src, srcline = err.args
            msg = self.reporter.error("Unexpected indentation.", source=src, line=srcline)
        paragraph, literalnext = self.paragraph(context + list(block), startline)
        self.parent += paragraph
        self.parent += msg
        if literalnext:
            try:
                machine.next_line()
            except EOFError:
                pass
            self.parent += self.literal_block()
        return [], next_state, []

    def literal_block(self) -> list[nodes.Node]:
        """Return a list of nodes."""
        indented, _indent, offset, blank_finish = self.state_machine.get_indented()
        while indented and not indented[-1].strip():
            indented.trim_end()
        if not indented:
            return self.quoted_literal_block()
        data = "\n".join(indented)
        literal_block = nodes.literal_block(data, data)
        literal_block.source, literal_block.line = self.state_machine.get_source_and_line(
            offset + 1)
        nodelist: list[nodes.Node] = [literal_block]
        if not blank_finish:
            nodelist.append(self.unindent_warning("Literal block"))
        return nodelist

    def quoted_literal_block(self) -> list[nodes.Node]:
        machine = self.state_machine
        parent_node = nodes.Element()
        new_abs_offset = self.nested_parse(
            machine.input_lines[machine.line_offset:],
            input_offset=machine.abs_line_offset(), node=parent_node, match_titles=False,
            state_machine_kwargs={"state_classes": (QuotedLiteralBlock,),
                                  "initial_state": "QuotedLiteralBlock"})
        self.goto_line(new_abs_offset)
        return parent_node.children

    def definition_list_item(self, termline: list[str]) -> tuple:
        """(definition_list_item, blank_finish); the machine is on the
        (indented) definition line after `termline`."""
        machine = self.state_machine
        dd_lineno = machine.abs_line_number()
        dt_lineno = dd_lineno - 1
        indented, _indent, line_offset, blank_finish = machine.get_indented()
        dl_item = nodes.definition_list_item("\n".join(termline + list(indented)))
        dl_item.source, dl_item.line = machine.get_source_and_line(dt_lineno)
        dt_nodes, messages = self.term(termline, dt_lineno)
        dl_item += dt_nodes
        dd = nodes.definition("", *messages)
        dd.source, dd.line = machine.get_source_and_line(dd_lineno)
        dl_item += dd
        if termline[0][-2:] == "::":
            dd += self.reporter.info(
                'Blank line missing before literal block (after the "::")? '
                "Interpreted as a definition list item.", line=dd_lineno)
        self.nested_parse(indented, input_offset=line_offset, node=dd)
        return dl_item, blank_finish

    def term(self, lines: list[str], lineno: int) -> tuple[list, list]:
        """Return a definition_list's term and optional classifiers."""
        assert len(lines) == 1
        text_nodes, messages = self.inline_text(lines[0], lineno)
        dt = nodes.term(lines[0])
        dt.source, dt.line = self.state_machine.get_source_and_line(lineno)
        node_list: list[nodes.Element] = [dt]
        for node in text_nodes:
            if not isinstance(node, nodes.Text):
                node_list[-1] += node
                continue
            parts = self.classifier_delimiter.split(node)
            if len(parts) == 1:
                node_list[-1] += node
                continue
            node_list[-1] += nodes.Text(parts[0].rstrip())
            node_list += [nodes.classifier(unescape(part, True), part) for part in parts[1:]]
        return node_list, messages


class SpecializedText(Text):
    """Superclass for second and subsequent lines of Text-variants.

    All transition methods are disabled; subclasses re-enable some.
    """

    def eof(self, context: Any) -> list:
        """Incomplete construct."""
        return []

    def invalid_input(self, match: Any = None, context: Any = None,
                      next_state: Any = None) -> Any:
        """Not a compound element member. Abort this state machine."""
        raise EOFError

    blank = indent = underline = text = invalid_input


class Definition(SpecializedText):
    """Second line of potential definition_list_item."""

    def eof(self, context: Any) -> list:
        """Not a definition."""
        self.state_machine.previous_line(2)  # so parent SM can reassess
        return []

    def indent(self, match: Any, context: Any, next_state: Any) -> tuple:
        """Definition list item."""
        dl_item, blank_finish = self.definition_list_item(context)
        self.parent += dl_item
        self.blank_finish = blank_finish
        return [], "DefinitionList", []


class Line(SpecializedText):
    """Second line of over- & underlined section title or transition marker."""

    eofcheck = 1  # ignored, will be removed in Docutils 2.0.

    def eof(self, context: Any) -> list:
        """Transition marker at end of section or document."""
        if len(context[0].strip()) < 4:
            self.state_correction(context)
        src, srcline = self.state_machine.get_source_and_line()
        transition = nodes.transition(rawsource=context[0])
        transition.source = src
        transition.line = srcline - 1
        self.parent += transition
        return []

    def blank(self, match: Any, context: Any, next_state: Any) -> tuple:
        """Transition marker."""
        src, srcline = self.state_machine.get_source_and_line()
        marker = context[0].strip()
        if len(marker) < 4:
            self.state_correction(context)
        transition = nodes.transition(rawsource=marker)
        transition.source = src
        transition.line = srcline - 1
        self.parent += transition
        return [], "Body", []

    def text(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Potential over- & underlined title."""
        lineno = self.state_machine.abs_line_number() - 1
        overline = context[0]
        title = match.string
        underline = ""
        try:
            underline = self.state_machine.next_line()
        except EOFError:
            blocktext = overline + "\n" + title
            if len(overline.rstrip()) < 4:
                self.short_overline(context, blocktext, lineno, 2)
            else:
                return self._title_error("Incomplete section title.", blocktext, lineno)
        source = "%s\n%s\n%s" % (overline, title, underline)
        overline = overline.rstrip()
        underline = underline.rstrip()
        blocktext = overline + "\n" + title + "\n" + underline
        if not self.transitions["underline"][0].match(underline):
            self._check_overline(context, blocktext, lineno)
            return self._title_error("Missing matching underline for section title overline.",
                                     source, lineno)
        if overline != underline:
            self._check_overline(context, blocktext, lineno)
            return self._title_error("Title overline & underline mismatch.", source, lineno)
        title = title.rstrip()
        messages = []
        if column_width(title) > len(overline):
            self._check_overline(context, overline + "\n" + title + "\n" + underline, lineno)
            messages.append(self.reporter.warning(
                "Title overline too short.", nodes.literal_block(source, source), line=lineno))
        self.section(title.lstrip(), source, (overline[0], underline[0]), lineno + 1, messages)
        return [], "Body", []

    indent = text  # indented title

    def _check_overline(self, context: Any, blocktext: str, lineno: int) -> None:
        """Treat a short overline of a problematic title as text."""
        if len(context[0].rstrip()) < 4:
            self.short_overline(context, blocktext, lineno, 2)

    def _title_error(self, message: str, blocktext: str, lineno: int) -> tuple:
        self.parent += self.reporter.error(message, nodes.literal_block(blocktext, blocktext),
                                           line=lineno)
        return [], "Body", []

    def underline(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        overline = context[0]
        blocktext = overline + "\n" + self.state_machine.line
        lineno = self.state_machine.abs_line_number() - 1
        if len(overline.rstrip()) < 4:
            self.short_overline(context, blocktext, lineno, 1)
        return self._title_error("Invalid section title or transition marker.", blocktext,
                                 lineno)

    def short_overline(self, context: Any, blocktext: str, lineno: int, lines: int = 1) -> None:
        self.parent += self.reporter.info(
            "Possible incomplete section title.\nTreating the overline as "
            "ordinary text because it's so short.", line=lineno)
        self.state_correction(context, lines)

    def state_correction(self, context: Any, lines: int = 1) -> None:
        self.state_machine.previous_line(lines)
        context[:] = []
        raise statemachine.StateCorrection("Body", "text")


class QuotedLiteralBlock(RSTState):
    """Nested parse handler for quoted (unindented) literal blocks.

    Special-purpose.  Not for inclusion in `state_classes`.
    """

    patterns = {"initial_quoted": r"(%(nonalphanum7bit)s)" % Body.pats, "text": r""}
    initial_transitions = ("initial_quoted", "text")

    def __init__(self, state_machine: Any, debug: bool = False) -> None:
        RSTState.__init__(self, state_machine, debug)
        self.messages: list[nodes.system_message] = []
        self.initial_lineno: int | None = None

    def blank(self, match: Any, context: Any, next_state: Any) -> tuple:
        if context:
            raise EOFError
        return context, next_state, []

    def eof(self, context: Any) -> list:
        if context:
            src, srcline = self.state_machine.get_source_and_line(self.initial_lineno)
            text = "\n".join(context)
            literal_block = nodes.literal_block(text, text)
            literal_block.source = src
            literal_block.line = srcline
            self.parent += literal_block
        else:
            # no source line: the machine's input is empty
            self.parent += self.reporter.warning("Literal block expected; none found.",
                                                 line=self.state_machine.abs_line_number())
            self.state_machine.previous_line()
        self.parent += self.messages
        return []

    def indent(self, match: Any, context: Any, next_state: Any) -> Any:
        assert context, "QuotedLiteralBlock.indent: context should not be empty!"
        self.messages.append(self.reporter.error(
            "Unexpected indentation.", line=self.state_machine.abs_line_number()))
        self.state_machine.previous_line()
        raise EOFError

    def initial_quoted(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Match arbitrary quote character on the first line only."""
        self.remove_transition("initial_quoted")
        pattern = re.compile(re.escape(match.string[0]))
        # further lines must use the same quote character
        self.add_transition("quoted", (pattern, self.quoted, self.__class__.__name__))
        self.initial_lineno = self.state_machine.abs_line_number()
        return [match.string], next_state, []

    def quoted(self, match: re.Match[str], context: Any, next_state: Any) -> tuple:
        """Match consistent quotes on subsequent lines."""
        context.append(match.string)
        return context, next_state, []

    def text(self, match: re.Match[str], context: Any, next_state: Any) -> Any:
        if context:
            self.messages.append(self.reporter.error(
                "Inconsistent literal block quoting.",
                line=self.state_machine.abs_line_number()))
            self.state_machine.previous_line()
        raise EOFError


state_classes = (Body, BulletList, DefinitionList, EnumeratedList, FieldList, OptionList,
                 LineBlock, ExtensionOptions, Explicit, Text, Definition, Line, SubstitutionDef,
                 RFC2822Body, RFC2822List)
"""Standard set of State classes used to start `RSTStateMachine`."""


# --- choosing the parser ------------------------------------------------------------------

_STOCK_CLASSES = state_classes
_STOCK_STATES = {cls.__name__: cls for cls in state_classes}
_SNAPSHOT = Snapshot([
    *state_classes, SpecializedBody, SpecializedText, QuotedLiteralBlock, RSTState,
    BodyHelpers, ExplicitHelpers, StateWS, statemachine.State, Inliner])


def _stock_classes(classes: Any) -> bool:
    """Whether `classes` are the stock state classes (in any order)."""
    if classes is _STOCK_CLASSES:
        return True
    try:
        return {cls.__name__: cls for cls in classes} == _STOCK_STATES
    except (TypeError, AttributeError):
        return False


def python_parser_needed(classes: Any, initial_state: str, inliner: Any = None) -> bool:
    """Whether a document parse with these state classes, initial state and
    inliner needs the Python state machine (see `docodin._grammar`)."""
    if python_forced() or initial_state not in ("Body", "RFC2822Body"):
        return True
    if inliner is not None and type(inliner) is not Inliner and not getattr(
            inliner, "docodin_native", False):
        return True
    if not _stock_classes(classes) or state_classes is not _STOCK_CLASSES:
        return True
    return _SNAPSHOT.grammar_changed()


def _replacement(cls: type, name: str) -> Any:
    """An extension's replacement of the stock method ``cls.name``, or None."""
    method = getattr(cls, name)
    return None if method is _SNAPSHOT.original(cls, name) else method
