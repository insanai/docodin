"""Calling the ``publish_*`` convenience functions (or instantiating a
`Publisher` object) with component names results in default behavior.
"""

from __future__ import annotations

import locale
import os
import pprint
import sys
import warnings
from typing import Any

from docutils import (
    SettingsSpec,
    __version__,
    __version_details__,
    io,
    parsers,
    readers,
    utils,
    writers,
)
from docutils.frontend import OptionParser
from docutils.readers import doctree

__docformat__ = "reStructuredText"


class Publisher:
    """Set up and run a reader -> parser -> transforms -> writer pipeline."""

    def __init__(self, reader: Any = None, parser: Any = None, writer: Any = None,
                 source: Any = None, source_class: type = io.FileInput, destination: Any = None,
                 destination_class: type = io.FileOutput, settings: Any = None) -> None:
        if isinstance(reader, str):
            reader = readers.get_reader_class(reader)(parser)
        if isinstance(parser, str):
            if isinstance(reader, readers.Reader):
                if reader.parser is None:
                    reader.set_parser(parser)
                parser = reader.parser
            else:
                parser = parsers.get_parser_class(parser)()
        if isinstance(writer, str):
            writer = writers.get_writer_class(writer)()
        self.document: Any = None
        self.reader = reader
        self.parser = parser
        self.writer = writer
        self.source = source
        self.source_class = source_class
        self.destination = destination
        self.destination_class = destination_class
        self.settings = settings
        self._stderr = io.ErrorOutput()

    def set_reader(self, reader: str, parser: Any = None, parser_name: str | None = None) -> None:
        reader_class = readers.get_reader_class(reader)
        self.reader = reader_class(parser, parser_name)
        if self.reader.parser is not None:
            self.parser = self.reader.parser
        elif self.parser is not None:
            self.reader.parser = self.parser

    def set_writer(self, writer_name: str) -> None:
        self.writer = writers.get_writer_class(writer_name)()

    def set_components(self, reader_name: str, parser_name: str, writer_name: str) -> None:
        warnings.warn("`Publisher.set_components()` will be removed in Docutils 2.0.  "
                      "Specify component names at instantiation.",
                      PendingDeprecationWarning, stacklevel=2)
        if self.reader is None:
            self.set_reader(reader_name, self.parser, parser_name)
        if self.parser is None:
            if self.reader.parser is None:
                self.reader.set_parser(parser_name)
            self.parser = self.reader.parser
        if self.writer is None:
            self.set_writer(writer_name)

    def _setup_settings_parser(self, usage: str | None = None, description: str | None = None,
                               settings_spec: Any = None, config_section: str | None = None,
                               **defaults: Any) -> OptionParser:
        with warnings.catch_warnings():
            warnings.filterwarnings("ignore", category=DeprecationWarning)
            if config_section:
                if not settings_spec:
                    settings_spec = SettingsSpec()
                settings_spec.config_section = config_section
                parts = config_section.split()
                if len(parts) > 1 and parts[-1] == "application":
                    settings_spec.config_section_dependencies = ["applications"]
            return OptionParser(
                components=(self.parser, self.reader, self.writer, settings_spec),
                defaults=defaults, read_config_files=True, usage=usage, description=description)

    def get_settings(self, usage: str | None = None, description: str | None = None,
                     settings_spec: Any = None, config_section: str | None = None,
                     **defaults: Any) -> Any:
        """Return settings from components, config files and `defaults`."""
        option_parser = self._setup_settings_parser(usage, description, settings_spec,
                                                    config_section, **defaults)
        self.settings = option_parser.get_default_values()
        return self.settings

    def process_programmatic_settings(self, settings_spec: Any, settings_overrides: Any,
                                      config_section: str | None) -> None:
        if self.settings is None:
            defaults = settings_overrides.copy() if settings_overrides else {}
            defaults.setdefault("traceback", True)
            self.get_settings(settings_spec=settings_spec, config_section=config_section,
                              **defaults)

    def process_command_line(self, argv: list[str] | None = None, usage: str | None = None,
                             description: str | None = None, settings_spec: Any = None,
                             config_section: str | None = None, **defaults: Any) -> None:
        """Set settings from command-line arguments (default: ``sys.argv[1:]``)."""
        option_parser = self._setup_settings_parser(usage, description, settings_spec,
                                                    config_section, **defaults)
        if argv is None:
            argv = sys.argv[1:]
        self.settings = option_parser.parse_args(argv)

    def set_io(self, source_path: str | None = None, destination_path: str | None = None) -> None:
        if self.source is None:
            self.set_source(source_path=source_path)
        if self.destination is None:
            self.set_destination(destination_path=destination_path)

    def set_source(self, source: Any = None, source_path: Any = None) -> None:
        if source_path is None:
            source_path = self.settings._source
        else:
            source_path = os.fspath(source_path)
            self.settings._source = source_path
        self.source = self.source_class(source=source, source_path=source_path,
                                        encoding=self.settings.input_encoding,
                                        error_handler=self.settings.input_encoding_error_handler)

    def set_destination(self, destination: Any = None, destination_path: Any = None) -> None:
        settings = self.settings
        if destination_path is not None:
            settings.output_path = os.fspath(destination_path)
        else:
            if getattr(settings, "output", None) and not settings.output_path:
                settings.output_path = settings.output
            if (settings.output_path and settings._destination
                    and settings.output_path != settings._destination):
                raise SystemExit("The --output-path option obsoletes the second positional "
                                 "argument (DESTINATION). You cannot use them together.")
            if settings.output_path is None:
                settings.output_path = settings._destination
            if settings.output_path == "-":
                settings.output_path = None
        settings._destination = settings.output = settings.output_path
        self.destination = self.destination_class(
            destination=destination, destination_path=settings.output_path,
            encoding=settings.output_encoding,
            error_handler=settings.output_encoding_error_handler)

    def apply_transforms(self) -> None:
        self.document.transformer.populate_from_components(
            (self.source, self.reader, self.reader.parser, self.writer, self.destination))
        self.document.transformer.apply_transforms()

    def publish(self, argv: list[str] | None = None, usage: str | None = None,
                description: str | None = None, settings_spec: Any = None,
                settings_overrides: Any = None, config_section: str | None = None,
                enable_exit_status: bool = False) -> Any:
        """Process command line options and arguments (if `self.settings` not
        already set), run `self.reader` and then `self.writer`.  Return
        `self.writer`'s output."""
        exit_status = None
        output = None
        try:
            if self.settings is None:
                self.process_command_line(argv, usage, description, settings_spec,
                                          config_section, **settings_overrides or {})
            self.set_io()
            self.prompt()
            self.document = self.reader.read(self.source, self.parser, self.settings)
            self.apply_transforms()
            output = self.writer.write(self.document, self.destination)
            self.writer.assemble_parts()
        except SystemExit as error:
            exit_status = (error.code,)
        except Exception as error:
            if not self.settings:
                raise
            if self.settings.traceback:
                self.debugging_dumps()
                raise
            self.report_Exception(error)
            exit_status = (1,)
        self.debugging_dumps()
        if (enable_exit_status and self.document
                and self.document.reporter.max_level >= self.settings.exit_status_level):
            sys.exit(self.document.reporter.max_level + 10)
        elif exit_status is not None:
            sys.exit(exit_status[0])
        return output

    def debugging_dumps(self) -> None:
        if not self.document:
            return
        settings = self.settings
        if settings.dump_settings:
            print("\n::: Runtime settings:", file=self._stderr)
            print(pprint.pformat(settings.__dict__), file=self._stderr)
        if settings.dump_internals:
            print("\n::: Document internals:", file=self._stderr)
            print(pprint.pformat(self.document.__dict__), file=self._stderr)
        if settings.dump_transforms:
            print("\n::: Transforms applied:", file=self._stderr)
            print(" (priority, transform class, pending node details, keyword args)",
                  file=self._stderr)
            applied = [(priority, "%s.%s" % (xclass.__module__, xclass.__name__),
                        pending and pending.details, kwargs)
                       for priority, xclass, pending, kwargs in self.document.transformer.applied]
            print(pprint.pformat(applied), file=self._stderr)
        if settings.dump_pseudo_xml:
            print("\n::: Pseudo-XML:", file=self._stderr)
            print(self.document.pformat().encode("raw_unicode_escape"), file=self._stderr)

    def prompt(self) -> None:
        """Print info and prompt when waiting for input from a terminal."""
        try:
            if not (self.source.isatty() and self._stderr.isatty()):
                return
        except AttributeError:
            return
        eot_key = "Ctrl+Z" if os.name == "nt" else "Ctrl+D"
        try:
            in_format, out_format = self.parser.supported[0], self.writer.supported[0]
        except (AttributeError, IndexError):
            in_format, out_format = "", "useful formats"
        print(f"Docutils {__version__} <https://docutils.sourceforge.io>\n"
              f'converting "{in_format}" into "{out_format}".\n'
              'Call with option "--help" for more info.\n'
              f".. Waiting for source text (finish with {eot_key} on an empty line):",
              file=self._stderr)

    def report_Exception(self, error: Exception) -> None:  # noqa: N802 - docutils name
        if isinstance(error, utils.SystemMessage):
            self.report_SystemMessage(error)
        elif isinstance(error, UnicodeEncodeError):
            self.report_UnicodeError(error)
        elif isinstance(error, io.InputError):
            self._stderr.write("Unable to open source file for reading:\n  %s\n"
                               % io.error_string(error))
        elif isinstance(error, io.OutputError):
            self._stderr.write("Unable to open destination file for writing:\n  %s\n"
                               % io.error_string(error))
        else:
            details = f" [{__version_details__}]" if __version_details__ else ""
            print("%s" % io.error_string(error), file=self._stderr)
            print('Exiting due to error.  Use "--traceback" to diagnose.\n'
                  "Please report errors to <docutils-users@lists.sourceforge.net>.\n"
                  f'Include "--traceback" output, Docutils version ({__version__}{details}),\n'
                  f"Python version ({sys.version.split()[0]}), your OS type & version, and the "
                  "command line used.", file=self._stderr)

    def report_SystemMessage(self, error: utils.SystemMessage) -> None:  # noqa: N802
        print("Exiting due to level-%s (%s) system message."
              % (error.level, utils.Reporter.levels[error.level]), file=self._stderr)

    def report_UnicodeError(self, error: UnicodeEncodeError) -> None:  # noqa: N802
        data = error.object[error.start:error.end]
        self._stderr.write(
            "%s\n\nThe specified output encoding (%s) cannot\nhandle all of the output.\n"
            'Try setting "--output-encoding-error-handler" to\n\n'
            '* "xmlcharrefreplace" (for HTML & XML output);\n'
            '  the output will contain "%s" and should be usable.\n'
            '* "backslashreplace" (for other output formats);\n'
            '  look for "%s" in the output.\n* "replace"; look for "?" in the output.\n\n'
            '"--output-encoding-error-handler" is currently set to "%s".\n\n'
            'Exiting due to error.  Use "--traceback" to diagnose.\n'
            "If the advice above doesn't eliminate the error,\n"
            "please report it to <docutils-users@lists.sourceforge.net>.\n"
            'Include "--traceback" output, Docutils version (%s),\n'
            "Python version (%s), your OS type & version, and the\ncommand line used.\n"
            % (io.error_string(error), self.settings.output_encoding,
               data.encode("ascii", "xmlcharrefreplace"), data.encode("ascii", "backslashreplace"),
               self.settings.output_encoding_error_handler, __version__,
               sys.version.split()[0]))


default_usage = "%prog [options] [<source> [<destination>]]"
default_description = ("Reads from <source> (default is stdin) and writes to <destination> "
                       "(default is stdout).  See https://docutils.sourceforge.io/docs/user/"
                       "config.html for a detailed settings reference.")


def publish_cmdline(reader: Any = None, reader_name: str | None = None, parser: Any = None,
                    parser_name: str | None = None, writer: Any = None,
                    writer_name: str | None = None, settings: Any = None,
                    settings_spec: Any = None, settings_overrides: Any = None,
                    config_section: str | None = None, enable_exit_status: bool = True,
                    argv: list[str] | None = None, usage: str = default_usage,
                    description: str = default_description) -> Any:
    """Set up & run a `Publisher` for command-line-based file I/O."""
    _name_arg_warning(reader_name, parser_name, writer_name)
    publisher = Publisher(reader or reader_name or "standalone",
                          parser or parser_name or "restructuredtext",
                          writer or writer_name or "pseudoxml", settings=settings)
    return publisher.publish(argv, usage, description, settings_spec, settings_overrides,
                             config_section=config_section,
                             enable_exit_status=enable_exit_status)


def publish_file(source: Any = None, source_path: Any = None, destination: Any = None,
                 destination_path: Any = None, reader: Any = None, reader_name: str | None = None,
                 parser: Any = None, parser_name: str | None = None, writer: Any = None,
                 writer_name: str | None = None, settings: Any = None, settings_spec: Any = None,
                 settings_overrides: Any = None, config_section: str | None = None,
                 enable_exit_status: bool = False) -> Any:
    """Set up & run a `Publisher` for programmatic use with file-like I/O."""
    _name_arg_warning(reader_name, parser_name, writer_name)
    output, _publisher = publish_programmatically(
        io.FileInput, source, source_path, io.FileOutput, destination, destination_path,
        reader, reader_name, parser, parser_name, writer, writer_name, settings,
        settings_spec, settings_overrides, config_section, enable_exit_status)
    return output


def publish_string(source: Any, source_path: Any = None, destination_path: Any = None,
                   reader: Any = None, reader_name: str | None = None, parser: Any = None,
                   parser_name: str | None = None, writer: Any = None,
                   writer_name: str | None = None, settings: Any = None,
                   settings_spec: Any = None, settings_overrides: Any = None,
                   config_section: str | None = None, enable_exit_status: bool = False) -> Any:
    """Set up & run a `Publisher` for programmatic use with string I/O."""
    _name_arg_warning(reader_name, parser_name, writer_name)
    output, _publisher = publish_programmatically(
        io.StringInput, source, source_path, io.StringOutput, None, destination_path,
        reader, reader_name, parser, parser_name, writer, writer_name, settings,
        settings_spec, settings_overrides, config_section, enable_exit_status)
    return output


def publish_parts(source: Any, source_path: Any = None, source_class: type = io.StringInput,
                  destination_path: Any = None, reader: Any = None,
                  reader_name: str | None = None, parser: Any = None,
                  parser_name: str | None = None, writer: Any = None,
                  writer_name: str | None = None, settings: Any = None,
                  settings_spec: Any = None, settings_overrides: Any = None,
                  config_section: str | None = None,
                  enable_exit_status: bool = False) -> dict[str, Any]:
    """Return the document parts of the writer (a dictionary)."""
    _name_arg_warning(reader_name, parser_name, writer_name)
    _output, publisher = publish_programmatically(
        source_class, source, source_path, io.StringOutput, None, destination_path,
        reader, reader_name, parser, parser_name, writer, writer_name, settings,
        settings_spec, settings_overrides, config_section, enable_exit_status)
    return publisher.writer.parts


def publish_doctree(source: Any, source_path: Any = None, source_class: type = io.StringInput,
                    reader: Any = None, reader_name: str | None = None, parser: Any = None,
                    parser_name: str | None = None, settings: Any = None,
                    settings_spec: Any = None, settings_overrides: Any = None,
                    config_section: str | None = None, enable_exit_status: bool = False) -> Any:
    """Return the document tree after reading, parsing and transforming."""
    _name_arg_warning(reader_name, parser_name, None)
    _output, publisher = publish_programmatically(
        source_class, source, source_path, io.NullOutput, None, None, reader, reader_name,
        parser, parser_name, "null", None, settings, settings_spec, settings_overrides,
        config_section, enable_exit_status)
    return publisher.document


def publish_from_doctree(document: Any, destination_path: Any = None, writer: Any = None,
                         writer_name: str | None = None, settings: Any = None,
                         settings_spec: Any = None, settings_overrides: Any = None,
                         config_section: str | None = None,
                         enable_exit_status: bool = False) -> Any:
    """Render an existing document tree with a writer."""
    _name_arg_warning(None, None, writer_name)
    publisher = Publisher(reader=doctree.Reader(), writer=writer or writer_name or "pseudoxml",
                          source=io.DocTreeInput(document), destination_class=io.StringOutput,
                          settings=settings)
    publisher.process_programmatic_settings(settings_spec, settings_overrides, config_section)
    publisher.set_destination(None, destination_path)
    return publisher.publish(enable_exit_status=enable_exit_status)


def publish_cmdline_to_binary(reader: Any = None, reader_name: str = "standalone",
                              parser: Any = None, parser_name: str = "restructuredtext",
                              writer: Any = None, writer_name: str = "pseudoxml",
                              settings: Any = None, settings_spec: Any = None,
                              settings_overrides: Any = None, config_section: str | None = None,
                              enable_exit_status: bool = True, argv: list[str] | None = None,
                              usage: str = default_usage, description: str = default_description,
                              destination: Any = None,
                              destination_class: type = io.BinaryFileOutput) -> Any:
    warnings.warn('"publish_cmdline_to_binary()" is obsoleted by "publish_cmdline()" and will '
                  "be removed in Docutils 0.24.", DeprecationWarning, stacklevel=2)
    publisher = Publisher(reader, parser, writer, settings=settings,
                          destination_class=destination_class)
    publisher.set_components(reader_name, parser_name, writer_name)
    return publisher.publish(argv, usage, description, settings_spec, settings_overrides,
                             config_section=config_section,
                             enable_exit_status=enable_exit_status)


def _name_arg_warning(*name_args: str | None) -> None:
    for component, name_arg in zip(("reader", "parser", "writer"), name_args, strict=False):
        if name_arg is not None:
            warnings.warn(f'Argument "{component}_name" will be removed in Docutils 2.0.  '
                          f'Specify {component} name in the "{component}" argument.',
                          PendingDeprecationWarning, stacklevel=3)


def publish_programmatically(source_class: type, source: Any, source_path: Any,
                             destination_class: type, destination: Any, destination_path: Any,
                             reader: Any, reader_name: str | None, parser: Any,
                             parser_name: str | None, writer: Any, writer_name: str | None,
                             settings: Any, settings_spec: Any, settings_overrides: Any,
                             config_section: str | None,
                             enable_exit_status: bool) -> tuple[Any, Publisher]:
    """Set up & run a `Publisher` for custom programmatic use; return (output, publisher)."""
    publisher = Publisher(reader or reader_name or "standalone",
                          parser or parser_name or "restructuredtext",
                          writer or writer_name or "pseudoxml", settings=settings,
                          source_class=source_class, destination_class=destination_class)
    publisher.process_programmatic_settings(settings_spec, settings_overrides, config_section)
    publisher.set_source(source, source_path)
    publisher.set_destination(destination, destination_path)
    output = publisher.publish(enable_exit_status=enable_exit_status)
    return output, publisher


def rst2something(writer: str, documenttype: str, doc_path: str = "") -> None:
    description = (f"Generate {documenttype} documents from standalone reStructuredText "
                   f"sources <https://docutils.sourceforge.io/docs/{doc_path}>.  "
                   + default_description)
    try:
        locale.setlocale(locale.LC_ALL, "")
    except locale.Error as e:
        sys.stderr.write(f"WARNING: Cannot set the default locale: {e}.\n")
    publish_cmdline(writer=writer, description=description)


def rst2html() -> None:
    rst2something("html", "HTML", "user/html.html#html")


def rst2html4() -> None:
    rst2something("html4", "XHTML 1.1", "user/html.html#html4css1")


def rst2html5() -> None:
    rst2something("html5", "HTML5", "user/html.html#html5-polyglot")


def rst2latex() -> None:
    rst2something("latex", "LaTeX", "user/latex.html")


def rst2man() -> None:
    rst2something("manpage", "Unix manual (troff)", "user/manpage.html")


def rst2odt() -> None:
    rst2something("odt", "OpenDocument text (ODT)", "user/odt.html")


def rst2pseudoxml() -> None:
    rst2something("pseudoxml", "pseudo-XML (test)", "ref/doctree.html")


def rst2s5() -> None:
    rst2something("s5", "S5 HTML slideshow", "user/slide-shows.html")


def rst2xetex() -> None:
    rst2something("xetex", "LaTeX (XeLaTeX/LuaLaTeX)", "user/latex.html")


def rst2xml() -> None:
    rst2something("xml", "Docutils-native XML", "ref/doctree.html")
