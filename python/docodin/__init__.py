"""docodin: a fast reStructuredText parser for docutils and Sphinx, written in Odin.

Ways to use it:

* docutils API with the docodin parser::

      import docodin
      html = docodin.publish_string(source, writer="html5")
      doctree = docodin.publish_doctree(source)

* everything built on docutils, process-wide::

      docodin.patch_docutils()

* Sphinx: add ``"docodin.sphinx"`` to ``extensions`` in ``conf.py``.

* docutils front ends: ``rst2html --parser=docodin input.rst``.
"""

from __future__ import annotations

from typing import Any

from docodin._native import native
from docodin.parser import Parser, is_patched, patch_docutils, unpatch_docutils

__version__ = "0.2.0"

# Backwards-compatible alias (docodin 0.1).
OdinRSTParser = Parser


def _publish_kwargs(kwargs: dict[str, Any]) -> dict[str, Any]:
    kwargs.setdefault("parser", Parser())
    kwargs.pop("parser_name", None)
    if "writer_name" in kwargs and "writer" not in kwargs:
        kwargs["writer"] = kwargs.pop("writer_name")
    return kwargs


def publish_doctree(source: str | bytes, source_path: str | None = None, **kwargs: Any) -> Any:
    """Like :func:`docutils.core.publish_doctree`, parsing with docodin."""
    import docutils.core

    return docutils.core.publish_doctree(source, source_path=source_path, **_publish_kwargs(kwargs))


def publish_string(source: str | bytes, source_path: str | None = None, **kwargs: Any) -> Any:
    """Like :func:`docutils.core.publish_string`, parsing with docodin."""
    import docutils.core

    return docutils.core.publish_string(source, source_path=source_path, **_publish_kwargs(kwargs))


def publish_parts(source: str | bytes, source_path: str | None = None, **kwargs: Any) -> dict[str, Any]:
    """Like :func:`docutils.core.publish_parts`, parsing with docodin."""
    import docutils.core

    return docutils.core.publish_parts(source, source_path=source_path, **_publish_kwargs(kwargs))


def publish_file(**kwargs: Any) -> Any:
    """Like :func:`docutils.core.publish_file`, parsing with docodin."""
    import docutils.core

    return docutils.core.publish_file(**_publish_kwargs(kwargs))


def parse(text: str, source: str = "<string>", settings: Any = None, **settings_overrides: Any) -> Any:
    """Parse reST into a new docutils document *without* applying transforms."""
    import docutils.frontend
    import docutils.utils

    if settings is None:
        settings = docutils.frontend.get_default_settings(Parser)
        for key, value in settings_overrides.items():
            setattr(settings, key, value)
    document = docutils.utils.new_document(source, settings)
    Parser().parse(text, document)
    return document


def version() -> str:
    """Version string of the loaded native library."""
    return native().version


__all__ = [
    "OdinRSTParser",
    "Parser",
    "__version__",
    "is_patched",
    "parse",
    "patch_docutils",
    "publish_doctree",
    "publish_file",
    "publish_parts",
    "publish_string",
    "unpatch_docutils",
    "version",
]
