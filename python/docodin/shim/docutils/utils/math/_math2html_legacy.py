"""Remnants of eLyXer's LyX-file conversion, kept for API compatibility with docutils.

`math2html.math2html` does not use these classes. The line-based parsers expect an
eLyXer line reader (with ``currentline()``, ``nextline()`` and ``linenumber``), which
neither docutils nor this module provides. `Formula` still works on a parse position:
``Formula().parse(TextPosition('$x^2$'))``.
"""

from __future__ import annotations

from typing import Any

from docutils.utils.math._math2html_config import ContainerConfig, FormulaConfig
from docutils.utils.math._math2html_options import DocumentParameters, Trace
from docutils.utils.math._math2html_pipeline import FormulaFactory, FormulaProcessor
from docutils.utils.math._math2html_text import Position
from docutils.utils.math._math2html_tree import (
    Container,
    ContentsOutput,
    EmptyOutput,
    TaggedOutput,
)

__docformat__ = "reStructuredText"


class Cloner:
    """Create objects of a class with an empty constructor."""

    @classmethod
    def clone(cls, original: object) -> Any:
        """Return a new object of the class of `original`."""
        return cls.create(original.__class__)

    @classmethod
    def create(cls, kind: type) -> Any:
        """Create an object of a given class."""
        return kind()


class BlackBox(Container):
    """A container that does not output anything."""

    def __init__(self) -> None:
        super().__init__()
        self.parser = LoneCommand()
        self.output = EmptyOutput()


class FilteredOutput(ContentsOutput):
    """The output of the contents, with some strings replaced by others."""

    def __init__(self) -> None:
        self.filters: list[tuple[str, str]] = []

    def addfilter(self, original: str, replacement: str) -> None:
        """Add a new filter: replace the original by the replacement."""
        self.filters.append((original, replacement))

    def gethtml(self, container: Container) -> list[str]:
        return [self.filter(line) for line in super().gethtml(container)]

    def filter(self, line: str) -> str:
        """Filter a single line with all available filters."""
        for original, replacement in self.filters:
            line = line.replace(original, replacement)
        return line


class Parser:
    """A generic parser of reader lines."""

    ending: str | None = None

    def __init__(self) -> None:
        self.begin = 0
        self.parameters: dict[str, Any] = {}

    def parseheader(self, reader: Any) -> list[str]:
        """Parse the header line."""
        header = reader.currentline().split()
        reader.nextline()
        self.begin = reader.linenumber
        return header

    def parseparameter(self, reader: Any) -> None:
        """Parse a ``key [value]`` parameter line."""
        split = reader.currentline().strip().split(" ", 1)
        reader.nextline()
        key = split[0]
        if len(split) == 1:
            self.parameters[key] = True
        elif '"' not in split[1]:
            self.parameters[key] = split[1].strip()
        else:
            self.parameters[key] = split[1].split('"')[1]

    def parseending(self, reader: Any, process: Any) -> None:
        """Call `process` until the current ending is found."""
        if not self.ending:
            Trace.error("No ending for " + str(self))
            return
        while not reader.currentline().startswith(self.ending):
            process()

    def parsecontainer(self, reader: Any, contents: list[Container]) -> None:
        container = self.factory.createcontainer(reader)
        if container:
            container.parent = self.parent
            contents.append(container)

    def __str__(self) -> str:
        return f"{self.__class__.__name__} ({self.begin})"


class LoneCommand(Parser):
    """A parser for just one command line."""

    def parse(self, reader: Any) -> list[Container]:
        return []


class TextParser(Parser):
    """A parser for a command and a bit of text.

    It needs ``ContainerConfig.endings`` from eLyXer, which docutils does not define.
    """

    stack: list[str | None] = []

    def __init__(self, container: Container) -> None:
        super().__init__()
        self.ending = ContainerConfig.endings.get(container.__class__.__name__)
        self.endings: list[str | None] = []

    def parse(self, reader: Any) -> list[Container]:
        """Parse lines as long as they are text."""
        TextParser.stack.append(self.ending)
        self.endings = [*TextParser.stack, ContainerConfig.endings["Layout"],
                        ContainerConfig.endings["Inset"], self.ending]
        contents: list[Container] = []
        while not self.isending(reader):
            self.parsecontainer(reader, contents)
        return contents

    def isending(self, reader: Any) -> bool:
        """Check if text is ending."""
        current = reader.currentline().split()
        if not current or current[0] not in self.endings:
            return False
        if current[0] in TextParser.stack:
            TextParser.stack.remove(current[0])
        else:
            TextParser.stack = []
        return True


class ExcludingParser(Parser):
    """A parser that excludes the final line."""

    def parse(self, reader: Any) -> list[Container]:
        contents: list[Container] = []
        self.parseending(reader, lambda: self.parsecontainer(reader, contents))
        return contents


class BoundedParser(ExcludingParser):
    """A parser bound by a final line (which it skips)."""

    def parse(self, reader: Any) -> list[Container]:
        contents = super().parse(reader)
        reader.nextline()
        return contents


class BoundedDummy(Parser):
    """A bound parser that ignores everything."""

    def parse(self, reader: Any) -> list[Container]:
        self.parseending(reader, reader.nextline)
        reader.nextline()
        return []


class StringParser(Parser):
    """Parses just a string."""

    def parseheader(self, reader: Any) -> list[str]:
        self.begin = reader.linenumber + 1
        return []

    def parse(self, reader: Any) -> str:
        contents = reader.currentline()
        reader.nextline()
        return contents


class FormulaParser(Parser):
    """Parses a formula in LyX-file lines."""

    def parseheader(self, reader: Any) -> list[str]:
        """See if the formula is inlined."""
        self.begin = reader.linenumber + 1
        kind = self.parsetype(reader)
        if not kind:
            reader.nextline()
            kind = self.parsetype(reader)
            if not kind:
                Trace.error("Unknown formula type in " + reader.currentline().strip())
                return ["unknown"]
        return [kind]

    def parsetype(self, reader: Any) -> str | None:
        """Get the formula type from the first line."""
        line = reader.currentline()
        starts = FormulaConfig.starts
        if starts["simple"] in line:
            return "inline"
        if starts["complex"] in line or starts["unnumbered"] in line:
            return "block"
        if starts["beginbefore"] in line:
            return "numbered"
        return None

    def parse(self, reader: Any) -> str:
        """Parse the formula until the end."""
        formula = self.parseformula(reader)
        while not reader.currentline().startswith(self.ending):
            stripped = reader.currentline().strip()
            if stripped:
                Trace.error("Unparsed formula line " + stripped)
            reader.nextline()
        reader.nextline()
        return formula

    def parseformula(self, reader: Any) -> str:
        """Parse the formula contents."""
        starts, endings = FormulaConfig.starts, FormulaConfig.endings
        line = reader.currentline()
        if starts["simple"] in line:
            if starts["simple"] in line.split(starts["simple"], 1)[1]:
                return self.parsesingleliner(reader, starts["simple"], starts["simple"])
            return self.parsemultiliner(reader, starts["simple"], starts["simple"])
        if starts["complex"] in line:
            return self.parsemultiliner(reader, starts["complex"], endings["complex"])
        if starts["beginbefore"] in line:
            return self.parseenvironment(reader)
        if starts["command"] in line and starts["bracket"] in line:
            return self.parsemultiliner(reader, starts["bracket"], endings["bracket"])
        Trace.error("Formula beginning " + line + " is unknown")
        return ""

    def parseenvironment(self, reader: Any) -> str:
        """Parse a ``\\begin{name}...\\end{name}`` formula."""
        starts, endings = FormulaConfig.starts, FormulaConfig.endings
        current = reader.currentline().strip()
        if not current.endswith(starts["beginafter"]):
            Trace.error("Missing " + starts["beginafter"] + " in " + reader.currentline())
            return ""
        name = current.split(starts["beginbefore"])[1].split(starts["beginafter"])[0]
        startpiece = starts["beginbefore"] + name + starts["beginafter"]
        endpiece = endings["endbefore"] + name + endings["endafter"]
        return startpiece + self.parsemultiliner(reader, startpiece, endpiece) + endpiece

    def parsesingleliner(self, reader: Any, start: str, ending: str) -> str:
        """Parse a formula in one line."""
        line = reader.currentline().strip()
        if start not in line:
            Trace.error("Line " + line + " does not contain formula start " + start)
            return ""
        if not line.endswith(ending):
            Trace.error("Formula " + line + " does not end with " + ending)
            return ""
        index = line.index(start)
        reader.nextline()
        return line[index + len(start):-len(ending)]

    def parsemultiliner(self, reader: Any, start: str, ending: str) -> str:
        """Parse a formula in multiple lines."""
        line = reader.currentline()
        if start not in line:
            Trace.error("Line " + line.strip() + " does not contain formula start " + start)
            return ""
        line = line[line.index(start) + len(start):].strip()
        formula = ""
        while not line.endswith(ending):
            formula += line + "\n"
            reader.nextline()
            line = reader.currentline()
        formula += line[:-len(ending)]
        reader.nextline()
        return formula


class Formula(Container):
    """A LaTeX formula in math delimiters: ``$...$``, ``$$...$$``, ``\\(...\\)`` or
    ``\\[...\\]``."""

    partkey = None
    header: list[str]
    parsed: str

    def __init__(self) -> None:
        super().__init__()
        self.parser = FormulaParser()
        self.output = TaggedOutput().settag('span class="formula"')

    def process(self) -> None:
        """Convert the formula to tags."""
        DocumentParameters.displaymode = self.header[0] != "inline"
        if DocumentParameters.displaymode:
            self.output.settag('div class="formula"', True)
        self.classic()

    def classic(self) -> None:
        """Make the contents using classic output generation with XHTML and CSS."""
        whole = FormulaFactory().parseformula(self.parsed)
        FormulaProcessor().process(whole)
        whole.parent = self
        self.contents = [whole]

    def parse(self, pos: Position) -> Formula:
        """Parse a formula in math delimiters at `pos`."""
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

    def parsedollarinline(self, pos: Position) -> None:
        """Parse a $...$ formula."""
        self.header = ["inline"]
        self.parsedollar(pos)

    def parsedollarblock(self, pos: Position) -> None:
        """Parse a $$...$$ formula."""
        self.header = ["block"]
        self.parsedollar(pos)
        if not pos.checkskip("$"):
            pos.error("Formula should be $$...$$, but last $ is missing.")

    def parsedollar(self, pos: Position) -> None:
        """Parse to the next $."""
        pos.pushending("$")
        self.parsed = pos.globexcluding("$")
        pos.popending("$")

    def parseinlineto(self, pos: Position, limit: str) -> None:
        """Parse a \\(...\\) formula."""
        self.header = ["inline"]
        self.parseupto(pos, limit)

    def parseblockto(self, pos: Position, limit: str) -> None:
        """Parse a \\[...\\] formula."""
        self.header = ["block"]
        self.parseupto(pos, limit)

    def parseupto(self, pos: Position, limit: str) -> None:
        """Parse a formula that ends with the given command."""
        pos.pushending(limit)
        self.parsed = pos.glob(lambda: True)
        pos.popending(limit)

    def __str__(self) -> str:
        if self.partkey and self.partkey.number:
            return "Formula (" + self.partkey.number + ")"
        return "Unnumbered formula"
