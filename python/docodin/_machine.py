"""docutils-compatible state machine, states and inliner of the native builder.

The native parser has already recognized the markup, so `OdinStateMachine` is never
run line by line; it gives directives, roles and extensions the complete
``StateMachineWS``/``RSTState`` interface, and routes their nested parses back to
the native parser (see `docodin.builder.nested_parse`).
"""

from __future__ import annotations

import re
from typing import TYPE_CHECKING, Any

from docutils import nodes, statemachine, utils
from docutils.parsers.rst import states
from docutils.parsers.rst.states import Inliner
from docutils.statemachine import StringList

if TYPE_CHECKING:
    from docodin.builder import DocumentContext

# Option names that are plain text when inline-parsed (docutils extracts
# ``field_name.astext()``); an underscore may end a reference (``alt_``).
_SIMPLE_OPTION_NAME = re.compile(r"[A-Za-z0-9.+-]+\Z")



class OdinStateMachine(statemachine.StateMachineWS):
    """A docutils state machine over a (nested) block of input lines.

    It is not *run* line by line — the native parser did that — but it exposes
    the full ``StateMachineWS`` interface to directives: ``input_lines``,
    ``input_offset``, ``line_offset``, ``get_source_and_line()``,
    ``insert_input()``, ``node``, ``memo``, ``match_titles`` ...
    """

    def __init__(self, ctx: DocumentContext, input_lines: StringList | None, input_offset: int,
                 node: nodes.Element, match_titles: bool, parent_sm: Any = None,
                 lazy_text: str | None = None, lines_owner: OdinStateMachine | None = None) -> None:
        # Deliberately not calling StateMachine.__init__(): it instantiates and
        # compiles every state class, which is the cost we avoid.
        self.ctx = ctx
        self._input_lines = input_lines
        self._lazy_text = lazy_text
        # Views of an enclosing parse (nested containers, table cells,
        # substitution definitions) share its input lines.
        self._lines_owner = lines_owner
        self.input_offset = input_offset
        self.line_offset = -1
        self.line = None
        self.node = node
        self.memo = ctx.memo
        self.document = ctx.document
        self.reporter = ctx.reporter
        self.language = ctx.language
        self.match_titles = match_titles
        self.parent_state_machine = parent_sm
        self.section_level_offset = 0
        # source line minus absolute line (docutils quirks: table cells -1,
        # substitution definitions spanning lines); see odin/rst/statemachine.odin
        self.line_delta = 0
        self.debug = False
        self.observers = []
        self.states = {}
        self.initial_state = "Body"
        self.current_state = "Body"
        self._state: Any = None
        # Fast path for get_source_and_line when input_lines map 1:1 to a source.
        self._linear_source = ctx.source if input_lines is None else None

    # input_lines is materialized on first use for top-level string input
    @property
    def input_lines(self) -> StringList:
        lines = self._input_lines
        if lines is None:
            owner = self._lines_owner
            if owner is not None:
                lines = owner.input_lines
            else:
                lines = self.ctx.make_input_lines(self._lazy_text)
            self._input_lines = lines
        return lines

    @input_lines.setter
    def input_lines(self, value: StringList) -> None:
        if value is not self._input_lines:
            self._linear_source = None
        self._input_lines = value

    def _is_linear(self) -> bool:
        """Top-level string input whose lines map 1:1 to the source (no
        pending ``insert_input`` lines)."""
        if self._linear_source is None:
            return False
        lines = self._input_lines
        if lines is None and self._lines_owner is not None:
            lines = self._lines_owner._input_lines
        return lines is None or len(lines) == self.ctx.line_count

    def get_source_and_line(self, lineno: int | None = None):
        # docutils looks the line up in the machine's own ``input_lines``,
        # whose items carry source offsets: ``line_delta`` maps this machine's
        # absolute numbering to those (table cells, substitution definitions)
        if lineno is None:
            lineno = self.line_offset + self.input_offset + 1
        lineno += self.line_delta
        if self._is_linear():
            if 1 <= lineno <= self.ctx.line_count + 1:  # n + 1: just past the end
                return self._linear_source, lineno
            return None, None
        return super().get_source_and_line(lineno)

    def srcline(self, lineno: int):
        """(source, line) for node attributes (``get_source_and_line``)."""
        if self._is_linear():
            return self._linear_source, lineno + self.line_delta
        try:
            return self.get_source_and_line(lineno)
        except Exception:  # noqa: BLE001 - never fail node construction
            return self.ctx.source, lineno + self.line_delta

    def state(self) -> OdinBody:
        st = self._state
        if st is None:
            st = self._state = _make_state(OdinBody, self)
        return st

    def run(self, *args: Any, **kwargs: Any) -> Any:  # pragma: no cover - not line-driven
        raise NotImplementedError("OdinStateMachine is not run line by line")

    def unlink(self) -> None:
        self.observers = []


def _make_state(cls: type, sm: OdinStateMachine) -> Any:
    st = cls.__new__(cls)
    st.state_machine = sm
    st.debug = False
    st.transitions = {}
    st.transition_order = []
    st.nested_sm = states.NestedStateMachine
    st.nested_sm_kwargs = {"state_classes": states.state_classes, "initial_state": "Body"}
    st.indent_sm = st.known_indent_sm = states.NestedStateMachine
    st.indent_sm_kwargs = st.known_indent_sm_kwargs = st.nested_sm_kwargs
    st.memo = sm.memo
    st.document = sm.document
    st.inliner = sm.memo.inliner
    st.reporter = sm.reporter
    st.blank_finish = True
    return st


class _OdinStateMixin:
    """Overrides of ``RSTState`` methods that route parsing to the native parser."""

    state_machine: OdinStateMachine

    def nested_parse(self, block, input_offset, node=None, match_titles=False,
                     state_machine_class=None, state_machine_kwargs=None):
        if state_machine_class is not None or state_machine_kwargs is not None:
            return states.RSTState.nested_parse(self, block, input_offset, node, match_titles,
                                                state_machine_class, state_machine_kwargs)
        from docodin.builder import nested_parse

        return nested_parse(self, block, input_offset, node, match_titles)

    def nested_list_parse(self, block, input_offset, node, initial_state, blank_finish,
                          blank_finish_state=None, extra_settings={}, match_titles=False,  # noqa: B006
                          state_machine_class=None, state_machine_kwargs=None):
        # Custom list states (e.g. MetaBody) run on docutils' own machinery.
        return states.RSTState.nested_list_parse(
            self, block, input_offset, node, initial_state, blank_finish, blank_finish_state,
            extra_settings, match_titles, state_machine_class, state_machine_kwargs)

    def inline_text(self, text, lineno):
        return self.state_machine.ctx.inline(text, lineno, self.state_machine.node)

    def parse_extension_options(self, option_spec, datalines):
        """Fast path of ``Body.parse_extension_options`` (``ExtensionOptions`` state)."""
        parsed = _parse_option_fields(datalines)
        if parsed is None:
            return states.Body.parse_extension_options(self, option_spec, datalines)
        node, complete, blank_finish, stop = parsed
        # docutils parses the block in a nested state machine: it runs to the
        # end of its input (the document's current line becomes undefined) or
        # steps back from the first line that is not an option
        document = self.state_machine.document
        items = getattr(datalines, "items", None)
        if items:
            if complete:
                document.current_source, document.current_line = items[-1][0], None
            else:
                source, offset = items[stop - 1]  # Python indexing, like info()
                document.current_source, document.current_line = source, offset + 1
        if not complete:
            return 0, "invalid option block"
        try:
            options = utils.extract_extension_options(node, option_spec)
        except KeyError as detail:
            return 0, 'unknown option: "%s"' % detail.args[0]
        except (ValueError, TypeError) as detail:
            return 0, "invalid option value: %s" % " ".join(detail.args)
        except utils.ExtensionOptionError as detail:
            return 0, "invalid option data: %s" % " ".join(detail.args)
        if blank_finish:
            return 1, options
        return 0, "option data incompletely parsed"


class OdinBody(_OdinStateMixin, states.Body):
    """``Body`` state used as ``self.state`` by directives."""


class OdinSubstitutionDef(_OdinStateMixin, states.SubstitutionDef):
    """``SubstitutionDef`` state for directives embedded in substitution definitions."""


_FIELD_MARKER = re.compile(states.Body.patterns["field_marker"])


def _parse_option_fields(datalines):
    """Run the ``ExtensionOptions`` state over directive option lines.

    Returns (field_list, parsed_completely, blank_finish, stop_index), or
    ``None`` when a field name needs inline parsing (handled by the docutils
    fallback).  ``stop_index`` is the first line not in the field list.
    """
    field_list = nodes.field_list()
    lines = list(datalines)
    n = len(lines)
    i = 0
    blank_finish = True
    while i < n:
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        match = None if line[0] == " " else _FIELD_MARKER.match(line)
        if not match:
            return field_list, False, blank_finish, i
        name = match.group()[1:]
        name = name[: name.rfind(":")]
        if not _SIMPLE_OPTION_NAME.match(name):
            return None
        end, indent, blank_finish = _indented_block(lines, i + 1)
        body = [line[match.end():]] + [ln[indent:] if indent else ln for ln in lines[i + 1:end]]
        field_list += _option_field(name, body)
        i = end
    return field_list, True, blank_finish, n


def _indented_block(lines: list[str], start: int) -> tuple[int, int | None, bool]:
    """``get_first_known_indented``: (end index, common indent, blank_finish)."""
    end = start
    indent = None
    while end < len(lines):
        ln = lines[end]
        if ln and ln[0] != " ":
            return end, indent, not lines[end - 1].strip()
        stripped = ln.lstrip()
        if stripped:
            li = len(ln) - len(stripped)
            indent = li if indent is None else min(indent, li)
        end += 1
    return end, indent, True


def _option_field(name: str, body: list[str]) -> nodes.field:
    """A field whose body paragraphs hold the plain option text."""
    while body and not body[0].strip():
        body.pop(0)
    field = nodes.field()
    field += nodes.field_name(name, name)
    field_body = nodes.field_body()
    field += field_body
    para: list[str] = []
    for ln in [*body, ""]:
        if ln.strip():
            para.append(ln)
        elif para:
            text = "\n".join(para)
            field_body += nodes.paragraph(text, text)
            para = []
    return field


class OdinInliner(Inliner):
    """docutils ``Inliner`` whose ``parse()`` uses the native inline parser.

    ``interpreted()``/``problematic()``/``adjust_uri()`` are inherited, so roles
    receive a genuine ``Inliner`` instance.
    """

    ctx: DocumentContext | None = None
    docodin_native = True  # parses natively: no reason to leave the native engine

    def parse(self, text, lineno, memo, parent):
        self.document = memo.document
        self.language = memo.language
        self.reporter = self.document.reporter
        self.parent = parent
        ctx = self.ctx
        if ctx is None:
            return super().parse(text, lineno, memo, parent)
        return ctx.inline(text, lineno, parent)


# ``Inliner.init_customizations`` formats its regular expressions with
# ``vars(self.__class__)`` (the class' *own* namespace), so a subclass must
# carry the pattern fragments of ``Inliner`` itself.
for _name, _value in vars(Inliner).items():
    if isinstance(_value, str) and not _name.startswith("__"):
        setattr(OdinInliner, _name, _value)
del _name, _value


# The shim's states know their stock methods (a snapshot taken when the module
# loads) and can hand natively built nodes to a replacement that wraps them;
# docutils' own states would parse the input again.
_REPLACEMENT = getattr(states, "_replacement", None)


def patched_transition(cls: type, name: str) -> Any:
    """An extension's replacement of the transition method ``cls.name``, or None
    (sphinx-autodoc-typehints replaces ``Body.doctest`` and wraps ``Text.indent``)."""
    if _REPLACEMENT is None:
        return None
    return _REPLACEMENT(cls, name)


def replay_transition(method: Any, cls: type, sm: OdinStateMachine, parent: nodes.Element,
                      start: int, lineno: int, lines: list[str], pattern: str,
                      context: list[str]) -> None:
    """Run ``method``, a replaced transition of state ``cls``, for the construct the
    native parser built into ``parent[start:]``, with the state machine on its
    (dedented) ``lines`` from absolute line ``lineno`` like docutils; a wrapped
    original adds the built nodes back."""
    built = parent.children[start:]
    del parent[start:]
    source, line = sm.srcline(lineno)
    line = lineno if line is None else line
    block = StringList(lines, items=[(source, line - 1 + i) for i in range(len(lines))])
    machine = OdinStateMachine(sm.ctx, block, line - 1, parent, False, parent_sm=sm)
    machine.line_offset = 0
    machine.line = lines[0] if lines else ""
    state = _make_state(cls, machine)
    state._docodin_replay = built
    method(state, re.match(pattern, machine.line), context, "Body")
