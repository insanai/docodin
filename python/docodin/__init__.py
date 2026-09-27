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


def render_html(
    source: str,
    *,
    title: str = "",
    author: str = "",
    standalone: bool = True,
    embed_css: bool = True,
) -> str:
    """Render reStructuredText directly to HTML5 using the native Odin engine.

    Args:
        source: Input reStructuredText markup string.
        title: Document title to embed in the HTML head and header.
        author: Document author metadata.
        standalone: Whether to emit a complete HTML5 document or just body fragment.
        embed_css: Whether to embed default responsive styling.

    Returns:
        The rendered HTML5 string.
    """
    return native().render_html(
        source,
        title=title,
        author=author,
        standalone=standalone,
        embed_css=embed_css,
    )


def render_latex(
    source: str,
    *,
    title: str = "",
    author: str = "",
    date: str = "",
    standalone: bool = True,
) -> str:
    """Render reStructuredText directly to LaTeX 2e using the native Odin engine.

    Args:
        source: Input reStructuredText markup string.
        title: Document title for the LaTeX preamble and \\maketitle.
        author: Document author metadata.
        date: Document date metadata.
        standalone: Whether to emit a complete LaTeX document or fragment.

    Returns:
        The rendered LaTeX string.
    """
    return native().render_latex(
        source,
        title=title,
        author=author,
        date=date,
        standalone=standalone,
    )


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
    "render_html",
    "render_latex",
    "uninstall_shim",
    "unpatch_docutils",
    "version",
]
