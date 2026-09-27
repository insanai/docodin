"""Directives for table elements."""

from __future__ import annotations

import csv
import warnings
from collections.abc import Iterable, Sequence
from typing import Any
from urllib.error import URLError
from urllib.request import urlopen

from docutils import nodes, statemachine
from docutils.io import FileInput, StringInput
from docutils.parsers.rst import Directive, directives
from docutils.parsers.rst.directives.misc import adapt_path
from docutils.utils import SystemMessagePropagation

__docformat__ = "reStructuredText"


def align(argument: str) -> str:
    return directives.choice(argument, ("left", "center", "right"))


class Table(Directive):
    """Generic table base class."""

    optional_arguments = 1
    final_argument_whitespace = True
    option_spec = {
        "class": directives.class_option,
        "name": directives.unchanged,
        "align": align,
        "width": directives.length_or_percentage_or_unitless,
        "widths": directives.value_or(("auto", "grid"), directives.positive_int_list),
    }
    has_content = True

    def make_title(self) -> tuple[nodes.title | None, list[nodes.system_message]]:
        if self.arguments:
            title_text = self.arguments[0]
            text_nodes, messages = self.state.inline_text(title_text, self.lineno)
            title = nodes.title(title_text, "", *text_nodes)
            title.source, title.line = self.state_machine.get_source_and_line(self.lineno)
            return title, messages
        return None, []

    def literal_error(self, message: str, level: str = "error") -> nodes.system_message:
        """Report `message` with the directive's block text as a literal block."""
        report = getattr(self.reporter, level)
        return report(message, nodes.literal_block(self.block_text, self.block_text),
                      line=self.lineno)

    def check_table_dimensions(self, rows: list, header_rows: int, stub_columns: int) -> None:
        if len(rows) < header_rows:
            raise SystemMessagePropagation(self.literal_error(
                '%s header row(s) specified but only %s row(s) of data supplied ("%s" directive).'
                % (header_rows, len(rows), self.name)))
        if len(rows) == header_rows > 0:
            raise SystemMessagePropagation(self.literal_error(
                f"Insufficient data supplied ({len(rows)} row(s)); no data remaining for table "
                f'body, required by "{self.name}" directive.'))
        for row in rows:
            if len(row) < stub_columns:
                raise SystemMessagePropagation(self.literal_error(
                    f"{stub_columns} stub column(s) specified but only {len(row)} columns(s) "
                    f'of data supplied ("{self.name}" directive).'))
            if len(row) == stub_columns > 0:
                raise SystemMessagePropagation(self.literal_error(
                    "Insufficient data supplied (%s columns(s)); no data remaining for table "
                    'body, required by "%s" directive.' % (len(row), self.name)))

    def set_table_width(self, table_node: nodes.table) -> None:
        if "width" in self.options:
            table_node["width"] = self.options.get("width")

    @property
    def widths(self) -> Any:
        return self.options.get("widths", "")

    def get_column_widths(self, n_cols: int) -> list[int]:
        if isinstance(self.widths, list):
            if len(self.widths) != n_cols:
                # TODO: use last value for missing columns?
                raise SystemMessagePropagation(self.literal_error(
                    '"%s" widths do not match the number of columns in table (%s).'
                    % (self.name, n_cols)))
            return self.widths
        if n_cols:
            return [100 // n_cols] * n_cols
        raise SystemMessagePropagation(self.literal_error("No table data detected in CSV file."))

    def extend_short_rows_with_empty_cells(self, columns: int,
                                           parts: Iterable[list[list]]) -> None:
        for part in parts:
            for row in part:
                if len(row) < columns:
                    row.extend([(0, 0, 0, [])] * (columns - len(row)))

    def finish_table(self, table_node: nodes.table, title: nodes.title | None,
                     messages: list[nodes.system_message]) -> list[nodes.Node]:
        """Apply the common options and the title; return the directive result."""
        table_node["classes"] += self.options.get("class", [])
        if "align" in self.options:
            table_node["align"] = self.options.get("align")
        self.set_table_width(table_node)
        self.add_name(table_node)
        if title:
            table_node.insert(0, title)
        return [table_node, *messages]


class RSTTable(Table):
    """Class for the `"table" directive`__ for formal tables using rST syntax.

    __ https://docutils.sourceforge.io/docs/ref/rst/directives.html
    """

    def run(self) -> list[nodes.Node]:
        if not self.content:
            return [self.literal_error('Content block expected for the "%s" directive; '
                                       "none found." % self.name, "warning")]
        title, messages = self.make_title()
        node = nodes.Element()  # anonymous container for parsing
        self.state.nested_parse(self.content, self.content_offset, node)
        if len(node) != 1 or not isinstance(node[0], nodes.table):
            return [self.literal_error('Error parsing content block for the "%s" directive: '
                                       "exactly one table expected." % self.name)]
        table_node = node[0]
        table_node["classes"] += self.options.get("class", [])
        self.set_table_width(table_node)  # before "align" and width classes (as upstream)
        if "align" in self.options:
            table_node["align"] = self.options.get("align")
        if isinstance(self.widths, list):
            tgroup = table_node[0]
            try:
                col_widths = self.get_column_widths(tgroup["cols"])
            except SystemMessagePropagation as detail:
                return [detail.args[0]]
            colspecs = [child for child in tgroup.children if child.tagname == "colspec"]
            for colspec, col_width in zip(colspecs, col_widths, strict=False):
                colspec["colwidth"] = col_width
        if self.widths == "auto":
            table_node["classes"] += ["colwidths-auto"]
        elif self.widths:  # "grid" or list of integers
            table_node["classes"] += ["colwidths-given"]
        self.add_name(table_node)
        if title:
            table_node.insert(0, title)
        return [table_node, *messages]


class CSVTable(Table):
    option_spec = {
        "header-rows": directives.nonnegative_int,
        "stub-columns": directives.nonnegative_int,
        "header": directives.unchanged,
        "width": directives.length_or_percentage_or_unitless,
        "widths": directives.value_or(("auto",), directives.positive_int_list),
        "file": directives.path,
        "url": directives.uri,
        "encoding": directives.encoding,
        "class": directives.class_option,
        "name": directives.unchanged,
        "align": align,
        # field delimiter char
        "delim": directives.single_char_or_whitespace_or_unicode,
        # treat whitespace after delimiter as significant
        "keepspace": directives.flag,
        # text field quote/unquote char:
        "quote": directives.single_char_or_unicode,
        # char used to escape delim & quote as-needed:
        "escape": directives.single_char_or_unicode,
    }

    class DocutilsDialect(csv.Dialect):
        """CSV dialect for `csv_table` directive."""

        delimiter = ","
        quotechar = '"'
        doublequote = True
        skipinitialspace = True
        strict = True
        lineterminator = "\n"
        quoting = csv.QUOTE_MINIMAL

        def __init__(self, options: dict[str, Any]) -> None:
            if "delim" in options:
                self.delimiter = options["delim"]
            if "keepspace" in options:
                self.skipinitialspace = False
            if "quote" in options:
                self.quotechar = options["quote"]
            if "escape" in options:
                self.doublequote = False
                self.escapechar = options["escape"]
            super().__init__()

    class HeaderDialect(csv.Dialect):
        """CSV dialect used for the "header" option data.

        Deprecated. Will be removed in Docutils 1.0.
        """

        delimiter = ","
        quotechar = '"'
        escapechar = "\\"
        doublequote = False
        skipinitialspace = True
        strict = True
        lineterminator = "\n"
        quoting = csv.QUOTE_MINIMAL

        def __init__(self) -> None:
            warnings.warn("CSVTable.HeaderDialect will be removed in Docutils 1.0",
                          DeprecationWarning, stacklevel=2)
            super().__init__()

    @staticmethod
    def check_requirements() -> None:
        warnings.warn("CSVTable.check_requirements() is not required with Python 3 and will "
                      "be removed in Docutils 0.22.", DeprecationWarning, stacklevel=2)

    def process_header_option(self) -> tuple[list, int]:
        source = self.state_machine.get_source(self.lineno - 1)
        table_head: list = []
        max_header_cols = 0
        if "header" in self.options:  # separate table header in option
            rows, max_header_cols = self.parse_csv_data_into_rows(
                self.options["header"].split("\n"), self.DocutilsDialect(self.options), source)
            table_head.extend(rows)
        return table_head, max_header_cols

    def run(self) -> list[nodes.Node]:
        try:
            if (not self.state.document.settings.file_insertion_enabled
                    and ("file" in self.options or "url" in self.options)):
                return [self.literal_error('File and URL access deactivated; ignoring "%s" '
                                           "directive." % self.name, "warning")]
            title, messages = self.make_title()
            csv_data, source = self.get_csv_data()
            table_head, max_header_cols = self.process_header_option()
            rows, max_cols = self.parse_csv_data_into_rows(
                csv_data, self.DocutilsDialect(self.options), source)
            max_cols = max(max_cols, max_header_cols)
            header_rows = self.options.get("header-rows", 0)
            stub_columns = self.options.get("stub-columns", 0)
            self.check_table_dimensions(rows, header_rows, stub_columns)
            table_head.extend(rows[:header_rows])
            table_body = rows[header_rows:]
            col_widths = self.get_column_widths(max_cols)
            self.extend_short_rows_with_empty_cells(max_cols, (table_head, table_body))
        except SystemMessagePropagation as detail:
            return [detail.args[0]]
        except csv.Error as detail:
            return [self.literal_error('Error with CSV data in "%s" directive:\n%s'
                                       % (self.name, detail))]
        table = (col_widths, table_head, table_body)
        table_node = self.state.build_table(table, self.content_offset, stub_columns,
                                            widths=self.widths)
        return self.finish_table(table_node, title, messages)

    def get_csv_data(self) -> tuple[Sequence[str], str]:
        """Get CSV data from the directive content, from an external file, or from a URL."""
        if self.content:  # CSV data is from directive content.
            if "file" in self.options or "url" in self.options:
                raise SystemMessagePropagation(self.literal_error(
                    '"%s" directive may not both specify an external file and have content.'
                    % self.name))
            return self.content, self.content.source(0)
        if "file" in self.options:
            if "url" in self.options:
                raise SystemMessagePropagation(self.literal_error(
                    'The "file" and "url" options may not be simultaneously specified for the '
                    '"%s" directive.' % self.name))
            return self._csv_from_file()
        if "url" in self.options:
            return self._csv_from_url()
        raise SystemMessagePropagation(self.literal_error(
            'The "%s" directive requires content; none supplied.' % self.name, "warning"))

    def _csv_from_file(self) -> tuple[list[str], str]:
        settings = self.state.document.settings
        source = adapt_path(self.options["file"], self.state.document.current_source,
                            settings.root_prefix)
        try:
            csv_file = FileInput(source_path=source,
                                 encoding=self.options.get("encoding", settings.input_encoding),
                                 error_handler=settings.input_encoding_error_handler)
            csv_data = csv_file.read().splitlines()
        except OSError as error:
            raise SystemMessagePropagation(self.literal_error(
                'Problems with "%s" directive path:\n%s.' % (self.name, error), "severe"),
            ) from None
        else:
            settings.record_dependencies.add(source)
        return csv_data, source

    def _csv_from_url(self) -> tuple[list[str], str]:
        settings = self.state.document.settings
        source = self.options["url"]
        try:
            with urlopen(source) as response:  # noqa: S310 - the author asked for this URL
                csv_text = response.read()
        except (URLError, OSError, ValueError) as error:
            raise SystemMessagePropagation(self.literal_error(
                'Problems with "%s" directive URL "%s":\n%s.' % (self.name, source, error),
                "severe")) from None
        csv_file = StringInput(source=csv_text, source_path=source,
                               encoding=self.options.get("encoding", settings.input_encoding),
                               error_handler=settings.input_encoding_error_handler)
        return csv_file.read().splitlines(), source

    def parse_csv_data_into_rows(self, csv_data: Iterable[str], dialect: csv.Dialect,
                                 source: str) -> tuple[list, int]:
        csv_reader = csv.reader((line + "\n" for line in csv_data), dialect=dialect)
        rows = []
        max_cols = 0
        for row in csv_reader:
            row_data = []
            for cell in row:
                # cell spans (morerows, morecols) & offset, then the cell content
                cell_data = (0, 0, 0, statemachine.StringList(cell.splitlines(), source=source))
                row_data.append(cell_data)
            rows.append(row_data)
            max_cols = max(max_cols, len(row))
        return rows, max_cols


class ListTable(Table):
    """Implement tables whose data is encoded as a uniform two-level bullet list.

    For further ideas, see
    https://docutils.sourceforge.io/docs/dev/rst/alternatives.html#list-driven-tables
    """

    option_spec = {
        "header-rows": directives.nonnegative_int,
        "stub-columns": directives.nonnegative_int,
        "width": directives.length_or_percentage_or_unitless,
        "widths": directives.value_or(("auto",), directives.positive_int_list),
        "class": directives.class_option,
        "name": directives.unchanged,
        "align": align,
    }

    def run(self) -> list[nodes.Node]:
        if not self.content:
            return [self.literal_error('The "%s" directive is empty; content required.'
                                       % self.name)]
        title, messages = self.make_title()
        node = nodes.Element()  # anonymous container for parsing
        self.state.nested_parse(self.content, self.content_offset, node)
        try:
            _num_cols, col_widths = self.check_list_content(node)
            table_data = [[item.children for item in row_list[0]] for row_list in node[0]]
            header_rows = self.options.get("header-rows", 0)
            stub_columns = self.options.get("stub-columns", 0)
            self.check_table_dimensions(table_data, header_rows, stub_columns)
        except SystemMessagePropagation as detail:
            return [detail.args[0]]
        table_node = self.build_table_from_list(table_data, col_widths, header_rows,
                                                stub_columns)
        return self.finish_table(table_node, title, messages)

    def check_list_content(self, node: nodes.Element) -> tuple[int, list[int]]:
        if len(node) != 1 or not isinstance(node[0], nodes.bullet_list):
            raise SystemMessagePropagation(self.literal_error(
                'Error parsing content block for the "%s" directive: exactly one bullet list '
                "expected." % self.name))
        list_node = node[0]
        num_cols = 0
        # Check for a uniform two-level bullet list:
        for item_index, item in enumerate(list_node):
            if len(item) != 1 or not isinstance(item[0], nodes.bullet_list):
                raise SystemMessagePropagation(self.literal_error(
                    'Error parsing content block for the "%s" directive: two-level bullet list '
                    "expected, but row %s does not contain a second-level bullet list."
                    % (self.name, item_index + 1)))
            if not item_index:
                num_cols = len(item[0])
            elif len(item[0]) != num_cols:
                # FIXME: Why not insert empty cells?
                raise SystemMessagePropagation(self.literal_error(
                    'Error parsing content block for the "%s" directive: uniform two-level '
                    "bullet list expected, but row %s does not contain the same number of "
                    "items as row 1 (%s vs %s)."
                    % (self.name, item_index + 1, len(item[0]), num_cols)))
        col_widths = self.get_column_widths(num_cols)
        return num_cols, col_widths

    def build_table_from_list(self, table_data: list[list], col_widths: list[int],
                              header_rows: int, stub_columns: int) -> nodes.table:
        table = nodes.table()
        if self.widths == "auto":
            table["classes"] += ["colwidths-auto"]
        elif self.widths:  # explicitly set column widths
            table["classes"] += ["colwidths-given"]
        tgroup = nodes.tgroup(cols=len(col_widths))
        table += tgroup
        for col_width in col_widths:
            colspec = nodes.colspec()
            if col_width is not None:
                colspec.attributes["colwidth"] = col_width
            if stub_columns:
                colspec.attributes["stub"] = True
                stub_columns -= 1
            tgroup += colspec
        rows = []
        for row in table_data:
            row_node = nodes.row()
            for cell in row:
                entry = nodes.entry()
                entry += cell
                row_node += entry
            rows.append(row_node)
        if header_rows:
            thead = nodes.thead()
            thead.extend(rows[:header_rows])
            tgroup += thead
        tbody = nodes.tbody()
        tbody.extend(rows[header_rows:])
        tgroup += tbody
        return table
