"""Docutils implemented by docodin (drop-in for docutils 0.22).

The reStructuredText parser is docodin's native engine; the rest of the
docutils API (nodes, transforms, writers, front end) is implemented here.
"""

from __future__ import annotations

import warnings
from collections import namedtuple
from typing import Any, ClassVar

__docformat__ = "reStructuredText"
__version__ = "0.22.4"
__version_details__ = ""
__docodin_shim__ = True

_RELEASE_LEVELS = ("alpha", "beta", "candidate", "final")


class VersionInfo(namedtuple("VersionInfo", "major minor micro releaselevel serial release")):
    """Comparable version information tuple."""

    __slots__ = ()

    def __new__(cls, major: int = 0, minor: int = 0, micro: int = 0,
                releaselevel: str = "final", serial: int = 0,
                release: bool = True) -> VersionInfo:
        if releaselevel not in _RELEASE_LEVELS:
            raise ValueError("releaselevel must be one of %r." % (_RELEASE_LEVELS,))
        if releaselevel == "final":
            if not release:
                raise ValueError('releaselevel "final" must not be used with development '
                                 "versions (leads to wrong version ordering of the related "
                                 "__version__")
            if serial != 0:
                raise ValueError('"serial" must be 0 for final releases')
        return super().__new__(cls, major, minor, micro, releaselevel, serial, release)

    def _coerce(self, other: object) -> object:
        return VersionInfo(*other) if isinstance(other, tuple) else other

    def __lt__(self, other: object) -> bool:
        return tuple.__lt__(self, self._coerce(other))

    def __gt__(self, other: object) -> bool:
        return tuple.__gt__(self, self._coerce(other))

    def __le__(self, other: object) -> bool:
        return tuple.__le__(self, self._coerce(other))

    def __ge__(self, other: object) -> bool:
        return tuple.__ge__(self, self._coerce(other))


__version_info__ = VersionInfo(major=0, minor=22, micro=4, releaselevel="final", serial=0,
                               release=True)


class ApplicationError(Exception):
    pass


class DataError(ApplicationError):
    pass


class SettingsSpec:
    """Runtime setting specification base class (see `docutils.frontend`)."""

    settings_spec: ClassVar[tuple] = ()
    settings_defaults: ClassVar[dict[str, Any] | None] = None
    settings_default_overrides: ClassVar[dict[str, Any] | None] = None
    relative_path_settings: ClassVar[tuple[str, ...]] = ()
    config_section: ClassVar[str | None] = None
    config_section_dependencies: ClassVar[tuple[str, ...] | None] = None


class TransformSpec:
    """Runtime transform specification base class."""

    default_transforms: ClassVar[tuple] = ()
    unknown_reference_resolvers: ClassVar[tuple] = ()

    def get_transforms(self) -> list[type]:
        """Transforms required by this class (override in subclasses)."""
        if self.default_transforms != ():
            warnings.warn('TransformSpec: the "default_transforms" attribute will be removed '
                          "in Docutils 2.0.\nUse get_transforms() method instead.",
                          DeprecationWarning, stacklevel=2)
            return list(self.default_transforms)
        return []


class Component(SettingsSpec, TransformSpec):
    """Base class for Docutils components."""

    component_type: ClassVar[str | None] = None
    supported: ClassVar[tuple[str, ...]] = ()

    def supports(self, format: str) -> bool:
        """Is `format` supported by this component?"""
        return format in self.supported
