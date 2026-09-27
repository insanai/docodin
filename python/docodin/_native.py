"""ctypes binding to the native docodin library (``libdocodin``)."""

from __future__ import annotations

import ctypes
import marshal
import os
import sys
import threading
from typing import Any

ABI_VERSION = 2
WIRE_VERSION = 2

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


class NativeLibrary:
    """Thin, thread-safe wrapper around the C ABI (the library keeps no global state)."""

    def __init__(self, path: str | None = None) -> None:
        self.path = path or _find_library()
        lib = ctypes.CDLL(self.path)
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
            ctypes.c_int32, ctypes.c_int32, ctypes.c_int32, ctypes.POINTER(ssize),
        ]
        lib.docodin_parse_inline.restype = ctypes.c_void_p
        lib.docodin_parse_inline.argtypes = [
            ctypes.c_char_p, ssize, ssize, ctypes.c_uint32, ctypes.POINTER(ssize),
        ]
        lib.docodin_split_lines.restype = ctypes.c_void_p
        lib.docodin_split_lines.argtypes = [ctypes.c_char_p, ssize, ctypes.c_int32, ctypes.POINTER(ssize)]
        lib.docodin_render_html.restype = ctypes.c_void_p
        lib.docodin_render_html.argtypes = [
            ctypes.c_char_p, ssize,
            ctypes.c_char_p, ssize,
            ctypes.c_char_p, ssize,
            ctypes.c_bool, ctypes.c_bool,
            ctypes.POINTER(ssize),
        ]
        lib.docodin_render_latex.restype = ctypes.c_void_p
        lib.docodin_render_latex.argtypes = [
            ctypes.c_char_p, ssize,
            ctypes.c_char_p, ssize,
            ctypes.c_char_p, ssize,
            ctypes.c_char_p, ssize,
            ctypes.c_bool,
            ctypes.POINTER(ssize),
        ]
        lib.docodin_free.restype = None
        lib.docodin_free.argtypes = [ctypes.c_void_p]
        self._lib = lib
        self._parse = lib.docodin_parse
        self._parse_inline = lib.docodin_parse_inline
        self._split_lines = lib.docodin_split_lines
        self._render_html = lib.docodin_render_html
        self._render_latex = lib.docodin_render_latex
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

    def _take_str(self, ptr: int | None, size: int) -> str:
        if not ptr:
            raise MemoryError("docodin: native renderer returned no result")
        try:
            data = ctypes.string_at(ptr, size)
        finally:
            self._free(ptr)
        return data.decode("utf-8")

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

        Returns:
            Tuple of (items, number_of_lines, final_line_offset, current_line).

        Raises:
            MemoryError: If the native parser fails to allocate a result buffer.
            RuntimeError: If the returned wire format version is unexpected.
        """
        data = text.encode("utf-8", "surrogatepass")
        size = ctypes.c_ssize_t()
        ptr = self._parse(
            data, len(data), input_offset, line_count, flags,
            tab_width, max(0, min(line_length_limit, 2**31 - 1)), root_line, ctypes.byref(size),
        )
        _, items, count, final_offset, current_line = self._take(ptr, size.value)
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

    def render_html(
        self,
        text: str,
        *,
        title: str = "",
        author: str = "",
        standalone: bool = True,
        embed_css: bool = True,
    ) -> str:
        """Render reStructuredText directly to HTML5 using the native Odin engine.

        Args:
            text: The reStructuredText markup string to render.
            title: Document title to embed in the HTML head and header.
            author: Document author metadata.
            standalone: Whether to emit a complete HTML5 document or just body fragment.
            embed_css: Whether to embed default responsive styling.

        Returns:
            The rendered HTML5 string.

        Raises:
            MemoryError: If the native renderer fails to allocate or return a buffer.
        """
        data = text.encode("utf-8", "surrogatepass")
        title_bytes = title.encode("utf-8", "surrogatepass") if title else b""
        author_bytes = author.encode("utf-8", "surrogatepass") if author else b""
        size = ctypes.c_ssize_t()
        ptr = self._render_html(
            data, len(data),
            title_bytes, len(title_bytes),
            author_bytes, len(author_bytes),
            standalone, embed_css,
            ctypes.byref(size),
        )
        return self._take_str(ptr, size.value)

    def render_latex(
        self,
        text: str,
        *,
        title: str = "",
        author: str = "",
        date: str = "",
        standalone: bool = True,
    ) -> str:
        """Render reStructuredText directly to LaTeX 2e using the native Odin engine.

        Args:
            text: The reStructuredText markup string to render.
            title: Document title for the LaTeX preamble and \\maketitle.
            author: Document author metadata.
            date: Document date metadata.
            standalone: Whether to emit a complete LaTeX document or fragment.

        Returns:
            The rendered LaTeX string.

        Raises:
            MemoryError: If the native renderer fails to allocate or return a buffer.
        """
        data = text.encode("utf-8", "surrogatepass")
        title_bytes = title.encode("utf-8", "surrogatepass") if title else b""
        author_bytes = author.encode("utf-8", "surrogatepass") if author else b""
        date_bytes = date.encode("utf-8", "surrogatepass") if date else b""
        size = ctypes.c_ssize_t()
        ptr = self._render_latex(
            data, len(data),
            title_bytes, len(title_bytes),
            author_bytes, len(author_bytes),
            date_bytes, len(date_bytes),
            standalone,
            ctypes.byref(size),
        )
        return self._take_str(ptr, size.value)


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
