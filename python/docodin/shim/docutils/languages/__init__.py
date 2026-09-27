"""Language-dependent features of Docutils (labels, bibliographic field names)."""

from __future__ import annotations

from importlib import import_module
from types import ModuleType
from typing import Any

from docutils.utils import normalize_language_tag

__docformat__ = "reStructuredText"


class LanguageImporter:
    """Import language modules, falling back to English (cached per code)."""

    packages: tuple[str, ...] = ("docutils.languages.", "")
    warn_msg = 'Language "%s" not supported: Docutils-generated text will be in English.'
    fallback: str | None = "en"

    def __init__(self) -> None:
        self.cache: dict[str, ModuleType | None] = {}

    def import_from_packages(self, name: str, reporter: Any = None) -> ModuleType | None:
        """Try loading module `name` from `self.packages`."""
        module = None
        for package in self.packages:
            try:
                module = import_module(package + name)
                self.check_content(module)
            except (ImportError, AttributeError):
                if reporter and module:
                    reporter.info(f"{module} is no complete Docutils language module.")
                elif reporter:
                    reporter.info(f'Module "{package + name}" not found.')
                continue
            break
        return module

    def check_content(self, module: ModuleType) -> None:
        """Raise ImportError if `module` is not a Docutils language module."""
        if not (isinstance(module.labels, dict)
                and isinstance(module.bibliographic_fields, dict)
                and isinstance(module.author_separators, list)):
            raise ImportError

    def __call__(self, language_code: str, reporter: Any = None) -> Any:
        try:
            return self.cache[language_code]
        except KeyError:
            pass
        for tag in normalize_language_tag(language_code):
            module = self.import_from_packages(tag.replace("-", "_"), reporter)
            if module is not None:
                break
        else:
            if reporter:
                reporter.warning(self.warn_msg % language_code)
            if self.fallback:
                module = self.import_from_packages(self.fallback)
        if reporter and language_code != "en":
            reporter.info(f'Using {module} for language "{language_code}".')
        self.cache[language_code] = module
        return module

    def __class_getitem__(cls, name: Any) -> type:
        return cls


get_language = LanguageImporter()
