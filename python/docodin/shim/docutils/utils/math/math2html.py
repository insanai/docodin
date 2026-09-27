"""Convert LaTeX math to HTML with CSS styling (based on eLyXer, by Alex Fernández).

`math2html` translates a TeX formula in three steps:

1. **Parse** (`FormulaFactory`). A `TextPosition` walks the source. At each character
   the first matching bit kind parses the next *formula bit*: a symbol, a run of letters
   or digits, a ``{}`` group, a comment, white space, a script (``^``/``_``), or a
   ``\\command``. Commands are looked up in the tables of `FormulaConfig` and read their
   parameters as the table they are found in prescribes (see `_math2html_commands`,
   `_math2html_arrays` and `_math2html_hybrid`). Nested constructs push their closing
   text onto the position's ending stack, so a parse stops at the right ``}``,
   ``\\end{...}``, ``&`` or ``\\\\``.

2. **Process** (`FormulaProcessor`). The tree is rewritten in place: in display mode,
   scripts of big operators become limits above and below them; sub- and superscript
   pairs are stacked; ``\\left``/``\\right`` brackets are rebuilt to span the rows of
   their contents; letters are set in italics.

3. **Output**. Each container renders itself through its output strategy, and the HTML
   strings are joined.

Problems in the input (unknown commands, unbalanced braces) are reported through
`Trace.error` on standard error and rendered as well as possible.

The implementation lives in private submodules (``_math2html_*``); all public names of
docutils' module are importable from here.
"""

from __future__ import annotations

import pathlib
import sys
import unicodedata

from docutils.utils.math import tex2unichar
from docutils.utils.math._math2html_arrays import (
    BeginCommand,
    BigBracket,
    EquationEnvironment,
    FormulaArray,
    FormulaCases,
    FormulaCell,
    FormulaEquation,
    FormulaMatrix,
    FormulaRow,
    MultiRowFormula,
)
from docutils.utils.math._math2html_bits import (
    Bracket,
    Comment,
    FormulaBit,
    FormulaConstant,
    FormulaNumber,
    FormulaSymbol,
    RawText,
    SquareBracket,
    TaggedBit,
    WhiteSpace,
    WholeFormula,
)
from docutils.utils.math._math2html_commands import (
    AlphaCommand,
    BracketCommand,
    CombiningFunction,
    CommandBit,
    EmptyCommand,
    FontFunction,
    FormulaCommand,
    LimitCommand,
    LimitPreviousCommand,
    OneParamFunction,
    OversetFunction,
    SpacedCommand,
    SymbolFunction,
    TextFunction,
    UndersetFunction,
)
from docutils.utils.math._math2html_config import ContainerConfig, EscapeConfig, FormulaConfig
from docutils.utils.math._math2html_hybrid import (
    HybridFunction,
    HybridSize,
    ParameterDefinition,
    ParameterFunction,
)
from docutils.utils.math._math2html_legacy import (
    BlackBox,
    BoundedDummy,
    BoundedParser,
    Cloner,
    ExcludingParser,
    FilteredOutput,
    Formula,
    FormulaParser,
    LoneCommand,
    Parser,
    StringParser,
    TextParser,
)
from docutils.utils.math._math2html_options import (
    CommandLineParser,
    DocumentParameters,
    Options,
    Trace,
)
from docutils.utils.math._math2html_options import (
    __version__ as __version__,
)
from docutils.utils.math._math2html_pipeline import (
    BracketProcessor,
    FormulaFactory,
    FormulaProcessor,
    LimitsProcessor,
    MathsProcessor,
)
from docutils.utils.math._math2html_text import (
    EndingList,
    Globable,
    Position,
    PositionEnding,
    TextPosition,
)
from docutils.utils.math._math2html_tree import (
    Constant,
    Container,
    ContainerExtractor,
    ContainerOutput,
    ContentsOutput,
    EmptyOutput,
    FixedOutput,
    StringContainer,
    StringOutput,
    TaggedOutput,
)

__docformat__ = "reStructuredText"

__all__ = [
    "AlphaCommand", "BeginCommand", "BigBracket", "BlackBox", "BoundedDummy", "BoundedParser",
    "Bracket", "BracketCommand", "BracketProcessor", "Cloner", "CombiningFunction",
    "CommandBit", "CommandLineParser", "Comment", "Constant", "Container", "ContainerConfig",
    "ContainerExtractor", "ContainerOutput", "ContentsOutput", "DocumentParameters",
    "EmptyCommand", "EmptyOutput", "EndingList", "EquationEnvironment", "EscapeConfig",
    "ExcludingParser", "FilteredOutput", "FixedOutput", "FontFunction", "Formula",
    "FormulaArray", "FormulaBit", "FormulaCases", "FormulaCell", "FormulaCommand",
    "FormulaConfig", "FormulaConstant", "FormulaEquation", "FormulaFactory", "FormulaMatrix",
    "FormulaNumber", "FormulaParser", "FormulaProcessor", "FormulaRow", "FormulaSymbol",
    "Globable", "HybridFunction", "HybridSize", "LimitCommand", "LimitPreviousCommand",
    "LimitsProcessor", "LoneCommand", "MathsProcessor", "MultiRowFormula", "OneParamFunction",
    "Options", "OversetFunction", "ParameterDefinition", "ParameterFunction", "Parser",
    "Position", "PositionEnding", "RawText", "SpacedCommand", "SquareBracket",
    "StringContainer", "StringOutput", "StringParser", "SymbolFunction", "TaggedBit",
    "TaggedOutput", "TextFunction", "TextParser", "TextPosition", "Trace", "UndersetFunction",
    "WhiteSpace", "WholeFormula", "main", "math2html", "pathlib", "sys", "tex2unichar",
    "unicodedata",
]


def math2html(formula: str) -> str:
    """Convert some TeX math to HTML.

    `DocumentParameters.displaymode` selects display (block) or inline rendering.
    """
    whole = FormulaFactory().parseformula(formula)
    FormulaProcessor().process(whole)
    return "".join(whole.gethtml())


def main() -> None:
    """Convert the formula given on the command line (after any options)."""
    args = sys.argv
    Options().parseoptions(args)
    if len(args) != 1:
        Trace.error("Usage: math2html.py escaped_string")
        sys.exit()
    Trace.message(math2html(args[0]))


if __name__ == "__main__":
    main()
