"""Finite state machine for line-oriented input, and the `StringList` input list.

reStructuredText itself is parsed by docodin's native engine; these classes
serve directives and extensions that drive their own state machines and use
``StringList``/``ViewList`` for source bookkeeping.
"""

from __future__ import annotations

import re
import sys
from collections.abc import Iterator
from typing import Any
from unicodedata import east_asian_width

__docformat__ = "restructuredtext"


class StateMachineError(Exception):
    pass


class UnknownStateError(StateMachineError):
    pass


class DuplicateStateError(StateMachineError):
    pass


class UnknownTransitionError(StateMachineError):
    pass


class DuplicateTransitionError(StateMachineError):
    pass


class TransitionPatternNotFound(StateMachineError):
    pass


class TransitionMethodNotFound(StateMachineError):
    pass


class UnexpectedIndentationError(StateMachineError):
    pass


class TransitionCorrection(Exception):
    """Raise from a transition method to switch to another transition."""


class StateCorrection(Exception):
    """Raise from a transition method to switch to another state."""


class StateMachine:
    """Line-oriented finite state machine running `State` transitions."""

    def __init__(self, state_classes: Any, initial_state: str, debug: bool = False) -> None:
        self.input_lines: StringList | None = None
        self.input_offset = 0
        self.line: str | None = None
        self.line_offset = -1
        self.debug = debug
        self.initial_state = initial_state
        self.current_state = initial_state
        self.states: dict[str, State] = {}
        self.add_states(state_classes)
        self.observers: list[Any] = []

    def unlink(self) -> None:
        """Remove circular references to objects no longer required."""
        for state in self.states.values():
            state.unlink()
        self.states = None

    def run(self, input_lines: Any, input_offset: int = 0, context: Any = None,
            input_source: str | None = None, initial_state: str | None = None) -> list:
        """Run the state machine on `input_lines`; return the results list."""
        self.runtime_init()
        if isinstance(input_lines, StringList):
            self.input_lines = input_lines
        else:
            self.input_lines = StringList(input_lines, source=input_source)
        self.input_offset = input_offset
        self.line_offset = -1
        self.current_state = initial_state or self.initial_state
        if self.debug:
            print("\nStateMachine.run: input_lines (line_offset=%s):\n| %s"
                  % (self.line_offset, "\n| ".join(self.input_lines)), file=sys.stderr)
        try:
            results = self._run_states(context)
        except BaseException:
            if self.debug:
                self.error()
            raise
        self.observers = []
        return results

    def _run_states(self, context: Any) -> list:
        results: list = []
        transitions = None
        state = self.get_state()
        context, result = state.bof(context)
        results.extend(result)
        while True:
            try:
                try:
                    self.next_line()
                    context, next_state, result = self.check_line(context, state, transitions)
                except EOFError:
                    results.extend(state.eof(context))
                    return results
                results.extend(result)
            except TransitionCorrection as exception:
                self.previous_line()
                transitions = (exception.args[0],)
                continue
            except StateCorrection as exception:
                self.previous_line()
                next_state = exception.args[0]
                transitions = None if len(exception.args) == 1 else (exception.args[1],)
            else:
                transitions = None
            state = self.get_state(next_state)

    def get_state(self, next_state: str | None = None) -> State:
        """Return the current state object, switching to `next_state` if given."""
        if next_state:
            if self.debug and next_state != self.current_state:
                print('\nStateMachine.get_state: Changing state from "%s" to "%s" '
                      "(input line %s)." % (self.current_state, next_state,
                                            self.abs_line_number()), file=sys.stderr)
            self.current_state = next_state
        try:
            return self.states[self.current_state]
        except KeyError:
            raise UnknownStateError(self.current_state) from None

    def next_line(self, n: int = 1) -> str:
        """Load `self.line` with the `n`'th next line and return it."""
        try:
            try:
                self.line_offset += n
                self.line = self.input_lines[self.line_offset]
            except IndexError:
                self.line = None
                raise EOFError from None
            return self.line
        finally:
            self.notify_observers()

    def is_next_line_blank(self) -> bool | int:
        try:
            return not self.input_lines[self.line_offset + 1].strip()
        except IndexError:
            return 1

    def at_eof(self) -> bool:
        return self.line_offset >= len(self.input_lines) - 1

    def at_bof(self) -> bool:
        return self.line_offset <= 0

    def previous_line(self, n: int = 1) -> str | None:
        """Load `self.line` with the `n`'th previous line and return it."""
        self.line_offset -= n
        self.line = None if self.line_offset < 0 else self.input_lines[self.line_offset]
        self.notify_observers()
        return self.line

    def goto_line(self, line_offset: int) -> str:
        """Jump to absolute line offset `line_offset`, load and return it."""
        try:
            try:
                self.line_offset = line_offset - self.input_offset
                self.line = self.input_lines[self.line_offset]
            except IndexError:
                self.line = None
                raise EOFError from None
            return self.line
        finally:
            self.notify_observers()

    def get_source(self, line_offset: int) -> str:
        return self.input_lines.source(line_offset - self.input_offset)

    def abs_line_offset(self) -> int:
        return self.line_offset + self.input_offset

    def abs_line_number(self) -> int:
        return self.line_offset + self.input_offset + 1

    def get_source_and_line(self, lineno: int | None = None) -> tuple[Any, int | None]:
        """(source, line) of the current line or of absolute line `lineno`."""
        offset = self.line_offset if lineno is None else lineno - self.input_offset - 1
        try:
            src, srcoffset = self.input_lines.info(offset)
            srcline = srcoffset + 1
        except TypeError:  # offset is just past the end
            src, srcline = self.get_source_and_line(offset + self.input_offset)
            return src, srcline + 1
        except IndexError:
            src, srcline = None, None
        return src, srcline

    def insert_input(self, input_lines: list[str], source: str) -> None:
        """Insert `input_lines` after the current line (with padding lines)."""
        self.input_lines.insert(self.line_offset + 1, "",
                                source="internal padding after " + source,
                                offset=len(input_lines))
        self.input_lines.insert(self.line_offset + 1, "",
                                source="internal padding before " + source, offset=-1)
        self.input_lines.insert(self.line_offset + 2, StringList(input_lines, source))

    def get_text_block(self, flush_left: bool = False) -> StringList:
        """Return the contiguous text block starting at the current line."""
        try:
            block = self.input_lines.get_text_block(self.line_offset, flush_left)
            self.next_line(len(block) - 1)
            return block
        except UnexpectedIndentationError as err:
            self.next_line(len(err.args[0]) - 1)
            raise

    def check_line(self, context: Any, state: State, transitions: Any = None) -> Any:
        """Apply the first matching transition of `state` to the current line."""
        if transitions is None:
            transitions = state.transition_order
        for name in transitions:
            pattern, method, next_state = state.transitions[name]
            match = pattern.match(self.line)
            if match:
                return method(match, context, next_state)
        return state.no_match(context, transitions)

    def add_state(self, state_class: type[State]) -> None:
        name = state_class.__name__
        if name in self.states:
            raise DuplicateStateError(name)
        self.states[name] = state_class(self, self.debug)

    def add_states(self, state_classes: Any) -> None:
        for state_class in state_classes:
            self.add_state(state_class)

    def runtime_init(self) -> None:
        for state in self.states.values():
            state.runtime_init()

    def error(self) -> None:
        """Report the current exception (debug mode)."""
        type_name, value, module, line, function = _exception_data()
        print("%s: %s" % (type_name, value), file=sys.stderr)
        print("input line %s" % self.abs_line_number(), file=sys.stderr)
        print("module %s, line %s, function %s" % (module, line, function), file=sys.stderr)

    def attach_observer(self, observer: Any) -> None:
        self.observers.append(observer)

    def detach_observer(self, observer: Any) -> None:
        self.observers.remove(observer)

    def notify_observers(self) -> None:
        for observer in self.observers:
            try:
                info = self.input_lines.info(self.line_offset)
            except IndexError:
                info = (None, None)
            observer(*info)


class State:
    """State of a `StateMachine`: a set of pattern/method transitions."""

    patterns: dict[str, Any] | None = None
    initial_transitions: Any = None
    nested_sm: Any = None
    nested_sm_kwargs: dict[str, Any] | None = None

    def __init__(self, state_machine: StateMachine, debug: bool = False) -> None:
        self.transition_order: list[str] = []
        self.transitions: dict[str, tuple] = {}
        self.add_initial_transitions()
        self.state_machine = state_machine
        self.debug = debug
        if self.nested_sm is None:
            self.nested_sm = self.state_machine.__class__
        if self.nested_sm_kwargs is None:
            self.nested_sm_kwargs = {"state_classes": [self.__class__],
                                     "initial_state": self.__class__.__name__}

    def runtime_init(self) -> None:
        pass

    def unlink(self) -> None:
        self.state_machine = None

    def add_initial_transitions(self) -> None:
        if self.initial_transitions:
            names, transitions = self.make_transitions(self.initial_transitions)
            self.add_transitions(names, transitions)

    def add_transitions(self, names: list[str], transitions: dict[str, tuple]) -> None:
        for name in names:
            if name in self.transitions:
                raise DuplicateTransitionError(name)
            if name not in transitions:
                raise UnknownTransitionError(name)
        self.transition_order[:0] = names
        self.transitions.update(transitions)

    def add_transition(self, name: str, transition: tuple) -> None:
        if name in self.transitions:
            raise DuplicateTransitionError(name)
        self.transition_order[:0] = [name]
        self.transitions[name] = transition

    def remove_transition(self, name: str) -> None:
        try:
            del self.transitions[name]
            self.transition_order.remove(name)
        except (KeyError, ValueError):
            raise UnknownTransitionError(name) from None

    def make_transition(self, name: str, next_state: str | None = None) -> tuple:
        """Return (compiled pattern, method, next state name) for `name`."""
        if next_state is None:
            next_state = self.__class__.__name__
        try:
            pattern = self.patterns[name]
            if not hasattr(pattern, "match"):
                pattern = self.patterns[name] = re.compile(pattern)
        except KeyError:
            raise TransitionPatternNotFound(
                "%s.patterns[%r]" % (self.__class__.__name__, name)) from None
        try:
            method = getattr(self, name)
        except AttributeError:
            raise TransitionMethodNotFound("%s.%s" % (self.__class__.__name__, name)) from None
        return pattern, method, next_state

    def make_transitions(self, name_list: Any) -> tuple[list[str], dict[str, tuple]]:
        names = []
        transitions = {}
        for namestate in name_list:
            if isinstance(namestate, str):
                transitions[namestate] = self.make_transition(namestate)
                names.append(namestate)
            else:
                transitions[namestate[0]] = self.make_transition(*namestate)
                names.append(namestate[0])
        return names, transitions

    def no_match(self, context: Any, transitions: Any) -> tuple:
        return context, None, []

    def bof(self, context: Any) -> tuple:
        return context, []

    def eof(self, context: Any) -> list:
        return []

    def nop(self, match: Any, context: Any, next_state: str) -> tuple:
        return context, next_state, []


class StateMachineWS(StateMachine):
    """`StateMachine` with methods for indented text blocks."""

    def get_indented(self, until_blank: bool = False,
                     strip_indent: bool = True) -> tuple[StringList, int, int, bool]:
        offset = self.abs_line_offset()
        indented, indent, blank_finish = self.input_lines.get_indented(
            self.line_offset, until_blank, strip_indent)
        if indented:
            self.next_line(len(indented) - 1)
        while indented and not indented[0].strip():
            indented.trim_start()
            offset += 1
        return indented, indent, offset, blank_finish

    def get_known_indented(self, indent: int, until_blank: bool = False,
                           strip_indent: bool = True) -> tuple[StringList, int, bool]:
        offset = self.abs_line_offset()
        indented, indent, blank_finish = self.input_lines.get_indented(
            self.line_offset, until_blank, strip_indent, block_indent=indent)
        self.next_line(len(indented) - 1)
        while indented and not indented[0].strip():
            indented.trim_start()
            offset += 1
        return indented, offset, blank_finish

    def get_first_known_indented(self, indent: int, until_blank: bool = False,
                                 strip_indent: bool = True,
                                 strip_top: bool = True) -> tuple[StringList, int, int, bool]:
        offset = self.abs_line_offset()
        indented, indent, blank_finish = self.input_lines.get_indented(
            self.line_offset, until_blank, strip_indent, first_indent=indent)
        self.next_line(len(indented) - 1)
        if strip_top:
            while indented and not indented[0].strip():
                indented.trim_start()
                offset += 1
        return indented, indent, offset, blank_finish


class StateWS(State):
    """`State` with default transitions for blank and indented lines."""

    indent_sm: Any = None
    indent_sm_kwargs: dict[str, Any] | None = None
    known_indent_sm: Any = None
    known_indent_sm_kwargs: dict[str, Any] | None = None
    ws_patterns = {"blank": re.compile(" *$"), "indent": re.compile(" +")}
    ws_initial_transitions: tuple[str, ...] = ("blank", "indent")

    def __init__(self, state_machine: StateMachine, debug: bool = False) -> None:
        State.__init__(self, state_machine, debug)
        if self.indent_sm is None:
            self.indent_sm = self.nested_sm
        if self.indent_sm_kwargs is None:
            self.indent_sm_kwargs = self.nested_sm_kwargs
        if self.known_indent_sm is None:
            self.known_indent_sm = self.indent_sm
        if self.known_indent_sm_kwargs is None:
            self.known_indent_sm_kwargs = self.indent_sm_kwargs

    def add_initial_transitions(self) -> None:
        State.add_initial_transitions(self)
        if self.patterns is None:
            self.patterns = {}
        self.patterns.update(self.ws_patterns)
        names, transitions = self.make_transitions(self.ws_initial_transitions)
        self.add_transitions(names, transitions)

    def blank(self, match: Any, context: Any, next_state: str) -> tuple:
        return self.nop(match, context, next_state)

    def indent(self, match: Any, context: Any, next_state: str) -> tuple:
        indented, _indent, line_offset, _blank = self.state_machine.get_indented()
        sm = self.indent_sm(debug=self.debug, **self.indent_sm_kwargs)
        return context, next_state, sm.run(indented, input_offset=line_offset)

    def known_indent(self, match: Any, context: Any, next_state: str) -> tuple:
        indented, line_offset, _blank = self.state_machine.get_known_indented(match.end())
        sm = self.known_indent_sm(debug=self.debug, **self.known_indent_sm_kwargs)
        return context, next_state, sm.run(indented, input_offset=line_offset)

    def first_known_indent(self, match: Any, context: Any, next_state: str) -> tuple:
        indented, line_offset, _blank = self.state_machine.get_first_known_indented(match.end())
        sm = self.known_indent_sm(debug=self.debug, **self.known_indent_sm_kwargs)
        return context, next_state, sm.run(indented, input_offset=line_offset)


class _SearchOverride:
    """Mix-in using ``pattern.search`` instead of ``pattern.match``."""

    def match(self, pattern: re.Pattern[str]) -> re.Match[str] | None:
        return pattern.search(self.line)


class SearchStateMachine(_SearchOverride, StateMachine):
    pass


class SearchStateMachineWS(_SearchOverride, StateMachineWS):
    pass


def _check_trim(n: int, size: int) -> None:
    if n > size:
        raise IndexError("Size of trim too large; can't trim %s items from a list of size %s."
                         % (n, size))
    if n < 0:
        raise IndexError("Trim size must be >= 0.")


class ViewList:
    """List with extended functionality: slices keep their source info and
    changes to a slice propagate to its parent."""

    def __init__(self, initlist: Any = None, source: str | None = None,
                 items: list[tuple] | None = None, parent: ViewList | None = None,
                 parent_offset: int | None = None) -> None:
        self.data: list = []
        self.items: list[tuple] = []
        self.parent = parent
        self.parent_offset = parent_offset
        if isinstance(initlist, ViewList):
            self.data = initlist.data[:]
            self.items = initlist.items[:]
        elif initlist is not None:
            self.data = list(initlist)
            self.items = items if items else [(source, i) for i in range(len(initlist))]
        assert len(self.data) == len(self.items), "data mismatch"

    def __str__(self) -> str:
        return str(self.data)

    def __repr__(self) -> str:
        return f"{self.__class__.__name__}({self.data}, items={self.items})"

    def _cast(self, other: Any) -> Any:
        return other.data if isinstance(other, ViewList) else other

    def __lt__(self, other: Any) -> bool:
        return self.data < self._cast(other)

    def __le__(self, other: Any) -> bool:
        return self.data <= self._cast(other)

    def __eq__(self, other: Any) -> bool:
        return self.data == self._cast(other)

    def __ne__(self, other: Any) -> bool:
        return self.data != self._cast(other)

    def __gt__(self, other: Any) -> bool:
        return self.data > self._cast(other)

    def __ge__(self, other: Any) -> bool:
        return self.data >= self._cast(other)

    __hash__ = None  # mutable

    def __contains__(self, item: Any) -> bool:
        return item in self.data

    def __len__(self) -> int:
        return len(self.data)

    def __getitem__(self, i: int | slice) -> Any:
        if isinstance(i, slice):
            assert i.step in (None, 1), "cannot handle slice with stride"
            return self.__class__(self.data[i.start:i.stop], items=self.items[i.start:i.stop],
                                  parent=self, parent_offset=i.start or 0)
        return self.data[i]

    def __setitem__(self, i: int | slice, item: Any) -> None:
        if isinstance(i, slice):
            assert i.step in (None, 1), "cannot handle slice with stride"
            if not isinstance(item, ViewList):
                raise TypeError("assigning non-ViewList to ViewList slice")
            self.data[i.start:i.stop] = item.data
            self.items[i.start:i.stop] = item.items
            assert len(self.data) == len(self.items), "data mismatch"
            if self.parent:
                start = (i.start or 0) + self.parent_offset
                stop = (i.stop or len(self)) + self.parent_offset
                self.parent[start:stop] = item
        else:
            self.data[i] = item
            if self.parent:
                self.parent[i + self.parent_offset] = item

    def __delitem__(self, i: int | slice) -> None:
        if isinstance(i, slice):
            assert i.step is None, "cannot handle slice with stride"
            stop = len(self) if i.stop is None else i.stop
            del self.data[i.start:i.stop]
            del self.items[i.start:i.stop]
            if self.parent:
                start = (i.start or 0) + self.parent_offset
                del self.parent[start:stop + self.parent_offset]
            return
        del self.data[i]
        del self.items[i]
        if self.parent:
            del self.parent[i + self.parent_offset]

    def __add__(self, other: Any) -> ViewList:
        if not isinstance(other, ViewList):
            raise TypeError("adding non-ViewList to a ViewList")
        return self.__class__(self.data + other.data, items=self.items + other.items)

    def __radd__(self, other: Any) -> ViewList:
        if not isinstance(other, ViewList):
            raise TypeError("adding ViewList to a non-ViewList")
        return self.__class__(other.data + self.data, items=other.items + self.items)

    def __iadd__(self, other: Any) -> ViewList:
        if not isinstance(other, ViewList):
            raise TypeError("argument to += must be a ViewList")
        self.data += other.data
        return self

    def __mul__(self, n: int) -> ViewList:
        return self.__class__(self.data * n, items=self.items * n)

    __rmul__ = __mul__

    def __imul__(self, n: int) -> ViewList:
        self.data *= n
        self.items *= n
        return self

    def extend(self, other: ViewList) -> None:
        if not isinstance(other, ViewList):
            raise TypeError("extending a ViewList with a non-ViewList")
        if self.parent:
            self.parent.insert(len(self.data) + self.parent_offset, other)
        self.data.extend(other.data)
        self.items.extend(other.items)

    def append(self, item: Any, source: str | None = None, offset: int = 0) -> None:
        if source is None:
            self.extend(item)
            return
        if self.parent:
            self.parent.insert(len(self.data) + self.parent_offset, item, source, offset)
        self.data.append(item)
        self.items.append((source, offset))

    def insert(self, i: int, item: Any, source: str | None = None, offset: int = 0) -> None:
        if source is None:
            if not isinstance(item, ViewList):
                raise TypeError("inserting non-ViewList with no source given")
            self.data[i:i] = item.data
            self.items[i:i] = item.items
            if self.parent:
                index = (len(self.data) + i) % len(self.data)
                self.parent.insert(index + self.parent_offset, item)
            return
        self.data.insert(i, item)
        self.items.insert(i, (source, offset))
        if self.parent:
            index = (len(self.data) + i) % len(self.data)
            self.parent.insert(index + self.parent_offset, item, source, offset)

    def pop(self, i: int = -1) -> Any:
        if self.parent:
            index = (len(self.data) + i) % len(self.data)
            self.parent.pop(index + self.parent_offset)
        self.items.pop(i)
        return self.data.pop(i)

    def trim_start(self, n: int = 1) -> None:
        """Remove items from the start (not propagated to the parent)."""
        _check_trim(n, len(self.data))
        del self.data[:n]
        del self.items[:n]
        if self.parent:
            self.parent_offset += n

    def trim_end(self, n: int = 1) -> None:
        """Remove items from the end (not propagated to the parent)."""
        _check_trim(n, len(self.data))
        del self.data[-n:]
        del self.items[-n:]

    def remove(self, item: Any) -> None:
        del self[self.index(item)]

    def count(self, item: Any) -> int:
        return self.data.count(item)

    def index(self, item: Any) -> int:
        return self.data.index(item)

    def reverse(self) -> None:
        self.data.reverse()
        self.items.reverse()
        self.parent = None

    def sort(self, *args: Any) -> None:
        tmp = sorted(zip(self.data, self.items, strict=True), *args)
        self.data = [entry[0] for entry in tmp]
        self.items = [entry[1] for entry in tmp]
        self.parent = None

    def info(self, i: int) -> tuple[Any, int | None]:
        """(source, offset) of item `i`; one past the end gives (source, None)."""
        try:
            return self.items[i]
        except IndexError:
            if i == len(self.data):
                return self.items[i - 1][0], None
            raise

    def source(self, i: int) -> Any:
        return self.info(i)[0]

    def offset(self, i: int) -> int | None:
        return self.info(i)[1]

    def disconnect(self) -> None:
        """Break the link to the parent list."""
        self.parent = None

    def xitems(self) -> Iterator[tuple[Any, int, Any]]:
        for value, (source, offset) in zip(self.data, self.items, strict=True):
            yield source, offset, value

    def pprint(self) -> None:
        for line in self.xitems():
            print("%s:%d:%s" % line)


class StringList(ViewList):
    """A `ViewList` of strings with text-block helpers."""

    def trim_left(self, length: int, start: int = 0, end: int = sys.maxsize) -> None:
        """Trim `length` characters off the beginning of each item."""
        self.data[start:end] = [line[length:] for line in self.data[start:end]]

    def get_text_block(self, start: int, flush_left: bool = False) -> StringList:
        """The text block from `start` up to the first blank line."""
        end = start
        last = len(self.data)
        while end < last:
            line = self.data[end]
            if not line.strip():
                break
            if flush_left and line[0] == " ":
                source, offset = self.info(end)
                raise UnexpectedIndentationError(self[start:end], source, offset + 1)
            end += 1
        return self[start:end]

    def get_indented(self, start: int = 0, until_blank: bool = False, strip_indent: bool = True,
                     block_indent: int | None = None,
                     first_indent: int | None = None) -> tuple[StringList, int, bool]:
        """Extract an indented block; return (block, indent, blank_finish)."""
        if block_indent is not None and first_indent is None:
            first_indent = block_indent
        end, indent, blank_finish = self._indented_end(
            start + (first_indent is not None), start, until_blank, block_indent)
        block = self[start:end]
        if first_indent is not None and block:
            block.data[0] = block.data[0][first_indent:]
        if indent and strip_indent:
            block.trim_left(indent, start=first_indent is not None)
        return block, indent or 0, blank_finish

    def _indented_end(self, end: int, start: int, until_blank: bool,
                      block_indent: int | None) -> tuple[int, int | None, bool]:
        indent = block_indent
        last = len(self.data)
        while end < last:
            line = self.data[end]
            if line and (line[0] != " " or (block_indent is not None
                                           and line[:block_indent].strip())):
                return end, indent, end > start and not self.data[end - 1].strip()
            stripped = line.lstrip()
            if not stripped:
                if until_blank:
                    return end, indent, True
            elif block_indent is None:
                line_indent = len(line) - len(stripped)
                indent = line_indent if indent is None else min(indent, line_indent)
            end += 1
        return end, indent, True

    def get_2D_block(self, top: int, left: int, bottom: int, right: int,  # noqa: N802
                     strip_indent: bool = True) -> StringList:
        """A rectangular block of text (column indices account for wide chars)."""
        from docutils import utils

        block = self[top:bottom]
        indent = right
        for i, line in enumerate(block.data):
            columns = utils.column_indices(line)
            left_i = columns[left] if left < len(columns) else left
            right_i = columns[right] if right < len(columns) else len(line)
            block.data[i] = line = line[left_i:right_i].rstrip()
            if line:
                indent = min(indent, len(line) - len(line.lstrip()))
        if strip_indent and 0 < indent < right:
            block.data = [line[indent:] for line in block.data]
        return block

    def pad_double_width(self, pad_char: str) -> None:
        """Pad double-width characters with `pad_char` (tables)."""
        for i, line in enumerate(self.data):
            if isinstance(line, str):
                self.data[i] = "".join(
                    char + pad_char if east_asian_width(char) in "WF" else char
                    for char in line)

    def replace(self, old: str, new: str) -> None:
        """Replace all occurrences of substring `old` with `new`."""
        self.data[:] = [line.replace(old, new) for line in self.data]


def string2lines(astring: str, tab_width: int = 8, convert_whitespace: bool = False,
                 whitespace: re.Pattern[str] = re.compile("[\x0b\x0c]")) -> list[str]:
    """Split `astring` into lines, expanding tabs and stripping trailing space."""
    if convert_whitespace:
        astring = whitespace.sub(" ", astring)
    return [s.expandtabs(tab_width).rstrip() for s in astring.splitlines()]


def _exception_data() -> tuple[str, Any, str, int, str]:
    """(type name, value, file, line, function) of the current exception."""
    typ, value, traceback = sys.exc_info()
    while traceback.tb_next:
        traceback = traceback.tb_next
    code = traceback.tb_frame.f_code
    return typ.__name__, value, code.co_filename, traceback.tb_lineno, code.co_name
