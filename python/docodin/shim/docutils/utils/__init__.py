"""Miscellaneous utilities: the `Reporter`, option extraction, text helpers."""

from __future__ import annotations

import itertools
import os
import os.path
import re
import sys
import unicodedata
import warnings
from collections.abc import Callable, Iterable
from pathlib import Path, PurePath
from typing import Any

from docutils import ApplicationError, DataError, io, nodes
from docutils.nodes import unescape  # noqa: F401 - part of the docutils.utils namespace

__docformat__ = "reStructuredText"


class SystemMessage(ApplicationError):
    def __init__(self, system_message: nodes.system_message, level: int) -> None:
        Exception.__init__(self, system_message.astext())
        self.level = level


class SystemMessagePropagation(ApplicationError):
    pass


class Reporter:
    """Create `system_message` nodes, write them to a stream, halt if needed."""

    levels = ("DEBUG", "INFO", "WARNING", "ERROR", "SEVERE")
    DEBUG_LEVEL = 0
    INFO_LEVEL = 1
    WARNING_LEVEL = 2
    ERROR_LEVEL = 3
    SEVERE_LEVEL = 4

    def __init__(self, source: str, report_level: int, halt_level: int, stream: Any = None,
                 debug: bool = False, encoding: str | None = None,
                 error_handler: str = "backslashreplace") -> None:
        self.source = source
        self.error_handler = error_handler
        self.debug_flag = debug
        self.report_level = report_level
        self.halt_level = halt_level
        if not isinstance(stream, io.ErrorOutput):
            stream = io.ErrorOutput(stream, encoding, error_handler)
        self.stream = stream
        self.encoding = encoding or getattr(stream, "encoding", "ascii")
        self.observers: list[Callable[[nodes.system_message], None]] = []
        self.max_level = -1

    def attach_observer(self, observer: Callable[[nodes.system_message], None]) -> None:
        self.observers.append(observer)

    def detach_observer(self, observer: Callable[[nodes.system_message], None]) -> None:
        self.observers.remove(observer)

    def notify_observers(self, message: nodes.system_message) -> None:
        for observer in self.observers:
            observer(message)

    def system_message(self, level: int, message: str, *children: nodes.Node,
                       **kwargs: Any) -> nodes.system_message:
        """Return a system_message node; report and halt according to settings."""
        if isinstance(message, Exception):
            message = str(message)
        attributes = self._message_attributes(kwargs)
        msg = nodes.system_message(message, *children, level=level, type=self.levels[level],
                                   **attributes)
        if self.stream and (level >= self.report_level
                            or self.debug_flag and level == self.DEBUG_LEVEL
                            or level >= self.halt_level):
            self.stream.write(msg.astext() + "\n")
        if level >= self.halt_level:
            raise SystemMessage(msg, level)
        if level > self.DEBUG_LEVEL or self.debug_flag:
            self.notify_observers(msg)
        self.max_level = max(level, self.max_level)
        return msg

    def _message_attributes(self, kwargs: dict[str, Any]) -> dict[str, Any]:
        attributes = kwargs.copy()
        if "base_node" in kwargs:
            source, line = get_source_line(attributes.pop("base_node"))
            if source is not None:
                attributes.setdefault("source", source)
            if line is not None:
                attributes.setdefault("line", line)
        if "source" not in attributes:
            try:
                source, line = self.get_source_and_line(attributes.get("line"))
            except AttributeError:
                source, line = None, None
            if source is not None:
                attributes["source"] = source
            if line is not None:
                attributes["line"] = line
        attributes.setdefault("source", self.source)
        return attributes

    def debug(self, *args: Any, **kwargs: Any) -> nodes.system_message | None:
        if self.debug_flag:
            return self.system_message(self.DEBUG_LEVEL, *args, **kwargs)
        return None

    def info(self, *args: Any, **kwargs: Any) -> nodes.system_message:
        return self.system_message(self.INFO_LEVEL, *args, **kwargs)

    def warning(self, *args: Any, **kwargs: Any) -> nodes.system_message:
        return self.system_message(self.WARNING_LEVEL, *args, **kwargs)

    def error(self, *args: Any, **kwargs: Any) -> nodes.system_message:
        return self.system_message(self.ERROR_LEVEL, *args, **kwargs)

    def severe(self, *args: Any, **kwargs: Any) -> nodes.system_message:
        return self.system_message(self.SEVERE_LEVEL, *args, **kwargs)


class ExtensionOptionError(DataError):
    pass


class BadOptionError(ExtensionOptionError):
    pass


class BadOptionDataError(ExtensionOptionError):
    pass


class DuplicateOptionError(ExtensionOptionError):
    pass


def extract_extension_options(field_list: nodes.field_list,
                              options_spec: dict[str, Callable[[Any], Any]]) -> dict[str, Any]:
    """Converted option values of a field list (directive options)."""
    return assemble_option_dict(extract_options(field_list), options_spec)


def extract_options(field_list: nodes.field_list) -> list[tuple[str, str | None]]:
    """(name, value) pairs of a flat field list with single-paragraph bodies."""
    option_list = []
    for field in field_list:
        if len(field[0].astext().split()) != 1:
            raise BadOptionError("extension option field name may not contain multiple words")
        name = str(field[0].astext().lower())
        body = field[1]
        if len(body) == 0:
            data = None
        elif (len(body) > 1 or not isinstance(body[0], nodes.paragraph)
              or len(body[0]) != 1 or not isinstance(body[0][0], nodes.Text)):
            raise BadOptionDataError("extension option field body may contain\n"
                                     'a single paragraph only (option "%s")' % name)
        else:
            data = body[0][0].astext()
        option_list.append((name, data))
    return option_list


def assemble_option_dict(option_list: list[tuple[str, str | None]],
                         options_spec: dict[str, Callable[[Any], Any]]) -> dict[str, Any]:
    """Map option names to converted values (KeyError for unknown options)."""
    options: dict[str, Any] = {}
    for name, value in option_list:
        convertor = options_spec[name]
        if convertor is None:
            raise KeyError(name)
        if name in options:
            raise DuplicateOptionError('duplicate option "%s"' % name)
        try:
            options[name] = convertor(value)
        except (ValueError, TypeError) as detail:
            raise detail.__class__('(option: "%s"; value: %r)\n%s'
                                   % (name, value, " ".join(detail.args))) from None
    return options


class NameValueError(DataError):
    pass


def decode_path(path: str | bytes | None) -> str:
    """Ensure `path` is a str (decode bytes with the file system encoding)."""
    if isinstance(path, str):
        return path
    if path is None:
        return ""
    try:
        return path.decode(sys.getfilesystemencoding(), "strict")
    except AttributeError:
        raise ValueError(f"`path` value must be a String or ``None``, not {path!r}") from None
    except UnicodeDecodeError:
        try:
            return path.decode("utf-8", "strict")
        except UnicodeDecodeError:
            return path.decode("ascii", "replace")


def _name_value_pair(line: str) -> tuple[str, str, str]:
    """Parse one ``name=value`` pair; return (name, value, rest of line)."""
    equals_index = line.find("=")
    if equals_index == -1:
        raise NameValueError('missing "="')
    attname = line[:equals_index].strip()
    if equals_index == 0 or not attname:
        raise NameValueError('missing attribute name before "="')
    line = line[equals_index + 1:].lstrip()
    if not line:
        raise NameValueError(f'missing value after "{attname}="')
    if line[0] in "'\"":
        endquote_index = line.find(line[0], 1)
        if endquote_index == -1:
            raise NameValueError(f'attribute "{attname}" missing end quote ({line[0]})')
        if len(line) > endquote_index + 1 and line[endquote_index + 1].strip():
            raise NameValueError(f'attribute "{attname}" end quote ({line[0]}) '
                                 "not followed by whitespace")
        return attname, line[1:endquote_index], line[endquote_index + 1:].lstrip()
    space_index = line.find(" ")
    if space_index == -1:
        return attname, line, ""
    return attname, line[:space_index], line[space_index + 1:].lstrip()


def extract_name_value(line: str) -> list[tuple[str, str]]:
    """List of (name, value) pairs of a ``name=value`` attribute list."""
    attlist = []
    while line:
        attname, data, line = _name_value_pair(line)
        attlist.append((attname.lower(), data))
    return attlist


def new_reporter(source_path: str, settings: Any) -> Reporter:
    """Return a new Reporter configured by `settings`."""
    return Reporter(source_path, settings.report_level, settings.halt_level,
                    stream=settings.warning_stream, debug=settings.debug,
                    encoding=settings.error_encoding,
                    error_handler=settings.error_encoding_error_handler)


def new_document(source_path: str, settings: Any = None) -> nodes.document:
    """Return a new empty document object ready for parsing."""
    from docutils import frontend

    if settings is None:
        settings = frontend.get_default_settings()
    reporter = new_reporter(source_path, settings)
    document = nodes.document(settings, reporter, source=source_path)
    document.note_source(source_path, -1)
    return document


def clean_rcs_keywords(paragraph: nodes.paragraph,
                       keyword_substitutions: Iterable[tuple[re.Pattern[str], str]]) -> None:
    if len(paragraph) == 1 and isinstance(paragraph[0], nodes.Text):
        textnode = paragraph[0]
        for pattern, substitution in keyword_substitutions:
            if pattern.search(textnode):
                paragraph[0] = nodes.Text(pattern.sub(substitution, textnode))
                return


def relative_path(source: str | None, target: str) -> str:
    """URL-style path from `source` to `target` (both file paths)."""
    source_parts = os.path.abspath(source or type(target)("dummy_file")).split(os.sep)
    target_parts = os.path.abspath(target).split(os.sep)
    if source_parts[:2] != target_parts[:2]:
        return "/".join(target_parts)
    source_parts.reverse()
    target_parts.reverse()
    while source_parts and target_parts and source_parts[-1] == target_parts[-1]:
        source_parts.pop()
        target_parts.pop()
    target_parts.reverse()
    return "/".join([".."] * (len(source_parts) - 1) + target_parts)


def get_stylesheet_reference(settings: Any, relative_to: str | None = None) -> str:
    warnings.warn("utils.get_stylesheet_reference() is obsoleted by utils.get_stylesheet_list() "
                  "and will be removed in Docutils 2.0.", DeprecationWarning, stacklevel=2)
    if settings.stylesheet_path:
        assert not settings.stylesheet, "stylesheet and stylesheet_path are mutually exclusive."
        if relative_to is None:
            relative_to = settings.output_path
        return relative_path(relative_to, settings.stylesheet_path)
    return settings.stylesheet


def get_stylesheet_list(settings: Any) -> list[str]:
    """List of stylesheets (paths resolved against ``stylesheet_dirs``)."""
    assert not (settings.stylesheet and settings.stylesheet_path), (
        "stylesheet and stylesheet_path are mutually exclusive.")
    stylesheets = settings.stylesheet_path or settings.stylesheet or []
    if not isinstance(stylesheets, list):
        stylesheets = [path.strip() for path in stylesheets.split(",")]
    if settings.stylesheet_path:
        stylesheets = [find_file_in_dirs(path, settings.stylesheet_dirs) for path in stylesheets]
    return stylesheets


def find_file_in_dirs(path: str | PurePath, dirs: Iterable[str]) -> str:
    """Return the first existing ``dir/path`` (as posix path) or `path` itself."""
    path = Path(path)
    if path.is_absolute():
        return path.as_posix()
    for directory in dirs:
        candidate = Path(directory).expanduser() / path
        if candidate.exists():
            return candidate.as_posix()
    return path.as_posix()


def get_trim_footnote_ref_space(settings: Any) -> bool:
    """Whether to trim the space before footnote references."""
    if settings.setdefault("trim_footnote_reference_space", None) is None:
        return getattr(settings, "footnote_references", None) == "superscript"
    return settings.trim_footnote_reference_space


def get_source_line(node: nodes.Node | None) -> tuple[str | None, int | None]:
    """(source, line) of `node` or of its closest ancestor that has them."""
    while node:
        if node.source or node.line:
            return node.source, node.line
        node = node.parent
    return None, None


def escape2null(text: str) -> str:
    """Return a string with escape-backslashes converted to nulls."""
    parts = []
    start = 0
    while True:
        bs_index = text.find("\\", start)
        if bs_index == -1:
            parts.append(text[start:])
            return "".join(parts)
        parts.extend((text[start:bs_index], "\x00" + text[bs_index + 1:bs_index + 2]))
        start = bs_index + 2


def split_escaped_whitespace(text: str) -> list[str]:
    """Split at escaped whitespace (null-escaped space or newline)."""
    strings = [string.split("\x00\n") for string in text.split("\x00 ")]
    return list(itertools.chain(*strings))


def strip_combining_chars(text: str) -> str:
    return "".join(c for c in text if not unicodedata.combining(c))


def find_combining_chars(text: str) -> list[int]:
    return [i for i, c in enumerate(text) if unicodedata.combining(c)]


def column_indices(text: str) -> list[int]:
    """Indices of the characters that start a column (not combining)."""
    return [i for i, c in enumerate(text) if not unicodedata.combining(c)]


east_asian_widths = {"W": 2, "F": 2, "Na": 1, "H": 1, "N": 1, "A": 1}


def column_width(text: str) -> int:
    """Width of `text` in columns (wide characters count twice)."""
    width = sum(east_asian_widths[unicodedata.east_asian_width(c)] for c in text)
    return width - len(find_combining_chars(text))


def uniq(items: list) -> list:
    result: list = []
    for item in items:
        if item not in result:
            result.append(item)
    return result


def normalize_language_tag(tag: str) -> list[str]:
    """Return a list of normalized combinations of a BCP 47 language tag."""
    tag = tag.lower().replace("-", "_")
    tag = re.sub(r"_([a-zA-Z0-9])_", r"_\1-", tag)
    subtags = list(tag.split("_"))
    base_tag = (subtags.pop(0),)
    taglist = ["-".join(base_tag + tags) for n in range(len(subtags), 0, -1)
               for tags in itertools.combinations(subtags, n)]
    taglist += base_tag
    return taglist


def xml_declaration(encoding: str | None = None) -> str:
    """Return an XML text declaration (with `encoding` unless "unicode")."""
    if encoding and encoding.lower() != "unicode":
        return f'<?xml version="1.0" encoding="{encoding}"?>\n'
    return '<?xml version="1.0"?>\n'


class DependencyList:
    """List of dependencies, optionally written to a file as they are added."""

    def __init__(self, output_file: str | None = None, dependencies: Iterable[str] = ()) -> None:
        self.set_output(output_file)
        self.add(*dependencies)

    def set_output(self, output_file: str | None) -> None:
        if output_file == "-":
            self.file = sys.stdout
        elif output_file:
            self.file = open(output_file, "w", encoding="utf-8")  # noqa: SIM115
        else:
            self.file = None
        self.list: list[str] = []

    def add(self, *paths: str | PurePath) -> None:
        for path in paths:
            if isinstance(path, PurePath):
                path = path.as_posix()
            if path not in self.list:
                self.list.append(path)
                if self.file is not None:
                    self.file.write(path + "\n")

    def close(self) -> None:
        if self.file is not sys.stdout:
            self.file.close()
        self.file = None

    def __repr__(self) -> str:
        try:
            output_file = self.file.name
        except AttributeError:
            output_file = None
        return "%s(%r, %s)" % (self.__class__.__name__, output_file, self.list)
