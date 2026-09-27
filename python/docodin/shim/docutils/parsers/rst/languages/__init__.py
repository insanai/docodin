"""Localized directive and role names for the reStructuredText parser."""

from __future__ import annotations

from types import ModuleType

from docutils.languages import LanguageImporter

__docformat__ = "reStructuredText"


class RstLanguageImporter(LanguageImporter):
    """Import language modules with localized directive and role names."""

    packages = ("docutils.parsers.rst.languages.", "")
    warn_msg = 'rST localisation for language "%s" not found.'
    fallback = None

    def check_content(self, module: ModuleType) -> None:
        """Raise ImportError if `module` has no directive and role mappings."""
        if not (isinstance(module.directives, dict) and isinstance(module.roles, dict)):
            raise ImportError


get_language = RstLanguageImporter()
