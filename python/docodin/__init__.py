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

import sys
from typing import Any

try:
    import docutils
except ImportError:
    from docodin.shim import install_shim
    install_shim()

from docodin._native import native
from docodin.parser import Parser, is_patched, patch_docutils, unpatch_docutils
from docodin.shim import install_shim, uninstall_shim

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
    """Publish a document tree from source text using the DocOdin parser.

    Args:
        source: Input reStructuredText string or bytes.
        source_path: Path to the source file, if applicable.
        **kwargs: Additional keyword arguments forwarded to docutils.

    Returns:
        The generated document tree.
    """
    import docutils.core

    return docutils.core.publish_doctree(source, source_path=source_path, **_publish_kwargs(kwargs))


def publish_string(source: str | bytes, source_path: str | None = None, **kwargs: Any) -> Any:
    """Publish formatted output from source text using the DocOdin parser.

    Args:
        source: Input reStructuredText string or bytes.
        source_path: Path to the source file, if applicable.
        **kwargs: Additional keyword arguments forwarded to docutils.

    Returns:
        Formatted document output as bytes or str.
    """
    import docutils.core

    return docutils.core.publish_string(source, source_path=source_path, **_publish_kwargs(kwargs))


def publish_parts(source: str | bytes, source_path: str | None = None, **kwargs: Any) -> dict[str, Any]:
    """Publish dictionary of document parts from source text using the DocOdin parser.

    Args:
        source: Input reStructuredText string or bytes.
        source_path: Path to the source file, if applicable.
        **kwargs: Additional keyword arguments forwarded to docutils.

    Returns:
        Mapping of part names to rendered components.
    """
    import docutils.core

    return docutils.core.publish_parts(source, source_path=source_path, **_publish_kwargs(kwargs))


def publish_file(**kwargs: Any) -> Any:
    """Publish document output from file using the DocOdin parser.

    Args:
        **kwargs: Arguments forwarded to docutils.core.publish_file.

    Returns:
        Published output produced by the configured writer.
    """
    import docutils.core

    return docutils.core.publish_file(**_publish_kwargs(kwargs))


def parse(text: str, source: str = "<string>", settings: Any = None, **settings_overrides: Any) -> Any:
    """Parse reST into a new docutils document without applying transforms.

    Args:
        text: Input reStructuredText markup string.
        source: Source file or stream identifier. Defaults to "<string>".
        settings: Runtime configuration settings. Defaults to None.
        **settings_overrides: Configuration key-value overrides.

    Returns:
        The parsed document tree.
    """
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
    """Retrieve version string of the loaded native library.

    Returns:
        Version string of the native DocOdin engine.
    """
    return native().version


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
    "publish_parts",
    "publish_string",
    "uninstall_shim",
    "unpatch_docutils",
    "version",
]
