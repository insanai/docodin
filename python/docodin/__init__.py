"""docodin: a fast reStructuredText processor with a native (Odin) parser.

Ways to use it:

* docutils API with the docodin parser::

      import docodin
      html = docodin.publish_string(source, writer="html5")
      doctree = docodin.publish_doctree(source)

* everything built on docutils, process-wide::

      docodin.patch_docutils()

* Sphinx: add ``"docodin.sphinx"`` to ``extensions`` in ``conf.py``.

* without docutils installed, ``import docutils`` is served by docodin's own
  implementation (:mod:`docodin.shim`), whose parser is the native engine.

Importing this package does not import docutils: the shim can still be
installed first (:func:`docodin.shim.install_shim`).
"""

from __future__ import annotations

from typing import Any

from docodin.shim import enable as _enable_shim
from docodin.shim import install_shim, uninstall_shim

__version__ = "0.1.0"

_enable_shim()

_LAZY = {
    "Parser": ("docodin.parser", "Parser"),
    "OdinRSTParser": ("docodin.parser", "Parser"),  # docodin 0.1 name
    "patch_docutils": ("docodin.parser", "patch_docutils"),
    "unpatch_docutils": ("docodin.parser", "unpatch_docutils"),
    "is_patched": ("docodin.parser", "is_patched"),
    "native": ("docodin._native", "native"),
}


def __getattr__(name: str) -> Any:
    try:
        module_name, attr = _LAZY[name]
    except KeyError:
        raise AttributeError(f"module 'docodin' has no attribute {name!r}") from None
    import importlib

    return getattr(importlib.import_module(module_name), attr)


def _publish_kwargs(kwargs: dict[str, Any]) -> dict[str, Any]:
    from docodin.parser import Parser

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

    from docodin.parser import Parser

    if settings is None:
        settings = docutils.frontend.get_default_settings(Parser)
        for key, value in settings_overrides.items():
            setattr(settings, key, value)
    document = docutils.utils.new_document(source, settings)
    Parser().parse(text, document)
    return document


def version() -> str:
    """Version string of the loaded native library."""
    from docodin._native import native

    return native().version


def publish_native(source: str | bytes, source_path: str | None = None, writer: str = "html5",
                   settings_overrides: dict[str, Any] | None = None, *, parts: bool = False,
                   docutils_dir: str | None = None) -> Any:
    """``docutils.core.publish_string`` (``publish_parts`` with ``parts``) without Python:
    the native reader, transforms and writers (pseudoxml, xml, html5, latex, xetex), with
    docutils' output, messages and exceptions.  See :mod:`docodin._publish`."""
    from docodin._publish import publish_native as _publish_native

    return _publish_native(source, source_path, writer, settings_overrides, parts=parts,
                           docutils_dir=docutils_dir)


def render_html(source: str, *, standalone: bool = True, **settings_overrides: Any) -> str:
    """HTML5 of reStructuredText, natively: the whole document, or the body of
    ``publish_parts`` (``standalone=False``)."""
    result = publish_native(source, writer="html5", settings_overrides=settings_overrides,
                            parts=True)
    return result["whole"] if standalone else result["body"]


def render_latex(source: str, *, standalone: bool = True, **settings_overrides: Any) -> str:
    """LaTeX of reStructuredText, natively: the whole document, or the body of
    ``publish_parts`` (``standalone=False``)."""
    result = publish_native(source, writer="latex", settings_overrides=settings_overrides,
                            parts=True)
    return result["whole"] if standalone else result["body"]


__all__ = [
    "OdinRSTParser",
    "Parser",
    "__version__",
    "install_shim",
    "is_patched",
    "parse",
    "patch_docutils",
    "publish_doctree",
    "publish_file",
    "publish_native",
    "publish_parts",
    "publish_string",
    "render_html",
    "render_latex",
    "uninstall_shim",
    "unpatch_docutils",
    "version",
]
