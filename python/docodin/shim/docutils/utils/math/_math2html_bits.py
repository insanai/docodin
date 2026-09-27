"""Formula bits: the nodes of a parsed formula, and the basic (non-command) kinds.

Every bit kind has a class-level `detect` test on the current character and a `parsebit`
method that consumes its source text. While parsing, each bit accumulates its source in
`original` (used to recognise precomposed forms like ``\\mathbb{R}``), and gets a `size`:
the number of text rows it spans, which decides how tall ``\\left``/``\\right`` brackets
are drawn.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import TYPE_CHECKING

from docutils.utils.math._math2html_config import FormulaConfig
from docutils.utils.math._math2html_text import Position
from docutils.utils.math._math2html_tree import (
    Constant,
    Container,
    ContentsOutput,
    TaggedOutput,
)

if TYPE_CHECKING:
    from docutils.utils.math._math2html_pipeline import FormulaFactory

__docformat__ = "reStructuredText"


class FormulaBit(Container):
    """A bit of a formula.

    `type` marks bits that the final pass treats specially: ``'alpha'`` (letters, set in
    italics), ``'number'`` and ``'font'`` (text in a font; separated from a preceding
    number by a thin space).
    """

    type: str | None = None
    size = 1
    original = ""
    factory: FormulaFactory

    def __init__(self) -> None:
        super().__init__()
        self.output = ContentsOutput()

    @classmethod
    def detect(cls, pos: Position) -> bool:
        """Does a bit of this kind start at the current position?"""
        return False

    def parsebit(self, pos: Position) -> FormulaBit | None:
        """Parse the bit; may return a replacement bit."""
        return None

    def setfactory(self, factory: FormulaFactory) -> FormulaBit:
        """Set the formula factory used to parse nested bits."""
        self.factory = factory
        return self

    def add(self, bit: Container) -> None:
        """Add a parsed bit to the contents (and its source to ours)."""
        self.contents.append(bit)
        self.original += bit.original
        bit.parent = self

    def skiporiginal(self, string: str, pos: Position) -> None:
        """Skip `string` in the source, recording it as ours."""
        self.original += string
        pos.skip(string)

    def computesize(self) -> int:
        """Compute the size as the maximum size of the contents (1 when empty)."""
        if not self.contents:
            return 1
        self.size = max(element.size for element in self.contents)
        return self.size

    def __str__(self) -> str:
        return self.__class__.__name__ + " read in " + self.original


class FormulaConstant(Constant):
    """A constant string in a formula."""

    def __init__(self, string: str) -> None:
        super().__init__(string)
        self.original = string
        self.size = 1
        self.type: str | None = None

    def computesize(self) -> int:
        """The size of a constant is always 1."""
        return self.size

    def __str__(self) -> str:
        return "Formula constant: " + self.string


class TaggedBit(FormulaBit):
    """A formula bit wrapped in an HTML tag."""

    def constant(self, constant: str, tag: str) -> TaggedBit:
        """Wrap the text `constant` in `tag`."""
        self.output = TaggedOutput().settag(tag)
        self.add(FormulaConstant(constant))
        return self

    def complete(self, contents: list[Container], tag: str,
                 breaklines: bool = False) -> TaggedBit:
        """Wrap `contents` in `tag`."""
        self.contents = contents
        self.output = TaggedOutput().settag(tag, breaklines)
        return self

    def selfcomplete(self, tag: str) -> TaggedBit:
        """Make a self-closing tag without contents (as in ``<hr/>``)."""
        self.output = TaggedOutput().settag(tag, empty=True)
        return self


class RawText(FormulaBit):
    """A run of letters: variables, set in italics."""

    @classmethod
    def detect(cls, pos: Position) -> bool:
        return pos.current().isalpha()

    def parsebit(self, pos: Position) -> None:
        self.add(FormulaConstant(pos.globalpha()))
        self.type = "alpha"


class FormulaSymbol(FormulaBit):
    """A symbol character, passed through or translated (with spacing)."""

    modified = FormulaConfig.modified
    unmodified = FormulaConfig.unmodified["characters"]

    @classmethod
    def detect(cls, pos: Position) -> bool:
        char = pos.current()
        return char in cls.unmodified or char in cls.modified

    def parsebit(self, pos: Position) -> None:
        char = pos.current()
        self.addsymbol(char if char in self.unmodified else self.modified[char], pos)

    def addsymbol(self, symbol: str, pos: Position) -> None:
        """Skip the current character and output `symbol` for it."""
        self.skiporiginal(pos.current(), pos)
        self.contents.append(FormulaConstant(symbol))


class FormulaNumber(FormulaBit):
    """A string of digits."""

    @classmethod
    def detect(cls, pos: Position) -> bool:
        return pos.current().isdigit()

    def parsebit(self, pos: Position) -> None:
        self.add(FormulaConstant(pos.glob(lambda: pos.current().isdigit())))
        self.type = "number"


class Comment(FormulaBit):
    """A LaTeX comment: % to the end of the line (no output)."""

    start = FormulaConfig.starts["comment"]

    @classmethod
    def detect(cls, pos: Position) -> bool:
        return pos.current() == cls.start

    def parsebit(self, pos: Position) -> None:
        self.original += pos.globincluding("\n")


class WhiteSpace(FormulaBit):
    """Some white space (no output)."""

    @classmethod
    def detect(cls, pos: Position) -> bool:
        return pos.current().isspace()

    def parsebit(self, pos: Position) -> None:
        self.original += pos.skipspace()

    def __str__(self) -> str:
        return "Whitespace: *" + self.original + "*"


class Bracket(FormulaBit):
    """A ``{}`` group; its contents are parsed as formula, as text, or as a literal."""

    start = FormulaConfig.starts["bracket"]
    ending = FormulaConfig.endings["bracket"]
    literal = ""

    @classmethod
    def detect(cls, pos: Position) -> bool:
        return pos.checkfor(cls.start)

    def parsebit(self, pos: Position) -> Bracket:
        """Parse a group of formula bits."""
        self.parsecomplete(pos, self.innerformula)
        return self

    def parsetext(self, pos: Position) -> Bracket:
        """Parse a group of text (as in ``\\text{...}``)."""
        self.parsecomplete(pos, self.innertext)
        return self

    def parseliteral(self, pos: Position) -> Bracket:
        """Parse a group read literally into `literal` (as in ``\\color{red}``)."""
        self.parsecomplete(pos, self.innerliteral)
        return self

    def parsecomplete(self, pos: Position, innerparser: Callable[[Position], None]) -> None:
        """Parse the opening mark, the contents with `innerparser`, and the closing mark."""
        self.skiporiginal(self.start, pos)
        pos.pushending(self.ending)
        innerparser(pos)
        self.original += pos.popending(self.ending)
        self.computesize()

    def innerformula(self, pos: Position) -> None:
        """Parse formula bits up to the closing mark."""
        while not pos.finished():
            self.add(self.factory.parseany(pos))

    def innertext(self, pos: Position) -> None:
        """Parse text: characters are kept as they are, except for commands, scripts,
        groups and comments (which also swallow one following space)."""
        specialchars = [*FormulaConfig.symbolfunctions, FormulaConfig.starts["command"],
                        FormulaConfig.starts["bracket"], Comment.start]
        while not pos.finished():
            if pos.current() in specialchars:
                self.add(self.factory.parseany(pos))
                if pos.checkskip(" "):
                    self.original += " "
            else:
                self.add(FormulaConstant(pos.skipcurrent()))

    def innerliteral(self, pos: Position) -> None:
        """Read the raw text up to the closing mark into `literal`.

        A nested group is parsed with this same bracket and restarts `literal`, so
        ``{a{b}c}`` reads as ``bc`` (as in docutils).
        """
        self.literal = ""
        while not pos.finished() and pos.current() != self.ending:
            if pos.current() == self.start:
                self.parseliteral(pos)
            else:
                self.literal += pos.skipcurrent()
        self.original += self.literal


class SquareBracket(Bracket):
    """A ``[]`` group (an optional parameter)."""

    start = FormulaConfig.starts["squarebracket"]
    ending = FormulaConfig.endings["squarebracket"]


class WholeFormula(FormulaBit):
    """A sequence of formula bits up to the end of the text or of the enclosing construct."""

    @classmethod
    def detect(cls, pos: Position) -> bool:
        return not pos.finished()

    def parsebit(self, pos: Position) -> None:
        while not pos.finished():
            self.add(self.factory.parseany(pos))
