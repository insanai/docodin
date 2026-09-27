"""Docutils rst languages drop-in implementation for docodin."""

from __future__ import annotations

import importlib
from typing import Any

from docodin.shim.parsers.rst.languages import en

_languages: dict[str, Any] = {"en": en}


def get_language(language_code: str, reporter: Any = None) -> Any:
    code = language_code.lower()
    if code in _languages:
        return _languages[code]
    try:
        mod = importlib.import_module(f"docutils.parsers.rst.languages.{code}")
        _languages[code] = mod
        return mod
    except ImportError:
        return en
