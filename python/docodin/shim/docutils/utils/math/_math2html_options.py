"""Diagnostics, runtime options and document parameters of `math2html`.

Everything here is process-global state held in class attributes, as in docutils:
`DocumentParameters.displaymode` selects inline or display rendering, `Options.simplemath`
switches off the stacking of limits and the resizing of brackets, and `Trace` writes
messages (errors go to `sys.stderr`, prefixed by ``*``).
"""

from __future__ import annotations

import pathlib
import sys
from typing import NoReturn, TextIO

__docformat__ = "reStructuredText"

__version__ = "1.3 (2021-06-02)"


class Trace:
    """Message output, configured through class attributes."""

    debugmode = False
    quietmode = False
    showlinesmode = False
    prefix: str | None = None

    @classmethod
    def debug(cls, message: str) -> None:
        """Show a debug message (only in debug mode)."""
        if Trace.debugmode and not Trace.quietmode:
            Trace.show(message, sys.stdout)

    @classmethod
    def message(cls, message: str) -> None:
        """Show a trace message (unless in quiet mode)."""
        if not Trace.quietmode:
            Trace.show(Trace._prefixed(message), sys.stdout)

    @classmethod
    def error(cls, message: str) -> None:
        """Show an error message on standard error."""
        Trace.show(Trace._prefixed("* " + message), sys.stderr)

    @classmethod
    def show(cls, message: str, channel: TextIO) -> None:
        """Write a message line to `channel`."""
        channel.write(message + "\n")

    @staticmethod
    def _prefixed(message: str) -> str:
        if Trace.prefix and Trace.showlinesmode:
            return Trace.prefix + message
        return message


class DocumentParameters:
    """Global parameters for the document."""

    displaymode = False  # display (block) math: stack limits above and below operators


class Options:
    """The runtime options, set from the command line."""

    location: str | None = None

    debug = False
    quiet = False
    version = False
    help = False
    simplemath = False
    showlines = True

    branches: dict[str, object] = {}

    def parseoptions(self, args: list[str]) -> None:
        """Parse command line options; `args` starts with the program name."""
        Options.location = args.pop(0)
        problem = CommandLineParser(Options).parseoptions(args)
        if problem:
            Trace.error(problem)
            self.usage()
        self.processoptions()

    def processoptions(self) -> None:
        """Act on the parsed options and configure `Trace`."""
        if Options.help:
            self.usage()
        if Options.version:
            self.showversion()
        Trace.debugmode = self.debug
        Trace.quietmode = self.quiet
        Trace.showlinesmode = self.showlines

    def usage(self) -> NoReturn:
        """Show the correct usage and exit."""
        Trace.error(f'Usage: {pathlib.Path(Options.location).parent} [options] "input string"')
        Trace.error("Convert input string with LaTeX math to MathML")
        self.showoptions()

    def showoptions(self) -> NoReturn:
        """Show all possible options and exit."""
        Trace.error("    --help:                 show this online help")
        Trace.error("    --quiet:                disables all runtime messages")
        Trace.error("    --debug:                enable debugging messages (for developers)")
        Trace.error("    --version:              show version number and release date")
        Trace.error("    --simplemath:           do not generate fancy math constructions")
        sys.exit()

    def showversion(self) -> NoReturn:
        """Show the version and exit."""
        Trace.error("math2html " + __version__)
        sys.exit()


class CommandLineParser:
    """Set the attributes of an options object from ``--name[=value]`` arguments."""

    def __init__(self, options: object) -> None:
        self.options = options

    def parseoptions(self, args: list[str]) -> str | None:
        """Consume the leading options in `args`; return a problem description or None."""
        while args and args[0].startswith("--"):
            key, value = self.readoption(args)
            if not key:
                return f"Option {value} not recognized"
            if not value:
                return f"Option {key} needs a value"
            setattr(self.options, key, value)
        return None

    def readoption(self, args: list[str]) -> tuple[str | None, object]:
        """Read the key and value of the first option in `args`.

        Boolean options are switched on; other options take the next argument
        (or the text after ``=``) as value, which list options append.
        """
        arg = args.pop(0)[2:]
        if "=" in arg:
            key = self.readequalskey(arg, args)
        else:
            key = arg.replace("-", "")
        if not hasattr(self.options, key):
            return None, key
        current = getattr(self.options, key)
        if isinstance(current, bool):
            return key, True
        if not args:
            return key, None
        value = args.pop(0)
        if isinstance(current, list):
            current.append(value)
            return key, current
        return key, value

    def readequalskey(self, arg: str, args: list[str]) -> str:
        """Split ``key=value``: put the value back in front of `args`, return the key."""
        key, value = arg.split("=", 1)
        args.insert(0, value)
        return key
