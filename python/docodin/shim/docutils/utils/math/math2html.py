"""Convert LaTeX equations to HTML output.

Based on eLyXer: convert LyX source files to HTML output.
http://alexfernandez.github.io/elyxer/

The implementation is split into private submodules (``_math2html_*``);
all names are importable from here.
"""

# Versions:
# 1.2.5  2015-02-26  eLyXer standalone formula conversion to HTML.
# 1.3    2021-06-02  Removed code for conversion of LyX files not
#                    required for LaTeX math.
#                    Support for more math commands from the AMS "math-guide".
# 2.0    2021-12-31  Drop 2.7 compatibility code.

from __future__ import annotations

import pathlib
import sys
import unicodedata

from docutils.utils.math import tex2unichar
from docutils.utils.math._math2html_base import (
    BlackBox,
    BoundedDummy,
    BoundedParser,
    Cloner,
    CommandLineParser,
    Constant,
    Container,
    ContainerExtractor,
    ContainerOutput,
    ContentsOutput,
    DocumentParameters,
    EmptyOutput,
    EndingList,
    ExcludingParser,
    FilteredOutput,
    FixedOutput,
    Globable,
    LoneCommand,
    Options,
    Parser,
    Position,
    PositionEnding,
    StringContainer,
    StringOutput,
    StringParser,
    TaggedOutput,
    TextParser,
    TextPosition,
    Trace,
)
from docutils.utils.math._math2html_commands import (
    BeginCommand,
    BigBracket,
    BracketCommand,
    BracketProcessor,
    CombiningFunction,
    EquationEnvironment,
    FormulaArray,
    FormulaCases,
    FormulaCell,
    FormulaEquation,
    FormulaMatrix,
    FormulaRow,
    HybridFunction,
    HybridSize,
    LimitCommand,
    LimitPreviousCommand,
    LimitsProcessor,
    MultiRowFormula,
    OversetFunction,
    ParameterDefinition,
    ParameterFunction,
    UndersetFunction,
)
from docutils.utils.math._math2html_config import (
    ContainerConfig,
    EscapeConfig,
    FormulaConfig,
)
from docutils.utils.math._math2html_formula import (
    AlphaCommand,
    Bracket,
    CommandBit,
    Comment,
    EmptyCommand,
    FontFunction,
    Formula,
    FormulaBit,
    FormulaCommand,
    FormulaConstant,
    FormulaFactory,
    FormulaNumber,
    FormulaParser,
    FormulaProcessor,
    FormulaSymbol,
    MathsProcessor,
    OneParamFunction,
    RawText,
    SpacedCommand,
    SquareBracket,
    SymbolFunction,
    TaggedBit,
    TextFunction,
    WhiteSpace,
    WholeFormula,
)

__docformat__ = "reStructuredText"

__all__ = [  # every public name of docutils' math2html (split into submodules)
    "AlphaCommand",
    "BeginCommand",
    "BigBracket",
    "BlackBox",
    "BoundedDummy",
    "BoundedParser",
    "Bracket",
    "BracketCommand",
    "BracketProcessor",
    "Cloner",
    "CombiningFunction",
    "CommandBit",
    "CommandLineParser",
    "Comment",
    "Constant",
    "Container",
    "ContainerConfig",
    "ContainerExtractor",
    "ContainerOutput",
    "ContentsOutput",
    "DocumentParameters",
    "EmptyCommand",
    "EmptyOutput",
    "EndingList",
    "EquationEnvironment",
    "EscapeConfig",
    "ExcludingParser",
    "FilteredOutput",
    "FixedOutput",
    "FontFunction",
    "Formula",
    "FormulaArray",
    "FormulaBit",
    "FormulaCases",
    "FormulaCell",
    "FormulaCommand",
    "FormulaConfig",
    "FormulaConstant",
    "FormulaEquation",
    "FormulaFactory",
    "FormulaMatrix",
    "FormulaNumber",
    "FormulaParser",
    "FormulaProcessor",
    "FormulaRow",
    "FormulaSymbol",
    "Globable",
    "HybridFunction",
    "HybridSize",
    "LimitCommand",
    "LimitPreviousCommand",
    "LimitsProcessor",
    "LoneCommand",
    "MathsProcessor",
    "MultiRowFormula",
    "OneParamFunction",
    "Options",
    "OversetFunction",
    "ParameterDefinition",
    "ParameterFunction",
    "Parser",
    "Position",
    "PositionEnding",
    "RawText",
    "SpacedCommand",
    "SquareBracket",
    "StringContainer",
    "StringOutput",
    "StringParser",
    "SymbolFunction",
    "TaggedBit",
    "TaggedOutput",
    "TextFunction",
    "TextParser",
    "TextPosition",
    "Trace",
    "UndersetFunction",
    "WhiteSpace",
    "WholeFormula",
    "main",
    "math2html",
    "pathlib",
    "sys",
    "tex2unichar",
    "unicodedata",
]


def math2html(formula: str) -> str:
    """Convert some TeX math to HTML."""
    factory = FormulaFactory()
    whole = factory.parseformula(formula)
    FormulaProcessor().process(whole)
    whole.process()
    return "".join(whole.gethtml())


def main() -> None:
    """Main function, called if invoked from the command line"""
    args = sys.argv
    Options().parseoptions(args)
    if len(args) != 1:
        Trace.error("Usage: math2html.py escaped_string")
        sys.exit()
    result = math2html(args[0])
    Trace.message(result)


if __name__ == "__main__":
    main()
