"""``include`` insertions: lines ``state_machine.insert_input()`` adds to the input.

docutils parses inserted lines in the state machine that ran the directive,
as part of its input.  The native parser gets the same behaviour through its
include hook (`IncludeHook`): when it meets a directive, the hook dry-runs the
``include`` directive (docutils' own class, without side effects) and returns
the lines it would insert; the parser inserts them and parses on, and the
hook inserts them into the host's input lines at the same place, so line
lookups stay in step.  When the builder runs the directive for real, its
``insert_input`` is skipped.

Nested parses (directive content) end before the enclosing parse goes on, so
their insertions are removed again afterwards (`remove_insertions`) and
restored for transforms at the end (`restore_insertions`), like the
insertions of directives the hook cannot dry-run (``include`` subclasses,
e.g. Sphinx's), which are parsed separately (`process_inserted_input`).
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from docutils import nodes
from docutils.parsers.rst import DirectiveError, directives
from docutils.parsers.rst.directives import misc
from docutils.parsers.rst.states import MarkupError
from docutils.statemachine import StringList

from docodin._machine import OdinBody, OdinStateMachine, _make_state, _parse_option_fields

if TYPE_CHECKING:
    from docodin.builder import DocumentContext


class _NotDry(Exception):
    """The dry run would have side effects (option names with inline markup)."""


class _DryBody(OdinBody):
    """``Body`` state of a dry run: option names are never inline-parsed."""

    def parse_extension_options(self, option_spec, datalines):
        if _parse_option_fields(datalines) is None:
            raise _NotDry
        return super().parse_extension_options(option_spec, datalines)


def _canonical_include(ctx: DocumentContext, name: str) -> bool:
    """Is ``name`` the ``include`` directive of the document's language (found
    without lookup messages)?"""
    table = getattr(ctx.language, "directives", None) or {}
    if table.get(name.lower()) != "include":
        return False
    directive_class, _messages = directives.directive(name, ctx.language, ctx.document)
    return directive_class is misc.Include


class IncludeHook:
    """The native parser's include hook for a parse of ``sm``'s input lines."""

    def __init__(self, ctx: DocumentContext, sm: OdinStateMachine) -> None:
        self.ctx = ctx
        self.sm = sm
        # (index in sm.input_lines, number of lines) in insertion order
        self.inserted: list[tuple[int, int]] = []
        # ``document.include_log`` as the parser sees it: entries with the
        # index of their end-of-inclusion comment (None: before this parse)
        log = getattr(ctx.document, "include_log", None) or []
        self.log: list[list[Any]] = [[entry, None] for entry in log]

    def line_count(self) -> int:
        """The number of lines inserted."""
        return sum(count for _at, count in self.inserted)

    def __call__(self, item: tuple) -> list[str] | None:
        # (K, line, name, block_text, lines, line_offset, end_offset, blank_finish,
        #  reporter_line, inserted)
        if not _canonical_include(self.ctx, item[2]):
            return None
        sm = self.sm
        index = item[6] - sm.input_offset  # the directive's last line
        captured = self._dry_run(item, index)
        if not captured:
            return None
        textlines, source = captured[0]
        self._note_insertion(index + 1, len(textlines) + 2)
        saved = sm.line_offset
        sm.line_offset = index
        OdinStateMachine.insert_input(sm, textlines, source)
        sm.line_offset = saved
        return textlines

    def _dry_run(self, item: tuple, index: int) -> list:
        """Run ``Include`` without side effects: the ``insert_input`` calls."""
        ctx, sm = self.ctx, self.sm
        document = ctx.document
        saved = (document.current_source, document.current_line, sm.line_offset,
                 getattr(document, "include_log", None))
        _, lineno, name, block_text, lines, line_offset, end_offset = item[:7]
        captured: list = []
        try:
            document.current_source, document.current_line = sm.srcline(end_offset + 1)
            sm.line_offset = index
            state = _make_state(_DryBody, sm)
            block = ctx.builder._block_lines(sm, lines, line_offset)
            arguments, options, content, content_offset = state.parse_directive_block(
                block, line_offset, misc.Include, {})
            if {"literal", "code", "parser"} & options.keys():
                return []  # no insertion; the run would create (and register) nodes
            document.include_log = [entry for entry, end in self.log
                                    if end is None or end >= index]
            logged = len(document.include_log)
            ctx.capture_insert = captured
            misc.Include(name, arguments, options, content, lineno, content_offset,
                         block_text, state, sm).run()
            if captured:
                self._note_log(document.include_log[logged:])
        except (DirectiveError, MarkupError, _NotDry):
            captured = []
        finally:
            ctx.capture_insert = None
            (document.current_source, document.current_line, sm.line_offset,
             document.include_log) = saved
        return captured

    def _note_log(self, added: list) -> None:
        """Log entries of a successful dry run; the included file's entry ends
        at its end-of-inclusion comment, the document's first entry never."""
        for entry in added[:-1]:
            self.log.append([entry, None])
        if added:
            self.log.append([added[-1], "pending"])

    def _note_insertion(self, at: int, count: int) -> None:
        """``count`` lines inserted at ``at``: later ends move down; the newest
        log entry ends at the inserted end-of-inclusion comment."""
        for entry in self.log:
            if isinstance(entry[1], int) and entry[1] >= at:
                entry[1] += count
        if self.log and self.log[-1][1] == "pending":
            self.log[-1][1] = at + count - 2
        self.inserted.append((at, count))


def remove_insertions(ctx: DocumentContext, sm: OdinStateMachine, hook: IncludeHook) -> None:
    """Drop the lines the hook inserted into a nested parse's input (the
    enclosing parse numbers its lines without them); ``restore_insertions``
    puts them back at the end."""
    lines = sm.input_lines
    # insertions into a list the document's input lines do not see
    # (``disconnect()``-ed blocks: table cells) leave its numbering alone
    connected = _reaches(lines, ctx.top_sm._input_lines if ctx.top_sm is not None else None)
    for at, count in reversed(hook.inserted):
        block = lines[at:at + count]
        if connected:
            ctx.insertions.append(
                (sm.input_offset + at, StringList(list(block.data), items=list(block.items))))
            ctx.last_removal_top = False
            ctx.removed_lines += count
        # item by item: ``ViewList.__delitem__`` with a slice deletes twice
        # when the list has a parent (docutils bug)
        for _ in range(count):
            del lines[at]


def _reaches(lines: StringList, top: StringList | None) -> bool:
    """Do insertions into ``lines`` reach ``top`` (through parent views)?"""
    while lines is not None:
        if lines is top:
            return True
        lines = lines.parent if lines.parent else None
    return False


def process_inserted_input(ctx: DocumentContext, sm: OdinStateMachine, start: int,
                           count: int) -> None:
    """Parse ``count`` lines ``insert_input()`` put after the directive ``sm``
    ran (where the hook could not dry-run it), then drop them again so that
    absolute line offsets of the remaining (already parsed) input stay valid."""
    input_lines = sm._input_lines
    # A connected slice: nested insertions (includes inside the included
    # text) propagate to the parent lists, as in docutils, so reporter line
    # lookups keep working; they are removed again the same way.
    inserted = input_lines[start:start + count]
    child = OdinStateMachine(ctx, inserted, sm.input_offset + start, sm.node,
                             sm.match_titles, parent_sm=sm.parent_state_machine)
    child.section_level_offset = sm.section_level_offset
    remove_insertions(ctx, child, ctx.parse_lines(child, inserted, sm.match_titles))
    if sm.match_titles:
        sm.node = child.node
    # recorded in removal order, without the (already removed) nested insertions
    ctx.insertions.append(
        (sm.input_offset + start, StringList(list(inserted.data), items=list(inserted.items))))
    ctx.last_removal_top = sm is ctx.top_sm
    for _ in range(count):
        del input_lines[start]
    ctx.removed_lines += count


def restore_insertions(ctx: DocumentContext, sm: OdinStateMachine) -> None:
    """Give transforms docutils' view of the input after removed insertions.

    docutils keeps inserted lines in ``input_lines``, so absolute line
    numbers after an insertion grow by its length.  Removed insertions go
    back into the input lines (latest removal first: each offset was taken
    with the later-removed enclosing blocks present and the earlier-removed
    ones absent) and nodes that only carry an absolute line are renumbered.
    """
    lines = sm.input_lines
    for offset, block in reversed(ctx.insertions):
        lines.insert(offset - sm.input_offset, block)
    for node, removed in ctx.absolute_lines.values():
        if node.line is not None:
            node.line += removed
    ctx.insertions = []
    ctx.absolute_lines = {}


def note_line(document: nodes.document, lines: StringList, index: int) -> None:
    """``document.note_source`` of the line at ``index`` of ``lines`` (a state
    machine's cursor move)."""
    try:
        source, offset = lines.info(index)
    except IndexError:
        source, offset = None, None
    document.current_source = source
    document.current_line = None if offset is None else offset + 1


def ends_with_insertion(lines: StringList) -> bool:
    """The last input line is the padding ``insert_input()`` puts after an insertion."""
    source = lines.info(len(lines) - 1)[0] if len(lines) else None
    return bool(source) and source.startswith("internal padding after ")


def note_directive_lines(ctx: DocumentContext, result: list, directive_class: type,
                         content_offset: int, removed: int) -> None:
    """Directive nodes without a source carry an absolute line, and so does
    ``parsed-literal``'s block (``content_offset + 1``); they got it with
    ``removed`` lines removed (before the directive's nested parses)."""
    from docutils.parsers.rst.directives import body

    for node in result:
        for n in node.findall(nodes.Element):
            if n.source is None and n.line is not None:
                ctx.note_absolute_line(n, removed)
    if (issubclass(directive_class, body.ParsedLiteral) and result
            and isinstance(result[0], nodes.literal_block)
            and result[0].line == content_offset + 1):
        ctx.note_absolute_line(result[0], removed)


__all__ = [
    "IncludeHook",
    "ends_with_insertion",
    "note_line",
    "note_directive_lines",
    "process_inserted_input",
    "remove_insertions",
    "restore_insertions",
]
