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
        lib.docodin_free.restype = None
        lib.docodin_free.argtypes = [ctypes.c_void_p]
        self._lib = lib
        self._parse = lib.docodin_parse
        self._parse_inline = lib.docodin_parse_inline
        self._split_lines = lib.docodin_split_lines
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
    ) -> tuple[list, int, int, int]:
        """Parse reST; ``line_count >= 0`` means ``text`` is ``'\\n'``-joined lines.

        Returns (items, number_of_lines, final_line_offset, current_line):
        ``current_line`` is docutils' ``document.current_line`` after the parse
        (a line number, 0 for None, -1 for None without a current source)."""
        data = text.encode("utf-8", "surrogatepass")
        size = ctypes.c_ssize_t()
        ptr = self._parse(
            data, len(data), input_offset, line_count, flags,
            tab_width, max(0, min(line_length_limit, 2**31 - 1)), root_line, ctypes.byref(size),
        )
        _, items, count, final_offset, current_line = self._take(ptr, size.value)
        return items, count, final_offset, current_line

    def split_lines(self, text: str, tab_width: int = 8) -> list[str]:
        """``docutils.statemachine.string2lines(text, tab_width, convert_whitespace=True)``."""
        data = text.encode("utf-8", "surrogatepass")
        size = ctypes.c_ssize_t()
        ptr = self._split_lines(data, len(data), tab_width, ctypes.byref(size))
        return self._take(ptr, size.value)[1]

    def parse_inline(self, text: str, lineno: int = 0, flags: int = 0) -> list:
        data = text.encode("utf-8", "surrogatepass")
        size = ctypes.c_ssize_t()
        ptr = self._parse_inline(data, len(data), lineno, flags, ctypes.byref(size))
        return self._take(ptr, size.value)[1]


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
