"""SmartyPants: typographic quotes, dashes and ellipses for plain ASCII text.

`educate_tokens` converts ("text" | "literal" | "tag", string) tokens; the
quotation marks depend on the language (see `smartchars.quotes`).
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Iterator
from typing import Any

from ._smartquotes_data import quotes as _QUOTES

default_smartypants_attr = "1"


class smartchars:  # noqa: N801 - docutils name
    """Smart quotes and dashes for a language."""

    endash = "–"
    emdash = "—"
    ellipsis = "…"
    apostrophe = "’"
    quotes = _QUOTES

    def __init__(self, language: str = "en") -> None:
        self.language = language
        try:
            (self.opquote, self.cpquote,
             self.osquote, self.csquote) = self.quotes[language.lower()]
        except KeyError:
            self.opquote, self.cpquote, self.osquote, self.csquote = "\"\"''"


class RegularExpressions:
    """Patterns of the quote education rules."""

    _CH_CLASSES = {
        "open": "[([{]",
        "close": r"[^\s]",
        "punct": "[-!\"  #\\$\\%'()*+,.\\/:;<=>?\\@\\[\\\\\\]\\^_`{|}~]",
        "dash": "[-–—]",
        "sep": "[\\s​‌]",
    }
    START_SINGLE = re.compile(r"^'(?=%s\\B)" % _CH_CLASSES["punct"])
    START_DOUBLE = re.compile(r'^"(?=%s\\B)' % _CH_CLASSES["punct"])
    ADJACENT_1 = re.compile("\"'(?=\\w)")
    ADJACENT_2 = re.compile("'\"(?=\\w)")
    OPEN_SINGLE = re.compile(r"(%(open)s|%(dash)s)'(?=%(punct)s? )" % _CH_CLASSES)
    OPEN_DOUBLE = re.compile(r'(%(open)s|%(dash)s)"(?=%(punct)s? )' % _CH_CLASSES)
    DECADE = re.compile(r"'(?=\d{2}s)")
    APOSTROPHE = re.compile(r"(?<=(\w|\d))'(?=\w)")
    OPENING_SECONDARY = re.compile(r"(%(sep)s|%(open)s|%(dash)s)'(?=\w|%(punct)s)"
                                   % _CH_CLASSES)
    CLOSING_SECONDARY = re.compile(r"(?<!\s)'")
    OPENING_PRIMARY = re.compile(r'(%(sep)s|%(open)s|%(dash)s)"(?=\w|%(punct)s)' % _CH_CLASSES)
    CLOSING_PRIMARY = re.compile(r'((?<!\s)"|"(?=\s))')


regexes = RegularExpressions()


def smartyPants(text: str, attr: str = default_smartypants_attr,  # noqa: N802
                language: str = "en") -> str:
    """Main function for "traditional" use."""
    return "".join(educate_tokens(tokenize(text), attr, language))


def _actions(attr: str) -> dict[str, int | bool]:
    """The transformations selected by `attr` (numeric or letter codes)."""
    presets = {"1": 1, "2": 2, "3": 3}
    if attr in presets:
        return {"quotes": True, "backticks": True, "dashes": presets[attr], "ellipses": True,
                "stupefy": False, "quot": False}
    if attr == "-1":
        return {"quotes": False, "backticks": False, "dashes": 0, "ellipses": False,
                "stupefy": True, "quot": False}
    dashes = 3 if "i" in attr else 2 if "D" in attr else 1 if "d" in attr else 0
    backticks = 2 if "B" in attr else "b" in attr
    return {"quotes": "q" in attr, "backticks": backticks, "dashes": dashes,
            "ellipses": "e" in attr, "stupefy": False, "quot": "w" in attr}


def _educate(text: str, actions: dict[str, int | bool], language: str, context: str) -> str:
    text = processEscapes(text)
    if actions["quot"]:
        text = text.replace("&quot;", '"')
    dash_rules = {1: educateDashes, 2: educateDashesOldSchool, 3: educateDashesOldSchoolInverted}
    if actions["dashes"]:
        text = dash_rules[actions["dashes"]](text)
    if actions["ellipses"]:
        text = educateEllipses(text)
    if actions["backticks"]:
        text = educateBackticks(text, language)
    if actions["backticks"] == 2:
        text = educateSingleBackticks(text, language)
    if actions["quotes"]:
        text = educateQuotes(context.replace('"', ";").replace("'", ";") + text, language)[1:]
    if actions["stupefy"]:
        text = stupefyEntities(text, language)
    return processEscapes(text, restore=True)


def educate_tokens(text_tokens: Iterable[tuple[str, str]], attr: str = default_smartypants_attr,
                   language: str = "en") -> Iterator[str]:
    """Return iterator that "educates" the items of `text_tokens`.

    Runs natively (all tokens at once) when the docodin library is available
    and the arguments are supported; the Python implementation is the reference.
    """
    lib = _native_library()
    if lib is not None and type(attr) is str and type(language) is str and language.isascii():
        quotes = _native_quotes(language)
        if quotes is not False:
            tokens = list(text_tokens)
            try:
                return iter(_native_educate(lib, tokens, attr, language, quotes))
            except (TypeError, ValueError, UnicodeEncodeError):
                text_tokens = tokens
    return _educate_tokens(text_tokens, attr, language)


def _native_educate(lib: Any, tokens: list[tuple[str, str]], attr: str, language: str,
                    quotes: tuple[str, ...] | None) -> list[str] | tuple[str, ...]:
    if not tokens:
        return []
    kinds, texts = zip(*tokens, strict=True)
    if attr != "-1" and _ACTIVE.search("".join(texts)) is None:
        return texts
    return lib.educate(kinds, texts, attr, language, quotes)


# The native library: None until loaded, False if unavailable.
_native_lib: Any = None
_DEFAULT_QUOTES = dict(_QUOTES)
_DEFAULT_CHARS = ("–", "—", "…", "’")
# text without these is left unchanged by all rules but "stupefy"
_ACTIVE = re.compile(r"[\"'`\\&]|--|\.\.\.|\. \. \.")


def _native_library() -> Any:
    global _native_lib
    if _native_lib is None:
        try:
            from docodin._native import native

            lib = native()
        except Exception:  # noqa: BLE001 - no library: the Python implementation
            lib = None
        _native_lib = lib if lib is not None and lib.has_educate else False
    if (smartchars.endash, smartchars.emdash, smartchars.ellipsis,
            smartchars.apostrophe) != _DEFAULT_CHARS:
        return None
    return _native_lib or None


def _native_quotes(language: str) -> tuple[str, ...] | None | bool:
    """Quotes for the native educator: None for its (generated) table, or the
    customized `smartchars.quotes` entry, or False if it cannot take them."""
    key = language.lower()
    marks = smartchars.quotes.get(key)
    if marks is _DEFAULT_QUOTES.get(key):
        return None
    if marks is None:
        return ('"', '"', "'", "'")
    try:
        marks = tuple(marks)
    except TypeError:
        return False
    # the marks go into ``re.sub`` templates: no escapes, no group numbers
    if len(marks) != 4 or not all(type(mark) is str and "\\" not in mark
                                  and not mark[:1].isdigit() for mark in marks):
        return False
    return marks


def _educate_tokens(text_tokens: Iterable[tuple[str, str]], attr: str,
                    language: str) -> Iterator[str]:
    """The Python implementation of `educate_tokens`."""
    actions = _actions(attr)
    prev_token_last_char = " "
    for ttype, text in text_tokens:
        if ttype == "tag" or not text:
            yield text
            continue
        if ttype == "literal":
            prev_token_last_char = text[-1:]
            yield text
            continue
        last_char = text[-1:]
        yield _educate(text, actions, language, prev_token_last_char)
        prev_token_last_char = last_char


def educateQuotes(text: str, language: str = "en") -> str:  # noqa: N802
    """Convert straight quotes to typographic quotes."""
    smart = smartchars(language)
    if not re.search("[-\"']", text):
        return text
    text = regexes.START_SINGLE.sub(smart.csquote, text)
    text = regexes.START_DOUBLE.sub(smart.cpquote, text)
    text = regexes.ADJACENT_1.sub(smart.opquote + smart.osquote, text)
    text = regexes.ADJACENT_2.sub(smart.osquote + smart.opquote, text)
    text = regexes.OPEN_SINGLE.sub(r"\1%s" % smart.csquote, text)
    text = regexes.OPEN_DOUBLE.sub(r"\1%s" % smart.cpquote, text)
    if language.startswith("en"):
        text = regexes.DECADE.sub(smart.apostrophe, text)
    text = regexes.OPENING_SECONDARY.sub(r"\1" + smart.osquote, text)
    if smart.csquote != smart.apostrophe:
        text = regexes.APOSTROPHE.sub(smart.apostrophe, text)
    text = regexes.CLOSING_SECONDARY.sub(smart.csquote, text)
    text = text.replace("'", smart.osquote)
    text = regexes.OPENING_PRIMARY.sub(r"\1" + smart.opquote, text)
    text = regexes.CLOSING_PRIMARY.sub(smart.cpquote, text)
    return text.replace('"', smart.opquote)


def educateBackticks(text: str, language: str = "en") -> str:  # noqa: N802
    smart = smartchars(language)
    return text.replace("``", smart.opquote).replace("''", smart.cpquote)


def educateSingleBackticks(text: str, language: str = "en") -> str:  # noqa: N802
    smart = smartchars(language)
    return text.replace("`", smart.osquote).replace("'", smart.csquote)


def educateDashes(text: str) -> str:  # noqa: N802
    return text.replace("---", smartchars.endash).replace("--", smartchars.emdash)


def educateDashesOldSchool(text: str) -> str:  # noqa: N802
    return text.replace("---", smartchars.emdash).replace("--", smartchars.endash)


def educateDashesOldSchoolInverted(text: str) -> str:  # noqa: N802
    return text.replace("---", smartchars.endash).replace("--", smartchars.emdash)


def educateEllipses(text: str) -> str:  # noqa: N802
    return text.replace("...", smartchars.ellipsis).replace(". . .", smartchars.ellipsis)


def stupefyEntities(text: str, language: str = "en") -> str:  # noqa: N802
    """Turn typographic characters back into ASCII."""
    smart = smartchars(language)
    for char, ascii_text in ((smart.endash, "-"), (smart.emdash, "--"),
                             (smart.osquote, "'"), (smart.csquote, "'"),
                             (smart.opquote, '"'), (smart.cpquote, '"'),
                             (smart.ellipsis, "...")):
        text = text.replace(char, ascii_text)
    return text


_ESCAPES = (("\\\\", "&#92;"), ('\\"', "&#34;"), ("\\'", "&#39;"), ("\\.", "&#46;"),
            ("\\-", "&#45;"), ("\\`", "&#96;"))


def processEscapes(text: str, restore: bool = False) -> str:  # noqa: N802
    """Protect backslash-escaped characters (or restore them)."""
    for char, replacement in _ESCAPES:
        text = text.replace(replacement, char[1]) if restore else text.replace(char,
                                                                               replacement)
    return text


def tokenize(text: str) -> Iterator[tuple[str, str]]:
    """Split `text` into ("text", ...) and ("tag", ...) tokens."""
    tag_soup = re.compile(r"([^<]*)(<[^>]*>)")
    token_match = tag_soup.search(text)
    previous_end = 0
    while token_match is not None:
        if token_match.group(1):
            yield "text", token_match.group(1)
        yield "tag", token_match.group(2)
        previous_end = token_match.end()
        token_match = tag_soup.search(text, token_match.end())
    if previous_end < len(text):
        yield "text", text[previous_end:]
