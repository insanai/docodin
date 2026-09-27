"""Docutils statemachine drop-in implementation for docodin."""

from __future__ import annotations

import re
import sys
from typing import Any, Iterator, Sequence

_WHITESPACE = re.compile(r"[\x00\x09-\x0d ]")


def string2lines(
    astring: str,
    tab_width: int = 8,
    convert_whitespace: bool = False,
    whitespace: re.Pattern[str] = _WHITESPACE,
) -> list[str]:
    """Convert an input string into a list of lines, expanding tabs.

    Delegates to the native Odin line splitter engine for high-performance
    tab expansion and Unicode newline normalization.

    Args:
        astring: Input string to split into lines.
        tab_width: Number of spaces for tab expansion. Defaults to 8.
        convert_whitespace: Whether to convert form feeds and other whitespace to space. Defaults to False.
        whitespace: Regex pattern matching whitespace to convert. Defaults to _WHITESPACE.

    Returns:
        List of expanded line strings.
    """
    if not astring:
        return []
    try:
        from docodin._native import native
        return native().split_lines(astring, tab_width)
    except Exception:
        if convert_whitespace:
            astring = whitespace.sub(" ", astring)
        if tab_width > 0:
            lines = [line.expandtabs(tab_width) for line in astring.splitlines()]
        else:
            lines = astring.splitlines()
        return lines


class StringList:
    """A list of strings with associated source and line number info.

    Attributes:
        source: Default source identifier.
        parent: Parent StringList instance if this is a slice or view.
        parent_offset: Offset within parent StringList.
        data: Underlying list of string lines.
        items: List of tuples containing line and (source, offset) pairs.
    """

    def __init__(
        self,
        initlist: Sequence[str] | None = None,
        source: str | None = None,
        items: list[tuple[str, tuple[str | None, int]]] | None = None,
        parent: StringList | None = None,
        parent_offset: int = 0,
    ) -> None:
        self.source = source
        self.parent = parent
        self.parent_offset = parent_offset
        if items is not None:
            self.data = [item[0] for item in items]
            self.items = list(items)
        elif initlist is not None:
            self.data = list(initlist)
            self.items = [(line, (source, i)) for i, line in enumerate(self.data)]
        else:
            self.data = []
            self.items = []

    def __len__(self) -> int:
        return len(self.data)

    def __getitem__(self, i: int | slice) -> Any:
        if isinstance(i, slice):
            return StringList(items=self.items[i], source=self.source, parent=self)
        return self.data[i]

    def __setitem__(self, i: int, value: str) -> None:
        self.data[i] = value
        info = self.items[i][1] if i < len(self.items) else (self.source, i)
        self.items[i] = (value, info)

    def __delitem__(self, i: int | slice) -> None:
        del self.data[i]
        del self.items[i]

    def __iter__(self) -> Iterator[str]:
        return iter(self.data)

    def __contains__(self, item: str) -> bool:
        return item in self.data

    def __repr__(self) -> str:
        return repr(self.data)

    def __str__(self) -> str:
        return str(self.data)

    def append(self, item: str, source: str | None = None, offset: int = 0) -> None:
        self.data.append(item)
        src = source if source is not None else self.source
        self.items.append((item, (src, offset)))

    def extend(self, other: Any) -> None:
        if isinstance(other, StringList):
            self.data.extend(other.data)
            self.items.extend(other.items)
        else:
            for line in other:
                self.append(line)

    def insert(self, i: int, item: str, source: str | None = None, offset: int = 0) -> None:
        self.data.insert(i, item)
        src = source if source is not None else self.source
        self.items.insert(i, (item, (src, offset)))

    def pop(self, i: int = -1) -> str:
        self.items.pop(i)
        return self.data.pop(i)

    def count(self, item: str) -> int:
        return self.data.count(item)

    def index(self, item: str) -> int:
        return self.data.index(item)

    def info(self, i: int) -> tuple[str | None, int]:
        if 0 <= i < len(self.items):
            return self.items[i][1]
        return (self.source, i)

    def source(self, i: int) -> str | None:
        return self.info(i)[0]

    def line(self, i: int) -> int:
        return self.info(i)[1]

    def pprint(self) -> str:
        return "\n".join(f"{line} {info}" for line, info in self.items)

    def trim_left(self, length: int, start: int = 0, end: int = sys.maxsize) -> None:
        end = min(end, len(self.data))
        for i in range(start, end):
            line = self.data[i]
            if line:
                self.data[i] = line[length:]
                self.items[i] = (self.data[i], self.items[i][1])

    def get_indented(
        self,
        start: int = 0,
        until_blank: bool = False,
        strip_indent: bool = True,
        block_indent: int | None = None,
        first_indent: int | None = None,
    ) -> tuple[StringList, int, int, bool]:
        """Extract an indented block of lines starting from a line index.

        Args:
            start: Starting line index. Defaults to 0.
            until_blank: Stop at first blank line if True. Defaults to False.
            strip_indent: Remove common leading indent if True. Defaults to True.
            block_indent: Expected indentation width. Defaults to None.
            first_indent: Indentation width of first line. Defaults to None.

        Returns:
            Tuple of (indented_string_list, indent_width, end_index, blank_finish).
        """
        if start >= len(self.data):
            return StringList(source=self.source), 0, start, True
        indent = None
        end = start
        blank_finish = False
        while end < len(self.data):
            line = self.data[end]
            if not line.strip():
                if until_blank:
                    blank_finish = True
                    break
                end += 1
                continue
            line_indent = len(line) - len(line.lstrip(" "))
            if indent is None:
                indent = line_indent
                if block_indent is not None and indent < block_indent:
                    break
            elif line_indent < (block_indent if block_indent is not None else indent):
                break
            end += 1
        indented_items = self.items[start:end]
        indented = StringList(items=indented_items, source=self.source, parent=self)
        if strip_indent and indent:
            indented.trim_left(indent)
        return indented, indent or 0, end, blank_finish

    def disconnect(self) -> None:
        self.parent = None


ViewList = StringList


class State:
    def __init__(self, state_machine: StateMachine, debug: bool = False) -> None:
        self.state_machine = state_machine
        self.debug = debug

    def unlink(self) -> None:
        self.state_machine = None  # type: ignore[assignment]


class StateMachine:
    def __init__(self, state_classes: Sequence[type] | None = None, initial_state: str | None = None, debug: bool = False) -> None:
        self.state_classes = state_classes or []
        self.initial_state = initial_state
        self.debug = debug
        self.states: dict[str, State] = {}

    def run(self, input_lines: Sequence[str] | StringList, input_offset: int = 0, **kwargs: Any) -> list[Any]:
        return []

    def unlink(self) -> None:
        self.states.clear()


class StateMachineWS(StateMachine):
    pass


class StateWS(State):
    pass


class SearchStateMachine(StateMachine):
    pass
