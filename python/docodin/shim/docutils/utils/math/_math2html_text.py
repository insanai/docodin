"""The parse position of `math2html`: a cursor over the TeX source with a stack of endings.

Nested constructs (``{...}``, ``[...]``, ``\\begin{env}...\\end{env}``, table rows and
cells) push the text that ends them onto the position's `EndingList`. The position
counts as `~Globable.finished` when it reaches the end of the text or an ending that is
reachable from the top of the stack, skipping *optional* endings (row and cell
separators) on the way. A construct then `~Globable.popending` its ending.

Unbalanced input is reported, not repaired: each time the end of the text is reached
while endings are still pending, an error names them (so one missing ``}`` may be reported
several times, exactly as in docutils).
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

from docutils.utils.math._math2html_options import Trace

__docformat__ = "reStructuredText"


@dataclass(eq=False)
class PositionEnding:
    """A text that ends a construct being parsed."""

    ending: str
    optional: bool

    def checkin(self, pos: Position) -> bool:
        """Check for the ending at the current position."""
        return pos.checkfor(self.ending)

    def __str__(self) -> str:
        return "Ending " + self.ending + (" (optional)" if self.optional else "")


class EndingList:
    """The stack of endings of the constructs enclosing a parse position."""

    def __init__(self) -> None:
        self.endings: list[PositionEnding] = []

    def add(self, ending: str, optional: bool = False) -> None:
        """Push a new ending."""
        self.endings.append(PositionEnding(ending, optional))

    def checkin(self, pos: Position) -> bool:
        """Check whether an ending is found at the current position."""
        return self.findending(pos) is not None

    def pop(self, pos: Position) -> str:
        """Remove the ending found at the current position, and the optional ones above it."""
        if pos.isout():
            Trace.error("No ending out of bounds")
            return ""
        ending = self.findending(pos)
        if not ending:
            Trace.error("No ending at " + pos.current())
            return ""
        index = next(i for i, each in enumerate(self.endings) if each is ending)
        del self.endings[index:]
        return ending.ending

    def findending(self, pos: Position) -> PositionEnding | None:
        """Find the ending at the current position: the innermost ending found before
        the first non-optional one that is not."""
        for ending in reversed(self.endings):
            if ending.checkin(pos):
                return ending
            if not ending.optional:
                return None
        return None

    def checkpending(self) -> None:
        """Report any endings left open."""
        if self.endings:
            Trace.error("Pending " + str(self) + " left open")

    def __str__(self) -> str:
        return "endings [" + ",".join(str(ending) for ending in self.endings) + "]"


class Globable:
    """A bit of text which can be globbed (consumed in runs of characters).

    Subclasses implement `isout`, `current`, `checkfor` and `skip`.
    """

    def __init__(self) -> None:
        self.endinglist = EndingList()

    def isout(self) -> bool:
        """Find out if we are past the end of the text."""
        raise NotImplementedError

    def current(self) -> str:
        """Return the current character."""
        raise NotImplementedError

    def checkfor(self, string: str) -> bool:
        """Check for `string` at the current position."""
        raise NotImplementedError

    def skip(self, string: str) -> None:
        """Advance over `string`."""
        raise NotImplementedError

    def skipcurrent(self) -> str:
        """Return the current character and skip it."""
        current = self.current()
        self.skip(current)
        return current

    def finished(self) -> bool:
        """Find out if the text or the current construct has ended.

        At the end of the text, still pending endings are reported.
        """
        if self.isout():
            self.endinglist.checkpending()
            return True
        return self.endinglist.checkin(self)

    def glob(self, currentcheck: Callable[[], bool]) -> str:
        """Consume characters while not finished and `currentcheck()` holds."""
        glob = ""
        while not self.finished() and currentcheck():
            glob += self.skipcurrent()
        return glob

    def globalpha(self) -> str:
        """Consume a run of letters."""
        return self.glob(lambda: self.current().isalpha())

    def isvalue(self) -> bool:
        """Is the current character part of a value (neither space nor bracket)?"""
        char = self.current()
        return not char.isspace() and char not in "{}()"

    def globvalue(self) -> str:
        """Consume a value: any characters except spaces and brackets."""
        return self.glob(self.isvalue)

    def skipspace(self) -> str:
        """Consume whitespace."""
        return self.glob(lambda: self.current().isspace())

    def globincluding(self, magicchar: str) -> str:
        """Consume text up to and including `magicchar` (which is assumed if missing)."""
        glob = self.glob(lambda: self.current() != magicchar) + magicchar
        self.skip(magicchar)
        return glob

    def globexcluding(self, excluded: str) -> str:
        """Consume text up to (excluding) any of the `excluded` characters."""
        return self.glob(lambda: self.current() not in excluded)

    def pushending(self, ending: str, optional: bool = False) -> None:
        """Push an ending for the construct being entered."""
        self.endinglist.add(ending, optional)

    def popending(self, expected: str | None = None) -> str:
        """Pop and skip the ending at the current position; return it ('' if none)."""
        ending = self.endinglist.pop(self)
        if expected and expected != ending:
            Trace.error("Expected ending " + expected + ", got " + ending)
        self.skip(ending)
        return ending

    def nextending(self) -> str | None:
        """Return the ending found at the current position, if any."""
        ending = self.endinglist.findending(self)
        return ending.ending if ending else None


class Position(Globable):
    """A parse position; subclasses implement `extract` and `identifier` too."""

    def extract(self, length: int) -> str | None:
        """Return the next `length` characters (None if there are fewer), not advancing."""
        raise NotImplementedError

    def identifier(self) -> str:
        """Return a description of the current position for messages."""
        raise NotImplementedError

    def checkfor(self, string: str) -> bool:
        return string == self.extract(len(string))

    def checkskip(self, string: str) -> bool:
        """Skip `string` if it is at the current position; return whether it was."""
        if not self.checkfor(string):
            return False
        self.skip(string)
        return True

    def error(self, message: str) -> None:
        """Report an error at the current position."""
        Trace.error(message + ": " + self.identifier())


class TextPosition(Position):
    """A parse position in a string."""

    def __init__(self, text: str) -> None:
        super().__init__()
        self.pos = 0
        self.text = text
        if not self.finished() and self.current() == "﻿":  # skip a byte-order mark
            self.skipcurrent()

    def skip(self, string: str) -> None:
        self.pos += len(string)

    def identifier(self) -> str:
        """Return the next 30 characters between stars."""
        return "*" + self.text[self.pos:self.pos + 30] + "*"

    def isout(self) -> bool:
        return self.pos >= len(self.text)

    def current(self) -> str:
        """Return the current character (raises IndexError past the end)."""
        return self.text[self.pos]

    def extract(self, length: int) -> str | None:
        if self.pos + length > len(self.text):
            return None
        return self.text[self.pos:self.pos + length]
