"""Formula parsing and the basic formula bits and commands of `math2html`."""

from __future__ import annotations

from docutils.utils.math._math2html_base import (
    Cloner,
    Constant,
    Container,
    ContentsOutput,
    DocumentParameters,
    FixedOutput,
    Parser,
    TaggedOutput,
    TextPosition,
    Trace,
)
from docutils.utils.math._math2html_config import FormulaConfig

__docformat__ = "reStructuredText"


class FormulaParser(Parser):
    """Parses a formula"""

    def parseheader(self, reader):
        """See if the formula is inlined"""
        self.begin = reader.linenumber + 1
        type = self.parsetype(reader)
        if not type:
            reader.nextline()
            type = self.parsetype(reader)
            if not type:
                Trace.error("Unknown formula type in " + reader.currentline().strip())
                return ["unknown"]
        return [type]

    def parsetype(self, reader):
        """Get the formula type from the first line."""
        if reader.currentline().find(FormulaConfig.starts["simple"]) >= 0:
            return "inline"
        if reader.currentline().find(FormulaConfig.starts["complex"]) >= 0:
            return "block"
        if reader.currentline().find(FormulaConfig.starts["unnumbered"]) >= 0:
            return "block"
        if reader.currentline().find(FormulaConfig.starts["beginbefore"]) >= 0:
            return "numbered"
        return None

    def parse(self, reader):
        """Parse the formula until the end"""
        formula = self.parseformula(reader)
        while not reader.currentline().startswith(self.ending):
            stripped = reader.currentline().strip()
            if len(stripped) > 0:
                Trace.error("Unparsed formula line " + stripped)
            reader.nextline()
        reader.nextline()
        return formula

    def parseformula(self, reader):
        """Parse the formula contents"""
        simple = FormulaConfig.starts["simple"]
        if simple in reader.currentline():
            rest = reader.currentline().split(simple, 1)[1]
            if simple in rest:
                # formula is $...$
                return self.parsesingleliner(reader, simple, simple)
            # formula is multiline $...$
            return self.parsemultiliner(reader, simple, simple)
        if FormulaConfig.starts["complex"] in reader.currentline():
            # formula of the form \[...\]
            return self.parsemultiliner(
                reader, FormulaConfig.starts["complex"], FormulaConfig.endings["complex"]
            )
        beginbefore = FormulaConfig.starts["beginbefore"]
        beginafter = FormulaConfig.starts["beginafter"]
        if beginbefore in reader.currentline():
            if reader.currentline().strip().endswith(beginafter):
                current = reader.currentline().strip()
                endsplit = current.split(beginbefore)[1].split(beginafter)
                startpiece = beginbefore + endsplit[0] + beginafter
                endbefore = FormulaConfig.endings["endbefore"]
                endafter = FormulaConfig.endings["endafter"]
                endpiece = endbefore + endsplit[0] + endafter
                return startpiece + self.parsemultiliner(reader, startpiece, endpiece) + endpiece
            Trace.error("Missing " + beginafter + " in " + reader.currentline())
            return ""
        begincommand = FormulaConfig.starts["command"]
        beginbracket = FormulaConfig.starts["bracket"]
        if begincommand in reader.currentline() and beginbracket in reader.currentline():
            endbracket = FormulaConfig.endings["bracket"]
            return self.parsemultiliner(reader, beginbracket, endbracket)
        Trace.error("Formula beginning " + reader.currentline() + " is unknown")
        return ""

    def parsesingleliner(self, reader, start, ending):
        """Parse a formula in one line"""
        line = reader.currentline().strip()
        if start not in line:
            Trace.error("Line " + line + " does not contain formula start " + start)
            return ""
        if not line.endswith(ending):
            Trace.error("Formula " + line + " does not end with " + ending)
            return ""
        index = line.index(start)
        rest = line[index + len(start) : -len(ending)]
        reader.nextline()
        return rest

    def parsemultiliner(self, reader, start, ending):
        """Parse a formula in multiple lines"""
        formula = ""
        line = reader.currentline()
        if start not in line:
            Trace.error("Line " + line.strip() + " does not contain formula start " + start)
            return ""
        index = line.index(start)
        line = line[index + len(start) :].strip()
        while not line.endswith(ending):
            formula += line + "\n"
            reader.nextline()
            line = reader.currentline()
        formula += line[: -len(ending)]
        reader.nextline()
        return formula


class FormulaBit(Container):
    """A bit of a formula"""

    type = None
    size = 1
    original = ""

    def __init__(self) -> None:
        """The formula bit type can be 'alpha', 'number', 'font'."""
        self.contents = []
        self.output = ContentsOutput()

    def setfactory(self, factory):
        """Set the internal formula factory."""
        self.factory = factory
        return self

    def add(self, bit) -> None:
        """Add any kind of formula bit already processed"""
        self.contents.append(bit)
        self.original += bit.original
        bit.parent = self

    def skiporiginal(self, string, pos) -> None:
        """Skip a string and add it to the original formula"""
        self.original += string
        if not pos.checkskip(string):
            Trace.error("String " + string + " not at " + pos.identifier())

    def computesize(self):
        """Compute the size of the bit as the max of the sizes of all contents."""
        if len(self.contents) == 0:
            return 1
        self.size = max(element.size for element in self.contents)
        return self.size

    def clone(self):
        """Return a copy of itself."""
        return self.factory.parseformula(self.original)

    def __str__(self) -> str:
        """Get a string representation"""
        return self.__class__.__name__ + " read in " + self.original


class TaggedBit(FormulaBit):
    """A tagged string in a formula"""

    def constant(self, constant, tag):
        """Set the constant and the tag"""
        self.output = TaggedOutput().settag(tag)
        self.add(FormulaConstant(constant))
        return self

    def complete(self, contents, tag, breaklines=False):
        """Set the constant and the tag"""
        self.contents = contents
        self.output = TaggedOutput().settag(tag, breaklines)
        return self

    def selfcomplete(self, tag):
        """Set the self-closing tag, no contents (as in <hr/>)."""
        self.output = TaggedOutput().settag(tag, empty=True)
        return self


class FormulaConstant(Constant):
    """A constant string in a formula"""

    def __init__(self, string) -> None:
        """Set the constant string"""
        Constant.__init__(self, string)
        self.original = string
        self.size = 1
        self.type = None

    def computesize(self):
        """Compute the size of the constant: always 1."""
        return self.size

    def clone(self):
        """Return a copy of itself."""
        return FormulaConstant(self.original)

    def __str__(self) -> str:
        """Return a printable representation."""
        return "Formula constant: " + self.string


class RawText(FormulaBit):
    """A bit of text inside a formula"""

    def detect(self, pos):
        """Detect a bit of raw text"""
        return pos.current().isalpha()

    def parsebit(self, pos) -> None:
        """Parse alphabetic text"""
        alpha = pos.globalpha()
        self.add(FormulaConstant(alpha))
        self.type = "alpha"


class FormulaSymbol(FormulaBit):
    """A symbol inside a formula"""

    modified = FormulaConfig.modified
    unmodified = FormulaConfig.unmodified["characters"]

    def detect(self, pos) -> bool:
        """Detect a symbol"""
        if pos.current() in FormulaSymbol.unmodified:
            return True
        if pos.current() in FormulaSymbol.modified:
            return True
        return False

    def parsebit(self, pos) -> None:
        """Parse the symbol"""
        if pos.current() in FormulaSymbol.unmodified:
            self.addsymbol(pos.current(), pos)
            return
        if pos.current() in FormulaSymbol.modified:
            self.addsymbol(FormulaSymbol.modified[pos.current()], pos)
            return
        Trace.error("Symbol " + pos.current() + " not found")

    def addsymbol(self, symbol, pos) -> None:
        """Add a symbol"""
        self.skiporiginal(pos.current(), pos)
        self.contents.append(FormulaConstant(symbol))


class FormulaNumber(FormulaBit):
    """A string of digits in a formula"""

    def detect(self, pos):
        """Detect a digit"""
        return pos.current().isdigit()

    def parsebit(self, pos) -> None:
        """Parse a bunch of digits"""
        digits = pos.glob(lambda: pos.current().isdigit())
        self.add(FormulaConstant(digits))
        self.type = "number"


class Comment(FormulaBit):
    """A LaTeX comment: % to the end of the line."""

    start = FormulaConfig.starts["comment"]

    def detect(self, pos):
        """Detect the %."""
        return pos.current() == self.start

    def parsebit(self, pos) -> None:
        """Parse to the end of the line."""
        self.original += pos.globincluding("\n")


class WhiteSpace(FormulaBit):
    """Some white space inside a formula."""

    def detect(self, pos):
        """Detect the white space."""
        return pos.current().isspace()

    def parsebit(self, pos) -> None:
        """Parse all whitespace."""
        self.original += pos.skipspace()

    def __str__(self) -> str:
        """Return a printable representation."""
        return "Whitespace: *" + self.original + "*"


class Bracket(FormulaBit):
    """A {} bracket inside a formula"""

    start = FormulaConfig.starts["bracket"]
    ending = FormulaConfig.endings["bracket"]

    def __init__(self) -> None:
        """Create a (possibly literal) new bracket"""
        FormulaBit.__init__(self)
        self.inner = None

    def detect(self, pos):
        """Detect the start of a bracket"""
        return pos.checkfor(self.start)

    def parsebit(self, pos):
        """Parse the bracket"""
        self.parsecomplete(pos, self.innerformula)
        return self

    def parsetext(self, pos):
        """Parse a text bracket"""
        self.parsecomplete(pos, self.innertext)
        return self

    def parseliteral(self, pos):
        """Parse a literal bracket"""
        self.parsecomplete(pos, self.innerliteral)
        return self

    def parsecomplete(self, pos, innerparser):
        """Parse the start and end marks"""
        if not pos.checkfor(self.start):
            Trace.error("Bracket should start with " + self.start + " at " + pos.identifier())
            return None
        self.skiporiginal(self.start, pos)
        pos.pushending(self.ending)
        innerparser(pos)
        self.original += pos.popending(self.ending)
        self.computesize()

    def innerformula(self, pos) -> None:
        """Parse a whole formula inside the bracket"""
        while not pos.finished():
            self.add(self.factory.parseany(pos))

    def innertext(self, pos) -> None:
        """Parse some text inside the bracket, following textual rules."""
        specialchars = list(FormulaConfig.symbolfunctions.keys()) + [
            FormulaConfig.starts["command"],
            FormulaConfig.starts["bracket"],
            Comment.start,
        ]
        while not pos.finished():
            if pos.current() in specialchars:
                self.add(self.factory.parseany(pos))
                if pos.checkskip(" "):
                    self.original += " "
            else:
                self.add(FormulaConstant(pos.skipcurrent()))

    def innerliteral(self, pos) -> None:
        """Parse a literal inside the bracket, which does not generate HTML."""
        self.literal = ""
        while not pos.finished() and not pos.current() == self.ending:
            if pos.current() == self.start:
                self.parseliteral(pos)
            else:
                self.literal += pos.skipcurrent()
        self.original += self.literal


class SquareBracket(Bracket):
    """A [] bracket inside a formula"""

    start = FormulaConfig.starts["squarebracket"]
    ending = FormulaConfig.endings["squarebracket"]

    def clone(self):
        """Return a new square bracket with the same contents."""
        bracket = SquareBracket()
        bracket.contents = self.contents
        return bracket


class MathsProcessor:
    """A processor for a maths construction inside the FormulaProcessor."""

    def process(self, contents, index) -> None:
        """Process an element inside a formula."""
        Trace.error("Unimplemented process() in " + str(self))

    def __str__(self) -> str:
        """Return a printable description."""
        return "Maths processor " + self.__class__.__name__


class FormulaProcessor:
    """A processor specifically for formulas."""

    processors = []

    def process(self, bit) -> None:
        """Process the contents of every formula bit, recursively."""
        self.processcontents(bit)
        self.processinsides(bit)
        self.traversewhole(bit)

    def processcontents(self, bit) -> None:
        """Process the contents of a formula bit."""
        if not isinstance(bit, FormulaBit):
            return
        bit.process()
        for element in bit.contents:
            self.processcontents(element)

    def processinsides(self, bit) -> None:
        """Process the insides (limits, brackets) in a formula bit."""
        if not isinstance(bit, FormulaBit):
            return
        for index, element in enumerate(bit.contents):
            for processor in self.processors:
                processor.process(bit.contents, index)
            # continue with recursive processing
            self.processinsides(element)

    def traversewhole(self, formula) -> None:
        """Traverse over the contents to alter variables and space units."""
        last = None
        for bit, contents in self.traverse(formula):
            if bit.type == "alpha":
                self.italicize(bit, contents)
            elif bit.type == "font" and last and last.type == "number":
                bit.contents.insert(0, FormulaConstant("\u2009"))
            last = bit

    def traverse(self, bit):
        """Traverse a formula and yield a flattened structure of (bit, list) pairs."""
        for element in bit.contents:
            if hasattr(element, "type") and element.type:
                yield element, bit.contents
            elif isinstance(element, FormulaBit):
                yield from self.traverse(element)

    def italicize(self, bit, contents) -> None:
        """Italicize the given bit of text."""
        index = contents.index(bit)
        contents[index] = TaggedBit().complete([bit], "i")


class Formula(Container):
    """A LaTeX formula"""

    def __init__(self) -> None:
        self.parser = FormulaParser()
        self.output = TaggedOutput().settag('span class="formula"')

    def process(self) -> None:
        """Convert the formula to tags"""
        if self.header[0] == "inline":
            DocumentParameters.displaymode = False
        else:
            DocumentParameters.displaymode = True
            self.output.settag('div class="formula"', True)
        self.classic()

    def classic(self) -> None:
        """Make the contents using classic output generation with XHTML and CSS."""
        whole = FormulaFactory().parseformula(self.parsed)
        FormulaProcessor().process(whole)
        whole.parent = self
        self.contents = [whole]

    def parse(self, pos):
        """Parse using a parse position instead of self.parser."""
        if pos.checkskip("$$"):
            self.parsedollarblock(pos)
        elif pos.checkskip("$"):
            self.parsedollarinline(pos)
        elif pos.checkskip("\\("):
            self.parseinlineto(pos, "\\)")
        elif pos.checkskip("\\["):
            self.parseblockto(pos, "\\]")
        else:
            pos.error("Unparseable formula")
        self.process()
        return self

    def parsedollarinline(self, pos) -> None:
        """Parse a $...$ formula."""
        self.header = ["inline"]
        self.parsedollar(pos)

    def parsedollarblock(self, pos) -> None:
        """Parse a $$...$$ formula."""
        self.header = ["block"]
        self.parsedollar(pos)
        if not pos.checkskip("$"):
            pos.error("Formula should be $$...$$, but last $ is missing.")

    def parsedollar(self, pos) -> None:
        """Parse to the next $."""
        pos.pushending("$")
        self.parsed = pos.globexcluding("$")
        pos.popending("$")

    def parseinlineto(self, pos, limit) -> None:
        """Parse a \\(...\\) formula."""
        self.header = ["inline"]
        self.parseupto(pos, limit)

    def parseblockto(self, pos, limit) -> None:
        """Parse a \\[...\\] formula."""
        self.header = ["block"]
        self.parseupto(pos, limit)

    def parseupto(self, pos, limit) -> None:
        """Parse a formula that ends with the given command."""
        pos.pushending(limit)
        self.parsed = pos.glob(lambda: True)
        pos.popending(limit)

    def __str__(self) -> str:
        """Return a printable representation."""
        if self.partkey and self.partkey.number:
            return "Formula (" + self.partkey.number + ")"
        return "Unnumbered formula"


class WholeFormula(FormulaBit):
    """Parse a whole formula"""

    def detect(self, pos) -> bool:
        """Not outside the formula is enough."""
        return not pos.finished()

    def parsebit(self, pos) -> None:
        """Parse with any formula bit"""
        while not pos.finished():
            self.add(self.factory.parseany(pos))


class FormulaFactory:
    """Construct bits of formula"""

    # bit types will be appended later
    types = [FormulaSymbol, RawText, FormulaNumber, Bracket, Comment, WhiteSpace]
    skippedtypes = [Comment, WhiteSpace]
    defining = False

    def __init__(self) -> None:
        """Initialize the map of instances."""
        self.instances = {}

    def detecttype(self, type, pos):
        """Detect a bit of a given type."""
        if pos.finished():
            return False
        return self.instance(type).detect(pos)

    def instance(self, type):
        """Get an instance of the given type."""
        if type not in self.instances or not self.instances[type]:
            self.instances[type] = self.create(type)
        return self.instances[type]

    def create(self, type):
        """Create a new formula bit of the given type."""
        return Cloner.create(type).setfactory(self)

    def clearskipped(self, pos) -> None:
        """Clear any skipped types."""
        while not pos.finished():
            if not self.skipany(pos):
                return
        return

    def skipany(self, pos):
        """Skip any skipped types."""
        for type in self.skippedtypes:
            if self.instance(type).detect(pos):
                return self.parsetype(type, pos)
        return None

    def parseany(self, pos):
        """Parse any formula bit at the current location."""
        for type in self.types + self.skippedtypes:
            if self.detecttype(type, pos):
                return self.parsetype(type, pos)
        Trace.error("Unrecognized formula at " + pos.identifier())
        return FormulaConstant(pos.skipcurrent())

    def parsetype(self, type, pos):
        """Parse the given type and return it."""
        bit = self.instance(type)
        self.instances[type] = None
        returnedbit = bit.parsebit(pos)
        if returnedbit:
            return returnedbit.setfactory(self)
        return bit

    def parseformula(self, formula):
        """Parse a string of text that contains a whole formula."""
        pos = TextPosition(formula)
        whole = self.create(WholeFormula)
        if whole.detect(pos):
            whole.parsebit(pos)
            return whole
        # no formula found
        if not pos.finished():
            Trace.error("Unknown formula at: " + pos.identifier())
            whole.add(TaggedBit().constant(formula, 'span class="unknown"'))
        return whole


class FormulaCommand(FormulaBit):
    """A LaTeX command inside a formula"""

    types = []
    start = FormulaConfig.starts["command"]
    commandmap = None

    def detect(self, pos):
        """Find the current command."""
        return pos.checkfor(FormulaCommand.start)

    def parsebit(self, pos):
        """Parse the command."""
        command = self.extractcommand(pos)
        bit = self.parsewithcommand(command, pos)
        if bit:
            return bit
        if command.startswith(("\\up", "\\Up")):
            upgreek = self.parseupgreek(command, pos)
            if upgreek:
                return upgreek
        if not self.factory.defining:
            Trace.error("Unknown command " + command)
        self.output = TaggedOutput().settag('span class="unknown"')
        self.add(FormulaConstant(command))
        return None

    def parsewithcommand(self, command, pos):
        """Parse the command type once we have the command."""
        for type in FormulaCommand.types:
            if command in type.commandmap:
                return self.parsecommandtype(command, type, pos)
        return None

    def parsecommandtype(self, command, type, pos):
        """Parse a given command type."""
        bit = self.factory.create(type)
        bit.setcommand(command)
        returned = bit.parsebit(pos)
        if returned:
            return returned
        return bit

    def extractcommand(self, pos):
        """Extract the command from the current position."""
        if not pos.checkskip(FormulaCommand.start):
            pos.error("Missing command start " + FormulaCommand.start)
            return
        if pos.finished():
            return self.emptycommand(pos)
        if pos.current().isalpha():
            # alpha command
            command = FormulaCommand.start + pos.globalpha()
            # skip mark of short command
            pos.checkskip("*")
            return command
        # symbol command
        return FormulaCommand.start + pos.skipcurrent()

    def emptycommand(self, pos):
        """Check for an empty command: look for command disguised as ending.
        Special case against '{ \\{ \\} }' situation."""
        command = ""
        if not pos.isout():
            ending = pos.nextending()
            if ending and pos.checkskip(ending):
                command = ending
        return FormulaCommand.start + command

    def parseupgreek(self, command, pos):
        """Parse the Greek \\up command.."""
        if len(command) < 4:
            return None
        if command.startswith("\\up"):
            upcommand = "\\" + command[3:]
        elif pos.checkskip("\\Up"):
            upcommand = "\\" + command[3:4].upper() + command[4:]
        else:
            Trace.error("Impossible upgreek command: " + command)
            return
        upgreek = self.parsewithcommand(upcommand, pos)
        if upgreek:
            upgreek.type = "font"
        return upgreek


class CommandBit(FormulaCommand):
    """A formula bit that includes a command"""

    def setcommand(self, command) -> None:
        """Set the command in the bit"""
        self.command = command
        if self.commandmap:
            self.original += command
            self.translated = self.commandmap[self.command]

    def parseparameter(self, pos):
        """Parse a parameter at the current position"""
        self.factory.clearskipped(pos)
        if pos.finished():
            return None
        parameter = self.factory.parseany(pos)
        self.add(parameter)
        return parameter

    def parsesquare(self, pos):
        """Parse a square bracket"""
        self.factory.clearskipped(pos)
        if not self.factory.detecttype(SquareBracket, pos):
            return None
        bracket = self.factory.parsetype(SquareBracket, pos)
        self.add(bracket)
        return bracket

    def parseliteral(self, pos):
        """Parse a literal bracket."""
        self.factory.clearskipped(pos)
        if not self.factory.detecttype(Bracket, pos):
            if not pos.isvalue():
                Trace.error("No literal parameter found at: " + pos.identifier())
                return None
            return pos.globvalue()
        bracket = Bracket().setfactory(self.factory)
        self.add(bracket.parseliteral(pos))
        return bracket.literal

    def parsesquareliteral(self, pos):
        """Parse a square bracket literally."""
        self.factory.clearskipped(pos)
        if not self.factory.detecttype(SquareBracket, pos):
            return None
        bracket = SquareBracket().setfactory(self.factory)
        self.add(bracket.parseliteral(pos))
        return bracket.literal

    def parsetext(self, pos):
        """Parse a text parameter."""
        self.factory.clearskipped(pos)
        if not self.factory.detecttype(Bracket, pos):
            Trace.error("No text parameter for " + self.command)
            return None
        bracket = Bracket().setfactory(self.factory).parsetext(pos)
        self.add(bracket)
        return bracket


class EmptyCommand(CommandBit):
    """An empty command (without parameters)"""

    commandmap = FormulaConfig.commands

    def parsebit(self, pos) -> None:
        """Parse a command without parameters"""
        self.contents = [FormulaConstant(self.translated)]


class SpacedCommand(CommandBit):
    """An empty command which should have math spacing in formulas."""

    commandmap = FormulaConfig.spacedcommands

    def parsebit(self, pos) -> None:
        """Place as contents the command translated and spaced."""
        # pad with MEDIUM MATHEMATICAL SPACE (4/18 em): too wide in STIX fonts :(
        # self.contents = [FormulaConstant('\u205f' + self.translated + '\u205f')]
        # pad with THIN SPACE (1/5 em)
        self.contents = [FormulaConstant("\u2009" + self.translated + "\u2009")]


class AlphaCommand(EmptyCommand):
    """A command without parameters whose result is alphabetical."""

    commandmap = FormulaConfig.alphacommands
    greek_capitals = (
        "\\Xi",
        "\\Theta",
        "\\Pi",
        "\\Sigma",
        "\\Gamma",
        "\\Lambda",
        "\\Phi",
        "\\Psi",
        "\\Delta",
        "\\Upsilon",
        "\\Omega",
    )

    def parsebit(self, pos) -> None:
        """Parse the command and set type to alpha"""
        EmptyCommand.parsebit(self, pos)
        if self.command not in self.greek_capitals:
            # Greek Capital letters are upright in LaTeX default math-style.
            # TODO: use italic, like in MathML and "iso" math-style?
            self.type = "alpha"


class OneParamFunction(CommandBit):
    """A function of one parameter"""

    commandmap = FormulaConfig.onefunctions
    simplified = False

    def parsebit(self, pos) -> None:
        """Parse a function with one parameter"""
        self.output = TaggedOutput().settag(self.translated)
        self.parseparameter(pos)
        self.simplifyifpossible()

    def simplifyifpossible(self) -> None:
        """Try to simplify to a single character."""
        if self.original in self.commandmap:
            self.output = FixedOutput()
            self.html = [self.commandmap[self.original]]
            self.simplified = True


class SymbolFunction(CommandBit):
    """Find a function which is represented by a symbol (like _ or ^)"""

    commandmap = FormulaConfig.symbolfunctions

    def detect(self, pos) -> bool:
        """Find the symbol"""
        return pos.current() in SymbolFunction.commandmap

    def parsebit(self, pos) -> None:
        """Parse the symbol"""
        self.setcommand(pos.current())
        pos.skip(self.command)
        self.output = TaggedOutput().settag(self.translated)
        self.parseparameter(pos)


class TextFunction(CommandBit):
    """A function where parameters are read as text."""

    commandmap = FormulaConfig.textfunctions

    def parsebit(self, pos) -> None:
        """Parse a text parameter"""
        self.output = TaggedOutput().settag(self.translated)
        self.parsetext(pos)

    def process(self) -> None:
        """Set the type to font"""
        self.type = "font"


class FontFunction(OneParamFunction):
    """A function of one parameter that changes the font."""

    # TODO: keep letters italic with \boldsymbol.

    commandmap = FormulaConfig.fontfunctions

    def process(self) -> None:
        """Simplify if possible using a single character."""
        self.type = "font"
        self.simplifyifpossible()


FormulaFactory.types += [FormulaCommand, SymbolFunction]


FormulaCommand.types = [
    AlphaCommand,
    EmptyCommand,
    OneParamFunction,
    FontFunction,
    TextFunction,
    SpacedCommand,
]
