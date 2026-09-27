"""``publish_string`` / ``publish_parts`` with the native pipeline (``docodin_publish``).

The standalone reader, the reStructuredText parser, the transforms and the writers
pseudoxml, xml, html5, latex and xetex run in the native library, with docutils' settings,
messages and exceptions.  Documents that need Python extensions (other readers, parsers or
writers, custom directives or roles, Pygments, PIL) need docutils.
"""

from __future__ import annotations

import builtins
import os
import sys
from pathlib import Path
from typing import Any

from docodin._native import native

# Settings of the Python run that the native pipeline has no use for.
_IGNORED = {"warning_stream", "traceback", "_disable_config", "record_dependencies"}


def publish_native(source: str | bytes, source_path: str | os.PathLike | None = None,
                   writer: str = "html5", settings_overrides: dict[str, Any] | None = None,
                   *, parts: bool = False, docutils_dir: str | None = None) -> Any:
    """``docutils.core.publish_string`` (or ``publish_parts`` with ``parts``) natively.

    Args:
        source: The reStructuredText source (bytes are decoded with ``input_encoding``).
        source_path: The source's path, for messages and relative paths.
        writer: pseudoxml, xml, html5 (html, xhtml), latex or xetex.
        settings_overrides: docutils settings, as ``publish_string`` takes them.
        parts: Return the ``publish_parts`` dictionary instead of the output.
        docutils_dir: The docutils package directory in messages and stylesheet paths
            (default: that of the importable ``docutils``).

    Returns:
        The output as ``publish_string`` returns it (bytes in ``output_encoding``, or str
        for "unicode"), or the parts.

    Raises:
        docutils.utils.SystemMessage: A message reached ``halt_level``.
        UnicodeEncodeError: The output encoding cannot encode the output.
        Exception: What docutils raises for the document (same class and message).
    """
    overrides = dict(settings_overrides or {})
    stream = overrides.get("warning_stream")
    if isinstance(source, bytes):
        source = source.decode(overrides.get("input_encoding") or "utf-8",
                               overrides.get("input_encoding_error_handler") or "strict")
    path = None if source_path is None else os.fspath(source_path)
    items = [(k, v) for k, v in overrides.items() if k not in _IGNORED]
    result = native().publish(source, path, writer, items, docutils_dir or _docutils_dir())
    _write_messages(stream, result.messages)
    if result.error is not None:
        raise _exception(result.error)
    if parts:
        return result.parts
    encoding = result.parts.get("encoding", "utf-8")
    if encoding == "unicode":
        return result.output
    return result.output.encode(encoding, result.parts.get("errors", "strict"))


def _docutils_dir() -> str:
    import docutils

    return str(Path(docutils.__file__).resolve().parent)


def _write_messages(stream: Any, messages: list[tuple[int, str]]) -> None:
    """``Reporter.stream``: None is standard error, False none, a string a file name."""
    if stream is False or stream == "" or not messages:
        return
    text = "".join(text for _, text in messages)
    if stream is None:
        sys.stderr.write(text)
    elif isinstance(stream, (str, os.PathLike)):
        Path(stream).write_text(text, encoding="utf-8")
    else:
        stream.write(text)


def _exception(error: tuple) -> BaseException:
    kind, text, _report, level, encoding, start, end, chars = error
    if kind == "system_message":
        from docutils.utils import SystemMessage

        class _Message:
            def astext(self) -> str:
                return text

        return SystemMessage(_Message(), level)
    if kind == "unicode_encode":
        reason = text.rsplit(": ", 1)[-1]
        return UnicodeEncodeError(encoding, "\0" * start + chars, start, end, reason)
    if kind == "settings" and text.startswith("Writer "):
        return ImportError(text)
    name, sep, message = text.partition(": ")
    cls = getattr(builtins, name, None) if sep else None
    if isinstance(cls, type) and issubclass(cls, Exception):
        return cls(message)
    return RuntimeError(text)
