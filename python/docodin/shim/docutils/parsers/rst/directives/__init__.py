"""The directive registry and directive option conversion functions."""

from __future__ import annotations

import codecs
import re
from collections.abc import Callable, Sequence
from importlib import import_module
from typing import Any

from docutils import nodes, parsers
from docutils.parsers.rst.languages import en as _fallback_language_module
from docutils.utils import escape2null, split_escaped_whitespace

__docformat__ = "reStructuredText"

_directive_registry = {
    "attention": ("admonitions", "Attention"),
    "caution": ("admonitions", "Caution"),
    "code": ("body", "CodeBlock"),
    "danger": ("admonitions", "Danger"),
    "error": ("admonitions", "Error"),
    "important": ("admonitions", "Important"),
    "note": ("admonitions", "Note"),
    "tip": ("admonitions", "Tip"),
    "hint": ("admonitions", "Hint"),
    "warning": ("admonitions", "Warning"),
    "admonition": ("admonitions", "Admonition"),
    "sidebar": ("body", "Sidebar"),
    "topic": ("body", "Topic"),
    "line-block": ("body", "LineBlock"),
    "parsed-literal": ("body", "ParsedLiteral"),
    "math": ("body", "MathBlock"),
    "rubric": ("body", "Rubric"),
    "epigraph": ("body", "Epigraph"),
    "highlights": ("body", "Highlights"),
    "pull-quote": ("body", "PullQuote"),
    "compound": ("body", "Compound"),
    "container": ("body", "Container"),
    "table": ("tables", "RSTTable"),
    "csv-table": ("tables", "CSVTable"),
    "list-table": ("tables", "ListTable"),
    "image": ("images", "Image"),
    "figure": ("images", "Figure"),
    "contents": ("parts", "Contents"),
    "sectnum": ("parts", "Sectnum"),
    "header": ("parts", "Header"),
    "footer": ("parts", "Footer"),
    "target-notes": ("references", "TargetNotes"),
    "meta": ("misc", "Meta"),
    "raw": ("misc", "Raw"),
    "include": ("misc", "Include"),
    "replace": ("misc", "Replace"),
    "unicode": ("misc", "Unicode"),
    "class": ("misc", "Class"),
    "role": ("misc", "Role"),
    "default-role": ("misc", "DefaultRole"),
    "title": ("misc", "Title"),
    "date": ("misc", "Date"),
    "restructuredtext-test-directive": ("misc", "TestDirective"),
}
"""Mapping of directive name to (module name, class name)."""

_directives: dict[str, Any] = {}
"""Cache of imported directives (and registered custom directives)."""


def directive(directive_name: str, language_module: Any,
              document: nodes.document) -> tuple[Any, list[nodes.system_message]]:
    """Locate and return a directive class (and messages) from its name.

    Return ``(None, messages)`` if the directive is not registered.
    """
    normname = directive_name.lower()
    messages: list[nodes.system_message] = []
    if normname in _directives:
        return _directives[normname], messages
    canonicalname, msg_text = _canonical_name(directive_name, normname, language_module)
    if msg_text:
        messages.append(document.reporter.info("\n".join(msg_text), line=document.current_line))
    try:
        modulename, classname = _directive_registry[canonicalname]
    except KeyError:
        return None, messages
    try:
        module = import_module("docutils.parsers.rst.directives." + modulename)
    except ImportError as detail:
        messages.append(document.reporter.error(
            'Error importing directive module "%s" (directive "%s"):\n%s'
            % (modulename, directive_name, detail), line=document.current_line))
        return None, messages
    try:
        directive_class = getattr(module, classname)
    except AttributeError:
        messages.append(document.reporter.error(
            'No directive class "%s" in module "%s" (directive "%s").'
            % (classname, modulename, directive_name), line=document.current_line))
        return None, messages
    _directives[normname] = directive_class
    return directive_class, messages


def _canonical_name(directive_name: str, normname: str,
                    language_module: Any) -> tuple[str, list[str]]:
    msg_text: list[str] = []
    canonicalname = None
    try:
        canonicalname = language_module.directives[normname]
    except AttributeError as error:
        msg_text.append("Problem retrieving directive entry from language module %r: %s."
                        % (language_module, error))
    except KeyError:
        msg_text.append('No directive entry for "%s" in module "%s".'
                        % (directive_name, language_module.__name__))
    if not canonicalname:
        try:
            canonicalname = _fallback_language_module.directives[normname]
            msg_text.append('Using English fallback for directive "%s".' % directive_name)
        except KeyError:
            msg_text.append('Trying "%s" as canonical directive name.' % directive_name)
            canonicalname = normname
    return canonicalname, msg_text


def register_directive(name: str, directive: Any) -> None:
    """Register a nonstandard application-defined directive function."""
    _directives[name] = directive


# --- option conversion functions ---------------------------------------------------------


def flag(argument: str | None) -> None:
    """Check for a valid flag option (no argument)."""
    if argument and argument.strip():
        raise ValueError('no argument is allowed; "%s" supplied' % argument)
    return None


def unchanged_required(argument: str | None) -> str:
    """Return the argument text, unchanged (an argument is required)."""
    if argument is None:
        raise ValueError("argument required but none supplied")
    return argument


def unchanged(argument: str | None) -> str:
    """Return the argument text, unchanged ("" if none)."""
    return "" if argument is None else argument


def path(argument: str | None) -> str:
    """Return the path argument unwrapped (with newlines removed)."""
    if argument is None:
        raise ValueError("argument required but none supplied")
    return "".join(s.strip() for s in argument.splitlines())


def uri(argument: str | None) -> str:
    """Return the URI argument with unescaped whitespace removed."""
    if argument is None:
        raise ValueError("argument required but none supplied")
    parts = split_escaped_whitespace(escape2null(argument))
    return " ".join("".join(nodes.unescape(part).split()) for part in parts)


def nonnegative_int(argument: str) -> int:
    """Check for a nonnegative integer argument."""
    value = int(argument)
    if value < 0:
        raise ValueError("negative value; must be positive or zero")
    return value


def percentage(argument: str) -> int:
    """Check for an integer percentage value with optional percent sign."""
    try:
        argument = argument.rstrip(" %")
    except AttributeError:
        pass
    return nonnegative_int(argument)


CSS3_LENGTH_UNITS = ("em", "ex", "ch", "rem", "vw", "vh", "vmin", "vmax", "cm", "mm", "Q",
                     "in", "pt", "pc", "px")
length_units = [*CSS3_LENGTH_UNITS]


def get_measure(argument: str, units: Sequence[str]) -> str:
    """Check for a positive argument of one of the `units`."""
    value, unit = nodes.parse_measure(argument)
    if value < 0 or unit not in units:
        raise ValueError("not a positive number or measure of one of the following units:\n"
                         + ", ".join(u for u in units if u))
    return f"{value}{unit}"


def length_or_unitless(argument: str) -> str:
    return get_measure(argument, (*CSS3_LENGTH_UNITS, ""))


def length_or_percentage_or_unitless(argument: str, default: str = "") -> str:
    """A length, a percentage, or a unitless number (plus `default` unit)."""
    try:
        return get_measure(argument, (*CSS3_LENGTH_UNITS, "%"))
    except ValueError as error:
        try:
            return get_measure(argument, [""]) + default
        except ValueError:
            raise error from None


def class_option(argument: str | None) -> list[str]:
    """Convert the argument into a list of ID-compatible strings."""
    if argument is None:
        raise ValueError("argument required but none supplied")
    class_names = []
    for name in argument.split():
        class_name = nodes.make_id(name)
        if not class_name:
            raise ValueError('cannot make "%s" into a class name' % name)
        class_names.append(class_name)
    return class_names


unicode_pattern = re.compile(r"(?:0x|x|\\x|U\+?|\\u)([0-9a-f]+)$|&#x([0-9a-f]+);$",
                             re.IGNORECASE)


def unicode_code(code: str) -> str:
    """Convert a Unicode character code to a Unicode character (or pass text through)."""
    try:
        if code.isdigit():  # decimal number
            return chr(int(code))
        match = unicode_pattern.match(code)
        if match:  # hex number
            return chr(int(match.group(1) or match.group(2), 16))
        return code  # other text
    except OverflowError as detail:
        raise ValueError("code too large (%s)" % detail) from None


def single_char_or_unicode(argument: str) -> str:
    """A single character or Unicode character code."""
    char = unicode_code(argument)
    if len(char) > 1:
        raise ValueError("%r invalid; must be a single character or a Unicode code" % char)
    return char


def single_char_or_whitespace_or_unicode(argument: str) -> str:
    """As with `single_char_or_unicode`, but "tab" and "space" are also supported."""
    if argument == "tab":
        return "\t"
    if argument == "space":
        return " "
    return single_char_or_unicode(argument)


def positive_int(argument: str) -> int:
    """Converts the argument into an integer.  Raises ValueError for 0 or negatives."""
    value = int(argument)
    if value < 1:
        raise ValueError("negative or zero value; must be positive")
    return value


def positive_int_list(argument: str) -> list[int]:
    """Converts a space- or comma-separated list of values into a list of integers."""
    entries = argument.split(",") if "," in argument else argument.split()
    return [positive_int(entry) for entry in entries]


def encoding(argument: str) -> str:
    """Verifies the encoding argument by lookup."""
    try:
        codecs.lookup(argument)
    except LookupError:
        raise ValueError('unknown encoding: "%s"' % argument) from None
    return argument


def choice(argument: str | None, values: Sequence[str]) -> str:
    """Directive option utility function: one of `values` (case-insensitive)."""
    try:
        value = argument.lower().strip()
    except AttributeError:
        raise ValueError("must supply an argument; choose from %s"
                         % format_values(values)) from None
    if value in values:
        return value
    raise ValueError('"%s" unknown; choose from %s' % (argument, format_values(values)))


def format_values(values: Sequence[str]) -> str:
    return '%s, or "%s"' % (", ".join('"%s"' % s for s in values[:-1]), values[-1])


def value_or(values: Sequence[str], other: type) -> Callable[[str], Any]:
    """Return a function that accepts `values` or converts with `other`."""
    def auto_or_other(argument: str) -> Any:
        return argument if argument in values else other(argument)
    return auto_or_other


def parser_name(argument: str | None) -> type[parsers.Parser] | None:
    """Return a docutils parser class whose name matches the argument."""
    if not argument:
        return None
    try:
        return parsers.get_parser_class(argument)
    except ImportError as err:
        raise ValueError(str(err)) from None
