"""Tracing, options, parse positions and generic containers of `math2html`."""

from __future__ import annotations

import pathlib
import sys
from typing import TextIO

from docutils.utils.math._math2html_config import ContainerConfig, EscapeConfig

__version__ = "1.3 (2021-06-02)"

__docformat__ = "reStructuredText"


class Trace:
    """A tracing class"""

    debugmode = False
    quietmode = False
    showlinesmode = False

    prefix: str | None = None

    @classmethod
    def debug(cls, message: str) -> None:
        """Show a debug message"""
        if not Trace.debugmode or Trace.quietmode:
            return
        Trace.show(message, sys.stdout)

    @classmethod
    def message(cls, message: str) -> None:
        """Show a trace message"""
        if Trace.quietmode:
            return
        if Trace.prefix and Trace.showlinesmode:
            message = Trace.prefix + message
        Trace.show(message, sys.stdout)

    @classmethod
    def error(cls, message: str) -> None:
        """Show an error message"""
        message = "* " + message
        if Trace.prefix and Trace.showlinesmode:
            message = Trace.prefix + message
        Trace.show(message, sys.stderr)

    @classmethod
    def show(cls, message: str, channel: TextIO) -> None:
        """Show a message out of a channel"""
        channel.write(message + "\n")



class CommandLineParser:
    """A parser for runtime options"""

    def __init__(self, options) -> None:
        self.options = options

    def parseoptions(self, args):
        """Parse command line options"""
        if len(args) == 0:
            return None
        while len(args) > 0 and args[0].startswith("--"):
            key, value = self.readoption(args)
            if not key:
                return "Option " + value + " not recognized"
            if not value:
                return "Option " + key + " needs a value"
            setattr(self.options, key, value)
        return None

    def readoption(self, args):
        """Read the key and value for an option"""
        arg = args[0][2:]
        del args[0]
        if "=" in arg:
            key = self.readequalskey(arg, args)
        else:
            key = arg.replace("-", "")
        if not hasattr(self.options, key):
            return None, key
        current = getattr(self.options, key)
        if isinstance(current, bool):
            return key, True
        # read value
        if len(args) == 0:
            return key, None
        if args[0].startswith('"'):
            initial = args[0]
            del args[0]
            return key, self.readquoted(args, initial)
        value = args[0].decode("utf-8")
        del args[0]
        if isinstance(current, list):
            current.append(value)
            return key, current
        return key, value

    def readquoted(self, args, initial):
        """Read a value between quotes"""
        Trace.error("Oops")
        value = initial[1:]
        while len(args) > 0 and not args[0].endswith('"') and not args[0].startswith("--"):
            Trace.error("Appending " + args[0])
            value += " " + args[0]
            del args[0]
        if len(args) == 0 or args[0].startswith("--"):
            return None
        value += " " + args[0:-1]
        return value

    def readequalskey(self, arg, args):
        """Read a key using equals"""
        split = arg.split("=", 1)
        key = split[0]
        value = split[1]
        args.insert(0, value)
        return key


class Options:
    """A set of runtime options"""

    location = None

    debug = False
    quiet = False
    version = False
    help = False
    simplemath = False
    showlines = True

    branches = {}

    def parseoptions(self, args) -> None:
        """Parse command line options"""
        Options.location = args[0]
        del args[0]
        parser = CommandLineParser(Options)
        result = parser.parseoptions(args)
        if result:
            Trace.error(result)
            self.usage()
        self.processoptions()

    def processoptions(self) -> None:
        """Process all options parsed."""
        if Options.help:
            self.usage()
        if Options.version:
            self.showversion()
        # set in Trace if necessary
        for param in dir(Trace):
            if param.endswith("mode"):
                setattr(Trace, param, getattr(self, param[:-4]))

    def usage(self) -> None:
        """Show correct usage"""
        Trace.error(f'Usage: {pathlib.Path(Options.location).parent} [options] "input string"')
        Trace.error("Convert input string with LaTeX math to MathML")
        self.showoptions()

    def showoptions(self) -> None:
        """Show all possible options"""
        Trace.error("    --help:                 show this online help")
        Trace.error("    --quiet:                disables all runtime messages")
        Trace.error("    --debug:                enable debugging messages (for developers)")
        Trace.error("    --version:              show version number and release date")
        Trace.error("    --simplemath:           do not generate fancy math constructions")
        sys.exit()

    def showversion(self) -> None:
        """Return the current eLyXer version string"""
        Trace.error("math2html " + __version__)
        sys.exit()


class Cloner:
    """An object used to clone other objects."""

    @classmethod
    def clone(cls, original):
        """Return an exact copy of an object.

        The original object must have an empty constructor.
        """
        return cls.create(original.__class__)

    @classmethod
    def create(cls, type):
        """Create an object of a given class."""
        clone = type.__new__(type)
        clone.__init__()
        return clone


class ContainerExtractor:
    """A class to extract certain containers.

    The config parameter is a map containing three lists:
    allowed, copied and extracted.
    Each of the three is a list of class names for containers.
    Allowed containers are included as is into the result.
    Cloned containers are cloned and placed into the result.
    Extracted containers are looked into.
    All other containers are silently ignored.
    """

    def __init__(self, config) -> None:
        self.allowed = config["allowed"]
        self.extracted = config["extracted"]

    def extract(self, container):
        """Extract a group of selected containers from a container."""
        lst = []

        def locate(c):
            return c.__class__.__name__ in self.allowed

        def recursive(c):
            return c.__class__.__name__ in self.extracted

        container.recursivesearch(locate, recursive, lambda c: self.process(c, lst))
        return lst

    def process(self, container, lst) -> None:
        """Add allowed containers."""
        name = container.__class__.__name__
        if name in self.allowed:
            lst.append(container)
        else:
            Trace.error("Unknown container class " + name)

    def safeclone(self, container):
        """Return a new container with contents only in a safe list, recursively."""
        clone = Cloner.clone(container)
        clone.output = container.output
        clone.contents = self.extract(container)
        return clone


class Parser:
    """A generic parser"""

    def __init__(self) -> None:
        self.begin = 0
        self.parameters = {}

    def parseheader(self, reader):
        """Parse the header"""
        header = reader.currentline().split()
        reader.nextline()
        self.begin = reader.linenumber
        return header

    def parseparameter(self, reader) -> None:
        """Parse a parameter"""
        split = reader.currentline().strip().split(" ", 1)
        reader.nextline()
        if len(split) == 0:
            return
        key = split[0]
        if len(split) == 1:
            self.parameters[key] = True
            return
        if '"' not in split[1]:
            self.parameters[key] = split[1].strip()
            return
        doublesplit = split[1].split('"')
        self.parameters[key] = doublesplit[1]

    def parseending(self, reader, process) -> None:
        """Parse until the current ending is found"""
        if not self.ending:
            Trace.error("No ending for " + str(self))
            return
        while not reader.currentline().startswith(self.ending):
            process()

    def parsecontainer(self, reader, contents) -> None:
        container = self.factory.createcontainer(reader)
        if container:
            container.parent = self.parent
            contents.append(container)

    def __str__(self) -> str:
        """Return a description"""
        return self.__class__.__name__ + " (" + str(self.begin) + ")"


class LoneCommand(Parser):
    """A parser for just one command line"""

    def parse(self, reader):
        """Read nothing"""
        return []


class TextParser(Parser):
    """A parser for a command and a bit of text"""

    stack = []

    def __init__(self, container) -> None:
        Parser.__init__(self)
        self.ending = None
        if container.__class__.__name__ in ContainerConfig.endings:
            self.ending = ContainerConfig.endings[container.__class__.__name__]
        self.endings = []

    def parse(self, reader):
        """Parse lines as long as they are text"""
        TextParser.stack.append(self.ending)
        self.endings = TextParser.stack + [
            ContainerConfig.endings["Layout"],
            ContainerConfig.endings["Inset"],
            self.ending,
        ]
        contents = []
        while not self.isending(reader):
            self.parsecontainer(reader, contents)
        return contents

    def isending(self, reader) -> bool:
        """Check if text is ending"""
        current = reader.currentline().split()
        if len(current) == 0:
            return False
        if current[0] in self.endings:
            if current[0] in TextParser.stack:
                TextParser.stack.remove(current[0])
            else:
                TextParser.stack = []
            return True
        return False


class ExcludingParser(Parser):
    """A parser that excludes the final line"""

    def parse(self, reader):
        """Parse everything up to (and excluding) the final line"""
        contents = []
        self.parseending(reader, lambda: self.parsecontainer(reader, contents))
        return contents


class BoundedParser(ExcludingParser):
    """A parser bound by a final line"""

    def parse(self, reader):
        """Parse everything, including the final line"""
        contents = ExcludingParser.parse(self, reader)
        # skip last line
        reader.nextline()
        return contents


class BoundedDummy(Parser):
    """A bound parser that ignores everything"""

    def parse(self, reader):
        """Parse the contents of the container"""
        self.parseending(reader, reader.nextline)
        # skip last line
        reader.nextline()
        return []


class StringParser(Parser):
    """Parses just a string"""

    def parseheader(self, reader):
        """Do nothing, just take note"""
        self.begin = reader.linenumber + 1
        return []

    def parse(self, reader):
        """Parse a single line"""
        contents = reader.currentline()
        reader.nextline()
        return contents


class ContainerOutput:
    """The generic HTML output for a container."""

    def gethtml(self, container) -> None:
        """Show an error."""
        Trace.error("gethtml() not implemented for " + str(self))

    def isempty(self) -> bool:
        """Decide if the output is empty: by default, not empty."""
        return False


class EmptyOutput(ContainerOutput):
    def gethtml(self, container):
        """Return empty HTML code."""
        return []

    def isempty(self) -> bool:
        """This output is particularly empty."""
        return True


class FixedOutput(ContainerOutput):
    """Fixed output"""

    def gethtml(self, container):
        """Return constant HTML code"""
        return container.html


class ContentsOutput(ContainerOutput):
    """Outputs the contents converted to HTML"""

    def gethtml(self, container):
        """Return the HTML code"""
        html = []
        if container.contents is None:
            return html
        for element in container.contents:
            if not hasattr(element, "gethtml"):
                Trace.error("No html in " + element.__class__.__name__ + ": " + str(element))
                return html
            html += element.gethtml()
        return html


class TaggedOutput(ContentsOutput):
    """Outputs an HTML tag surrounding the contents."""

    tag = None
    breaklines = False
    empty = False

    def settag(self, tag, breaklines=False, empty=False):
        """Set the value for the tag and other attributes."""
        self.tag = tag
        if breaklines:
            self.breaklines = breaklines
        if empty:
            self.empty = empty
        return self

    def setbreaklines(self, breaklines):
        """Set the value for breaklines."""
        self.breaklines = breaklines
        return self

    def gethtml(self, container):
        """Return the HTML code."""
        if self.empty:
            return [self.selfclosing(container)]
        html = [self.open(container)]
        html += ContentsOutput.gethtml(self, container)
        html.append(self.close(container))
        return html

    def open(self, container):
        """Get opening line."""
        if not self.checktag(container):
            return ""
        open_tag = "<" + self.tag + ">"
        if self.breaklines:
            return open_tag + "\n"
        return open_tag

    def close(self, container):
        """Get closing line."""
        if not self.checktag(container):
            return ""
        close = "</" + self.tag.split()[0] + ">"
        if self.breaklines:
            return "\n" + close + "\n"
        return close

    def selfclosing(self, container):
        """Get self-closing line."""
        if not self.checktag(container):
            return ""
        selfclosing = "<" + self.tag + "/>"
        if self.breaklines:
            return selfclosing + "\n"
        return selfclosing

    def checktag(self, container) -> bool:
        """Check that the tag is valid."""
        if not self.tag:
            Trace.error("No tag in " + str(container))
            return False
        if self.tag == "":
            return False
        return True


class FilteredOutput(ContentsOutput):
    """Returns the output in the contents, but filtered:

    some strings are replaced by others.
    """

    def __init__(self) -> None:
        """Initialize the filters."""
        self.filters = []

    def addfilter(self, original, replacement) -> None:
        """Add a new filter: replace the original by the replacement."""
        self.filters.append((original, replacement))

    def gethtml(self, container):
        """Return the HTML code"""
        html = ContentsOutput.gethtml(self, container)
        result = [self.filter(line) for line in html]
        return result

    def filter(self, line):
        """Filter a single line with all available filters."""
        for original, replacement in self.filters:
            if original in line:
                line = line.replace(original, replacement)
        return line


class StringOutput(ContainerOutput):
    """Returns a bare string as output"""

    def gethtml(self, container):
        """Return a bare string"""
        return [container.string]


class Globable:
    """A bit of text which can be globbed (lumped together in bits).
    Methods current(), skipcurrent(), checkfor() and isout() have to be
    implemented by subclasses."""

    leavepending = False

    def __init__(self) -> None:
        self.endinglist = EndingList()

    def checkbytemark(self) -> None:
        """Check for a Unicode byte mark and skip it."""
        if self.finished():
            return
        if ord(self.current()) == 0xFEFF:
            self.skipcurrent()

    def isout(self) -> bool:
        """Find out if we are out of the position yet."""
        Trace.error("Unimplemented isout()")
        return True

    def current(self) -> str:
        """Return the current character."""
        Trace.error("Unimplemented current()")
        return ""

    def checkfor(self, string) -> bool:
        """Check for the given string in the current position."""
        Trace.error("Unimplemented checkfor()")
        return False

    def finished(self):
        """Find out if the current text has finished."""
        if self.isout():
            if not self.leavepending:
                self.endinglist.checkpending()
            return True
        return self.endinglist.checkin(self)

    def skipcurrent(self) -> str:
        """Return the current character and skip it."""
        Trace.error("Unimplemented skipcurrent()")
        return ""

    def glob(self, currentcheck):
        """Glob a bit of text that satisfies a check on the current char."""
        glob = ""
        while not self.finished() and currentcheck():
            glob += self.skipcurrent()
        return glob

    def globalpha(self):
        """Glob a bit of alpha text"""
        return self.glob(lambda: self.current().isalpha())

    def globnumber(self):
        """Glob a row of digits."""
        return self.glob(lambda: self.current().isdigit())

    def isidentifier(self) -> bool:
        """Return if the current character is alphanumeric or _."""
        if self.current().isalnum() or self.current() == "_":
            return True
        return False

    def globidentifier(self):
        """Glob alphanumeric and _ symbols."""
        return self.glob(self.isidentifier)

    def isvalue(self) -> bool:
        """Return if the current character is a value character:

        not a bracket or a space.
        """
        if self.current().isspace():
            return False
        if self.current() in "{}()":
            return False
        return True

    def globvalue(self):
        """Glob a value: any symbols but brackets."""
        return self.glob(self.isvalue)

    def skipspace(self):
        """Skip all whitespace at current position."""
        return self.glob(lambda: self.current().isspace())

    def globincluding(self, magicchar):
        """Glob a bit of text up to (including) the magic char."""
        glob = self.glob(lambda: self.current() != magicchar) + magicchar
        self.skip(magicchar)
        return glob

    def globexcluding(self, excluded):
        """Glob a bit of text up until (excluding) any excluded character."""
        return self.glob(lambda: self.current() not in excluded)

    def pushending(self, ending, optional=False) -> None:
        """Push a new ending to the bottom"""
        self.endinglist.add(ending, optional)

    def popending(self, expected=None):
        """Pop the ending found at the current position"""
        if self.isout() and self.leavepending:
            return expected
        ending = self.endinglist.pop(self)
        if expected and expected != ending:
            Trace.error("Expected ending " + expected + ", got " + ending)
        self.skip(ending)
        return ending

    def nextending(self):
        """Return the next ending in the queue."""
        nextending = self.endinglist.findending(self)
        if not nextending:
            return None
        return nextending.ending


class EndingList:
    """A list of position endings"""

    def __init__(self) -> None:
        self.endings = []

    def add(self, ending, optional=False) -> None:
        """Add a new ending to the list"""
        self.endings.append(PositionEnding(ending, optional))

    def pickpending(self, pos) -> None:
        """Pick any pending endings from a parse position."""
        self.endings += pos.endinglist.endings

    def checkin(self, pos) -> bool:
        """Search for an ending"""
        if self.findending(pos):
            return True
        return False

    def pop(self, pos):
        """Remove the ending at the current position"""
        if pos.isout():
            Trace.error("No ending out of bounds")
            return ""
        ending = self.findending(pos)
        if not ending:
            Trace.error("No ending at " + pos.current())
            return ""
        for each in reversed(self.endings):
            self.endings.remove(each)
            if each == ending:
                return each.ending
            elif not each.optional:
                Trace.error("Removed non-optional ending " + each)
        Trace.error("No endings left")
        return ""

    def findending(self, pos):
        """Find the ending at the current position"""
        if len(self.endings) == 0:
            return None
        for ending in reversed(self.endings):
            if ending.checkin(pos):
                return ending
            if not ending.optional:
                return None
        return None

    def checkpending(self) -> None:
        """Check if there are any pending endings"""
        if len(self.endings) != 0:
            Trace.error("Pending " + str(self) + " left open")

    def __str__(self) -> str:
        """Printable representation"""
        string = "endings ["
        for ending in self.endings:
            string += str(ending) + ","
        if len(self.endings) > 0:
            string = string[:-1]
        return string + "]"


class PositionEnding:
    """An ending for a parsing position"""

    def __init__(self, ending, optional) -> None:
        self.ending = ending
        self.optional = optional

    def checkin(self, pos):
        """Check for the ending"""
        return pos.checkfor(self.ending)

    def __str__(self) -> str:
        """Printable representation"""
        string = "Ending " + self.ending
        if self.optional:
            string += " (optional)"
        return string


class Position(Globable):
    """A position in a text to parse.
    Including those in Globable, functions to implement by subclasses are:
    skip(), identifier(), extract(), isout() and current()."""

    def __init__(self) -> None:
        Globable.__init__(self)

    def skip(self, string) -> None:
        """Skip a string"""
        Trace.error("Unimplemented skip()")

    def identifier(self) -> str:
        """Return an identifier for the current position."""
        Trace.error("Unimplemented identifier()")
        return "Error"

    def extract(self, length):
        """Extract the next string of the given length, or None if not enough text,

        without advancing the parse position.
        """
        Trace.error("Unimplemented extract()")
        return None

    def checkfor(self, string):
        """Check for a string at the given position."""
        return string == self.extract(len(string))

    def checkforlower(self, string):
        """Check for a string in lower case."""
        extracted = self.extract(len(string))
        if not extracted:
            return False
        return string.lower() == self.extract(len(string)).lower()

    def skipcurrent(self):
        """Return the current character and skip it."""
        current = self.current()
        self.skip(current)
        return current

    def __next__(self):
        """Advance the position and return the next character."""
        self.skipcurrent()
        return self.current()

    def checkskip(self, string) -> bool:
        """Check for a string at the given position; if there, skip it"""
        if not self.checkfor(string):
            return False
        self.skip(string)
        return True

    def error(self, message) -> None:
        """Show an error message and the position identifier."""
        Trace.error(message + ": " + self.identifier())


class TextPosition(Position):
    """A parse position based on a raw text."""

    def __init__(self, text) -> None:
        """Create the position from some text."""
        Position.__init__(self)
        self.pos = 0
        self.text = text
        self.checkbytemark()

    def skip(self, string) -> None:
        """Skip a string of characters."""
        self.pos += len(string)

    def identifier(self):
        """Return a sample of the remaining text."""
        length = 30
        if self.pos + length > len(self.text):
            length = len(self.text) - self.pos
        return "*" + self.text[self.pos : self.pos + length] + "*"

    def isout(self):
        """Find out if we are out of the text yet."""
        return self.pos >= len(self.text)

    def current(self):
        """Return the current character, assuming we are not out."""
        return self.text[self.pos]

    def extract(self, length):
        """Extract the next string of the given length, or None if not enough text."""
        if self.pos + length > len(self.text):
            return None
        return self.text[self.pos : self.pos + length]  # noqa: E203


class Container:
    """A container for text and objects in a lyx file"""

    partkey = None
    parent = None
    begin = None

    def __init__(self) -> None:
        self.contents = []

    def process(self) -> None:
        """Process contents"""

    def gethtml(self):
        """Get the resulting HTML"""
        html = self.output.gethtml(self)
        if isinstance(html, str):
            Trace.error("Raw string " + html)
            html = [html]
        return html

    def escape(self, line, replacements=EscapeConfig.entities):
        """Escape a line with replacements from a map"""
        pieces = sorted(replacements.keys())
        # do them in order
        for piece in pieces:
            if piece in line:
                line = line.replace(piece, replacements[piece])
        return line

    def escapeentities(self, line):
        """Escape all Unicode characters to HTML entities."""
        result = ""
        pos = TextPosition(line)
        while not pos.finished():
            if ord(pos.current()) > 128:
                codepoint = hex(ord(pos.current()))
                if codepoint == "0xd835":
                    codepoint = hex(ord(next(pos)) + 0xF800)
                result += "&#" + codepoint[1:] + ";"
            else:
                result += pos.current()
            pos.skipcurrent()
        return result

    def searchall(self, type):
        """Search for all embedded containers of a given type"""
        lst = []
        self.searchprocess(type, lst.append)
        return lst

    def searchremove(self, type):
        """Search for all containers of a type and remove them"""
        lst = self.searchall(type)
        for container in lst:
            container.parent.contents.remove(container)
        return lst

    def searchprocess(self, type, process) -> None:
        """Search for elements of a given type and process them"""
        self.locateprocess(lambda container: isinstance(container, type), process)

    def locateprocess(self, locate, process) -> None:
        """Search for all embedded containers and process them"""
        for container in self.contents:
            container.locateprocess(locate, process)
            if locate(container):
                process(container)

    def recursivesearch(self, locate, recursive, process) -> None:
        """Perform a recursive search in the container."""
        for container in self.contents:
            if recursive(container):
                container.recursivesearch(locate, recursive, process)
            if locate(container):
                process(container)

    def extracttext(self):
        """Extract all text from allowed containers."""
        constants = ContainerExtractor(ContainerConfig.extracttext).extract(self)
        return "".join(constant.string for constant in constants)

    def group(self, index, group, isingroup) -> None:
        """Group some adjoining elements into a group"""
        if index >= len(self.contents):
            return
        if hasattr(self.contents[index], "grouped"):
            return
        while index < len(self.contents) and isingroup(self.contents[index]):
            self.contents[index].grouped = True
            group.contents.append(self.contents[index])
            self.contents.pop(index)
        self.contents.insert(index, group)

    def remove(self, index) -> None:
        """Remove a container but leave its contents"""
        container = self.contents[index]
        self.contents.pop(index)
        while len(container.contents) > 0:
            self.contents.insert(index, container.contents.pop())

    def tree(self, level=0) -> None:
        """Show in a tree"""
        Trace.debug("  " * level + str(self))
        for container in self.contents:
            container.tree(level + 1)

    def getparameter(self, name):
        """Get the value of a parameter, if present."""
        if name not in self.parameters:
            return None
        return self.parameters[name]

    def getparameterlist(self, name):
        """Get the value of a comma-separated parameter as a list."""
        paramtext = self.getparameter(name)
        if not paramtext:
            return []
        return paramtext.split(",")

    def hasemptyoutput(self) -> bool:
        """Check if the parent's output is empty."""
        current = self.parent
        while current:
            if current.output.isempty():
                return True
            current = current.parent
        return False

    def __str__(self) -> str:
        """Get a description"""
        if not self.begin:
            return self.__class__.__name__
        return self.__class__.__name__ + "@" + str(self.begin)


class BlackBox(Container):
    """A container that does not output anything"""

    def __init__(self) -> None:
        self.parser = LoneCommand()
        self.output = EmptyOutput()
        self.contents = []


class StringContainer(Container):
    """A container for a single string"""

    parsed = None

    def __init__(self) -> None:
        self.parser = StringParser()
        self.output = StringOutput()
        self.string = ""

    def process(self) -> None:
        """Replace special chars from the contents."""
        if self.parsed:
            self.string = self.replacespecial(self.parsed)
            self.parsed = None

    def replacespecial(self, line):
        """Replace all special chars from a line"""
        replaced = self.escape(line, EscapeConfig.entities)
        replaced = self.changeline(replaced)
        if ContainerConfig.string["startcommand"] in replaced and len(replaced) > 1:
            # unprocessed commands
            if self.begin:
                message = "Unknown command at " + str(self.begin) + ": "
            else:
                message = "Unknown command: "
            Trace.error(message + replaced.strip())
        return replaced

    def changeline(self, line):
        return self.escape(line, EscapeConfig.chars)

    def extracttext(self):
        """Return all text."""
        return self.string

    def __str__(self) -> str:
        """Return a printable representation."""
        result = "StringContainer"
        if self.begin:
            result += "@" + str(self.begin)
        ellipsis = "..."
        if len(self.string.strip()) <= 15:
            ellipsis = ""
        return result + " (" + self.string.strip()[:15] + ellipsis + ")"


class Constant(StringContainer):
    """A constant string"""

    def __init__(self, text) -> None:
        self.contents = []
        self.string = text
        self.output = StringOutput()

    def __str__(self) -> str:
        return "Constant: " + self.string


class DocumentParameters:
    """Global parameters for the document."""

    displaymode = False
