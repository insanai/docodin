"""Environments (``\\begin{name}...\\end{name}``), tables of rows and cells, and big brackets.

A multi-row environment pushes the optional endings ``\\\\`` (row separator) and ``&``
(cell separator) and parses cells as whole formulas until one of them, or the
``\\end{name}`` ending, is reached. Between two parsed rows an empty spacer row is added.
Brackets spanning several rows are built from Unicode bracket pieces (⎛ ⎜ ⎝) stacked
in a table.
"""

from __future__ import annotations

from collections.abc import Iterator

from docutils.utils.math._math2html_bits import FormulaConstant, TaggedBit, WholeFormula
from docutils.utils.math._math2html_commands import CommandBit, FormulaCommand
from docutils.utils.math._math2html_config import FormulaConfig
from docutils.utils.math._math2html_options import Trace
from docutils.utils.math._math2html_text import Position
from docutils.utils.math._math2html_tree import ContentsOutput, EmptyOutput, TaggedOutput

__docformat__ = "reStructuredText"


class BigBracket:
    """A bracket of `size` rows, built from the pieces in `FormulaConfig.bigbrackets`."""

    def __init__(self, size: int, bracket: str, alignment: str = "l") -> None:
        self.size = size
        self.original = bracket
        self.alignment = alignment
        self.pieces: list[str] | None = FormulaConfig.bigbrackets.get(bracket)

    def getpiece(self, index: int) -> str:
        """Return the piece for row `index`."""
        return self._piecegetters[len(self.pieces)](self, index)

    def getpiece1(self, index: int) -> str:
        """A single-piece bracket repeats its piece."""
        return self.pieces[0]

    def getpiece3(self, index: int) -> str:
        """A parenthesis or square bracket: top, extension, bottom."""
        if index == 0:
            return self.pieces[0]
        if index == self.size - 1:
            return self.pieces[-1]
        return self.pieces[1]

    def getpiece4(self, index: int) -> str:
        """A curly bracket: top, extension, middle, extension, bottom."""
        if index == 0:
            return self.pieces[0]
        if index == self.size - 1:
            return self.pieces[3]
        if index == (self.size - 1) / 2:
            return self.pieces[2]
        return self.pieces[1]

    _piecegetters = {1: getpiece1, 3: getpiece3, 4: getpiece4}

    def getcell(self, index: int) -> TaggedBit:
        """Return the piece for row `index` as a table cell."""
        span = 'span class="bracket align-' + self.alignment + '"'
        return TaggedBit().constant(self.getpiece(index), span)

    def getcontents(self) -> list[TaggedBit]:
        """Return the bracket as a table of pieces, or as a single stretchy sign."""
        if self.size == 1 or not self.pieces:
            return self.getsinglebracket()
        rows = [TaggedBit().complete([self.getcell(index)], 'span class="arrayrow"')
                for index in range(self.size)]
        return [TaggedBit().complete(rows, 'span class="array"')]

    def getsinglebracket(self) -> list[TaggedBit]:
        """Return the bracket as a single sign (``.`` is the empty bracket)."""
        if self.original == ".":
            return [TaggedBit().constant("", 'span class="emptydot"')]
        return [TaggedBit().constant(self.original, 'span class="stretchy"')]


class FormulaCell(FormulaCommand):
    """A table cell: a whole formula up to the next cell or row separator."""

    def setalignment(self, alignment: str) -> FormulaCell:
        self.alignment = alignment
        self.output = TaggedOutput().settag(f'span class="arraycell align-{alignment}"', True)
        return self

    def parsebit(self, pos: Position) -> None:
        self.factory.clearskipped(pos)
        if pos.finished():
            return
        self.add(self.factory.parsetype(WholeFormula, pos))


class FormulaRow(FormulaCommand):
    """A table row: cells separated by ``&``."""

    cellseparator = FormulaConfig.array["cellseparator"]

    def setalignments(self, alignments: list[str]) -> FormulaRow:
        self.alignments = alignments
        self.output = TaggedOutput().settag('span class="arrayrow"', True)
        return self

    def parsebit(self, pos: Position) -> None:
        """Parse cells up to the end of the row."""
        index = 0
        pos.pushending(self.cellseparator, optional=True)
        while not pos.finished():
            cell = self.createcell(index)
            cell.parsebit(pos)
            self.add(cell)
            index += 1
            pos.checkskip(self.cellseparator)
        if not self.contents:
            self.output = EmptyOutput()

    def createcell(self, index: int) -> FormulaCell:
        """Create the cell for column `index` (alignments repeat cyclically)."""
        alignment = self.alignments[index % len(self.alignments)]
        return self.factory.create(FormulaCell).setalignment(alignment)


class MultiRowFormula(CommandBit):
    """A formula with rows separated by ``\\\\``; `alignments` are set by subclasses."""

    alignments: list[str]

    def parserows(self, pos: Position) -> None:
        """Parse all rows, with an empty spacer row between two rows."""
        self.rows: list[FormulaRow] = []
        for index, row in enumerate(self.iteraterows(pos)):
            if index:
                self.addempty()
            row.parsebit(pos)
            self.addrow(row)
        self.size = len(self.rows)

    def iteraterows(self, pos: Position) -> Iterator[FormulaRow]:
        """Yield rows to parse while each parsed row ends at a row separator."""
        rowseparator = FormulaConfig.array["rowseparator"]
        while True:
            pos.pushending(rowseparator, True)
            yield self.factory.create(FormulaRow).setalignments(self.alignments)
            if not pos.checkfor(rowseparator):
                return
            self.original += pos.popending(rowseparator)

    def addempty(self) -> None:
        """Add a spacer row with as many cells as the previous row."""
        row = self.factory.create(FormulaRow).setalignments(self.alignments)
        for index in range(len(self.rows[-1].contents)):
            cell = row.createcell(index)
            cell.add(FormulaConstant(" "))  # FOUR-PER-EM SPACE
            row.add(cell)
        self.addrow(row)

    def addrow(self, row: FormulaRow) -> None:
        self.rows.append(row)
        self.add(row)


class FormulaEquation(CommandBit):
    """A simple numbered equation: its contents only."""

    piece = "equation"

    def parsebit(self, pos: Position) -> None:
        self.output = ContentsOutput()
        self.add(self.factory.parsetype(WholeFormula, pos))


class FormulaArray(MultiRowFormula):
    """An array with ``[valign]{alignments}`` parameters."""

    piece = "array"

    def parsebit(self, pos: Position) -> None:
        self.output = TaggedOutput().settag('span class="array"', False)
        self.parsealignments(pos)
        self.parserows(pos)

    def parsealignments(self, pos: Position) -> None:
        """Parse the vertical alignment (unused) and the column alignments."""
        self.valign = self.parsesquareliteral(pos) or "c"
        self.alignments = list(self.parseliteral(pos))


class FormulaMatrix(MultiRowFormula):
    """A matrix: an array with centered columns."""

    piece = "matrix"

    def parsebit(self, pos: Position) -> None:
        self.output = TaggedOutput().settag('span class="array"', False)
        self.valign = "c"
        self.alignments = ["c"]
        self.parserows(pos)


class FormulaCases(MultiRowFormula):
    """A cases statement: left-aligned rows after a big curly bracket."""

    piece = "cases"

    def parsebit(self, pos: Position) -> None:
        self.output = ContentsOutput()
        self.alignments = ["l", "l"]
        self.parserows(pos)
        for row in self.contents:
            for cell in row.contents:
                cell.output.settag('span class="case align-l"', True)
                cell.contents.append(FormulaConstant(" "))  # EM SPACE
        array = TaggedBit().complete(self.contents, 'span class="bracketcases"', True)
        brace = BigBracket(len(self.contents), "{", "l")
        self.contents = [*brace.getcontents(), array]


class EquationEnvironment(MultiRowFormula):
    """A named multi-row environment like ``align`` (unknown names are shown in red)."""

    piece: str

    def parsebit(self, pos: Position) -> None:
        environment = self.piece.replace("*", "")
        self.output = TaggedOutput().settag(f'span class="environment {environment}"', False)
        if environment in FormulaConfig.environments:
            self.alignments = FormulaConfig.environments[environment]
        else:
            Trace.error("Unknown equation environment " + self.piece)
            self.output = TaggedOutput().settag('span class="unknown"')
            self.add(FormulaConstant("\\begin{%s} " % environment))
            self.alignments = ["l"]
        self.parserows(pos)


class BeginCommand(CommandBit):
    """``\\begin{name}``: parse the environment up to ``\\end{name}``."""

    commandmap = {FormulaConfig.array["begin"]: ""}
    types = [FormulaEquation, FormulaArray, FormulaCases, FormulaMatrix]

    def parsebit(self, pos: Position) -> None:
        command = self.parseliteral(pos)
        bit = self.findbit(command)
        ending = FormulaConfig.array["end"] + "{" + command + "}"
        pos.pushending(ending)
        bit.parsebit(pos)
        self.add(bit)
        self.original += pos.popending(ending)
        self.size = bit.size

    def findbit(self, piece: str) -> CommandBit:
        """Create the bit for environment `piece` (starred variants included)."""
        name = piece.replace("*", "")
        for kind in BeginCommand.types:
            if name == kind.piece:
                return self.factory.create(kind)
        bit = self.factory.create(EquationEnvironment)
        bit.piece = piece
        return bit
