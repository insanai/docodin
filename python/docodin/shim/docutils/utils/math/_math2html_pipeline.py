"""The two passes of `math2html`: parsing TeX into formula bits, and processing the tree.

`FormulaFactory` parses: at each position, the first bit kind in `FormulaFactory.types`
whose `detect` accepts the current character parses the next bit. Commands are dispatched
further on their name through `FormulaFactory.commandtypes`.

`FormulaProcessor` then rewrites the tree in place: it lets every bit `process` itself,
runs the maths processors (limits and scripts, then brackets) over each list of
contents, and finally sets letters in italics and separates units from numbers.
"""

from __future__ import annotations

from collections.abc import Iterator

from docutils.utils.math._math2html_arrays import BeginCommand, BigBracket
from docutils.utils.math._math2html_bits import (
    Bracket,
    Comment,
    FormulaBit,
    FormulaConstant,
    FormulaNumber,
    FormulaSymbol,
    RawText,
    TaggedBit,
    WhiteSpace,
    WholeFormula,
)
from docutils.utils.math._math2html_commands import (
    AlphaCommand,
    BracketCommand,
    CombiningFunction,
    CommandBit,
    EmptyCommand,
    FontFunction,
    FormulaCommand,
    LimitCommand,
    OneParamFunction,
    OversetFunction,
    SpacedCommand,
    SymbolFunction,
    TextFunction,
    UndersetFunction,
)
from docutils.utils.math._math2html_hybrid import HybridFunction
from docutils.utils.math._math2html_options import DocumentParameters, Options, Trace
from docutils.utils.math._math2html_text import Position, TextPosition
from docutils.utils.math._math2html_tree import Container, ContentsOutput

__docformat__ = "reStructuredText"


class FormulaFactory:
    """Construct the bits of a formula."""

    # bit kinds, tried in order on the current character
    types: list[type[FormulaBit]] = [FormulaSymbol, RawText, FormulaNumber, Bracket, Comment,
                                     WhiteSpace, FormulaCommand, SymbolFunction]
    # bit kinds skipped before parameters
    skippedtypes: list[type[FormulaBit]] = [Comment, WhiteSpace]
    # command kinds, looked up in order in their `commandmap`
    commandtypes: list[type[CommandBit]] = [
        AlphaCommand, EmptyCommand, OneParamFunction, FontFunction, TextFunction, SpacedCommand,
        BeginCommand, OversetFunction, UndersetFunction, CombiningFunction, LimitCommand,
        BracketCommand, HybridFunction]

    def create[Bit: FormulaBit](self, kind: type[Bit]) -> Bit:
        """Create a new formula bit of the given kind."""
        bit = kind()
        bit.setfactory(self)
        return bit

    def detecttype(self, kind: type[FormulaBit], pos: Position) -> bool:
        """Detect a bit of a given kind at the (unfinished) position."""
        return not pos.finished() and kind.detect(pos)

    def clearskipped(self, pos: Position) -> None:
        """Skip any white space and comments."""
        while not pos.finished():
            if not self.skipany(pos):
                return

    def skipany(self, pos: Position) -> FormulaBit | None:
        """Skip white space or a comment; return the skipped bit, if any."""
        for kind in self.skippedtypes:
            if kind.detect(pos):
                return self.parsetype(kind, pos)
        return None

    def parseany(self, pos: Position) -> Container:
        """Parse any formula bit at the current position.

        Callers check that the position is not finished; a character that no bit kind
        accepts is reported and passed through.
        """
        if not pos.finished():
            for kind in self.types:
                if kind.detect(pos):
                    return self.parsetype(kind, pos)
        Trace.error("Unrecognized formula at " + pos.identifier())
        return FormulaConstant(pos.skipcurrent())

    def parsetype(self, kind: type[FormulaBit], pos: Position) -> FormulaBit:
        """Parse a bit of the given kind (which may hand back a replacement bit)."""
        bit = self.create(kind)
        return bit.parsebit(pos) or bit

    def commandtype(self, command: str) -> type[CommandBit] | None:
        """Return the kind of a command like ``\\frac``, or None if unknown."""
        return next((kind for kind in self.commandtypes if command in kind.commandmap), None)

    def parseformula(self, formula: str) -> WholeFormula:
        """Parse a string of text that contains a whole formula."""
        whole = self.create(WholeFormula)
        whole.parsebit(TextPosition(formula))
        return whole


class MathsProcessor:
    """A processor for a maths construction inside the FormulaProcessor."""

    def process(self, contents: list[Container], index: int) -> None:
        """Process the element at `index` of `contents` (which may be modified)."""
        raise NotImplementedError

    def __str__(self) -> str:
        return "Maths processor " + self.__class__.__name__


class LimitsProcessor(MathsProcessor):
    """Stack scripts: limits of big operators in display mode, and ``x^a_b`` pairs."""

    def process(self, contents: list[Container], index: int) -> None:
        if Options.simplemath:
            return
        if self.checklimits(contents, index):
            self.modifylimits(contents, index)
        if self.checkscript(contents, index) and self.checkscript(contents, index + 1):
            self.modifyscripts(contents, index)

    def checklimits(self, contents: list[Container], index: int) -> bool:
        """Is this a limit command followed by a script, in display mode?"""
        if not DocumentParameters.displaymode:
            return False
        if not isinstance(contents[index], LimitCommand):
            return False
        return self.checkscript(contents, index + 1)

    def modifylimits(self, contents: list[Container], index: int) -> None:
        """Move the scripts after a limit command above and below it."""
        limited = contents[index]
        subscript = self.getlimit(contents, index + 1)
        if self.checkscript(contents, index + 1):
            superscript = self.getlimit(contents, index + 1)
        else:
            superscript = TaggedBit().constant(" ", 'sup class="limit"')
        if subscript.command == "^":  # the source is x^i
            superscript, subscript = subscript, superscript
        limited.contents.append(subscript)
        limited.contents.insert(0, superscript)

    def getlimit(self, contents: list[Container], index: int) -> SymbolFunction:
        """Remove the script at `index` and restyle it as a limit."""
        limit = self.getscript(contents, index)
        limit.output.tag = limit.output.tag.replace("script", "limit")
        return limit

    def modifyscripts(self, contents: list[Container], index: int) -> None:
        """Replace a sub- and superscript pair by a vertically aligned stack."""
        subscript = self.getscript(contents, index)
        superscript = self.getscript(contents, index)  # the next one moved to `index`
        if subscript.command == "^":  # the source is x^i_j
            superscript, subscript = subscript, superscript
        scripts = TaggedBit().complete([superscript, subscript], 'span class="scripts"')
        contents.insert(index, scripts)

    def checkscript(self, contents: list[Container], index: int) -> bool:
        """Is there a sub- or superscript at `index`?"""
        return self.checkcommand(contents, index, SymbolFunction)

    def checkcommand(self, contents: list[Container], index: int, kind: type) -> bool:
        """Is there a bit of the given kind at `index`?"""
        return index < len(contents) and isinstance(contents[index], kind)

    def getscript(self, contents: list[Container], index: int) -> SymbolFunction:
        """Remove the script at `index` and mark it as a script."""
        bit = contents.pop(index)
        bit.output.tag += ' class="script"'
        return bit


class BracketProcessor(MathsProcessor):
    """Resize ``\\left`` and ``\\right`` brackets to the rows of what they enclose."""

    def process(self, contents: list[Container], index: int) -> None:
        if Options.simplemath:
            return
        if self.checkleft(contents, index):
            self.processleft(contents, index)

    def processleft(self, contents: list[Container], index: int) -> None:
        """Resize a left bracket and its matching right bracket, if any."""
        rightindex = self.findright(contents, index + 1)
        if not rightindex:
            return
        size = self.findmax(contents, index, rightindex)
        self.resize(contents[index], size)
        self.resize(contents[rightindex], size)

    def checkleft(self, contents: list[Container], index: int) -> bool:
        return self.checkdirection(contents[index], "\\left")

    def checkright(self, contents: list[Container], index: int) -> bool:
        return self.checkdirection(contents[index], "\\right")

    def checkdirection(self, bit: Container, command: str) -> bool:
        """Is `bit` a bracket command for `command`?"""
        return isinstance(bit, BracketCommand) and bit.command == command

    def findright(self, contents: list[Container], index: int) -> int | None:
        """Find the matching right bracket from `index` on."""
        depth = 1
        for position in range(index, len(contents)):
            if self.checkleft(contents, position):
                depth += 1
            if self.checkright(contents, position):
                depth -= 1
            if depth == 0:
                return position
        return None

    def findmax(self, contents: list[Container], leftindex: int, rightindex: int) -> int:
        """Find the maximum size of the bits from the left bracket up to the right one."""
        return max(element.size for element in contents[leftindex:rightindex])

    def resize(self, command: BracketCommand, size: int) -> None:
        """Rebuild a bracket command as a bracket of `size` rows."""
        bracket = BigBracket(size, command.extracttext(), command.command.replace("\\", ""))
        command.output = ContentsOutput()
        command.contents = bracket.getcontents()


class FormulaProcessor:
    """Process a parsed formula in place."""

    processors: list[MathsProcessor] = [LimitsProcessor(), BracketProcessor()]

    def process(self, bit: FormulaBit) -> None:
        """Process the contents of every formula bit, recursively."""
        self.processcontents(bit)
        self.processinsides(bit)
        self.traversewhole(bit)

    def processcontents(self, bit: Container) -> None:
        """Let each bit process itself (parents before children)."""
        if not isinstance(bit, FormulaBit):
            return
        bit.process()
        for element in bit.contents:
            self.processcontents(element)

    def processinsides(self, bit: Container) -> None:
        """Run the maths processors over the contents, then recurse.

        The processors may restructure the list being enumerated; the recursion goes
        into the element found at each index before processing.
        """
        if not isinstance(bit, FormulaBit):
            return
        for index, element in enumerate(bit.contents):
            for processor in self.processors:
                processor.process(bit.contents, index)
            self.processinsides(element)

    def traversewhole(self, formula: FormulaBit) -> None:
        """Italicize letters and put a thin space between a number and a following unit."""
        last = None
        for bit, contents in self.traverse(formula):
            if bit.type == "alpha":
                self.italicize(bit, contents)
            elif bit.type == "font" and last and last.type == "number":
                bit.contents.insert(0, FormulaConstant(" "))
            last = bit

    def traverse(self, bit: FormulaBit) -> Iterator[tuple[Container, list[Container]]]:
        """Yield the typed bits in document order, with the list containing each."""
        for element in bit.contents:
            if getattr(element, "type", None):
                yield element, bit.contents
            elif isinstance(element, FormulaBit):
                yield from self.traverse(element)

    def italicize(self, bit: Container, contents: list[Container]) -> None:
        """Wrap `bit` in an ``<i>`` tag."""
        index = contents.index(bit)
        contents[index] = TaggedBit().complete([bit], "i")
