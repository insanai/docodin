"""``publish_string`` / ``publish_parts`` with the native pipeline (``docodin_publish``).

The standalone reader, the reStructuredText parser, the transforms and the writers
pseudoxml, xml, html5, latex and xetex run in the native library, with docutils' settings,
messages and exceptions.  Where docutils would use a Python library (Pygments, PIL,
``urllib``, codecs, parser and writer modules, external MathML converters), the native
publisher reports it, and the document is published with docutils instead: the result is
always docutils'.  Custom directives, roles and other extensions registered in Python are
not seen by the native pipeline: use docutils (``docodin.publish_string``) for them.
"""

from __future__ import annotations

import builtins
import os
import sys
from pathlib import Path
from typing import Any

from docodin._native import PythonNeed, native

# Settings of the Python run that the native pipeline has no use for.
_IGNORED = {"warning_stream", "traceback", "_disable_config", "record_dependencies"}


class NeedsPythonError(RuntimeError):
    """The document needs Python libraries, and native publishing was requested
    (``native_only``).  ``needs`` says where docutils would use them."""

    def __init__(self, needs: list[PythonNeed]) -> None:
        self.needs = list(needs)
        lines = "".join(f"\n  {need}" for need in self.needs)
        super().__init__(
            "The document needs Python libraries that the native publisher does not have; "
            "publish it without native_only=True to use docutils:" + lines)


def publish_native(source: str | bytes, source_path: str | os.PathLike | None = None,
                   writer: str = "html5", settings_overrides: dict[str, Any] | None = None,
                   *, parts: bool = False, docutils_dir: str | None = None,
                   native_only: bool = False) -> Any:
    """``docutils.core.publish_string`` (or ``publish_parts`` with ``parts``) natively.

    Where docutils would use a Python library (Pygments, PIL, ``urllib``, codecs, parser
    and writer modules, external MathML converters), the document is published with
    docutils (``publish_string`` / ``publish_parts`` with the same arguments) instead, so
    the result is always that of docutils.

    Args:
        source: The reStructuredText source (bytes are decoded with ``input_encoding``).
        source_path: The source's path, for messages and relative paths.
        writer: pseudoxml, xml, html5 (html, xhtml), latex or xetex natively; other
            writers through docutils.
        settings_overrides: docutils settings, as ``publish_string`` takes them.
        parts: Return the ``publish_parts`` dictionary instead of the output.
        docutils_dir: The docutils package directory in messages and stylesheet paths
            (default: that of the importable ``docutils``).
        native_only: Raise ``NeedsPythonError`` instead of publishing with docutils.

    Returns:
        The output as ``publish_string`` returns it (bytes in ``output_encoding``, or str
        for "unicode"), or the parts.

    Raises:
        NeedsPythonError: With ``native_only``, the document needs Python libraries.
        docutils.utils.SystemMessage: A message reached ``halt_level``.
        UnicodeEncodeError: The output encoding cannot encode the output.
        Exception: What docutils raises for the document (same class and message).
    """
    overrides = dict(settings_overrides or {})
    stream = overrides.get("warning_stream")
    path = None if source_path is None else os.fspath(source_path)
    text, needs = _decode(source, overrides)
    if text is not None:
        items = [(k, v) for k, v in overrides.items() if k not in _IGNORED]
        result = native().publish(text, path, writer, items, docutils_dir or _docutils_dir())
        needs = result.needs_python
    if needs:
        if native_only:
            raise NeedsPythonError(needs)
        return _publish_docutils(source, path, writer, settings_overrides, parts)
    _write_messages(stream, result.messages)
    if result.error is not None:
        raise _exception(result.error)
    if parts:
        return result.parts
    encoding = result.parts.get("encoding", "utf-8")
    if encoding == "unicode":
        return result.output
    return result.output.encode(encoding, result.parts.get("errors", "strict"))


def _decode(source: str | bytes, overrides: dict[str, Any]) -> tuple[str | None, list]:
    """The text of the source; for bytes that ``input_encoding`` does not decode (an unknown
    codec, or bytes that are not valid), None and the need: docutils' ``Input.decode``
    reports it."""
    if not isinstance(source, bytes):
        return source, []
    encoding = overrides.get("input_encoding") or "utf-8"
    try:
        return source.decode(encoding,
                             overrides.get("input_encoding_error_handler") or "strict"), []
    except (LookupError, UnicodeError):
        text = f'The codec or error handler "{encoding}" needs Python\'s codecs.'
        return None, [PythonNeed("codec", str(encoding), "", 0, text)]


def _publish_docutils(source: str | bytes, source_path: str | None, writer: str,
                      settings_overrides: dict[str, Any] | None, parts: bool) -> Any:
    """``publish_string`` / ``publish_parts`` of the importable docutils (docodin's
    implementation, or docutils itself when it is installed)."""
    import docutils.core

    publish = docutils.core.publish_parts if parts else docutils.core.publish_string
    return publish(source, source_path=source_path, writer=writer,
                   settings_overrides=settings_overrides)


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
