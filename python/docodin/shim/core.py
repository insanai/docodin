"""Docutils core drop-in implementation for docodin."""

from __future__ import annotations

import io
import sys
from typing import Any

from docodin.shim import frontend, utils, writers
from docodin.shim.parsers.rst import Parser

default_usage = "%prog [options] [<source> [<destination>]]"
default_description = "Generates documents from reStructuredText sources."


class Publisher:
    """Core docutils publisher object that coordinates parser, writer, and reader.

    Attributes:
        reader: Input reader component.
        parser: Parser instance (defaults to DocOdin Parser).
        writer: Writer instance for rendering output.
        source: Source content or stream.
        destination: Output destination stream.
        settings: Runtime configuration settings.
        document: Document tree generated after parse.
    """

    def __init__(
        self,
        reader: Any = None,
        parser: Any = None,
        writer: Any = None,
        source: Any = None,
        destination: Any = None,
        settings: Any = None,
    ) -> None:
        self.reader = reader
        self.parser = parser or Parser()
        self.writer = writer
        self.source = source
        self.destination = destination
        self.settings = settings
        self.document: Any = None

    def set_reader(self, reader_name: str, parser: Any = None, parser_name: str | None = None) -> None:
        """Set the reader component and its parser."""
        if parser:
            self.parser = parser

    def set_writer(self, writer_name: str | Any) -> None:
        """Set the writer component by name or instance."""
        if isinstance(writer_name, str):
            writer_cls = writers.get_writer_class(writer_name)
            self.writer = writer_cls()
        else:
            self.writer = writer_name

    def set_components(
        self,
        reader_name: str = "standalone",
        parser_name: str = "restructuredtext",
        writer_name: str = "pseudoxml",
    ) -> None:
        """Set reader, parser, and writer components together."""
        self.set_reader(reader_name, parser_name=parser_name)
        self.set_writer(writer_name)

    def get_settings(self, *components: Any) -> frontend.Values:
        """Get default settings for publisher and configured components."""
        comps = list(components)
        if self.parser:
            comps.append(self.parser)
        if self.writer:
            comps.append(self.writer)
        return frontend.get_default_settings(*comps)

    def process_programmatic_settings(
        self,
        settings_spec: Any,
        settings_overrides: dict[str, Any] | None,
        config_section: str | None,
    ) -> None:
        """Process and merge programmatic settings overrides."""
        if self.settings is None:
            self.settings = self.get_settings()
        if settings_overrides:
            self.settings.update(settings_overrides)

    def set_source(self, source: Any = None, source_path: str | None = None) -> None:
        """Set document source input string or path."""
        self.source = source
        self.source_path = source_path

    def set_destination(self, destination: Any = None, destination_path: str | None = None) -> None:
        """Set document output destination stream or path."""
        self.destination = destination
        self.destination_path = destination_path

    def apply_transforms(self) -> None:
        """Apply registered transforms to the document tree."""
        if self.document and hasattr(self.document, "transformer"):
            self.document.transformer.apply_transforms()

    def publish(
        self,
        argv: list[str] | None = None,
        usage: str | None = None,
        description: str | None = None,
        settings_spec: Any = None,
        settings_overrides: dict[str, Any] | None = None,
        config_section: str | None = None,
        enable_exit_status: bool = False,
    ) -> Any:
        """Execute the parse and translation pipeline.

        Args:
            argv: Optional list of command-line arguments.
            usage: Usage string for option parser.
            description: Description string for option parser.
            settings_spec: Settings specification tuple.
            settings_overrides: Dictionary of settings overrides.
            config_section: Optional configuration section name.
            enable_exit_status: Whether to exit on error status.

        Returns:
            Rendered document output.
        """
        self.process_programmatic_settings(settings_spec, settings_overrides, config_section)
        src_text = self.source
        if hasattr(src_text, "read"):
            src_text = src_text.read()
        if isinstance(src_text, bytes):
            src_text = src_text.decode(getattr(self.settings, "input_encoding", "utf-8"))

        source_path = getattr(self, "source_path", None) or "<string>"
        self.document = utils.new_document(source_path, self.settings)
        self.parser.parse(src_text, self.document)
        self.apply_transforms()

        if self.writer is None:
            self.set_writer("pseudoxml")

        output = self.writer.write(self.document, self.destination)
        return output


def _publish(
    source: Any,
    source_path: str | None,
    destination: Any,
    destination_path: str | None,
    reader: Any,
    reader_name: str,
    parser: Any,
    parser_name: str,
    writer: Any,
    writer_name: str,
    settings: Any,
    settings_spec: Any,
    settings_overrides: dict[str, Any] | None,
    config_section: str | None,
    enable_exit_status: bool,
) -> Publisher:
    pub = Publisher(reader=reader, parser=parser or Parser(), settings=settings)
    pub.set_writer(writer or writer_name)
    pub.set_source(source=source, source_path=source_path)
    pub.set_destination(destination=destination, destination_path=destination_path)
    pub.publish(
        settings_spec=settings_spec,
        settings_overrides=settings_overrides,
        config_section=config_section,
        enable_exit_status=enable_exit_status,
    )
    return pub


def publish_cmdline(
    reader: Any = None,
    reader_name: str = "standalone",
    parser: Any = None,
    parser_name: str = "restructuredtext",
    writer: Any = None,
    writer_name: str = "pseudoxml",
    settings: Any = None,
    settings_spec: Any = None,
    settings_overrides: dict[str, Any] | None = None,
    config_section: str | None = None,
    enable_exit_status: bool = False,
    argv: list[str] | None = None,
    usage: str = default_usage,
    description: str = default_description,
) -> Any:
    """Publish output from command-line arguments.

    Args:
        reader: Reader component.
        reader_name: Reader name identifier.
        parser: Parser instance.
        parser_name: Parser name identifier.
        writer: Writer component.
        writer_name: Writer name identifier.
        settings: Pre-configured settings.
        settings_spec: Settings specification.
        settings_overrides: Settings override dictionary.
        config_section: Configuration section name.
        enable_exit_status: Whether to exit on error.
        argv: Command-line arguments list.
        usage: Usage description.
        description: Command description.

    Returns:
        Rendered output content.
    """
    args = sys.argv[1:] if argv is None else argv
    source = "-"
    destination = "-"
    if len(args) >= 1 and not args[0].startswith("-"):
        source = args[0]
    if len(args) >= 2 and not args[1].startswith("-"):
        destination = args[1]

    src_content = sys.stdin.read() if source == "-" else open(source, "r", encoding="utf-8").read()
    dest_stream = sys.stdout if destination == "-" else open(destination, "w", encoding="utf-8")

    pub = _publish(
        source=src_content,
        source_path=source if source != "-" else "<stdin>",
        destination=dest_stream,
        destination_path=destination if destination != "-" else "<stdout>",
        reader=reader,
        reader_name=reader_name,
        parser=parser,
        parser_name=parser_name,
        writer=writer,
        writer_name=writer_name,
        settings=settings,
        settings_spec=settings_spec,
        settings_overrides=settings_overrides,
        config_section=config_section,
        enable_exit_status=enable_exit_status,
    )
    return pub.writer.output


def publish_string(
    source: str | bytes,
    source_path: str | None = None,
    destination_path: str | None = None,
    reader: Any = None,
    reader_name: str = "standalone",
    parser: Any = None,
    parser_name: str = "restructuredtext",
    writer: Any = None,
    writer_name: str = "pseudoxml",
    settings: Any = None,
    settings_spec: Any = None,
    settings_overrides: dict[str, Any] | None = None,
    config_section: str | None = None,
    enable_exit_status: bool = False,
) -> Any:
    """Publish formatted output from a source string.

    Args:
        source: Input markup string or bytes.
        source_path: Source file or stream identifier.
        destination_path: Destination output path.
        reader: Reader component.
        reader_name: Reader name identifier.
        parser: Parser instance.
        parser_name: Parser name identifier.
        writer: Writer component.
        writer_name: Writer name identifier.
        settings: Settings object.
        settings_spec: Settings specification.
        settings_overrides: Settings override dictionary.
        config_section: Configuration section name.
        enable_exit_status: Whether to exit on error.

    Returns:
        Rendered output as bytes or string.
    """
    pub = _publish(
        source=source,
        source_path=source_path,
        destination=None,
        destination_path=destination_path,
        reader=reader,
        reader_name=reader_name,
        parser=parser,
        parser_name=parser_name,
        writer=writer,
        writer_name=writer_name,
        settings=settings,
        settings_spec=settings_spec,
        settings_overrides=settings_overrides,
        config_section=config_section,
        enable_exit_status=enable_exit_status,
    )
    output = pub.writer.output
    out_encoding = getattr(pub.settings, "output_encoding", "utf-8")
    if out_encoding and out_encoding.lower() != "unicode" and isinstance(output, str):
        return output.encode(out_encoding)
    return output


def publish_parts(
    source: str | bytes,
    source_path: str | None = None,
    destination_path: str | None = None,
    reader: Any = None,
    reader_name: str = "standalone",
    parser: Any = None,
    parser_name: str = "restructuredtext",
    writer: Any = None,
    writer_name: str = "pseudoxml",
    settings: Any = None,
    settings_spec: Any = None,
    settings_overrides: dict[str, Any] | None = None,
    config_section: str | None = None,
    enable_exit_status: bool = False,
) -> dict[str, Any]:
    """Publish a dictionary of document parts from source markup.

    Args:
        source: Input markup string or bytes.
        source_path: Source file or stream identifier.
        destination_path: Destination output path.
        reader: Reader component.
        reader_name: Reader name identifier.
        parser: Parser instance.
        parser_name: Parser name identifier.
        writer: Writer component.
        writer_name: Writer name identifier.
        settings: Settings object.
        settings_spec: Settings specification.
        settings_overrides: Settings override dictionary.
        config_section: Configuration section name.
        enable_exit_status: Whether to exit on error.

    Returns:
        Dictionary mapping part names to rendered components.
    """
    pub = _publish(
        source=source,
        source_path=source_path,
        destination=None,
        destination_path=destination_path,
        reader=reader,
        reader_name=reader_name,
        parser=parser,
        parser_name=parser_name,
        writer=writer,
        writer_name=writer_name,
        settings=settings,
        settings_spec=settings_spec,
        settings_overrides=settings_overrides,
        config_section=config_section,
        enable_exit_status=enable_exit_status,
    )
    return pub.writer.parts


def publish_file(
    source: Any = None,
    source_path: str | None = None,
    destination: Any = None,
    destination_path: str | None = None,
    reader: Any = None,
    reader_name: str = "standalone",
    parser: Any = None,
    parser_name: str = "restructuredtext",
    writer: Any = None,
    writer_name: str = "pseudoxml",
    settings: Any = None,
    settings_spec: Any = None,
    settings_overrides: dict[str, Any] | None = None,
    config_section: str | None = None,
    enable_exit_status: bool = False,
) -> Any:
    """Publish output from an input file or stream to an output file or stream.

    Args:
        source: Input file or stream object.
        source_path: Source file path.
        destination: Destination file or stream object.
        destination_path: Destination file path.
        reader: Reader component.
        reader_name: Reader name identifier.
        parser: Parser instance.
        parser_name: Parser name identifier.
        writer: Writer component.
        writer_name: Writer name identifier.
        settings: Settings object.
        settings_spec: Settings specification.
        settings_overrides: Settings override dictionary.
        config_section: Configuration section name.
        enable_exit_status: Whether to exit on error.

    Returns:
        Rendered output.
    """
    pub = _publish(
        source=source,
        source_path=source_path,
        destination=destination,
        destination_path=destination_path,
        reader=reader,
        reader_name=reader_name,
        parser=parser,
        parser_name=parser_name,
        writer=writer,
        writer_name=writer_name,
        settings=settings,
        settings_spec=settings_spec,
        settings_overrides=settings_overrides,
        config_section=config_section,
        enable_exit_status=enable_exit_status,
    )
    return pub.writer.output


def publish_doctree(
    source: str | bytes,
    source_path: str | None = None,
    reader: Any = None,
    reader_name: str = "standalone",
    parser: Any = None,
    parser_name: str = "restructuredtext",
    settings: Any = None,
    settings_spec: Any = None,
    settings_overrides: dict[str, Any] | None = None,
    config_section: str | None = None,
    enable_exit_status: bool = False,
) -> Any:
    """Publish document tree from source markup.

    Args:
        source: Input markup string or bytes.
        source_path: Source file or stream identifier.
        reader: Reader component.
        reader_name: Reader name identifier.
        parser: Parser instance.
        parser_name: Parser name identifier.
        settings: Settings object.
        settings_spec: Settings specification.
        settings_overrides: Settings override dictionary.
        config_section: Configuration section name.
        enable_exit_status: Whether to exit on error.

    Returns:
        The generated document tree.
    """
    pub = Publisher(reader=reader, parser=parser or Parser(), settings=settings)
    pub.set_source(source=source, source_path=source_path)
    pub.process_programmatic_settings(settings_spec, settings_overrides, config_section)
    src_text = source.decode("utf-8") if isinstance(source, bytes) else source
    pub.document = utils.new_document(source_path or "<string>", pub.settings)
    pub.parser.parse(src_text, pub.document)
    pub.apply_transforms()
    return pub.document


def publish_from_doctree(
    document: Any,
    destination_path: str | None = None,
    writer: Any = None,
    writer_name: str = "pseudoxml",
    settings: Any = None,
    settings_spec: Any = None,
    settings_overrides: dict[str, Any] | None = None,
    config_section: str | None = None,
    enable_exit_status: bool = False,
) -> Any:
    """Publish rendered document output directly from an existing document tree.

    Args:
        document: Document tree instance.
        destination_path: Destination output path.
        writer: Writer component.
        writer_name: Writer name identifier.
        settings: Settings object.
        settings_spec: Settings specification.
        settings_overrides: Settings override dictionary.
        config_section: Configuration section name.
        enable_exit_status: Whether to exit on error.

    Returns:
        Rendered output from writer.
    """
    pub = Publisher(writer=writer, settings=settings)
    pub.set_writer(writer or writer_name)
    pub.process_programmatic_settings(settings_spec, settings_overrides, config_section)
    pub.document = document
    return pub.writer.write(document, None)
