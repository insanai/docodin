"""Docutils directives drop-in implementation for docodin."""

from __future__ import annotations

import codecs
import re
from typing import Any, Callable

from docodin.shim.parsers.rst import Directive, convert_directive_function

_directives: dict[str, Any] = {}
_directive_registry: dict[str, tuple[str, str]] = {}


def register_directive(name: str, directive_obj: Any) -> None:
    """Register a directive with a canonical name.

    Args:
        name: Name of the directive to register.
        directive_obj: Directive class or callable.
    """
    if not (isinstance(directive_obj, type) and issubclass(directive_obj, Directive)):
        directive_obj = convert_directive_function(directive_obj)
    _directives[name.lower()] = directive_obj


def directive(directive_name: str, language_module: Any, document: Any) -> tuple[Any, list[Any]]:
    """Locate and return a directive class by its language-dependent name.

    Args:
        directive_name: Name of directive to look up.
        language_module: Module containing localized directive names.
        document: Document context object for reporting messages.

    Returns:
        Tuple of (directive_class, messages).
    """
    normname = directive_name.lower()
    messages: list[Any] = []
    if normname in _directives:
        return _directives[normname], messages

    canonicalname = None
    if hasattr(language_module, "directives") and normname in language_module.directives:
        canonicalname = language_module.directives[normname]
    else:
        from docodin.shim.parsers.rst.languages import en as en_rst

        if hasattr(en_rst, "directives") and normname in en_rst.directives:
            canonicalname = en_rst.directives[normname]
        else:
            canonicalname = normname

    if canonicalname in _directives:
        return _directives[canonicalname], messages

    return None, messages


# Option conversion / validation helpers


def flag(argument: str | None) -> None:
    """Validate that an option behaves as a boolean flag without arguments.

    Args:
        argument: Option argument string, which must be empty or None.

    Returns:
        None if valid.

    Raises:
        ValueError: If an unexpected argument is provided.
    """
    if argument and argument.strip():
        raise ValueError(f"no argument that takes a parameter: {argument!r}")
    return None


def unchanged(argument: str | None) -> str:
    """Return argument unchanged (or empty string if None).

    Args:
        argument: Input argument string.

    Returns:
        Argument string or empty string.
    """
    return argument or ""


def unchanged_required(argument: str | None) -> str:
    """Return argument unchanged; error if empty."""
    if not argument or not argument.strip():
        raise ValueError("argument required but none supplied")
    return argument


def path(argument: str | None) -> str:
    """Return path stripped of whitespace."""
    if not argument:
        raise ValueError("argument required but none supplied")
    return argument.strip()


def uri(argument: str | None) -> str:
    """Return URI stripped of whitespace."""
    if not argument:
        raise ValueError("argument required but none supplied")
    return argument.strip()


def class_option(argument: str | None) -> list[str]:
    """Convert argument to a list of class names."""
    if not argument:
        return []
    return [c.strip() for c in argument.split()]


def positive_int(argument: str | None) -> int:
    """Convert argument to a positive integer."""
    if argument is None:
        raise ValueError("argument required")
    val = int(argument)
    if val <= 0:
        raise ValueError(f"negative or zero value; must be positive: {argument!r}")
    return val


def nonnegative_int(argument: str | None) -> int:
    """Convert argument to a non-negative integer."""
    if argument is None:
        raise ValueError("argument required")
    val = int(argument)
    if val < 0:
        raise ValueError(f"negative value; must be non-negative: {argument!r}")
    return val


def positive_int_list(argument: str | None) -> list[int]:
    """Convert space- or comma-separated numbers to a list of positive integers."""
    if not argument:
        return []
    res = []
    for item in re.split(r"[\s,]+", argument.strip()):
        if item:
            res.append(positive_int(item))
    return res


def choice(values: Sequence[str]) -> Callable[[str | None], str]:
    """Return a validator that checks against allowed choices."""
    def validator(argument: str | None) -> str:
        if argument is None:
            raise ValueError(f"must be one of {format_values(values)}")
        val = argument.strip()
        if val not in values:
            raise ValueError(f"{val!r} unknown; must be one of {format_values(values)}")
        return val

    return validator


def format_values(values: Sequence[str]) -> str:
    return ", ".join(f'"{v}"' for v in values)


def encoding(argument: str | None) -> str:
    """Check for a valid encoding."""
    if not argument:
        raise ValueError("argument required")
    enc = argument.strip()
    try:
        codecs.lookup(enc)
    except LookupError:
        raise ValueError(f"unknown encoding: {enc!r}")
    return enc


def length_or_unitless(argument: str | None) -> str:
    if not argument:
        return ""
    return argument.strip()


def length_or_percentage_or_unitless(argument: str | None, default: str = "") -> str:
    if not argument:
        return default
    return argument.strip()


def value_error(msg: str) -> ValueError:
    return ValueError(msg)
