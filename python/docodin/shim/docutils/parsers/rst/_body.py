"""Helpers of the reStructuredText ``Body`` state: block-level constructs.

`BodyHelpers` holds the methods the ``Body`` transitions build their
elements with (block quotes and attributions, list items, enumerators,
fields, option lists, line blocks and tables).  Directives and extensions
call several of them directly.
"""

from __future__ import annotations

import re
from typing import Any

from docutils import ApplicationError, DataError, nodes, statemachine
from docutils.parsers.rst import tableparser
from docutils.utils import strip_combining_chars
from docutils.utils._roman_numerals import InvalidRomanNumeralError, RomanNumeral

FIELD_MARKER = r":(?![: ])([^:\\]|\\.|:(?!([ `]|$)))*(?<! ):( +|$)"


class MarkupError(DataError):
    pass


class ParserError(ApplicationError):
    pass


def _split_option_string(optionstring: str) -> tuple[list[str], str]:
    """Tokens (option, argument) of one option and the delimiter between them."""
    tokens = optionstring.split()
    delimiter = " "
    head = tokens[0]
    option, equals, value = head.partition("=")
    if equals:  # "--opt=value"
        tokens[:1] = [option, value]
        delimiter = "="
    elif len(head) > 2 and (head.startswith("+")
                            or (head.startswith("-") and not head.startswith("--"))):
        tokens[:1] = [head[:2], head[2:]]  # "-ovalue"
        delimiter = ""
    if len(tokens) > 1 and tokens[1].startswith("<") and tokens[-1].endswith(">"):
        tokens[1:] = [" ".join(tokens[1:])]  # "-o <value1 value2>"
    return tokens, delimiter


class BodyHelpers:
    """Mix-in of ``Body``: the methods that build block-level elements."""

    attribution_pattern = re.compile("(---?(?!-)|—) *(?=[^ \\n])")
    double_width_pad_char = tableparser.TableParser.double_width_pad_char

    # --- block quotes and attributions ---------------------------------------------

    def block_quote(self, indented: statemachine.StringList,
                    line_offset: int) -> list[nodes.Element]:
        """Block quote elements (split at attributions) for `indented`."""
        elements: list[nodes.Element] = []
        while indented:
            blockquote = nodes.block_quote(rawsource="\n".join(indented))
            blockquote.source, blockquote.line = self.state_machine.get_source_and_line(
                line_offset + 1)
            (blockquote_lines, attribution_lines, attribution_offset, indented,
             new_line_offset) = self.split_attribution(indented, line_offset)
            self.nested_parse(blockquote_lines, line_offset, blockquote)
            elements.append(blockquote)
            if attribution_lines:
                attribution, messages = self.parse_attribution(
                    attribution_lines, line_offset + attribution_offset)
                blockquote += attribution
                elements += messages
            line_offset = new_line_offset
            while indented and not indented[0]:
                indented = indented[1:]
                line_offset += 1
        return elements

    def split_attribution(self, indented: statemachine.StringList, line_offset: int) -> tuple:
        """(quote lines, attribution lines, attribution offset, rest, rest offset).

        An attribution starts with a dash after a blank line that follows quote
        content; its further lines share one indentation.
        """
        blank = None
        nonblank_seen = False
        for i in range(len(indented)):
            line = indented[i].rstrip()
            if not line:
                blank = i
                continue
            if nonblank_seen and blank == i - 1:
                match = self.attribution_pattern.match(line)
                if match:
                    attribution_end, indent = self.check_attribution(indented, i)
                    if attribution_end:
                        a_lines = indented[i:attribution_end]
                        a_lines.trim_left(match.end(), end=1)
                        a_lines.trim_left(indent, start=1)
                        return (indented[:i], a_lines, i, indented[attribution_end:],
                                line_offset + attribution_end)
            nonblank_seen = True
        return indented, None, None, None, None

    def check_attribution(self, indented: statemachine.StringList,
                          attribution_start: int) -> tuple[int | None, int | None]:
        """(end, indent) of a consistently indented attribution, or (None, None)."""
        indent = None
        end = len(indented)
        for i in range(attribution_start + 1, len(indented)):
            line = indented[i].rstrip()
            if not line:
                end = i
                break
            if indent is None:
                indent = len(line) - len(line.lstrip())
            elif len(line) - len(line.lstrip()) != indent:
                return None, None
        else:
            end = max(len(indented), attribution_start + 2)
        return end, indent or 0

    def parse_attribution(self, indented: statemachine.StringList,
                          line_offset: int) -> tuple[nodes.attribution, list]:
        text = "\n".join(indented).rstrip()
        lineno = 1 + line_offset
        textnodes, messages = self.inline_text(text, lineno)
        node = nodes.attribution(text, "", *textnodes)
        node.source, node.line = self.state_machine.get_source_and_line(lineno)
        return node, messages

    # --- list items and enumerators ------------------------------------------------

    def list_item(self, indent: int) -> tuple[nodes.list_item, bool]:
        """The list item whose text starts at column `indent` of the current line."""
        src, srcline = self.state_machine.get_source_and_line()
        if self.state_machine.line[indent:]:
            indented, line_offset, blank_finish = (
                self.state_machine.get_known_indented(indent))
        else:
            indented, indent, line_offset, blank_finish = (
                self.state_machine.get_first_known_indented(indent))
        listitem = nodes.list_item("\n".join(indented))
        listitem.source, listitem.line = src, srcline
        if indented:
            self.nested_parse(indented, input_offset=line_offset, node=listitem)
        return listitem, blank_finish

    def parse_enumerator(self, match: re.Match[str],
                         expected_sequence: str | None = None) -> tuple:
        """(format, sequence, text, ordinal) of an enumerator match.

        `expected_sequence` is tried first; otherwise "i"/"I" are Roman
        numerals, and other text takes the first sequence it fits.  The ordinal
        is None for an invalid Roman numeral.
        """
        groupdict = match.groupdict()
        format = next((name for name in self.enum.formats if groupdict[name]), None)
        if format is None:
            raise ParserError("enumerator format not matched")
        info = self.enum.formatinfo[format]
        text = groupdict[format][info.start:info.end]
        sequence = ""
        if text == "#":
            sequence = "#"
        elif expected_sequence:
            try:
                if self.enum.sequenceregexps[expected_sequence].match(text):
                    sequence = expected_sequence
            except KeyError:
                raise ParserError("unknown enumerator sequence: %s" % sequence) from None
        elif text in ("i", "I"):
            sequence = "lowerroman" if text == "i" else "upperroman"
        if not sequence:
            sequence = next((name for name in self.enum.sequences
                             if self.enum.sequenceregexps[name].match(text)), "")
            if not sequence:
                raise ParserError("enumerator sequence not matched")
        if sequence == "#":
            return format, sequence, text, 1
        try:
            ordinal = int(self.enum.converters[sequence](text))
        except InvalidRomanNumeralError:
            ordinal = None
        return format, sequence, text, ordinal

    def is_enumerated_list_item(self, ordinal: int | None, sequence: str,
                                format: str) -> int | None:
        """Whether an enumerator starts a list item: its ordinal is valid and
        the next line is blank, indented, or starts with the next enumerator."""
        if ordinal is None:
            return None
        machine = self.state_machine
        try:
            next_line = machine.next_line()
        except EOFError:
            machine.previous_line()
            return 1
        machine.previous_line()
        if not next_line[:1].strip():
            return 1
        result = self.make_enumerator(ordinal + 1, sequence, format)
        if result and next_line.startswith(result):
            return 1
        return None

    def make_enumerator(self, ordinal: int, sequence: str,
                        format: str) -> tuple[str, str] | None:
        """(next enumerator, auto-enumerator) for `ordinal`, or None when out of range."""
        if sequence == "#":
            enumerator = "#"
        elif sequence == "arabic":
            enumerator = str(ordinal)
        else:
            if sequence.endswith("alpha"):
                if ordinal > 26:
                    return None
                enumerator = chr(ordinal + ord("a") - 1)
            elif sequence.endswith("roman"):
                try:
                    enumerator = RomanNumeral(ordinal).to_uppercase()
                except TypeError:
                    return None
            else:
                raise ParserError('unknown enumerator sequence: "%s"' % sequence)
            if sequence.startswith("lower"):
                enumerator = enumerator.lower()
            elif sequence.startswith("upper"):
                enumerator = enumerator.upper()
            else:
                raise ParserError('unknown enumerator sequence: "%s"' % sequence)
        info = self.enum.formatinfo[format]
        return (info.prefix + enumerator + info.suffix + " ",
                info.prefix + "#" + info.suffix + " ")

    # --- fields ---------------------------------------------------------------------

    def field(self, match: re.Match[str]) -> tuple[nodes.field, bool]:
        name = self.parse_field_marker(match)
        src, srcline = self.state_machine.get_source_and_line()
        lineno = self.state_machine.abs_line_number()
        indented, _indent, line_offset, blank_finish = (
            self.state_machine.get_first_known_indented(match.end()))
        field_node = nodes.field()
        field_node.source = src
        field_node.line = srcline
        name_nodes, name_messages = self.inline_text(name, lineno)
        field_node += nodes.field_name(name, "", *name_nodes)
        field_body = nodes.field_body("\n".join(indented), *name_messages)
        field_node += field_body
        if indented:
            self.parse_field_body(indented, line_offset, field_body)
        return field_node, blank_finish

    def parse_field_marker(self, match: re.Match[str]) -> str:
        """Extract & return field name from a field marker match."""
        field = match.group()[1:]
        return field[:field.rfind(":")]

    def parse_field_body(self, indented: statemachine.StringList, offset: int,
                         node: nodes.Element) -> None:
        self.nested_parse(indented, input_offset=offset, node=node)

    # --- option lists ------------------------------------------------------------------

    def option_list_item(self, match: re.Match[str]) -> tuple[nodes.option_list_item, bool]:
        offset = self.state_machine.abs_line_offset()
        options = self.parse_option_marker(match)
        indented, _indent, line_offset, blank_finish = (
            self.state_machine.get_first_known_indented(match.end()))
        if not indented:  # not an option list item
            self.goto_line(offset)
            raise statemachine.TransitionCorrection("text")
        option_group = nodes.option_group("", *options)
        description = nodes.description("\n".join(indented))
        option_list_item = nodes.option_list_item("", option_group, description)
        self.nested_parse(indented, input_offset=line_offset, node=description)
        return option_list_item, blank_finish

    def parse_option_marker(self, match: re.Match[str]) -> list[nodes.option]:
        """The `nodes.option` elements of an option marker (MarkupError if invalid)."""
        optlist = []
        # split at ", " except inside < > (complex arguments)
        for optionstring in re.split(r", (?![^<]*>)", match.group().rstrip()):
            tokens, delimiter = _split_option_string(optionstring)
            if not 0 < len(tokens) <= 2:
                raise MarkupError('wrong number of option tokens (=%s), should be 1 or 2: "%s"'
                                  % (len(tokens), optionstring))
            option = nodes.option(optionstring)
            option += nodes.option_string(tokens[0], tokens[0])
            if len(tokens) > 1:
                option += nodes.option_argument(tokens[1], tokens[1], delimiter=delimiter)
            optlist.append(option)
        return optlist

    # --- line blocks ------------------------------------------------------------------

    def line_block_line(self, match: re.Match[str], lineno: int) -> tuple:
        """Return one line element of a line_block."""
        indented, _indent, _line_offset, blank_finish = (
            self.state_machine.get_first_known_indented(match.end(), until_blank=True))
        text = "\n".join(indented)
        text_nodes, messages = self.inline_text(text, lineno)
        line = nodes.line(text, "", *text_nodes)
        line.source, line.line = self.state_machine.get_source_and_line(lineno)
        if match.string.rstrip() != "|":  # not empty
            line.indent = len(match.group(1)) - 1
        return line, messages, blank_finish

    def nest_line_block_lines(self, block: nodes.line_block) -> None:
        for index in range(1, len(block)):
            if block[index].indent is None:
                block[index].indent = block[index - 1].indent
        self.nest_line_block_segment(block)

    def nest_line_block_segment(self, block: nodes.line_block) -> None:
        least = min(item.indent for item in block)
        new_items: list[nodes.Element] = []
        new_block = nodes.line_block()
        for item in block:
            if item.indent > least:
                new_block.append(item)
                continue
            if len(new_block):
                self.nest_line_block_segment(new_block)
                new_items.append(new_block)
                new_block = nodes.line_block()
            new_items.append(item)
        if len(new_block):
            self.nest_line_block_segment(new_block)
            new_items.append(new_block)
        block[:] = new_items

    # --- tables -----------------------------------------------------------------------

    def table_top(self, match: re.Match[str], context: Any, next_state: Any,
                  isolate_function: Any, parser_class: type) -> tuple:
        """Top border of a generic table."""
        nodelist, blank_finish = self.table(isolate_function, parser_class)
        self.parent += nodelist
        if not blank_finish:
            self.parent += self.reporter.warning(
                "Blank line required after table.",
                line=self.state_machine.abs_line_number() + 1)
        return [], next_state, []

    def table(self, isolate_function: Any, parser_class: type) -> tuple[list, bool]:
        """Parse a table: (nodes, blank_finish)."""
        block, messages, blank_finish = isolate_function()
        if not block:
            return messages, blank_finish
        try:
            tabledata = parser_class().parse(block)
            tableline = self.state_machine.abs_line_number() - len(block) + 1
            nodelist = [self.build_table(tabledata, tableline), *messages]
        except tableparser.TableMarkupError as err:
            nodelist = self.malformed_table(block, " ".join(err.args),
                                            offset=err.offset) + messages
        return nodelist, blank_finish

    def isolate_grid_table(self) -> tuple:
        """(table lines, messages, blank_finish) of a grid table."""
        messages = []
        blank_finish = True
        machine = self.state_machine
        try:
            block = machine.get_text_block(flush_left=True)
        except statemachine.UnexpectedIndentationError as err:
            block, src, srcline = err.args
            messages.append(self.reporter.error("Unexpected indentation.",
                                                source=src, line=srcline))
            blank_finish = False
        block.disconnect()
        block.pad_double_width(self.double_width_pad_char)
        width = len(block[0].strip())
        truncated = False
        for i in range(len(block)):
            block[i] = block[i].strip()
            if block[i][0] not in "+|":  # left edge
                blank_finish = False
                truncated = True
                machine.previous_line(len(block) - i)
                del block[i:]
                break
        if not self.grid_table_top_pat.match(block[-1]):  # bottom border
            bottom = self._grid_table_bottom(block)
            if bottom is None:
                # the line docutils reports: the third, or the last one scanned
                offset = 2 if len(block) > 3 else len(block) - (not truncated)
                messages.extend(self.malformed_table(
                    block, "Bottom border missing or corrupt.", offset))
                return [], messages, blank_finish
            machine.previous_line(len(block) - bottom + 1)
            del block[bottom + 1:]
            blank_finish = False
        for i in range(len(block)):  # right edge
            if len(strip_combining_chars(block[i])) != width or block[i][-1] not in "+|":
                messages.extend(self.malformed_table(
                    block, "Right border not aligned or missing.", i))
                return [], messages, blank_finish
        return block, messages, blank_finish

    def _grid_table_bottom(self, block: statemachine.StringList) -> int | None:
        """The last border line from the second-last to the third line, if any."""
        for i in range(len(block) - 2, 1, -1):
            if self.grid_table_top_pat.match(block[i]):
                return i
        return None

    def isolate_simple_table(self) -> tuple:
        """(table lines, messages, blank_finish) of a simple table."""
        machine = self.state_machine
        start = machine.line_offset
        lines = machine.input_lines
        limit = len(lines) - 1
        toplen = len(lines[start].strip())
        found = 0
        found_at = None
        i = start + 1
        while i <= limit:
            line = lines[i]
            if self.simple_table_border_pat.match(line):
                if len(line.strip()) != toplen:
                    machine.next_line(i - start)
                    messages = self.malformed_table(
                        lines[start:i + 1],
                        "Bottom border or header rule does not match top border.", i - start)
                    return [], messages, i == limit or not lines[i + 1].strip()
                found += 1
                found_at = i
                if found == 2 or i == limit or not lines[i + 1].strip():
                    machine.next_line(i - start)
                    block = lines[start:i + 1]
                    block.pad_double_width(self.double_width_pad_char)
                    return block, [], i == limit or not lines[i + 1].strip()
            i += 1
        details = "No bottom table border found"
        if found:
            details += " or no blank line after table bottom"
            machine.next_line(found_at - start)
            block = lines[start:found_at + 1]
        else:
            machine.next_line(i - start - 1)
            block = lines[start:]
        return [], self.malformed_table(block, details + "."), not found

    def malformed_table(self, block: statemachine.StringList, detail: str = "",
                        offset: int = 0) -> list[nodes.system_message]:
        block.replace(self.double_width_pad_char, "")
        data = "\n".join(block)
        message = "Malformed table." + ("\n" + detail if detail else "")
        startline = self.state_machine.abs_line_number() - len(block) + 1
        return [self.reporter.error(message, nodes.literal_block(data, data),
                                    line=startline + offset)]

    def build_table(self, tabledata: tuple, tableline: int, stub_columns: int = 0,
                    widths: Any = None) -> nodes.table:
        """Table element for `tabledata` = (colwidths, headrows, bodyrows)."""
        colwidths, headrows, bodyrows = tabledata
        table = nodes.table()
        if widths == "auto":
            table["classes"] += ["colwidths-auto"]
        elif widths:  # "grid" or list of integers
            table["classes"] += ["colwidths-given"]
        tgroup = nodes.tgroup(cols=len(colwidths))
        table += tgroup
        for colwidth in colwidths:
            colspec = nodes.colspec(colwidth=colwidth)
            if stub_columns:
                colspec.attributes["stub"] = True
                stub_columns -= 1
            tgroup += colspec
        if headrows:
            thead = nodes.thead()
            tgroup += thead
            for row in headrows:
                thead += self.build_table_row(row, tableline)
        tbody = nodes.tbody()
        tgroup += tbody
        for row in bodyrows:
            tbody += self.build_table_row(row, tableline)
        return table

    def build_table_row(self, rowdata: list, tableline: int) -> nodes.row:
        row = nodes.row()
        for cell in rowdata:
            if cell is None:
                continue
            morerows, morecols, offset, cellblock = cell
            attributes = {}
            if morerows:
                attributes["morerows"] = morerows
            if morecols:
                attributes["morecols"] = morecols
            entry = nodes.entry(**attributes)
            row += entry
            if "".join(cellblock):
                self.nested_parse(cellblock, input_offset=tableline + offset, node=entry)
        return row
