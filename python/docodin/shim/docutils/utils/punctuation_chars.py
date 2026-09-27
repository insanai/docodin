"""Unicode punctuation character sets for inline markup recognition rules."""

from __future__ import annotations

from ._punctuation_data import closers, closing_delimiters, delimiters, openers, quote_pairs

__docformat__ = "reStructuredText"
__all__ = ["closers", "closing_delimiters", "delimiters", "match_chars", "openers",
           "quote_pairs"]


def match_chars(c1: str, c2: str) -> bool:
    """Whether `c1` and `c2` are a matching open/close character pair."""
    try:
        i = openers.index(c1)
    except ValueError:
        return False
    return c2 == closers[i] or c2 in quote_pairs.get(c1, "")
