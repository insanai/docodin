"""Brackets, arrays, limits and template-defined commands of `math2html`."""

from __future__ import annotations

import unicodedata

from docutils.utils.math._math2html_base import (
    ContainerExtractor,
    ContentsOutput,
    DocumentParameters,
    EmptyOutput,
    Options,
    TaggedOutput,
    TextPosition,
    Trace,
)
from docutils.utils.math._math2html_config import ContainerConfig, FormulaConfig
from docutils.utils.math._math2html_formula import (
    CommandBit,
    EmptyCommand,
    FormulaCommand,
    FormulaConstant,
    FormulaProcessor,
    MathsProcessor,
    OneParamFunction,
    SymbolFunction,
    TaggedBit,
    WholeFormula,
)

__docformat__ = "reStructuredText"


class BigBracket:
    """A big bracket generator."""

    def __init__(self, size, bracket, alignment="l") -> None:
        """Set the size and symbol for the bracket."""
        self.size = size
        self.original = bracket
        self.alignment = alignment
        self.pieces = None
        if bracket in FormulaConfig.bigbrackets:
            self.pieces = FormulaConfig.bigbrackets[bracket]

    def getpiece(self, index):
        """Return the nth piece for the bracket."""
        function = getattr(self, "getpiece" + str(len(self.pieces)))
        return function(index)

    def getpiece1(self, index):
        """Return the only piece for a single-piece bracket."""
        return self.pieces[0]

    def getpiece3(self, index):
        """Get the nth piece for a 3-piece bracket: parenthesis or square bracket."""
        if index == 0:
            return self.pieces[0]
        if index == self.size - 1:
            return self.pieces[-1]
        return self.pieces[1]

    def getpiece4(self, index):
        """Get the nth piece for a 4-piece bracket: curly bracket."""
        if index == 0:
            return self.pieces[0]
        if index == self.size - 1:
            return self.pieces[3]
        if index == (self.size - 1) / 2:
            return self.pieces[2]
        return self.pieces[1]

    def getcell(self, index):
        """Get the bracket piece as an array cell."""
        piece = self.getpiece(index)
        span = 'span class="bracket align-' + self.alignment + '"'
        return TaggedBit().constant(piece, span)

    def getcontents(self):
        """Get the bracket as an array or as a single bracket."""
        if self.size == 1 or not self.pieces:
            return self.getsinglebracket()
        rows = []
        for index in range(self.size):
            cell = self.getcell(index)
            rows.append(TaggedBit().complete([cell], 'span class="arrayrow"'))
        return [TaggedBit().complete(rows, 'span class="array"')]

    def getsinglebracket(self):
        """Return the bracket as a single sign."""
        if self.original == ".":
            return [TaggedBit().constant("", 'span class="emptydot"')]
        return [TaggedBit().constant(self.original, 'span class="stretchy"')]


class FormulaEquation(CommandBit):
    """A simple numbered equation."""

    piece = "equation"

    def parsebit(self, pos) -> None:
        """Parse the array"""
        self.output = ContentsOutput()
        self.add(self.factory.parsetype(WholeFormula, pos))


class FormulaCell(FormulaCommand):
    """An array cell inside a row"""

    def setalignment(self, alignment):
        self.alignment = alignment
        self.output = TaggedOutput().settag('span class="arraycell align-' + alignment + '"', True)
        return self

    def parsebit(self, pos) -> None:
        self.factory.clearskipped(pos)
        if pos.finished():
            return
        self.add(self.factory.parsetype(WholeFormula, pos))


class FormulaRow(FormulaCommand):
    """An array row inside an array"""

    cellseparator = FormulaConfig.array["cellseparator"]

    def setalignments(self, alignments):
        self.alignments = alignments
        self.output = TaggedOutput().settag('span class="arrayrow"', True)
        return self

    def parsebit(self, pos) -> None:
        """Parse a whole row"""
        index = 0
        pos.pushending(self.cellseparator, optional=True)
        while not pos.finished():
            cell = self.createcell(index)
            cell.parsebit(pos)
            self.add(cell)
            index += 1
            pos.checkskip(self.cellseparator)
        if len(self.contents) == 0:
            self.output = EmptyOutput()

    def createcell(self, index):
        """Create the cell that corresponds to the given index."""
        alignment = self.alignments[index % len(self.alignments)]
        return self.factory.create(FormulaCell).setalignment(alignment)


class MultiRowFormula(CommandBit):
    """A formula with multiple rows."""

    def parserows(self, pos) -> None:
        """Parse all rows, finish when no more row ends"""
        self.rows = []
        first = True
        for row in self.iteraterows(pos):
            if first:
                first = False
            else:
                # intersparse empty rows
                self.addempty()
            row.parsebit(pos)
            self.addrow(row)
        self.size = len(self.rows)

    def iteraterows(self, pos):
        """Iterate over all rows, end when no more row ends"""
        rowseparator = FormulaConfig.array["rowseparator"]
        while True:
            pos.pushending(rowseparator, True)
            row = self.factory.create(FormulaRow)
            yield row.setalignments(self.alignments)
            if pos.checkfor(rowseparator):
                self.original += pos.popending(rowseparator)
            else:
                return

    def addempty(self) -> None:
        """Add an empty row."""
        row = self.factory.create(FormulaRow).setalignments(self.alignments)
        for index in range(len(self.rows[-1].contents)):
            cell = row.createcell(index)
            cell.add(FormulaConstant(" "))
            row.add(cell)
        self.addrow(row)

    def addrow(self, row) -> None:
        """Add a row to the contents and to the list of rows."""
        self.rows.append(row)
        self.add(row)


class FormulaArray(MultiRowFormula):
    """An array within a formula"""

    piece = "array"

    def parsebit(self, pos) -> None:
        """Parse the array"""
        self.output = TaggedOutput().settag('span class="array"', False)
        self.parsealignments(pos)
        self.parserows(pos)

    def parsealignments(self, pos) -> None:
        """Parse the different alignments"""
        # vertical
        self.valign = "c"
        literal = self.parsesquareliteral(pos)
        if literal:
            self.valign = literal
        # horizontal
        literal = self.parseliteral(pos)
        self.alignments = []
        for s in literal:
            self.alignments.append(s)


class FormulaMatrix(MultiRowFormula):
    """A matrix (array with center alignment)."""

    piece = "matrix"

    def parsebit(self, pos) -> None:
        """Parse the matrix, set alignments to 'c'."""
        self.output = TaggedOutput().settag('span class="array"', False)
        self.valign = "c"
        self.alignments = ["c"]
        self.parserows(pos)


class FormulaCases(MultiRowFormula):
    """A cases statement"""

    piece = "cases"

    def parsebit(self, pos) -> None:
        """Parse the cases"""
        self.output = ContentsOutput()
        self.alignments = ["l", "l"]
        self.parserows(pos)
        for row in self.contents:
            for cell in row.contents:
                cell.output.settag('span class="case align-l"', True)
                cell.contents.append(FormulaConstant(" "))
        array = TaggedBit().complete(self.contents, 'span class="bracketcases"', True)
        brace = BigBracket(len(self.contents), "{", "l")
        self.contents = brace.getcontents() + [array]


class EquationEnvironment(MultiRowFormula):
    """A \\begin{}...\\end equation environment with rows and cells."""

    def parsebit(self, pos) -> None:
        """Parse the whole environment."""
        environment = self.piece.replace("*", "")
        self.output = TaggedOutput().settag('span class="environment %s"' % environment, False)
        if environment in FormulaConfig.environments:
            self.alignments = FormulaConfig.environments[environment]
        else:
            Trace.error("Unknown equation environment " + self.piece)
            # print in red
            self.output = TaggedOutput().settag('span class="unknown"')
            self.add(FormulaConstant("\\begin{%s} " % environment))

            self.alignments = ["l"]
        self.parserows(pos)


class BeginCommand(CommandBit):
    """A \\begin{}...\\end command and what it entails (array, cases, aligned)"""

    commandmap = {FormulaConfig.array["begin"]: ""}

    types = [FormulaEquation, FormulaArray, FormulaCases, FormulaMatrix]

    def parsebit(self, pos) -> None:
        """Parse the begin command"""
        command = self.parseliteral(pos)
        bit = self.findbit(command)
        ending = FormulaConfig.array["end"] + "{" + command + "}"
        pos.pushending(ending)
        bit.parsebit(pos)
        self.add(bit)
        self.original += pos.popending(ending)
        self.size = bit.size

    def findbit(self, piece):
        """Find the command bit corresponding to the \\begin{piece}"""
        for type in BeginCommand.types:
            if piece.replace("*", "") == type.piece:
                return self.factory.create(type)
        bit = self.factory.create(EquationEnvironment)
        bit.piece = piece
        return bit


FormulaCommand.types += [BeginCommand]


class CombiningFunction(OneParamFunction):
    commandmap = FormulaConfig.combiningfunctions

    def parsebit(self, pos) -> None:
        """Parse a combining function."""
        combining = self.translated
        parameter = self.parsesingleparameter(pos)
        if not parameter:
            Trace.error("Missing parameter for combining function " + self.command)
            return
        # Trace.message('apply %s to %r'%(self.command, parameter.extracttext()))
        # parameter.tree()
        if not isinstance(parameter, FormulaConstant):
            try:
                extractor = ContainerExtractor(ContainerConfig.extracttext)
                parameter = extractor.extract(parameter)[0]
            except IndexError:
                Trace.error('No base character found for "%s".' % self.command)
                return
        # Trace.message('  basechar: %r' % parameter.string)
        # Insert combining character after the first character:
        if parameter.string.startswith("\u2009"):
            i = 2  # skip padding by SpacedCommand and FormulaConfig.modified
        else:
            i = 1
        parameter.string = parameter.string[:i] + combining + parameter.string[i:]
        # Use pre-composed characters if possible: \not{=} -> ≠, say.
        parameter.string = unicodedata.normalize("NFC", parameter.string)

    def parsesingleparameter(self, pos):
        """Parse a parameter, or a single letter."""
        self.factory.clearskipped(pos)
        if pos.finished():
            return None
        return self.parseparameter(pos)


class OversetFunction(OneParamFunction):
    """A function that decorates some bit of text with an overset."""

    commandmap = FormulaConfig.oversetfunctions

    def parsebit(self, pos) -> None:
        """Parse an overset-function"""
        symbol = self.translated
        self.symbol = TaggedBit().constant(symbol, "sup")
        self.parameter = self.parseparameter(pos)
        self.output = TaggedOutput().settag('span class="embellished"')
        self.contents.insert(0, self.symbol)
        self.parameter.output = TaggedOutput().settag('span class="base"')
        self.simplifyifpossible()


class UndersetFunction(OneParamFunction):
    """A function that decorates some bit of text with an underset."""

    commandmap = FormulaConfig.undersetfunctions

    def parsebit(self, pos) -> None:
        """Parse an underset-function"""
        symbol = self.translated
        self.symbol = TaggedBit().constant(symbol, "sub")
        self.parameter = self.parseparameter(pos)
        self.output = TaggedOutput().settag('span class="embellished"')
        self.contents.insert(0, self.symbol)
        self.parameter.output = TaggedOutput().settag('span class="base"')
        self.simplifyifpossible()


class LimitCommand(EmptyCommand):
    """A command which accepts limits above and below, in display mode."""

    commandmap = FormulaConfig.limitcommands

    def parsebit(self, pos) -> None:
        """Parse a limit command."""
        self.output = TaggedOutput().settag('span class="limits"')
        symbol = self.translated
        self.contents.append(TaggedBit().constant(symbol, 'span class="limit"'))


class LimitPreviousCommand(LimitCommand):
    """A command to limit the previous command."""

    commandmap = None

    def parsebit(self, pos) -> None:
        """Do nothing."""
        self.output = TaggedOutput().settag('span class="limits"')
        self.factory.clearskipped(pos)

    def __str__(self) -> str:
        """Return a printable representation."""
        return "Limit previous command"


class LimitsProcessor(MathsProcessor):
    """A processor for limits inside an element."""

    def process(self, contents, index) -> None:
        """Process the limits for an element."""
        if Options.simplemath:
            return
        if self.checklimits(contents, index):
            self.modifylimits(contents, index)
        if self.checkscript(contents, index) and self.checkscript(contents, index + 1):
            self.modifyscripts(contents, index)

    def checklimits(self, contents, index):
        """Check if the current position has a limits command."""
        # TODO: check for \limits macro
        if not DocumentParameters.displaymode:
            return False
        if self.checkcommand(contents, index + 1, LimitPreviousCommand):
            self.limitsahead(contents, index)
            return False
        if not isinstance(contents[index], LimitCommand):
            return False
        return self.checkscript(contents, index + 1)

    def limitsahead(self, contents, index) -> None:
        """Limit the current element based on the next."""
        contents[index + 1].add(contents[index].clone())
        contents[index].output = EmptyOutput()

    def modifylimits(self, contents, index) -> None:
        """Modify a limits commands so that the limits appear above and below."""
        limited = contents[index]
        subscript = self.getlimit(contents, index + 1)
        if self.checkscript(contents, index + 1):
            superscript = self.getlimit(contents, index + 1)
        else:
            superscript = TaggedBit().constant("\u2009", 'sup class="limit"')
        # fix order if source is x^i
        if subscript.command == "^":
            superscript, subscript = subscript, superscript
        limited.contents.append(subscript)
        limited.contents.insert(0, superscript)

    def getlimit(self, contents, index):
        """Get the limit for a limits command."""
        limit = self.getscript(contents, index)
        limit.output.tag = limit.output.tag.replace("script", "limit")
        return limit

    def modifyscripts(self, contents, index) -> None:
        """Modify the super- and subscript to appear vertically aligned."""
        subscript = self.getscript(contents, index)
        # subscript removed so instead of index + 1 we get index again
        superscript = self.getscript(contents, index)
        # super-/subscript are reversed if source is x^i_j
        if subscript.command == "^":
            superscript, subscript = subscript, superscript
        scripts = TaggedBit().complete([superscript, subscript], 'span class="scripts"')
        contents.insert(index, scripts)

    def checkscript(self, contents, index):
        """Check if the current element is a sub- or superscript."""
        return self.checkcommand(contents, index, SymbolFunction)

    def checkcommand(self, contents, index, type):
        """Check for the given type as the current element."""
        if len(contents) <= index:
            return False
        return isinstance(contents[index], type)

    def getscript(self, contents, index):
        """Get the sub- or superscript."""
        bit = contents[index]
        bit.output.tag += ' class="script"'
        del contents[index]
        return bit


class BracketCommand(OneParamFunction):
    """A command which defines a bracket."""

    commandmap = FormulaConfig.bracketcommands

    def parsebit(self, pos) -> None:
        """Parse the bracket."""
        OneParamFunction.parsebit(self, pos)

    def create(self, direction, character):
        """Create the bracket for the given character."""
        self.original = character
        self.command = "\\" + direction
        self.contents = [FormulaConstant(character)]
        return self


class BracketProcessor(MathsProcessor):
    """A processor for bracket commands."""

    def process(self, contents, index):
        """Convert the bracket using Unicode pieces, if possible."""
        if Options.simplemath:
            return
        if self.checkleft(contents, index):
            return self.processleft(contents, index)

    def processleft(self, contents, index) -> None:
        """Process a left bracket."""
        rightindex = self.findright(contents, index + 1)
        if not rightindex:
            return
        size = self.findmax(contents, index, rightindex)
        self.resize(contents[index], size)
        self.resize(contents[rightindex], size)

    def checkleft(self, contents, index):
        """Check if the command at the given index is left."""
        return self.checkdirection(contents[index], "\\left")

    def checkright(self, contents, index):
        """Check if the command at the given index is right."""
        return self.checkdirection(contents[index], "\\right")

    def checkdirection(self, bit, command):
        """Check if the given bit is the desired bracket command."""
        if not isinstance(bit, BracketCommand):
            return False
        return bit.command == command

    def findright(self, contents, index):
        """Find the right bracket starting at the given index, or 0."""
        depth = 1
        while index < len(contents):
            if self.checkleft(contents, index):
                depth += 1
            if self.checkright(contents, index):
                depth -= 1
            if depth == 0:
                return index
            index += 1
        return None

    def findmax(self, contents, leftindex, rightindex):
        """Find the max size of the contents between the two given indices."""
        sliced = contents[leftindex:rightindex]
        return max(element.size for element in sliced)

    def resize(self, command, size) -> None:
        """Resize a bracket command to the given size."""
        character = command.extracttext()
        alignment = command.command.replace("\\", "")
        bracket = BigBracket(size, character, alignment)
        command.output = ContentsOutput()
        command.contents = bracket.getcontents()


FormulaCommand.types += [
    OversetFunction, UndersetFunction, CombiningFunction, LimitCommand, BracketCommand]


FormulaProcessor.processors += [
    LimitsProcessor(),
    BracketProcessor(),
]


class ParameterDefinition:
    """The definition of a parameter in a hybrid function.

    [] parameters are optional, {} parameters are mandatory.
    Each parameter has a one-character name, like {$1} or {$p}.
    A parameter that ends in ! like {$p!} is a literal.
    Example: [$1]{$p!} reads an optional parameter $1 and a literal mandatory parameter p.
    """

    parambrackets = [("[", "]"), ("{", "}")]

    def __init__(self) -> None:
        self.name = None
        self.literal = False
        self.optional = False
        self.value = None
        self.literalvalue = None

    def parse(self, pos):
        """Parse a parameter definition: [$0], {$x}, {$1!}..."""
        for opening, closing in ParameterDefinition.parambrackets:
            if pos.checkskip(opening):
                if opening == "[":
                    self.optional = True
                if not pos.checkskip("$"):
                    Trace.error("Wrong parameter name, did you mean $" + pos.current() + "?")
                    return None
                self.name = pos.skipcurrent()
                if pos.checkskip("!"):
                    self.literal = True
                if not pos.checkskip(closing):
                    Trace.error("Wrong parameter closing " + pos.skipcurrent())
                    return None
                return self
        Trace.error("Wrong character in parameter template: " + pos.skipcurrent())
        return None

    def read(self, pos, function) -> None:
        """Read the parameter itself using the definition."""
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
        """Return a printable representation."""
        result = "param " + self.name
        if self.value:
            result += ": " + str(self.value)
        else:
            result += " (empty)"
        return result


class ParameterFunction(CommandBit):
    """A function with a variable number of parameters defined in a template.

    The parameters are defined as a parameter definition.
    """

    def readparams(self, readtemplate, pos) -> None:
        """Read the params according to the template."""
        self.params = {}
        for paramdef in self.paramdefs(readtemplate):
            paramdef.read(pos, self)
            self.params["$" + paramdef.name] = paramdef

    def paramdefs(self, readtemplate):
        """Read each param definition in the template"""
        pos = TextPosition(readtemplate)
        while not pos.finished():
            paramdef = ParameterDefinition().parse(pos)
            if paramdef:
                yield paramdef

    def getparam(self, name):
        """Get a parameter as parsed."""
        if name not in self.params:
            return None
        return self.params[name]

    def getvalue(self, name):
        """Get the value of a parameter."""
        return self.getparam(name).value

    def getliteralvalue(self, name):
        """Get the literal value of a parameter."""
        param = self.getparam(name)
        if not param or not param.literalvalue:
            return None
        return param.literalvalue


class HybridFunction(ParameterFunction):
    """
    A parameter function where the output is also defined using a template.
    The template can use a number of functions; each function has an associated
    tag.
    Example: [f0{$1},span class="fbox"] defines a function f0 which corresponds
    to a span of class fbox, yielding <span class="fbox">$1</span>.
    Literal parameters can be used in tags definitions:
      [f0{$1},span style="color: $p;"]
    yields <span style="color: $p;">$1</span>, where $p is a literal parameter.
    Sizes can be specified in hybridsizes, e.g. adding parameter sizes. By
    default the resulting size is the max of all arguments. Sizes are used
    to generate the right parameters.
    A function followed by a single / is output as a self-closing XHTML tag:
      [f0/,hr]
    will generate <hr/>.
    """

    commandmap = FormulaConfig.hybridfunctions

    def parsebit(self, pos) -> None:
        """Parse a function with [] and {} parameters"""
        readtemplate = self.translated[0]
        writetemplate = self.translated[1]
        self.readparams(readtemplate, pos)
        self.contents = self.writeparams(writetemplate)
        self.computehybridsize()

    def writeparams(self, writetemplate):
        """Write all params according to the template"""
        return self.writepos(TextPosition(writetemplate))

    def writepos(self, pos):
        """Write all params as read in the parse position."""
        result = []
        while not pos.finished():
            if pos.checkskip("$"):
                param = self.writeparam(pos)
                if param:
                    result.append(param)
            elif pos.checkskip("f"):
                function = self.writefunction(pos)
                if function:
                    function.type = None
                    result.append(function)
            elif pos.checkskip("("):
                result.append(self.writebracket("left", "("))
            elif pos.checkskip(")"):
                result.append(self.writebracket("right", ")"))
            else:
                result.append(FormulaConstant(pos.skipcurrent()))
        return result

    def writeparam(self, pos):
        """Write a single param of the form $0, $x..."""
        name = "$" + pos.skipcurrent()
        if name not in self.params:
            Trace.error("Unknown parameter " + name)
            return None
        if not self.params[name]:
            return None
        if pos.checkskip("."):
            self.params[name].value.type = pos.globalpha()
        return self.params[name].value

    def writefunction(self, pos):
        """Write a single function f0,...,fn."""
        tag = self.readtag(pos)
        if not tag:
            return None
        if pos.checkskip("/"):
            # self-closing XHTML tag, such as <hr/>
            return TaggedBit().selfcomplete(tag)
        if not pos.checkskip("{"):
            Trace.error("Function should be defined in {}")
            return None
        pos.pushending("}")
        contents = self.writepos(pos)
        pos.popending()
        if len(contents) == 0:
            return None
        return TaggedBit().complete(contents, tag)

    def readtag(self, pos):
        """Get the tag corresponding to the given index. Does parameter substitution."""
        if not pos.current().isdigit():
            Trace.error("Function should be f0,...,f9: f" + pos.current())
            return None
        index = int(pos.skipcurrent())
        if 2 + index > len(self.translated):
            Trace.error("Function f" + str(index) + " is not defined")
            return None
        tag = self.translated[2 + index]
        if "$" not in tag:
            return tag
        for variable in self.params:
            if variable in tag:
                param = self.params[variable]
                if not param.literal:
                    Trace.error(f"Parameters in tag {tag} should be literal: {{{variable}!}}")
                    continue
                if param.literalvalue:
                    value = param.literalvalue
                else:
                    value = ""
                tag = tag.replace(variable, value)
        return tag

    def writebracket(self, direction, character):
        """Return a new bracket looking at the given direction."""
        return self.factory.create(BracketCommand).create(direction, character)

    def computehybridsize(self) -> None:
        """Compute the size of the hybrid function."""
        if self.command not in HybridSize.configsizes:
            self.computesize()
            return
        self.size = HybridSize().getsize(self)
        # set the size in all elements at first level
        for element in self.contents:
            element.size = self.size


class HybridSize:
    """The size associated with a hybrid function."""

    configsizes = FormulaConfig.hybridsizes

    def getsize(self, function):
        """Read the size for a function and parse it."""
        sizestring = self.configsizes[function.command]
        for name in function.params:
            if name in sizestring:
                size = function.params[name].value.computesize()
                sizestring = sizestring.replace(name, str(size))
        if "$" in sizestring:
            Trace.error("Unconverted variable in hybrid size: " + sizestring)
            return 1
        return eval(sizestring)


FormulaCommand.types += [HybridFunction]
