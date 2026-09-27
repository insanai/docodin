"""Parsers for grid and simple tables.

The table parsers return a data structure ``(colspecs, headrows, bodyrows)``: `colspecs` is a
list of column widths; `headrows` and `bodyrows` are lists of rows, each row a list of cells
``(morerows, morecols, offset, cellblock)`` (or None for cells spanned by another one).
"""

from __future__ import annotations

import re
import sys
from typing import Any

from docutils import DataError
from docutils.utils import strip_combining_chars

__docformat__ = "reStructuredText"


class TableMarkupError(DataError):
    """Raise if there is any problem with table markup.

    The keyword argument `offset` denotes the offset of the problem from the table's start
    line.
    """

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        self.offset = kwargs.pop("offset", 0)
        DataError.__init__(self, *args)


class TableParser:
    """Abstract superclass for the common parts of the syntax-specific parsers."""

    head_body_separator_pat: re.Pattern[str] | None = None
    """Matches the row separator between head rows and body rows."""

    double_width_pad_char = "\x00"
    """Padding character for East Asian double-width text."""

    def parse(self, block: Any) -> tuple:
        """Analyze the text `block` and return a table data structure."""
        self.setup(block)
        self.find_head_body_sep()
        self.parse_table()
        return self.structure_from_cells()

    def find_head_body_sep(self) -> None:
        """Look for a head/body row separator line; store the line index."""
        i = 0
        for i, line in enumerate(self.block):
            if self.head_body_separator_pat.match(line):
                if self.head_body_sep:
                    raise TableMarkupError(
                        "Multiple head/body row separators (table lines %s and %s); only one "
                        "allowed." % (self.head_body_sep + 1, i + 1), offset=i)
                self.head_body_sep = i
                self.block[i] = line.replace("=", "-")
        if self.head_body_sep == 0 or self.head_body_sep == (len(self.block) - 1):
            raise TableMarkupError("The head/body row separator may not be the first or last "
                                   "line of the table.", offset=i)


class GridTableParser(TableParser):
    """Parse a grid table using `parse()`.

    The cells are found with a corner-to-corner scan: each "+" corner found at the top-left
    of an unparsed region is scanned right, down, left and up to find the cell boundaries.
    """

    head_body_separator_pat = re.compile(r"\+=[=+]+=\+ *$")

    def setup(self, block: Any) -> None:
        self.block = block[:]  # make a copy; it may be modified
        self.block.disconnect()  # don't propagate changes to parent
        self.bottom = len(block) - 1
        self.right = len(block[0]) - 1
        self.head_body_sep: int | None = None
        self.done = [-1] * len(block[0])
        self.cells: list[tuple] = []
        self.rowseps: dict[int, list[int]] = {0: [0]}
        self.colseps: dict[int, list[int]] = {0: [0]}

    def parse_table(self) -> None:
        """Start with a queue of upper-left corners, containing the upper-left corner of the
        table itself.  Trace out one rectangular cell, remember it, and add its upper-right
        and lower-left corners to the queue of potential upper-left corners of further cells.
        Process the queue in top-to-bottom order, keeping track of how much of each text
        column has been seen.
        """
        # Combining chars don't take up any space, so we need to strip them.
        self.stripped_block = [strip_combining_chars(line) for line in self.block]
        corners = [(0, 0)]
        while corners:
            top, left = corners.pop(0)
            if top == self.bottom or left == self.right or top <= self.done[left]:
                continue
            result = self.scan_cell(top, left)
            if not result:
                continue
            bottom, right, rowseps, colseps = result
            update_dict_of_lists(self.rowseps, rowseps)
            update_dict_of_lists(self.colseps, colseps)
            self.mark_done(top, left, bottom, right)
            cellblock = self.block.get_2D_block(top + 1, left + 1, bottom, right)
            cellblock.disconnect()  # lines in cell can't sync with parent
            cellblock.replace(self.double_width_pad_char, "")
            self.cells.append((top, left, bottom, right, cellblock))
            corners.extend([(top, right), (bottom, left)])
            corners.sort()
        if not self.check_parse_complete():
            raise TableMarkupError("Malformed table; parse incomplete.")

    def mark_done(self, top: int, left: int, bottom: int, right: int) -> None:
        """For keeping track of how much of each text column has been seen."""
        before = top - 1
        after = bottom - 1
        for col in range(left, right):
            assert self.done[col] == before
            self.done[col] = after

    def check_parse_complete(self) -> bool:
        """Each text column should have been completely seen."""
        last = self.bottom - 1
        return all(self.done[col] == last for col in range(self.right))

    def scan_cell(self, top: int, left: int) -> tuple | None:
        """Starting at the top-left corner, start tracing out a cell."""
        assert self.stripped_block[top][left] == "+"
        return self.scan_right(top, left)

    def scan_right(self, top: int, left: int) -> tuple | None:
        """Look for the top-right corner of the cell, and make note of all column boundaries
        ('+').
        """
        colseps: dict[int, list[int]] = {}
        line = self.stripped_block[top]
        for i in range(left + 1, self.right + 1):
            if line[i] == "+":
                colseps[i] = [top]
                result = self.scan_down(top, left, i)
                if result:
                    bottom, rowseps, newcolseps = result
                    update_dict_of_lists(colseps, newcolseps)
                    return bottom, i, rowseps, colseps
            elif line[i] != "-":
                return None
        return None

    def scan_down(self, top: int, left: int, right: int) -> tuple | None:
        """Look for the bottom-right corner of the cell, making note of all row boundaries."""
        rowseps: dict[int, list[int]] = {}
        for i in range(top + 1, self.bottom + 1):
            if self.stripped_block[i][right] == "+":
                rowseps[i] = [right]
                result = self.scan_left(top, left, i, right)
                if result:
                    newrowseps, colseps = result
                    update_dict_of_lists(rowseps, newrowseps)
                    return i, rowseps, colseps
            elif self.stripped_block[i][right] != "|":
                return None
        return None

    def scan_left(self, top: int, left: int, bottom: int, right: int) -> tuple | None:
        """Noting column boundaries, look for the bottom-left corner of the cell.  It must
        line up with the starting point.
        """
        colseps: dict[int, list[int]] = {}
        line = self.stripped_block[bottom]
        for i in range(right - 1, left, -1):
            if line[i] == "+":
                colseps[i] = [bottom]
            elif line[i] != "-":
                return None
        if line[left] != "+":
            return None
        rowseps = self.scan_up(top, left, bottom, right)
        if rowseps is not None:
            return rowseps, colseps
        return None

    def scan_up(self, top: int, left: int, bottom: int,
                right: int) -> dict[int, list[int]] | None:
        """Noting row boundaries, see if we can return to the starting point."""
        rowseps: dict[int, list[int]] = {}
        for i in range(bottom - 1, top, -1):
            if self.stripped_block[i][left] == "+":
                rowseps[i] = [left]
            elif self.stripped_block[i][left] != "|":
                return None
        return rowseps

    def structure_from_cells(self) -> tuple:
        """From the data collected by `scan_cell()`, convert to the final data structure."""
        rowseps = sorted(self.rowseps)  # list of row boundaries
        rowindex = {sep: i for i, sep in enumerate(rowseps)}  # row boundary -> row number
        colseps = sorted(self.colseps)  # list of column boundaries
        colindex = {sep: i for i, sep in enumerate(colseps)}  # column boundary -> col number
        colspecs = [(colseps[i] - colseps[i - 1] - 1) for i in range(1, len(colseps))]
        # prepare an empty table with the correct number of rows & columns
        onerow: list[Any] = [None] * (len(colseps) - 1)
        rows = [onerow[:] for _ in range(len(rowseps) - 1)]
        # keep track of # of cells remaining; should reduce to zero
        remaining = (len(rowseps) - 1) * (len(colseps) - 1)
        for top, left, bottom, right, block in self.cells:
            rownum = rowindex[top]
            colnum = colindex[left]
            assert rows[rownum][colnum] is None, (
                "Cell (row %s, column %s) already used." % (rownum + 1, colnum + 1))
            morerows = rowindex[bottom] - rownum - 1
            morecols = colindex[right] - colnum - 1
            remaining -= (morerows + 1) * (morecols + 1)
            # write the cell into the table
            rows[rownum][colnum] = (morerows, morecols, top + 1, block)
        assert remaining == 0, "Unused cells remaining."
        if self.head_body_sep:  # separate head rows from body rows
            numheadrows = rowindex[self.head_body_sep]
            return colspecs, rows[:numheadrows], rows[numheadrows:]
        return colspecs, [], rows


class SimpleTableParser(TableParser):
    """Parse a simple table using `parse()`."""

    head_body_separator_pat = re.compile("=[ =]*$")
    span_pat = re.compile("-[ -]*$")

    def setup(self, block: Any) -> None:
        self.block = block[:]  # copy it
        self.block.disconnect()  # don't propagate changes to parent
        # Convert top & bottom borders to column span underlines:
        self.block[0] = self.block[0].replace("=", "-")
        self.block[-1] = self.block[-1].replace("=", "-")
        self.head_body_sep: int | None = None
        self.columns: list[tuple[int, int]] = []
        self.border_end: int | None = None
        self.table: list[list] = []
        self.done = [-1] * len(block[0])
        self.rowseps = {0: [0]}
        self.colseps = {0: [0]}

    def parse_table(self) -> None:
        """First determine the column boundaries from the top border, then process rows.

        Each row may consist of multiple lines; accumulate lines until a row is complete.
        Call `self.parse_row` to finish the job.
        """
        # Top border must fully describe all table columns.
        self.columns = self.parse_columns(self.block[0], 0)
        self.border_end = self.columns[-1][1]
        firststart, firstend = self.columns[0]
        offset = 1  # skip top border
        start = 1
        text_found = False
        while offset < len(self.block):
            line = self.block[offset]
            if self.span_pat.match(line):
                # Column span underline or border; row is complete.
                self.parse_row(self.block[start:offset], start, (line.rstrip(), offset))
                start = offset + 1
                text_found = False
            elif line[firststart:firstend].strip():
                # First column not blank, therefore it's a new row.
                if text_found and offset != start:
                    self.parse_row(self.block[start:offset], start)
                start = offset
                text_found = True
            elif not text_found:
                start = offset + 1
            offset += 1

    def parse_columns(self, line: str, offset: int) -> list[tuple[int, int]]:
        """Given a column span underline, return a list of (begin, end) pairs."""
        cols = []
        end = 0
        while True:
            begin = line.find("-", end)
            end = line.find(" ", begin)
            if begin < 0:
                break
            if end < 0:
                end = len(line)
            cols.append((begin, end))
        if self.columns:
            if cols[-1][1] != self.border_end:
                raise TableMarkupError("Column span incomplete in table line %s."
                                       % (offset + 1), offset=offset)
            # Allow for an unbounded rightmost column:
            cols[-1] = (cols[-1][0], self.columns[-1][1])
        return cols

    def init_row(self, colspec: list[tuple[int, int]], offset: int) -> list[list]:
        i = 0
        cells = []
        for start, end in colspec:
            morecols = 0
            try:
                assert start == self.columns[i][0]
                while end != self.columns[i][1]:
                    i += 1
                    morecols += 1
            except (AssertionError, IndexError):
                raise TableMarkupError("Column span alignment problem in table line %s."
                                       % (offset + 2), offset=offset + 1) from None
            cells.append([0, morecols, offset, []])
            i += 1
        return cells

    def parse_row(self, lines: Any, start: int, spanline: tuple | None = None) -> None:
        """Given the text `lines` of a row, parse it and append to `self.table`.

        The row is parsed according to the current column spec (either `spanline` if
        provided or `self.columns`).  For each column, extract text from each line, and check
        for text in column margins.  Finally, adjust for insignificant whitespace.
        """
        if not (lines or spanline):
            # No new row, just blank lines.
            return
        columns = self.parse_columns(*spanline) if spanline else self.columns[:]
        self.check_columns(lines, start, columns)
        row = self.init_row(columns, start)
        for i, (col_start, col_end) in enumerate(columns):
            cellblock = lines.get_2D_block(0, col_start, len(lines), col_end)
            cellblock.disconnect()  # lines in cell can't sync with parent
            cellblock.replace(self.double_width_pad_char, "")
            row[i][3] = cellblock
        self.table.append(row)

    def check_columns(self, lines: Any, first_line: int, columns: list) -> None:
        """Check for text in column margins and text overflow in the last column.

        Raise TableMarkupError if anything but whitespace is in column margins.  Adjust the
        end value for the last column if there is text overflow.
        """
        # "Infinite" value for a dummy last column's beginning, used to check for text
        # overflow:
        columns.append((sys.maxsize, None))
        lastcol = len(columns) - 2
        # combining characters do not contribute to the column width
        stripped = [strip_combining_chars(line) for line in lines]
        for i in range(len(columns) - 1):
            start, end = columns[i]
            nextstart = columns[i + 1][0]
            for offset, line in enumerate(stripped):
                if i == lastcol and line[end:].strip():
                    text = line[start:].rstrip()
                    new_end = start + len(text)
                    main_start, main_end = self.columns[-1]
                    columns[i] = (start, max(main_end, new_end))
                    if new_end > main_end:
                        self.columns[-1] = (main_start, new_end)
                elif line[end:nextstart].strip():
                    raise TableMarkupError("Text in column margin in table line %s."
                                           % (first_line + offset + 1),
                                           offset=first_line + offset)
        columns.pop()

    def structure_from_cells(self) -> tuple:
        colspecs = [end - start for start, end in self.columns]
        first_body_row = 0
        if self.head_body_sep:
            for i, row in enumerate(self.table):
                if row[0][2] > self.head_body_sep:
                    first_body_row = i
                    break
        return colspecs, self.table[:first_body_row], self.table[first_body_row:]


def update_dict_of_lists(master: dict[Any, list], newdata: dict[Any, list]) -> None:
    """Extend the list values of `master` with those from `newdata`.

    Both parameters must be dictionaries containing list values.
    """
    for key, values in newdata.items():
        master.setdefault(key, []).extend(values)
