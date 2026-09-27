"""Docutils smartquotes drop-in implementation for docodin."""

from __future__ import annotations

import re
from typing import Any

default_smartypants_attr = "1"


class smartchars:
    """Language-aware typographic quotes and punctuation characters.

    Attributes:
        endash: En-dash unicode character.
        emdash: Em-dash unicode character.
        ellipsis: Horizontal ellipsis unicode character.
        apostrophe: Right single quotation mark / apostrophe.
        opquote: Primary opening quote.
        cpquote: Primary closing quote.
        osquote: Secondary opening quote.
        csquote: Secondary closing quote.
    """

    endash = "–"
    emdash = "—"
    ellipsis = "…"
    apostrophe = "’"

    quotes: dict[str, str | tuple[str, ...]] = {
        "af": "“”‘’",
        "ca": "«»“”",
        "cs": "„“‚‘",
        "da": "»«›‹",
        "de": "„“‚‘",
        "de-ch": "«»‹›",
        "el": "«»“”",
        "en": "“”‘’",
        "en-uk-x-altquot": "‘’“”",
        "eo": "“”‘’",
        "es": "«»“”",
        "et": "„“‚‘",
        "eu": "«»‹›",
        "fi": "””’’",
        "fr": ("« ", " »", "“", "”"),
        "fr-ch": "«»‹›",
        "it": "«»“”",
        "ja": "「」『』",
        "nl": "“”‘’",
        "no": "«»’’",
        "pl": "„”«»",
        "pt": "«»“”",
        "ru": "«»„“",
        "sv": "””’’",
        "zh-cn": "“”‘’",
    }

    def __init__(self, language: str = "en") -> None:
        self.language = language
        try:
            (self.opquote, self.cpquote, self.osquote, self.csquote) = self.quotes[language.lower()]
        except (KeyError, ValueError):
            self.opquote, self.cpquote, self.osquote, self.csquote = '""\'\''


def educateDashesOldSchool(text: str) -> str:
    """Convert double and triple hyphens to en-dash and em-dash.

    Args:
        text: Input string.

    Returns:
        String with hyphens converted to dashes.
    """
    text = text.replace("---", smartchars.emdash)
    text = text.replace("--", smartchars.endash)
    return text


def educateDashes(text: str) -> str:
    """Convert hyphens to em-dashes and en-dashes.

    Args:
        text: Input string.

    Returns:
        String with educated dashes.
    """
    return educateDashesOldSchool(text)


def educateDashesOldSchoolInverted(text: str) -> str:
    """Convert hyphens to dashes with inverted convention.

    Args:
        text: Input string.

    Returns:
        String with educated dashes.
    """
    text = text.replace("---", smartchars.endash)
    text = text.replace("--", smartchars.emdash)
    return text


def educateEllipses(text: str) -> str:
    """Convert triple dots to unicode ellipsis.

    Args:
        text: Input string.

    Returns:
        String with educated ellipses.
    """
    return text.replace("...", smartchars.ellipsis)


def educateBackticks(text: str) -> str:
    """Convert backticks to curly quotes.

    Args:
        text: Input string.

    Returns:
        String with educated backtick quotes.
    """
    text = text.replace("``", "“")
    text = text.replace("''", "”")
    return text


def educateSingleBackticks(text: str) -> str:
    """Convert single backticks to curly quotes.

    Args:
        text: Input string.

    Returns:
        String with educated single backtick quotes.
    """
    text = text.replace("`", "‘")
    text = text.replace("'", "’")
    return text


def educateQuotes(text: str, language: str = "en") -> str:
    """Convert straight quotes to typographic curly quotes.

    Args:
        text: Input string.
        language: BCP 47 language tag. Defaults to "en".

    Returns:
        String with typographic curly quotes.
    """
    smart = smartchars(language)
    if not re.search(r'[-"\']', text):
        return text

    # Simple regex-based substitution for standard straight quotes
    # Replace double quotes: opening after whitespace/start, closing otherwise
    text = re.sub(r'(^|[\s(\[{<])"', r"\1" + smart.opquote, text)
    text = text.replace('"', smart.cpquote)

    # Replace single quotes: apostrophe or closing quote
    text = re.sub(r"(\w)'(\w)", r"\1" + smart.apostrophe + r"\2", text)
    text = re.sub(r"(^|[\s(\[{<])'", r"\1" + smart.osquote, text)
    text = text.replace("'", smart.csquote)

    return text


def smartyPants(text: str, attr: str = default_smartypants_attr, language: str = "en") -> str:
    """Process text using SmartyPants typographic formatting rules.

    Args:
        text: Input text string.
        attr: Configuration attribute string.
        language: Language identifier code.

    Returns:
        Typographically formatted text string.
    """
    text = educateDashesOldSchool(text)
    text = educateEllipses(text)
    text = educateQuotes(text, language=language)
    return text
