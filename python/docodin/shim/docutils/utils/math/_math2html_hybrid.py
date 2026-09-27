"""Template-defined commands with several parameters, like ``\\frac`` or ``\\sqrt``.

Each entry of `FormulaConfig.hybridfunctions` has a *read template*, a *write template*
and the tags of the functions ``f0``, ``f1``, ... used by the write template.

The read template lists the parameters: ``{$1}`` is a mandatory parameter, ``[$0]`` an
optional one; a name ending in ``!`` (``{$p!}``) is read literally, as text that can be
substituted into tags (``span style="color: $p;"``).

The write template builds the output: ``$1`` inserts a parameter (``$1.font`` also sets
its type), ``f0{...}`` wraps its contents in the tag of ``f0`` (``f0/`` is a self-closing
tag), ``(`` and ``)`` are brackets resized like ``\\left(`` and ``\\right)``, and any other
character is literal text. For example, ``\\frac`` reads ``{$1}{$2}`` and writes
``f0{f3{(}f1{$1}f3{)/(}f2{$2}f3{)}}``: a fraction span holding the numerator and the
denominator, with hidden parentheses and slash for copy and paste.
"""

from __future__ import annotations

import functools
import re
from dataclasses import dataclass

from docutils.utils.math._math2html_bits import FormulaConstant, TaggedBit
from docutils.utils.math._math2html_commands import BracketCommand, CommandBit
from docutils.utils.math._math2html_config import FormulaConfig
from docutils.utils.math._math2html_options import Trace
from docutils.utils.math._math2html_text import Position
from docutils.utils.math._math2html_tree import Container

__docformat__ = "reStructuredText"

# a parameter definition: "[" (optional) or "{", "$", a one-character name, "!" if literal
_PARAMETER = re.compile(r"(?P<bracket>[\[{])\$(?P<name>.)(?P<literal>!?)[\]}]")


@dataclass(eq=False)
class ParameterDefinition:
    """A parameter of a hybrid function, as defined in its read template, and its value."""

    name: str | None = None
    literal: bool = False
    optional: bool = False
    value: Container | None = None
    literalvalue: str | None = None

    @classmethod
    def fromtemplate(cls, template: str) -> list[ParameterDefinition]:
        """Return the parameter definitions of a read template like ``[$0]{$p!}``."""
        return [cls(match["name"], bool(match["literal"]), match["bracket"] == "[")
                for match in _PARAMETER.finditer(template)]

    def read(self, pos: Position, function: CommandBit) -> None:
        """Read the parameter value for `function` at `pos`."""
        if self.literal:
            if self.optional:
                self.literalvalue = function.parsesquareliteral(pos)
            else:
                self.literalvalue = function.parseliteral(pos)
            if self.literalvalue:
                self.value = FormulaConstant(self.literalvalue)
        elif self.optional:
            self.value = function.parsesquare(pos)
        else:
            self.value = function.parseparameter(pos)

    def __str__(self) -> str:
        return f"param {self.name}" + (f": {self.value}" if self.value else " (empty)")


class ParameterFunction(CommandBit):
    """A command with parameters defined by a read template."""

    params: dict[str, ParameterDefinition]

    def readparams(self, readtemplate: str, pos: Position) -> None:
        """Read the parameters defined in `readtemplate` into `params` (by ``$name``)."""
        self.params = {}
        for paramdef in ParameterDefinition.fromtemplate(readtemplate):
            paramdef.read(pos, self)
            self.params["$" + paramdef.name] = paramdef


# the write template, compiled into nodes


@dataclass(frozen=True)
class _Param:
    name: str  # "$1"
    typename: str | None  # the type set by "$1.font"


@dataclass(frozen=True)
class _Function:
    index: int  # "f0"
    contents: tuple[_Node, ...] | None  # None for a self-closing tag "f0/"


@dataclass(frozen=True)
class _Bracket:
    character: str  # "(" or ")"


@dataclass(frozen=True)
class _Text:
    character: str


type _Node = _Param | _Function | _Bracket | _Text


@functools.cache
def _compile(template: str) -> tuple[_Node, ...]:
    """Compile a write template into nodes."""
    nodes, _ = _compilefrom(template, 0, nested=False)
    return nodes


def _compilefrom(template: str, index: int, nested: bool) -> tuple[tuple[_Node, ...], int]:
    """Compile the template from `index` up to its end or, if `nested`, a closing brace.

    Return the nodes and the index after them.
    """
    nodes: list[_Node] = []
    while index < len(template):
        char = template[index]
        index += 1
        if nested and char == "}":
            break
        if char == "$":
            name = "$" + template[index]
            index += 1
            typename = None
            if template.startswith(".", index):
                end = index + 1
                while end < len(template) and template[end].isalpha():
                    end += 1
                typename, index = template[index + 1:end], end
            nodes.append(_Param(name, typename))
        elif char == "f":
            number = int(template[index])
            if template.startswith("/", index + 1):
                nodes.append(_Function(number, None))
                index += 2
            else:
                contents, index = _compilefrom(template, index + 2, nested=True)
                nodes.append(_Function(number, contents))
        elif char in "()":
            nodes.append(_Bracket(char))
        else:
            nodes.append(_Text(char))
    return tuple(nodes), index


class HybridFunction(ParameterFunction):
    """A command whose parameters and output are defined by templates."""

    commandmap = FormulaConfig.hybridfunctions

    def parsebit(self, pos: Position) -> None:
        readtemplate, writetemplate = self.translated[:2]
        self.readparams(readtemplate, pos)
        self.contents = self.writeparams(writetemplate)
        self.computehybridsize()

    def writeparams(self, writetemplate: str) -> list[Container]:
        """Build the output bits from the write template."""
        return self.writenodes(_compile(writetemplate))

    def writenodes(self, nodes: tuple[_Node, ...]) -> list[Container]:
        """Build the bits for `nodes`, leaving out missing parameters and empty tags."""
        result = []
        for node in nodes:
            match node:
                case _Param(name, typename):
                    bit = self.writeparam(name, typename)
                case _Function(index, contents):
                    bit = self.writefunction(index, contents)
                case _Bracket("("):
                    bit = self.writebracket("left", "(")
                case _Bracket(character):
                    bit = self.writebracket("right", character)
                case _Text(character):
                    bit = FormulaConstant(character)
            if bit:
                result.append(bit)
        return result

    def writeparam(self, name: str, typename: str | None) -> Container | None:
        """Return the value of parameter `name`, setting its type if given."""
        if name not in self.params:
            Trace.error("Unknown parameter " + name)
            return None
        value = self.params[name].value
        if typename is not None:
            value.type = typename
        return value

    def writefunction(self, index: int, contents: tuple[_Node, ...] | None) -> TaggedBit | None:
        """Wrap the bits for `contents` in the tag of function `index`."""
        tag = self.readtag(index)
        if not tag:
            return None
        if contents is None:
            return TaggedBit().selfcomplete(tag)
        bits = self.writenodes(contents)
        if not bits:
            return None
        return TaggedBit().complete(bits, tag)

    def readtag(self, index: int) -> str | None:
        """Return the tag of function `index`, with literal parameters substituted."""
        if 2 + index >= len(self.translated):
            Trace.error(f"Function f{index} is not defined")
            return None
        tag = self.translated[2 + index]
        for variable, param in self.params.items():
            if variable not in tag:
                continue
            if not param.literal:
                Trace.error(f"Parameters in tag {tag} should be literal: {{{variable}!}}")
                continue
            tag = tag.replace(variable, param.literalvalue or "")
        return tag

    def writebracket(self, direction: str, character: str) -> BracketCommand:
        """Return a new bracket looking in the given direction."""
        return self.factory.create(BracketCommand).create(direction, character)

    def computehybridsize(self) -> None:
        """Compute the size; stacking functions give it to all their top-level bits."""
        if self.command not in HybridSize.configsizes:
            self.computesize()
            return
        self.size = HybridSize().getsize(self)
        for element in self.contents:
            element.size = self.size


class HybridSize:
    """The size of a stacking hybrid function, from `FormulaConfig.hybridsizes`."""

    configsizes = FormulaConfig.hybridsizes

    def getsize(self, function: HybridFunction) -> int:
        """Evaluate a size expression like ``$1+$2+1`` for the parameters of `function`."""
        sizestring = self.configsizes[function.command]
        for name, param in function.params.items():
            if name in sizestring:
                sizestring = sizestring.replace(name, str(param.value.computesize()))
        if "$" in sizestring:
            Trace.error("Unconverted variable in hybrid size: " + sizestring)
            return 1
        return sum(int(term) for term in sizestring.split("+"))

