"""``docodin`` command: a docutils front end that parses with docodin.

    docodin [--writer=NAME] [docutils options] [SOURCE [DESTINATION]]

Accepts every docutils command-line option (see ``docodin --help``); the
default writer is ``html5``.  Equivalent to ``docutils --parser=docodin``.
"""

from __future__ import annotations

import sys

import docutils.core

from docodin.parser import Parser

WRITER_ALIASES = {
    "html": "html5", "rst2html": "html5", "rst2html5": "html5", "rst2latex": "latex",
    "rst2xml": "xml", "rst2pseudoxml": "pseudoxml", "rst2man": "manpage", "rst2odt": "odt",
    "rst2s5": "s5", "rst2xetex": "xetex",
}


def main(argv: list[str] | None = None) -> None:
    args = list(sys.argv[1:] if argv is None else argv)
    writer = "html5"
    rest = []
    i = 0
    while i < len(args):
        arg = args[i]
        if arg.startswith("--writer="):
            writer = arg.split("=", 1)[1]
        elif arg == "--writer" and i + 1 < len(args):
            writer = args[i + 1]
            i += 1
        elif i == 0 and arg in WRITER_ALIASES:
            writer = arg
        else:
            rest.append(arg)
        i += 1
    writer = WRITER_ALIASES.get(writer, writer)
    docutils.core.publish_cmdline(
        parser=Parser(), writer=writer, argv=rest,
        description="Process reStructuredText with the docodin parser. " + docutils.core.default_description,
    )


if __name__ == "__main__":
    main()
