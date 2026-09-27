"""``docodin`` command: a docutils front end that parses with docodin.

    docodin [--writer=NAME] [docutils options] [SOURCE [DESTINATION]]

Accepts every docutils command-line option (see ``docodin --help``); the
default writer is ``html5``.  Equivalent to ``docutils --parser=docodin``.
The native ``docodin`` runs documents that need Python through it, with the
same arguments (the writer as ``--writer=NAME``, or a first argument such as
``latex``, as for the native command).
"""

from __future__ import annotations

import sys

# isort: off
import docodin  # enables the docutils shim when docutils is not installed
import docutils.core
# isort: on

from docodin.parser import Parser

WRITER_ALIASES = {
    "html": "html5", "rst2html": "html5", "rst2html5": "html5", "rst2latex": "latex",
    "rst2xml": "xml", "rst2pseudoxml": "pseudoxml", "rst2man": "manpage", "rst2odt": "odt",
    "rst2s5": "s5", "rst2xetex": "xetex",
}
# First arguments that name the writer (as for the native ``docodin``).
WRITER_COMMANDS = {*WRITER_ALIASES, "html5", "xhtml", "latex", "latex2e", "xetex", "xml",
                   "pseudoxml"}


def split_writer(args: list[str]) -> tuple[str, list[str]]:
    """The writer (``--writer=NAME``, ``--writer NAME`` or a first-argument command) and
    the other arguments; the arguments after ``--`` are positional."""
    writer = "html5"
    rest: list[str] = []
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--":
            rest.extend(args[i:])
            break
        if arg.startswith("--writer="):
            writer = arg.split("=", 1)[1]
        elif arg == "--writer" and i + 1 < len(args):
            writer = args[i + 1]
            i += 1
        elif i == 0 and arg in WRITER_COMMANDS:
            writer = arg
        else:
            rest.append(arg)
        i += 1
    return WRITER_ALIASES.get(writer, writer), rest


def main(argv: list[str] | None = None) -> None:
    """Run the docodin CLI front-end or delegated Sphinx build.

    Args:
        argv: Optional command-line argument list. Defaults to sys.argv[1:].
    """
    args = list(sys.argv[1:] if argv is None else argv)

    # Check for 'sphinx' subcommand: docodin sphinx [options] sourcedir outdir
    if len(args) > 0 and args[0] == "sphinx":
        try:
            from sphinx.cmd.build import main as sphinx_main
        except ImportError:
            sys.stderr.write("docodin: sphinx is not installed in this environment.\n")
            sys.exit(1)
        docodin.patch_docutils()
        sys.exit(sphinx_main(args[1:]))

    writer, rest = split_writer(args)
    docutils.core.publish_cmdline(
        parser=Parser(), writer=writer, argv=rest,
        description=("Process reStructuredText with the docodin parser. "
                     + docutils.core.default_description),
    )


if __name__ == "__main__":
    main()
