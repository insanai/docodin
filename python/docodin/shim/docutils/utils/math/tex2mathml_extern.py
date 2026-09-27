"""Wrappers for TeX->MathML conversion by external tools

This module is provisional:
the API is not settled and may change with any minor Docutils version.
"""

from __future__ import annotations

import subprocess

from docutils import nodes
from docutils.utils.math import MathError, wrap_math_code

__docformat__ = "reStructuredText"

# `latexml` expects a complete document:
document_template = r"""\documentclass{article}
\begin{document}
%s
\end{document}
"""

_LATEXML_ERROR_TAGS = ("Error:", "Warning:", "Fatal:")


def _check_result(result: subprocess.CompletedProcess, details: list | None = None) -> None:
    """Raise MathError if the conversion went wrong.

    :details: list of doctree nodes with additional info
    """
    details = details or []
    msg = ""
    if not details and result.stderr:
        details = [nodes.paragraph("", result.stderr, classes=["pre-wrap"])]
    if details:
        msg = f"TeX to MathML converter `{result.args[0]}` failed:"
    elif result.returncode:
        msg = (f"TeX to MathMl converter `{result.args[0]}` "
               f"exited with Errno {result.returncode}.")
    elif not result.stdout:
        msg = f"TeX to MathML converter `{result.args[0]}` returned no MathML."
    if msg:
        raise MathError(msg, details=details)


def _between(text: str, start: str, stop: str, offset: int) -> str:
    """Return `text` from `start` (+`offset`) up to `stop` (``str.find`` semantics)."""
    return text[text.find(start) + offset:text.find(stop)]


def blahtexml(math_code: str, as_block: bool = False) -> str:
    """Convert LaTeX math code to MathML with blahtexml__.

    __ http://gva.noekeon.org/blahtexml/
    """
    args = ["blahtexml",
            "--mathml",
            "--indented",
            "--spacing", "moderate",
            "--mathml-encoding", "raw",
            "--other-encoding", "raw",
            "--doctype-xhtml+mathml",
            "--annotate-TeX",
            ]
    # "blahtexml" expects LaTeX code without math-mode-switch.
    # We still need to tell it about displayed equation(s).
    mathml_args = ' display="block"' if as_block else ""
    _wrapped = wrap_math_code(math_code, as_block)
    if "{align*}" in _wrapped:
        math_code = _wrapped.replace("{align*}", "{aligned}")

    result = subprocess.run(args, input=math_code, capture_output=True, text=True)

    # blahtexml writes <error> messages to stdout
    if "<error>" in result.stdout:
        result.stderr = _between(result.stdout, "<message>", "</message>", 9)
    else:
        result.stdout = _between(result.stdout, "<markup>", "</markup>", 9)
    _check_result(result)
    return (f'<math xmlns="http://www.w3.org/1998/Math/MathML"{mathml_args}>'
            f"\n{result.stdout}</math>")


def _latexml_errors(text: str) -> str:
    return "\n".join(line for line in text.splitlines()
                     if line.startswith(_LATEXML_ERROR_TAGS))


def latexml(math_code: str, as_block: bool = False) -> str:
    """Convert LaTeX math code to MathML with LaTeXML__.

    Comprehensive macro support but **very** slow.

    __ http://dlmf.nist.gov/LaTeXML/
    """
    # LaTeXML works in 2 stages, expects complete documents.
    #
    # The `latexmlmath`__ convenience wrapper does not support block-level
    # (displayed) equations.
    #
    # __ https://metacpan.org/dist/LaTeXML/view/bin/latexmlmath
    args1 = ["latexml",
             "-",  # read from stdin
             "--preload=amsmath",
             "--preload=amssymb",  # also loads amsfonts
             "--inputencoding=utf8",
             "--",
             ]
    math_code = document_template % wrap_math_code(math_code, as_block)

    result1 = subprocess.run(args1, input=math_code, capture_output=True, text=True)
    if result1.stderr:
        result1.stderr = _latexml_errors(result1.stderr)
    _check_result(result1)

    args2 = ["latexmlpost",
             "-",
             "--nonumbersections",
             "--format=html5",  # maths included as MathML
             "--omitdoctype",   # Make it simple, we only need the maths.
             "--noscan",        # ...
             "--nocrossref",
             "--nographicimages",
             "--nopictureimages",
             "--nodefaultresources",  # do not copy *.css files to output dir
             "--",
             ]
    result2 = subprocess.run(args2, input=result1.stdout, capture_output=True, text=True)
    # Extract MathML from HTML document:
    # <table> with <math> in cells for "align", <math> element else.
    start = result2.stdout.find('<table class="ltx_equationgroup')
    if start != -1:
        stop = result2.stdout.find("</table>", start) + 8
        result2.stdout = result2.stdout[start:stop].replace(
            "ltx_equationgroup", "borderless align-center")
    else:
        result2.stdout = _math_element(result2.stdout)
    # Search for error messages
    # (latexmlpost reports errors in output, stderr is a fallback)
    result2.stderr = _latexml_errors(result2.stdout or result2.stderr)
    _check_result(result2)
    return result2.stdout


def pandoc(math_code: str, as_block: bool = False) -> str:
    """Convert LaTeX math code to MathML with pandoc__.

    __ https://pandoc.org/
    """
    args = ["pandoc",
            "--mathml",
            "--from=latex",
            ]
    result = subprocess.run(args, input=wrap_math_code(math_code, as_block),
                            capture_output=True, text=True)

    result.stdout = _math_element(result.stdout)
    # Pandoc (2.9.2.1) messages are pre-formatted for the terminal:
    #   1. summary
    #   2. math source (part)
    #   3. error spot indicator '^' (works only in a literal block)
    #   4. assumed problem
    #   5. assumed solution (may be wrong or confusing)
    # Construct a "details" list:
    details = []
    if result.stderr:
        lines = result.stderr.splitlines()
        details += [nodes.paragraph("", lines[0]),
                    nodes.literal_block("", "\n".join(lines[1:3])),
                    nodes.paragraph("", "\n".join(lines[3:]), classes=["pre-wrap"]),
                    ]
    _check_result(result, details=details)
    return result.stdout


def _math_element(text: str) -> str:
    """Return the ``<math>`` element in `text` (``str.find`` semantics)."""
    return text[text.find("<math"):text.find("</math>") + 7]


def ttm(math_code: str, as_block: bool = False) -> str:
    """Convert LaTeX math code to MathML with TtM__.

    Aged, limited, but fast.

    __ http://silas.psfc.mit.edu/tth/mml/
    """
    args = ["ttm",
            "-L",  # source is LaTeX snippet
            "-r"]  # output MathML snippet
    math_code = wrap_math_code(math_code, as_block)

    # "ttm" does not support UTF-8 input. (Docutils converts most math
    # characters to LaTeX commands before calling this function.)
    try:
        result = subprocess.run(args, input=math_code, capture_output=True, text=True,
                                encoding="ISO-8859-1")
    except UnicodeEncodeError as err:
        raise MathError(err) from err

    result.stdout = _math_element(result.stdout)
    if as_block:
        result.stdout = result.stdout.replace("<math xmlns=", '<math display="block" xmlns=')
    result.stderr = "\n".join(line[5:] + "."
                              for line in result.stderr.splitlines()
                              if line.startswith("**** "))
    _check_result(result)
    return result.stdout
