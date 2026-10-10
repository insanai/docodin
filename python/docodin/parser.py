"""docutils-compatible reStructuredText parser backed by the native engine."""

from __future__ import annotations

from typing import Any

import docutils.parsers.rst
import docutils.statemachine
from docutils.parsers.rst import roles, states
from docutils.statemachine import StringList

from docodin._grammar import Snapshot, python_forced
from docodin.builder import OdinInliner, parse_string, parse_string_list

_ORIGINAL_PARSE = docutils.parsers.rst.Parser.parse
_ORIGINAL_RUN = states.RSTStateMachine.run


# The stock states of an installed docutils as they were when docodin.parser was
# imported (docodin's own docutils keeps its snapshot in ``states``).
_STOCK_SNAPSHOT = None if hasattr(states, "python_parser_needed") else Snapshot([
    *states.state_classes, states.SpecializedBody, states.SpecializedText,
    states.QuotedLiteralBlock, states.RSTState, docutils.statemachine.StateWS,
    docutils.statemachine.State, states.Inliner])


def _supported(state_classes: Any, inliner: Any, initial_state: str = "Body") -> bool:
    """Whether the native engine can stand in for this parser configuration.

    Custom state classes, a custom ``Inliner`` subclass (extra inline
    patterns), patched stock states and ``DOCODIN_NATIVE=0`` keep the
    pure-Python docutils parser, as in docodin's own docutils (`docodin._grammar`).
    """
    if _STOCK_SNAPSHOT is None:
        classes = states.state_classes if state_classes is None else state_classes
        return not states.python_parser_needed(classes, initial_state, inliner)
    if python_forced() or initial_state not in ("Body", "RFC2822Body"):
        return False
    if state_classes is not None and tuple(state_classes) != tuple(states.state_classes):
        return False
    if inliner is not None and type(inliner) not in (states.Inliner, OdinInliner):
        return False
    return not _STOCK_SNAPSHOT.grammar_changed()


class Parser(docutils.parsers.rst.Parser):
    """Drop-in replacement for :class:`docutils.parsers.rst.Parser`.

    Usable wherever docutils accepts a parser instance or name, e.g.
    ``docutils.core.publish_string(src, parser=docodin.Parser())`` or
    ``rst2html --parser=docodin``.
    """

    def parse(self, inputstring: str | StringList, document: Any) -> None:
        """Parse source text or StringList into a document tree using DocOdin.

        Args:
            inputstring: Source markup text or pre-split StringList.
            document: Target docutils document tree.
        """
        if not _supported(self.state_classes, self.inliner, self.initial_state):
            return _ORIGINAL_PARSE(self, inputstring, document)
        self.setup_parse(inputstring, document)
        document.settings.setdefault("tab_width", 8)
        document.settings.setdefault("syntax_highlight", "long")
        rfc2822 = self.initial_state == "RFC2822Body"
        if isinstance(inputstring, str):
            parse_string(inputstring, document, self.inliner, rfc2822=rfc2822)
        else:
            if not isinstance(inputstring, StringList):
                inputstring = StringList(list(inputstring), document.get("source", ""))
            parse_string_list(inputstring, document, self.inliner, rfc2822=rfc2822)
        # restore the "default" default role after parsing a document
        if "" in roles._roles:
            del roles._roles[""]
        self.finish_parse()


def _patched_parse(self: Any, inputstring: Any, document: Any) -> None:
    return Parser.parse(self, inputstring, document)


def _patched_run(self: Any, input_lines: Any, document: Any, input_offset: int = 0,
                 match_titles: bool = True, inliner: Any = None) -> None:
    """Replacement for ``RSTStateMachine.run`` (used e.g. by Sphinx's parser)."""
    state_classes = [type(s) for s in self.states.values()] if getattr(self, "states", None) else None
    if (state_classes is not None and set(state_classes) != set(states.state_classes)) \
            or not _supported(None, inliner, getattr(self, "initial_state", "Body")):
        return _ORIGINAL_RUN(self, input_lines, document, input_offset, match_titles, inliner)
    if not isinstance(input_lines, StringList):
        input_lines = StringList(list(input_lines), document.get("source", ""))
    rfc2822 = getattr(self, "initial_state", "Body") == "RFC2822Body"
    parse_string_list(input_lines, document, inliner, input_offset, match_titles, rfc2822=rfc2822)
    self.node = self.memo = None
    return None


_patched = False


def patch_docutils() -> None:
    """Make docutils (and everything built on it) parse reST with docodin.

    Replaces ``docutils.parsers.rst.Parser.parse`` and
    ``docutils.parsers.rst.states.RSTStateMachine.run`` process-wide.
    """
    global _patched
    if _patched:
        return
    docutils.parsers.rst.Parser.parse = _patched_parse
    states.RSTStateMachine.run = _patched_run
    _patched = True


def unpatch_docutils() -> None:
    """Undo :func:`patch_docutils`."""
    global _patched
    docutils.parsers.rst.Parser.parse = _ORIGINAL_PARSE
    states.RSTStateMachine.run = _ORIGINAL_RUN
    _patched = False


def is_patched() -> bool:
    """Check whether docutils has been globally patched with DocOdin.

    Returns:
        True if docutils is currently monkeypatched, False otherwise.
    """
    return _patched
