"""Docutils frontend drop-in implementation for docodin."""

from __future__ import annotations

import copy
from typing import Any, Sequence


class Values:
    """Runtime configuration settings holder for docutils components."""

    def __init__(self, defaults: dict[str, Any] | None = None) -> None:
        self.__dict__["_data"] = {}
        if defaults:
            self.__dict__["_data"].update(defaults)

    def __getattr__(self, name: str) -> Any:
        data = self.__dict__.get("_data", {})
        if name in data:
            return data[name]
        return None

    def __setattr__(self, name: str, value: Any) -> None:
        if name == "_data":
            self.__dict__["_data"] = value
        else:
            self.__dict__.setdefault("_data", {})[name] = value

    def __getitem__(self, key: str) -> Any:
        return self.__dict__["_data"][key]

    def __setitem__(self, key: str, value: Any) -> None:
        self.__dict__["_data"][key] = value

    def __contains__(self, key: str) -> bool:
        return key in self.__dict__.get("_data", {})

    def get(self, key: str, default: Any = None) -> Any:
        return self.__dict__.get("_data", {}).get(key, default)

    def setdefault(self, key: str, default: Any = None) -> Any:
        return self.__dict__.setdefault("_data", {}).setdefault(key, default)

    def update(self, other: Any) -> None:
        if isinstance(other, Values):
            self.__dict__["_data"].update(other.__dict__["_data"])
        elif isinstance(other, dict):
            self.__dict__["_data"].update(other)

    def copy(self) -> Values:
        v = Values()
        v.__dict__["_data"] = copy.deepcopy(self.__dict__["_data"])
        return v

    def __repr__(self) -> str:
        return f"Values({self.__dict__.get('_data', {})!r})"


_DEFAULT_SETTINGS: dict[str, Any] = {
    "tab_width": 8,
    "syntax_highlight": "long",
    "input_encoding": "utf-8",
    "output_encoding": "utf-8",
    "error_encoding": "utf-8",
    "error_encoding_error_handler": "replace",
    "language_code": "en",
    "id_prefix": "",
    "auto_id_prefix": "%",
    "report_level": 2,
    "halt_level": 4,
    "debug": False,
    "warning_stream": None,
    "file_insertion_enabled": True,
    "raw_enabled": True,
    "line_length_limit": 10000,
    "character_level_inline_markup": False,
    "smart_quotes": False,
    "pep_references": False,
    "pep_base_url": "https://peps.python.org/",
    "pep_file_url_template": "pep-%04d",
    "rfc_references": False,
    "rfc_base_url": "https://tools.ietf.org/html/",
    "trim_footnote_reference_space": False,
    "footnote_backlinks": True,
    "footnote_references": "brackets",
    "toc_backlinks": "entry",
    "generator": True,
    "datestamp": None,
    "source_link": None,
    "source_url": None,
    "strip_comments": True,
    "strip_elements_with_classes": None,
    "strip_classes": None,
    "dump_settings": False,
    "dump_transforms": False,
    "dump_pseudo_xml": False,
    "expose_internals": None,
    "strict_visitor": False,
}


def get_default_settings(*components: Any) -> Values:
    """Return default runtime configuration settings for the given components.

    Args:
        *components: Docutils component classes or instances with optional
            default_settings or settings_spec attributes.

    Returns:
        Configuration holder pre-populated with default settings.
    """
    settings = Values(_DEFAULT_SETTINGS)
    for comp in components:
        comp_settings = getattr(comp, "default_settings", None)
        if isinstance(comp_settings, dict):
            settings.update(comp_settings)
        settings_spec = getattr(comp, "settings_spec", None)
        if settings_spec and len(settings_spec) >= 3 and isinstance(settings_spec[2], dict):
            settings.update(settings_spec[2])
    return settings


class OptionParser:
    """Option parser for docutils command line and settings."""

    def __init__(self, components: Sequence[Any] = (), usage: str | None = None, description: str | None = None) -> None:
        self.components = components
        self.usage = usage
        self.description = description

    def get_default_values(self) -> Values:
        return get_default_settings(*self.components)

    def parse_args(self, args: list[str] | None = None, values: Values | None = None) -> tuple[Values, list[str]]:
        vals = values or self.get_default_values()
        return (vals, args or [])


class ConfigParser:
    def __init__(self) -> None:
        pass


def validate_boolean(setting: str, value: Any, *args: Any, **kwargs: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.lower() in ("true", "yes", "1", "on")
    return bool(value)


def validate_nonnegative_int(setting: str, value: Any, *args: Any, **kwargs: Any) -> int:
    val = int(value)
    if val < 0:
        raise ValueError(f"{setting} must be non-negative")
    return val


def validate_threshold(setting: str, value: Any, *args: Any, **kwargs: Any) -> int:
    return int(value)


def validate_colon_separated_string_list(setting: str, value: Any, *args: Any, **kwargs: Any) -> list[str]:
    if isinstance(value, list):
        return value
    return str(value).split(":")


def validate_comma_separated_list(setting: str, value: Any, *args: Any, **kwargs: Any) -> list[str]:
    if isinstance(value, list):
        return value
    return [v.strip() for v in str(value).split(",")]


def validate_url_trailing_slash(setting: str, value: Any, *args: Any, **kwargs: Any) -> str:
    s = str(value)
    return s if s.endswith("/") else s + "/"


def validate_dependency_file(setting: str, value: Any, *args: Any, **kwargs: Any) -> str:
    return str(value)
