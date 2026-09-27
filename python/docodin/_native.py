"""ctypes binding to the native docodin library (``libdocodin``)."""

from __future__ import annotations

import array
import ctypes
import itertools
import marshal
import os
import struct
import sys
import threading
from collections.abc import Callable, Sequence
from typing import Any, NamedTuple

ABI_VERSION = 4
WIRE_VERSION = 3

# Parse_Flag bit positions (odin/rst/document.odin)
MATCH_TITLES = 1 << 0
RAW_LINES = 1 << 1
CHARACTER_LEVEL_INLINE_MARKUP = 1 << 2
PEP_REFERENCES = 1 << 3
RFC_REFERENCES = 1 << 4
TRIM_FOOTNOTE_REFERENCE_SPACE = 1 << 5
RFC2822 = 1 << 6


def _library_name() -> str:
    if sys.platform == "darwin":
        return "libdocodin.dylib"
    if sys.platform.startswith("win"):
        return "docodin.dll"
    return "libdocodin.so"


def _find_library() -> str:
    env_path = os.environ.get("DOCODIN_LIB_PATH")
    if env_path:
        if os.path.exists(env_path):
            return env_path
        raise RuntimeError(f"DOCODIN_LIB_PATH={env_path!r} does not exist")
    name = _library_name()
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(here, name),
        os.path.join(here, "..", "..", "build", name),
    ]
    for cand in candidates:
        if os.path.exists(cand):
            return os.path.abspath(cand)
    raise RuntimeError(
        f"Could not find the docodin native library ({name}); searched {candidates}. "
        "Build it with scripts/build_odin.sh or set DOCODIN_LIB_PATH."
    )



_HOOK_TYPE = ctypes.CFUNCTYPE(
    ctypes.c_int32, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ssize_t,
    ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_ssize_t),
)


class _Hook:
    """The C callback of ``docodin_parse``'s include hook around a Python callable.

    Exceptions cannot cross the C boundary: the first one is kept and re-raised
    after the parse.  Returned buffers stay alive until the parse ends.
    """

    def __init__(self, function: Callable[[tuple], list[str] | None]) -> None:
        self.function = function
        self.error: BaseException | None = None
        self.buffers: list[Any] = []
        self.callback = _HOOK_TYPE(self._call)
        self.pointer = ctypes.cast(self.callback, ctypes.c_void_p)

    def _call(self, _data, item, item_len, out, out_len) -> int:
        if self.error is not None:
            return 0
        try:
            lines = self.function(marshal.loads(ctypes.string_at(item, item_len)))
            if lines is None:
                return 0
            buffer = ctypes.create_string_buffer("\n".join(lines).encode("utf-8", "surrogatepass"))
            self.buffers.append(buffer)
            out[0] = ctypes.cast(buffer, ctypes.c_void_p)
            out_len[0] = len(buffer) - 1
            return 1
        except BaseException as error:  # noqa: BLE001 - re-raised after the parse
            self.error = error
            return 0

class NativeLibrary:
    """Thin, thread-safe wrapper around the C ABI (the library keeps no global state)."""

    def __init__(self, path: str | None = None) -> None:
        self.path = path or _find_library()
        lib = ctypes.CDLL(self.path)
        lib.docodin_init.restype = None
        lib.docodin_init()  # the runtime start-up (a no-op if the loader ran it)
        lib.docodin_abi_version.restype = ctypes.c_int32
        lib.docodin_version.restype = ctypes.c_char_p
        abi = lib.docodin_abi_version()
        if abi != ABI_VERSION:
            raise RuntimeError(
                f"docodin native library ABI {abi} does not match the Python package (ABI {ABI_VERSION}); "
                "rebuild with scripts/build_odin.sh"
            )
        ssize = ctypes.c_ssize_t
        lib.docodin_parse.restype = ctypes.c_void_p
        lib.docodin_parse.argtypes = [
            ctypes.c_char_p, ssize, ssize, ssize, ctypes.c_uint32,
            ctypes.c_int32, ctypes.c_int32, ctypes.c_int32, ctypes.c_void_p, ctypes.c_void_p,
            ctypes.POINTER(ssize),
        ]
        lib.docodin_parse_inline.restype = ctypes.c_void_p
        lib.docodin_parse_inline.argtypes = [
            ctypes.c_char_p, ssize, ssize, ctypes.c_uint32, ctypes.POINTER(ssize),
        ]
        lib.docodin_split_lines.restype = ctypes.c_void_p
        lib.docodin_split_lines.argtypes = [ctypes.c_char_p, ssize, ctypes.c_int32, ctypes.POINTER(ssize)]
        lib.docodin_publish.restype = ctypes.c_void_p
        lib.docodin_publish.argtypes = [ctypes.c_char_p, ssize, ctypes.POINTER(ssize)]
        self._educate = getattr(lib, "docodin_educate", None)
        if self._educate is not None:
            self._educate.restype = ctypes.c_void_p
            self._educate.argtypes = [ctypes.c_char_p, ssize, ctypes.POINTER(ssize)]
        self._educate_headers: dict[tuple[str, str, tuple[str, ...] | None], bytes] = {}
        lib.docodin_free.restype = None
        lib.docodin_free.argtypes = [ctypes.c_void_p]
        self._lib = lib
        self._parse = lib.docodin_parse
        self._parse_inline = lib.docodin_parse_inline
        self._split_lines = lib.docodin_split_lines
        self._publish = lib.docodin_publish
        self._free = lib.docodin_free
        self.version = lib.docodin_version().decode()

    def _take(self, ptr: int | None, size: int) -> Any:
        if not ptr:
            raise MemoryError("docodin: native parser returned no result")
        try:
            data = ctypes.string_at(ptr, size)
        finally:
            self._free(ptr)
        result = marshal.loads(data)
        if result[0] != WIRE_VERSION:
            raise RuntimeError(f"docodin: unexpected wire format version {result[0]}")
        return result

    def parse(
        self,
        text: str,
        *,
        input_offset: int = 0,
        line_count: int = -1,
        flags: int = MATCH_TITLES,
        tab_width: int = 8,
        line_length_limit: int = 10_000,
        root_line: int = 0,
        include_hook: Callable[[tuple], list[str] | None] | None = None,
    ) -> tuple[list, int, int, int]:
        """Parse reStructuredText markup into an intermediate wire-format tree.

        Args:
            text: The reStructuredText markup string to parse.
            input_offset: Offset in lines of this block within parent source. Defaults to 0.
            line_count: Number of pre-split lines if text is '\\n'-joined; -1 if raw text.
            flags: Bitmask flags controlling parse behavior (e.g. MATCH_TITLES, RFC2822).
            tab_width: Number of spaces per tab expansion. Defaults to 8.
            line_length_limit: Maximum allowed characters per line before error. Defaults to 10,000.
            root_line: Line number offset from top-level state machine. Defaults to 0.
            include_hook: Called with the wire tuple of each directive the parser finds in
                input connected to the parsed lines; returns the lines to insert after the
                directive (``insert_input``), which the parser then parses in place, or None.

        Returns:
            Tuple of (items, number_of_lines, final_line_offset, current_line).

        Raises:
            MemoryError: If the native parser fails to allocate a result buffer.
            RuntimeError: If the returned wire format version is unexpected.
        """
        data = text.encode("utf-8", "surrogatepass")
        size = ctypes.c_ssize_t()
        hook = _Hook(include_hook) if include_hook is not None else None
        ptr = self._parse(
            data, len(data), input_offset, line_count, flags,
            tab_width, max(0, min(line_length_limit, 2**31 - 1)), root_line,
            hook.pointer if hook else None, None, ctypes.byref(size),
        )
        result = self._take(ptr, size.value)
        if hook is not None and hook.error is not None:
            raise hook.error
        _, items, count, final_offset, current_line = result
        return items, count, final_offset, current_line

    def split_lines(self, text: str, tab_width: int = 8) -> list[str]:
        """Split string into normalized lines with tab expansion via native Odin engine.

        Args:
            text: The input text to split into lines.
            tab_width: Number of spaces for tab expansion. Defaults to 8.

        Returns:
            List of normalized string lines with expanded tabs.

        Raises:
            MemoryError: If the native splitter fails to allocate a buffer.
        """
        data = text.encode("utf-8", "surrogatepass")
        size = ctypes.c_ssize_t()
        ptr = self._split_lines(data, len(data), tab_width, ctypes.byref(size))
        return self._take(ptr, size.value)[1]

    def parse_inline(self, text: str, lineno: int = 0, flags: int = 0) -> list:
        """Parse inline reStructuredText markup into node tuples via native Odin engine.

        Args:
            text: The inline reStructuredText markup string to parse.
            lineno: Source line number for error reporting. Defaults to 0.
            flags: Parser flags bitmask. Defaults to 0.

        Returns:
            List of parsed inline node tuples in wire format.

        Raises:
            MemoryError: If the native inline parser fails to allocate a buffer.
        """
        data = text.encode("utf-8", "surrogatepass")
        size = ctypes.c_ssize_t()
        ptr = self._parse_inline(data, len(data), lineno, flags, ctypes.byref(size))
        return self._take(ptr, size.value)[1]

    def publish(
        self,
        text: str,
        source_path: str | None,
        writer: str,
        overrides: Sequence[tuple[str, Any]],
        docutils_dir: str = "",
    ) -> PublishResult:
        """``publish_string`` / ``publish_parts`` natively (``docodin_publish``).

        Args:
            text: The reStructuredText source.
            source_path: The source's path (None: "<string>").
            writer: pseudoxml, xml, html5 (html, xhtml), latex or xetex.
            overrides: Settings as (docutils name, value): None, bool, int, str, or a list of
                str and (language, quotes) pairs.  A string of a setting with a validator is
                converted as on the command line.
            docutils_dir: The docutils package directory named in messages and stylesheet
                paths ("": ``<docutils>``).

        Returns:
            The output (text), parts, messages, exit status and error (None, or
            (kind, text, report, level, encoding, start, end, characters)).

        Raises:
            TypeError: If a setting value has another type.
            MemoryError: If the native call fails.
        """
        fields = [_field(text), _pack_int(source_path is not None), _field(source_path or ""),
                  _field(writer), _field(docutils_dir), _pack_int(len(overrides))]
        for name, value in overrides:
            fields.append(_field(name))
            fields.append(_setting_value(name, value))
        request = b"".join(fields)
        size = ctypes.c_ssize_t()
        ptr = self._publish(request, len(request), ctypes.byref(size))
        _, output, parts, messages, status, error = self._take(ptr, size.value)
        return PublishResult(output, dict(parts), messages, status, error)

    @property
    def has_educate(self) -> bool:
        """Whether the library exports ``docodin_educate`` (smart quotes)."""
        return self._educate is not None

    def educate(
        self,
        kinds: Sequence[str],
        texts: Sequence[str],
        attr: str,
        language: str,
        quotes: tuple[str, ...] | None = None,
    ) -> list[str]:
        """``smartquotes.educate_tokens`` natively, for one block of tokens.

        Args:
            kinds: The token types: "tag", "literal" or other (text).
            texts: The token texts.
            attr: The ``educate_tokens`` action string ("1", "2", "3", "-1", letters).
            language: The language tag (its quotes come from the native table).
            quotes: Quotation marks overriding the table's (open/close primary,
                open/close secondary).

        Returns:
            The educated text of every token.

        Raises:
            UnicodeEncodeError: If a text is not encodable (lone surrogates).
            MemoryError: If the native call fails.
        """
        header = self._educate_headers.get((attr, language, quotes))
        if header is None:
            header = self._educate_header(attr, language, quotes)
        request = b"".join((
            header, _pack_int(len(texts)), array.array(_SSIZE_CODE, map(len, texts)).tobytes(),
            bytes(map(_TOKEN_KINDS.get, kinds, itertools.repeat(0))),
            "".join(texts).encode("utf-8"),
        ))
        size = ctypes.c_ssize_t()
        ptr = self._educate(request, len(request), ctypes.byref(size))
        return self._take(ptr, size.value)[1]

    def _educate_header(self, attr: str, language: str,
                        quotes: tuple[str, ...] | None) -> bytes:
        """The settings part of an educate request (see ``docodin_educate``)."""
        marks = () if quotes is None else quotes
        header = b"".join((
            _field(attr), _field(language), _pack_int(quotes is not None), *map(_field, marks),
        ))
        if len(self._educate_headers) < 64:
            self._educate_headers[(attr, language, quotes)] = header
        return header


# Token_Kind of odin/text/smartquotes.odin
_TOKEN_KINDS = {"literal": 1, "tag": 2}
# array and struct code of ``ctypes.c_ssize_t`` (Odin ``int``)
_SSIZE_CODE = "q" if ctypes.sizeof(ctypes.c_ssize_t) == 8 else "i"
_pack_int = struct.Struct("=" + _SSIZE_CODE).pack


def _field(text: str) -> bytes:
    """A length-prefixed UTF-8 field of a request."""
    data = text.encode("utf-8", "surrogatepass")
    return _pack_int(len(data)) + data


def _setting_value(name: str, value: Any) -> bytes:
    """A setting value of a publish request (see ``docodin_publish``)."""
    if value is None:
        return _pack_int(0)
    if isinstance(value, bool):
        return _pack_int(2 if value else 1)
    if isinstance(value, int):
        return _pack_int(3) + _pack_int(value)
    if isinstance(value, (str, os.PathLike)):
        return _pack_int(4) + _field(os.fspath(value))
    if isinstance(value, tuple) and name == "math_output":  # validated: (format, options)
        return _pack_int(4) + _field(" ".join(value))
    if isinstance(value, (list, tuple)):
        items = [":".join(map(str, item)) if isinstance(item, (list, tuple)) else str(item)
                 for item in value]
        return _pack_int(5) + _pack_int(len(items)) + b"".join(map(_field, items))
    raise TypeError(f"docodin: setting {name!r}: unsupported value {value!r}")


class PublishResult(NamedTuple):
    """What ``docodin_publish`` returns."""

    output: str
    parts: dict[str, str]
    messages: list[tuple[int, str]]
    exit_status: int
    error: tuple | None

_lock = threading.Lock()
_instance: NativeLibrary | None = None


def native() -> NativeLibrary:
    """Return the process-wide library wrapper (loaded on first use)."""
    global _instance
    if _instance is None:
        with _lock:
            if _instance is None:
                _instance = NativeLibrary()
    return _instance
