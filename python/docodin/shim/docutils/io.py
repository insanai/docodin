"""I/O classes providing a uniform API for low-level input and output."""

from __future__ import annotations

import codecs
import locale
import os
import re
import sys
import warnings
from typing import Any, ClassVar

from docutils import TransformSpec

__docformat__ = "reStructuredText"


def _find_locale_encoding() -> str | None:
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            encoding = (locale.getlocale()[1] or locale.getdefaultlocale()[1]).lower()
        codecs.lookup(encoding)
    except Exception:  # noqa: BLE001 - any failure means "unknown"
        return None
    return encoding


_locale_encoding = _find_locale_encoding()


class InputError(OSError):
    pass


class OutputError(OSError):
    pass


def check_encoding(stream: Any, encoding: str) -> bool | None:
    """Whether `stream` uses `encoding` (None if undeterminable)."""
    try:
        return codecs.lookup(stream.encoding) == codecs.lookup(encoding)
    except (LookupError, AttributeError, TypeError):
        return None


def error_string(err: BaseException) -> str:
    """Exception class name and message."""
    return f"{err.__class__.__name__}: {err}"


class Input(TransformSpec):
    """Abstract base class for input wrappers."""

    component_type = "input"
    default_source_path: ClassVar[str | None] = None
    coding_slug = re.compile(rb"coding[:=]\s*([-\w.]+)")
    byte_order_marks = (
        (codecs.BOM_UTF32_BE, "utf-32"), (codecs.BOM_UTF32_LE, "utf-32"),
        (codecs.BOM_UTF8, "utf-8-sig"), (codecs.BOM_UTF16_BE, "utf-16"),
        (codecs.BOM_UTF16_LE, "utf-16"),
    )

    def __init__(self, source: Any = None, source_path: str | None = None,
                 encoding: str | None = "utf-8", error_handler: str | None = "strict") -> None:
        self.encoding = encoding
        self.error_handler = error_handler
        self.source = source
        self.source_path = source_path or self.default_source_path
        self.successful_encoding: str | None = None

    def __repr__(self) -> str:
        return "%s: source=%r, source_path=%r" % (self.__class__, self.source, self.source_path)

    def read(self) -> Any:
        raise NotImplementedError

    def decode(self, data: str | bytes) -> str:
        """Decode `data` with the configured encoding (or detected ones)."""
        if isinstance(data, str):
            return data
        candidates = self._encoding_candidates(data)
        error: Exception | None = None
        for enc in candidates:
            try:
                decoded = str(data, enc, self.error_handler)
            except (UnicodeError, LookupError) as err:
                error = err
                continue
            self.successful_encoding = enc
            return decoded
        tried = ", ".join(repr(enc) for enc in candidates)
        raise UnicodeError(f"Unable to decode input data.  Tried the following encodings: "
                           f"{tried}.\n({error_string(error)})")

    def _encoding_candidates(self, data: bytes) -> list[str]:
        if self.encoding:
            assert self.encoding.lower() != "unicode", (
                'input encoding is "unicode" but `data` is no `str` instance')
            return [self.encoding]
        with warnings.catch_warnings():
            warnings.filterwarnings("ignore", category=DeprecationWarning)
            data_encoding = self.determine_encoding_from_data(data)
        if data_encoding:
            candidates = [data_encoding]
        else:
            candidates = ["utf-8"]
            fallback = locale.getencoding()
            if fallback and fallback.lower() != "utf-8":
                candidates.append(fallback)
        if candidates[0] != "utf-8":
            warnings.warn('Input encoding auto-detection will be removed and the encoding values '
                          'None and "" become invalid in Docutils\xa01.0.',
                          DeprecationWarning, stacklevel=3)
        return candidates

    def determine_encoding_from_data(self, data: bytes) -> str | None:
        """Encoding from a byte order mark or a "coding:" slug, if any."""
        warnings.warn("docutils.io.Input.determine_encoding_from_data() will be removed in "
                      "Docutils\xa01.0.", DeprecationWarning, stacklevel=2)
        for start_bytes, encoding in self.byte_order_marks:
            if data.startswith(start_bytes):
                return encoding
        for line in data.splitlines()[:2]:
            match = self.coding_slug.search(line)
            if match:
                return match.group(1).decode("ascii")
        return None

    def isatty(self) -> bool:
        try:
            return self.source.isatty()
        except AttributeError:
            return False


class Output(TransformSpec):
    """Abstract base class for output wrappers."""

    component_type = "output"
    default_destination_path: ClassVar[str | None] = None

    def __init__(self, destination: Any = None, destination_path: str | None = None,
                 encoding: str | None = None, error_handler: str | None = "strict") -> None:
        self.encoding = encoding
        self.error_handler = error_handler or "strict"
        self.destination = destination
        self.destination_path = destination_path or self.default_destination_path

    def __repr__(self) -> str:
        return "%s: destination=%r, destination_path=%r" % (
            self.__class__, self.destination, self.destination_path)

    def write(self, data: str | bytes) -> Any:
        raise NotImplementedError

    def encode(self, data: str | bytes) -> str | bytes:
        """Encode `data` (unless the output encoding is "unicode")."""
        if self.encoding and self.encoding.lower() == "unicode":
            assert isinstance(data, str), (
                'output encoding is "unicode" but `data` is no `str` instance')
            return data
        if not isinstance(data, str):
            return data
        return data.encode(self.encoding, self.error_handler)


class ErrorOutput:
    """Wrapper for error output streams (writes str, bytes or exceptions)."""

    def __init__(self, destination: Any = None, encoding: str | None = None,
                 encoding_errors: str = "backslashreplace",
                 decoding_errors: str = "replace") -> None:
        if destination is None:
            destination = sys.stderr
        elif not destination:
            destination = False
        elif isinstance(destination, str):
            destination = open(destination, "w")  # noqa: SIM115 - kept open like docutils
        self.destination = destination
        self.encoding = (encoding or getattr(destination, "encoding", None)
                         or _locale_encoding or "ascii")
        self.encoding_errors = encoding_errors
        self.decoding_errors = decoding_errors

    def write(self, data: str | bytes | Exception) -> None:
        if not self.destination:
            return
        if isinstance(data, Exception):
            data = str(data)
        try:
            self.destination.write(data)
        except UnicodeEncodeError:
            self.destination.write(data.encode(self.encoding, self.encoding_errors))
        except TypeError:
            self._write_converted(data)

    def _write_converted(self, data: str | bytes) -> None:
        if isinstance(data, str):
            self.destination.write(data.encode(self.encoding, self.encoding_errors))
        elif self.destination in (sys.stderr, sys.stdout):
            self.destination.buffer.write(data)
        else:
            self.destination.write(data.decode(self.encoding, self.decoding_errors))

    def close(self) -> None:
        if self.destination in (sys.stdout, sys.stderr):
            return
        try:
            self.destination.close()
        except AttributeError:
            pass

    def isatty(self) -> bool:
        try:
            return self.destination.isatty()
        except AttributeError:
            return False


class FileInput(Input):
    """Input for single, simple file-like objects."""

    def __init__(self, source: Any = None, source_path: str | None = None,
                 encoding: str | None = "utf-8", error_handler: str | None = "strict",
                 autoclose: bool = True, mode: str = "r") -> None:
        super().__init__(source, source_path, encoding, error_handler)
        self.autoclose = autoclose
        self._stderr = ErrorOutput()
        if source is None:
            if source_path:
                try:
                    self.source = open(source_path, mode, encoding=self.encoding,  # noqa: SIM115
                                       errors=self.error_handler)
                except OSError as error:
                    raise InputError(error.errno, error.strerror, source_path) from None
            else:
                self.source = sys.stdin
        elif check_encoding(self.source, self.encoding) is False:
            raise UnicodeError('Encoding clash: encoding given is "%s" but source is opened with '
                               'encoding "%s".' % (self.encoding, self.source.encoding))
        if not source_path:
            try:
                self.source_path = self.source.name
            except AttributeError:
                pass

    def read(self) -> str:
        """Read and decode the whole file."""
        try:
            if not self.encoding and hasattr(self.source, "buffer"):
                data = self.decode(self.source.buffer.read())
                data = "\n".join(data.splitlines() + [""])
            else:
                data = self.decode(self.source.read())
        finally:
            if self.autoclose:
                self.close()
        return data

    def readlines(self) -> list[str]:
        return self.read().splitlines(True)

    def close(self) -> None:
        if self.source is not sys.stdin:
            self.source.close()


class FileOutput(Output):
    """Output for single, simple file-like objects."""

    default_destination_path = "<file>"
    mode = "w"

    def __init__(self, destination: Any = None, destination_path: str | None = None,
                 encoding: str | None = None, error_handler: str | None = "strict",
                 autoclose: bool = True, handle_io_errors: None = None,
                 mode: str | None = None) -> None:
        super().__init__(destination, destination_path, encoding, error_handler)
        self.opened = True
        self.autoclose = autoclose
        if handle_io_errors is not None:
            warnings.warn('io.FileOutput: init argument "handle_io_errors" is ignored and will be '
                          "removed in Docutils 2.0.", DeprecationWarning, stacklevel=2)
        if mode is not None:
            self.mode = mode
        self._stderr = ErrorOutput()
        if destination is None:
            if destination_path:
                self.opened = False
            else:
                self.destination = sys.stdout
        elif mode and hasattr(self.destination, "mode") and mode != self.destination.mode:
            print('Warning: Destination mode "%s" differs from specified mode "%s"'
                  % (self.destination.mode, mode), file=self._stderr)
        if not destination_path:
            try:
                self.destination_path = self.destination.name
            except AttributeError:
                pass

    def open(self) -> None:
        kwargs = {} if "b" in self.mode else {"encoding": self.encoding,
                                               "errors": self.error_handler}
        try:
            self.destination = open(self.destination_path, self.mode, **kwargs)  # noqa: SIM115
        except OSError as error:
            raise OutputError(error.errno, error.strerror, self.destination_path) from None
        self.opened = True

    def write(self, data: str | bytes) -> str | bytes:
        """Write `data` (str or bytes) to the destination; return it."""
        if not self.opened:
            self.open()
        if isinstance(data, str) and check_encoding(self.destination, self.encoding) is False:
            if os.linesep != "\n":
                data = data.replace("\n", os.linesep)
            data = self.encode(data)
        try:
            self.destination.write(data)
        except TypeError as err:
            self._write_bytes(data, err)
        except (UnicodeError, LookupError) as err:
            raise UnicodeError(f"Unable to encode output data. output-encoding is: "
                               f"{self.encoding}.\n({error_string(err)})") from None
        finally:
            if self.autoclose:
                self.close()
        return data

    def _write_bytes(self, data: str | bytes, err: TypeError) -> None:
        if not isinstance(data, bytes):
            return
        try:
            self.destination.buffer.write(data)
        except AttributeError:
            if check_encoding(self.destination, self.encoding) is False:
                raise ValueError(f"Encoding of {self.destination_path} "
                                 f"({self.destination.encoding}) differs \n"
                                 f"  from specified encoding ({self.encoding})") from None
            raise err from None

    def close(self) -> None:
        if self.destination not in (sys.stdout, sys.stderr):
            self.destination.close()
            self.opened = False


class BinaryFileOutput(FileOutput):
    """Deprecated: use `FileOutput` with a binary mode."""

    mode = "wb"

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        warnings.warn('"BinaryFileOutput" is obsoleted by "FileOutput" and will be removed in '
                      "Docutils 0.24.", DeprecationWarning, stacklevel=2)
        super().__init__(*args, **kwargs)


class StringInput(Input):
    """Input from a `str` or `bytes` instance."""

    default_source_path = "<string>"

    def read(self) -> str:
        return self.decode(self.source)


class StringOutput(Output):
    """Output to a `bytes` or `str` instance."""

    default_destination_path = "<string>"

    def write(self, data: str | bytes) -> str | bytes:
        self.destination = self.encode(data)
        return self.destination


class NullInput(Input):
    """Degenerate input: read nothing."""

    default_source_path = "null input"

    def read(self) -> str:
        return ""


class NullOutput(Output):
    """Degenerate output: write nothing."""

    default_destination_path = "null output"

    def write(self, data: str | bytes) -> None:
        pass


class DocTreeInput(Input):
    """Input from an existing document tree."""

    default_source_path = "doctree input"

    def read(self) -> Any:
        return self.source
