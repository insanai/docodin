"""Lexical analysis of formal languages (i.e. code) using Pygments."""

from __future__ import annotations

from collections.abc import Iterable, Iterator
from typing import Any

from docutils import ApplicationError

try:
    import pygments
    from pygments.formatters.html import _get_ttype_class
    from pygments.lexers import get_lexer_by_name

    with_pygments = True
except ImportError:
    with_pygments = False

__docformat__ = "reStructuredText"

unstyled_tokens = ["token", "text", ""]


class LexerError(ApplicationError):
    pass


class Lexer:
    """Parse `code` lines and yield "classified" tokens (classes, value)."""

    def __init__(self, code: str, language: str, tokennames: str = "short") -> None:
        self.code = code
        self.language = language
        self.tokennames = tokennames
        self.lexer: Any = None
        if language in ("", "text") or tokennames == "none":
            return
        if not with_pygments:
            raise LexerError("Cannot analyze code. Pygments package not found.")
        try:
            self.lexer = get_lexer_by_name(self.language)
        except pygments.util.ClassNotFound:
            raise LexerError('Cannot analyze code. No Pygments lexer found for "%s".'
                             % language) from None

    def merge(self, tokens: Iterable[tuple[Any, str]]) -> Iterator[tuple[Any, str]]:
        """Merge subsequent tokens of the same token-type; drop the final newline."""
        tokens = iter(tokens)
        lasttype, lastval = next(tokens)
        for ttype, value in tokens:
            if ttype is lasttype:
                lastval += value
            else:
                yield lasttype, lastval
                lasttype, lastval = ttype, value
        lastval = lastval.removesuffix("\n")
        if lastval:
            yield lasttype, lastval

    def __iter__(self) -> Iterator[tuple[list[str], str]]:
        """Yield (classes, value) pairs: the token classes of each code token."""
        if self.lexer is None:
            yield [], self.code
            return
        for tokentype, value in self.merge(pygments.lex(self.code, self.lexer)):
            if self.tokennames == "long":
                classes = str(tokentype).lower().split(".")
            else:
                classes = [_get_ttype_class(tokentype)]
            yield [cls for cls in classes if cls not in unstyled_tokens], value


class NumberLines:
    """Insert linenumber-tokens at the start of every code line."""

    def __init__(self, tokens: Iterable[tuple[list[str], str]], startline: int,
                 endline: int) -> None:
        self.tokens = tokens
        self.startline = startline
        self.fmt_str = f"%{len(str(endline))}d "

    def __iter__(self) -> Iterator[tuple[list[str], str]]:
        lineno = self.startline
        yield ["ln"], self.fmt_str % lineno
        for ttype, value in self.tokens:
            lines = value.split("\n")
            for line in lines[:-1]:
                yield ttype, line + "\n"
                lineno += 1
                yield ["ln"], self.fmt_str % lineno
            yield ttype, lines[-1]
