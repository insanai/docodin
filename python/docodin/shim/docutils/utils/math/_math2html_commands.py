"""LaTeX commands in a formula: ``\\name`` followed by its parameters.

`FormulaCommand` reads the command name and asks the factory for the command kind whose
table (`commandmap`) contains it. That kind's `parsebit` then reads the parameters and
decides the output. Unknown commands are reported and shown in a ``span class="unknown"``.
"""

from __future__ import annotations

import unicodedata
from typing import Any

from docutils.utils.math._math2html_bits import (
    Bracket,
    FormulaBit,
    FormulaConstant,
    SquareBracket,
    TaggedBit,
)
from docutils.utils.math._math2html_config import ContainerConfig, FormulaConfig
from docutils.utils.math._math2html_options import Trace
from docutils.utils.math._math2html_text import Position
from docutils.utils.math._math2html_tree import (
    ContainerExtractor,
    FixedOutput,
    TaggedOutput,
)

__docformat__ = "reStructuredText"


class FormulaCommand(FormulaBit):
    """A LaTeX command inside a formula."""

    start = FormulaConfig.starts["command"]
    commandmap: dict[str, Any] | None = None

    @classmethod
    def detect(cls, pos: Position) -> bool:
        return pos.checkfor(FormulaCommand.start)

    def parsebit(self, pos: Position) -> FormulaBit | None:
        """Parse the command with its kind; an unknown command stays this bit."""
        command = self.extractcommand(pos)
        bit = self.parsewithcommand(command, pos)
        if bit:
            return bit
        if command.startswith(("\\up", "\\Up")):
            upgreek = self.parseupgreek(command, pos)
            if upgreek:
                return upgreek
        Trace.error("Unknown command " + command)
        self.output = TaggedOutput().settag('span class="unknown"')
        self.add(FormulaConstant(command))
        return None

    def parsewithcommand(self, command: str, pos: Position) -> FormulaBit | None:
        """Parse the command with the kind that knows it, if any."""
        kind = self.factory.commandtype(command)
        if kind is None:
            return None
        return self.parsecommandtype(command, kind, pos)

    def parsecommandtype(self, command: str, kind: type[CommandBit],
                         pos: Position) -> FormulaBit:
        """Parse the command as a bit of the given kind."""
        bit = self.factory.create(kind)
        bit.setcommand(command)
        return bit.parsebit(pos) or bit

    def extractcommand(self, pos: Position) -> str:
        """Read the command name: a run of letters (and an optional ``*``) or one symbol."""
        pos.skip(FormulaCommand.start)
        if pos.finished():
            return self.emptycommand(pos)
        if pos.current().isalpha():
            command = FormulaCommand.start + pos.globalpha()
            pos.checkskip("*")  # starred variants are treated like the plain command
            return command
        return FormulaCommand.start + pos.skipcurrent()

    def emptycommand(self, pos: Position) -> str:
        """A backslash before an ending escapes it: ``{ \\{ \\} }``."""
        command = ""
        if not pos.isout():
            ending = pos.nextending()
            if ending and pos.checkskip(ending):
                command = ending
        return FormulaCommand.start + command

    def parseupgreek(self, command: str, pos: Position) -> FormulaBit | None:
        """Parse upright Greek letters like ``\\upalpha`` as the plain letter in a font."""
        if len(command) < 4:
            return None
        if command.startswith("\\up"):
            upcommand = "\\" + command[3:]
        elif pos.checkskip("\\Up"):
            upcommand = "\\" + command[3:4].upper() + command[4:]
        else:
            Trace.error("Impossible upgreek command: " + command)
            return None
        upgreek = self.parsewithcommand(upcommand, pos)
        if upgreek:
            upgreek.type = "font"
        return upgreek


class CommandBit(FormulaCommand):
    """A known command: `translated` is its entry in `commandmap`."""

    command: str
    translated: Any

    def setcommand(self, command: str) -> None:
        """Set the command and look up its translation."""
        self.command = command
        if self.commandmap:
            self.original += command
            self.translated = self.commandmap[command]

    def parseparameter(self, pos: Position) -> FormulaBit | None:
        """Parse a parameter: the next formula bit, after any space or comment."""
        self.factory.clearskipped(pos)
        if pos.finished():
            return None
        parameter = self.factory.parseany(pos)
        self.add(parameter)
        return parameter

    def parsesquare(self, pos: Position) -> SquareBracket | None:
        """Parse an optional ``[...]`` parameter."""
        self.factory.clearskipped(pos)
        if not self.factory.detecttype(SquareBracket, pos):
            return None
        bracket = self.factory.parsetype(SquareBracket, pos)
        self.add(bracket)
        return bracket

    def parseliteral(self, pos: Position) -> str | None:
        """Parse a literal parameter: a ``{...}`` group, or a run of value characters."""
        self.factory.clearskipped(pos)
        if not self.factory.detecttype(Bracket, pos):
            if not pos.isvalue():
                Trace.error("No literal parameter found at: " + pos.identifier())
                return None
            return pos.globvalue()
        bracket = self.factory.create(Bracket)
        self.add(bracket.parseliteral(pos))
        return bracket.literal

    def parsesquareliteral(self, pos: Position) -> str | None:
        """Parse an optional ``[...]`` parameter literally."""
        self.factory.clearskipped(pos)
        if not self.factory.detecttype(SquareBracket, pos):
            return None
        bracket = self.factory.create(SquareBracket)
        self.add(bracket.parseliteral(pos))
        return bracket.literal

    def parsetext(self, pos: Position) -> Bracket | None:
        """Parse a ``{...}`` text parameter."""
        self.factory.clearskipped(pos)
        if not self.factory.detecttype(Bracket, pos):
            Trace.error("No text parameter for " + self.command)
            return None
        bracket = self.factory.create(Bracket).parsetext(pos)
        self.add(bracket)
        return bracket


class EmptyCommand(CommandBit):
    """A command without parameters, replaced by its translation."""

    commandmap = FormulaConfig.commands

    def parsebit(self, pos: Position) -> None:
        self.contents = [FormulaConstant(self.translated)]


class SpacedCommand(CommandBit):
    """A relation symbol, padded with thin spaces."""

    commandmap = FormulaConfig.spacedcommands

    def parsebit(self, pos: Position) -> None:
        self.contents = [FormulaConstant(" " + self.translated + " ")]


class AlphaCommand(EmptyCommand):
    """A command for a letter, set in italics (except upright Greek capitals)."""

    commandmap = FormulaConfig.alphacommands
    greek_capitals = ("\\Xi", "\\Theta", "\\Pi", "\\Sigma", "\\Gamma", "\\Lambda", "\\Phi",
                      "\\Psi", "\\Delta", "\\Upsilon", "\\Omega")

    def parsebit(self, pos: Position) -> None:
        super().parsebit(pos)
        if self.command not in self.greek_capitals:
            self.type = "alpha"


class OneParamFunction(CommandBit):
    """A command wrapping its parameter in a tag."""

    commandmap = FormulaConfig.onefunctions
    simplified = False

    def parsebit(self, pos: Position) -> None:
        self.output = TaggedOutput().settag(self.translated)
        self.parseparameter(pos)
        self.simplifyifpossible()

    def simplifyifpossible(self) -> None:
        """Use the fixed translation of the whole source, like ``\\mathbb{R}``, if any."""
        if self.original in self.commandmap:
            self.output = FixedOutput()
            self.html = [self.commandmap[self.original]]
            self.simplified = True


class SymbolFunction(CommandBit):
    """A sub- or superscript: ``_`` or ``^`` and a parameter."""

    commandmap = FormulaConfig.symbolfunctions

    @classmethod
    def detect(cls, pos: Position) -> bool:
        return pos.current() in SymbolFunction.commandmap

    def parsebit(self, pos: Position) -> None:
        self.setcommand(pos.current())
        pos.skip(self.command)
        self.output = TaggedOutput().settag(self.translated)
        self.parseparameter(pos)


class TextFunction(CommandBit):
    """A command whose parameter is read as text."""

    commandmap = FormulaConfig.textfunctions

    def parsebit(self, pos: Position) -> None:
        self.output = TaggedOutput().settag(self.translated)
        self.parsetext(pos)

    def process(self) -> None:
        self.type = "font"


class FontFunction(OneParamFunction):
    """A command setting its parameter in a font."""

    commandmap = FormulaConfig.fontfunctions

    def process(self) -> None:
        self.type = "font"
        self.simplifyifpossible()


class CombiningFunction(OneParamFunction):
    """An accent: a combining character added after the first character of the parameter."""

    commandmap = FormulaConfig.combiningfunctions

    def parsebit(self, pos: Position) -> None:
        parameter = self.parsesingleparameter(pos)
        if not parameter:
            Trace.error("Missing parameter for combining function " + self.command)
            return
        if not isinstance(parameter, FormulaConstant):
            constants = ContainerExtractor(ContainerConfig.extracttext).extract(parameter)
            if not constants:
                Trace.error('No base character found for "%s".' % self.command)
                return
            parameter = constants[0]
        # skip the thin space padding of spaced commands and symbols
        split = 2 if parameter.string.startswith(" ") else 1
        text = parameter.string[:split] + self.translated + parameter.string[split:]
        # use a precomposed character if possible: \not{=} -> ≠, say
        parameter.string = unicodedata.normalize("NFC", text)

    def parsesingleparameter(self, pos: Position) -> FormulaBit | None:
        """Parse a parameter, or a single letter."""
        self.factory.clearskipped(pos)
        if pos.finished():
            return None
        return self.parseparameter(pos)


def _embellish(function: OneParamFunction, pos: Position, symboltag: str) -> None:
    """Put the translated symbol of `function` over or under its parameter."""
    symbol = TaggedBit().constant(function.translated, symboltag)
    function.symbol = symbol
    function.parameter = function.parseparameter(pos)
    function.output = TaggedOutput().settag('span class="embellished"')
    function.contents.insert(0, symbol)
    function.parameter.output = TaggedOutput().settag('span class="base"')
    function.simplifyifpossible()


class OversetFunction(OneParamFunction):
    """A command setting a symbol over its parameter, like ``\\vec``."""

    commandmap = FormulaConfig.oversetfunctions

    def parsebit(self, pos: Position) -> None:
        _embellish(self, pos, "sup")


class UndersetFunction(OneParamFunction):
    """A command setting a symbol under its parameter."""

    commandmap = FormulaConfig.undersetfunctions

    def parsebit(self, pos: Position) -> None:
        _embellish(self, pos, "sub")


class LimitCommand(EmptyCommand):
    """A big operator; in display mode, its scripts become limits above and below."""

    commandmap = FormulaConfig.limitcommands

    def parsebit(self, pos: Position) -> None:
        self.output = TaggedOutput().settag('span class="limits"')
        self.contents.append(TaggedBit().constant(self.translated, 'span class="limit"'))


class LimitPreviousCommand(LimitCommand):
    """A command to limit the previous command (unused: ``\\limits`` is not supported)."""

    commandmap = None

    def parsebit(self, pos: Position) -> None:
        self.output = TaggedOutput().settag('span class="limits"')
        self.factory.clearskipped(pos)

    def __str__(self) -> str:
        return "Limit previous command"


class BracketCommand(OneParamFunction):
    """A ``\\left``, ``\\middle`` or ``\\right`` bracket; resized by the bracket processor."""

    commandmap = FormulaConfig.bracketcommands

    def create(self, direction: str, character: str) -> BracketCommand:
        """Make this a ``\\left`` or ``\\right`` bracket for `character`."""
        self.original = character
        self.command = "\\" + direction
        self.contents = [FormulaConstant(character)]
        return self
