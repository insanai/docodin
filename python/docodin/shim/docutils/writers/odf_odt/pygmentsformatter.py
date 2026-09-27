"""Additional support for Pygments formatter."""

from __future__ import annotations

import pygments
import pygments.formatter
import pygments.token

_SPAN = '<text:span text:style-name="%s">%s</text:span>'
_Token = pygments.token.Token

_PROG_STYLES = {
    _Token.Keyword: "codeblock-keyword",
    _Token.Literal.String: "codeblock-string",
    _Token.Literal.Number.Integer: "codeblock-number",
    _Token.Literal.Number.Integer.Long: "codeblock-number",
    _Token.Literal.Number.Float: "codeblock-number",
    _Token.Literal.Number.Hex: "codeblock-number",
    _Token.Literal.Number.Oct: "codeblock-number",
    _Token.Literal.Number: "codeblock-number",
    _Token.Operator: "codeblock-operator",
    _Token.Comment: "codeblock-comment",
    _Token.Name.Class: "codeblock-classname",
    _Token.Name.Function: "codeblock-functionname",
    _Token.Name: "codeblock-name",
}

_LATEX_STYLES = {
    _Token.Keyword: "codeblock-keyword",
    _Token.Literal.String: "codeblock-string",
    _Token.Literal.String.Backtick: "codeblock-string",
    _Token.Name.Attribute: "codeblock-operator",
    _Token.Comment: "codeblock-comment",
    _Token.Name.Builtin: "codeblock-name",
}


class OdtPygmentsFormatter(pygments.formatter.Formatter):
    def __init__(self, rststyle_function, escape_function) -> None:
        pygments.formatter.Formatter.__init__(self)
        self.rststyle_function = rststyle_function
        self.escape_function = escape_function

    def rststyle(self, name, parameters=()):
        return self.rststyle_function(name, parameters)


class OdtPygmentsProgFormatter(OdtPygmentsFormatter):
    def format(self, tokensource, outfile) -> None:  # noqa: A003 - Pygments API name
        for ttype, value in tokensource:
            value = self.escape_function(value)
            style = _PROG_STYLES.get(ttype)
            if style is not None:
                value = _SPAN % (self.rststyle(style), value)
            outfile.write(value)


class OdtPygmentsLaTeXFormatter(OdtPygmentsFormatter):
    def format(self, tokensource, outfile) -> None:  # noqa: A003 - Pygments API name
        for ttype, value in tokensource:
            value = self.escape_function(value)
            style = _LATEX_STYLES.get(ttype)
            if style is None:
                pass
            elif ttype == _Token.Comment and value[-1] == "\n":
                value = _SPAN % (self.rststyle(style), value[:-1]) + "\n"
            else:
                value = _SPAN % (self.rststyle(style), value)
            outfile.write(value)
