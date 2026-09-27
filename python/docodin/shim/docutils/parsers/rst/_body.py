"""Python helpers of the reStructuredText ``Body`` state.

These are the parts of the ``Body`` state that directives and extensions
call directly (directive block parsing, targets, tables, line blocks,
attributions, fields); the markup itself is recognized by docodin's native
parser.
"""

from __future__ import annotations

import re
from types import SimpleNamespace as Struct
from typing import Any

from docutils import ApplicationError, nodes, statemachine, utils
from docutils.nodes import fully_normalize_name as normalize_name
from docutils.nodes import unescape, whitespace_normalize_name
from docutils.utils import split_escaped_whitespace

from ._inliner import Inliner

FIELD_MARKER = r":(?![: ])([^:\\]|\\.|:(?!([ `]|$)))*(?<! ):( +|$)"


class MarkupError(utils.DataError):
    pass


_TARGET_PATTERN = r"""
    (
      _               # anonymous target
    |               # *OR*
      (?!_)           # no underscore at the beginning
      (?P<quote>`?)   # optional open quote
      (?![ `])        # first char. not space or backquote
      (?P<name>       # reference name
        .+?
      )
      %(non_whitespace_escape_before)s
      (?P=quote)      # close quote if open quote used
    )
    (?<!(?<!\x00):) # no unescaped colon at end
    %(non_whitespace_escape_before)s
    [ ]?            # optional space
    :               # end of reference name
    ([ ]+|$)        # followed by whitespace
    """

_REFERENCE_PATTERN = r"""
    (
      (?P<simple>%(simplename)s)_
    |                  # *OR*
      `                  # open backquote
      (?![ ])            # not space
      (?P<phrase>.+?)    # hyperlink phrase
      %(non_whitespace_escape_before)s
      `_                 # close backquote, reference mark
    )
    $                  # end of string
    """

_SUBSTITUTION_PATTERN = r"""
    (
      (?![ ])          # first char. not space
      (?P<name>.+?)    # substitution text
      %(non_whitespace_escape_before)s
      \|               # close delimiter
    )
    ([ ]+|$)           # followed by whitespace
    """

_INLINER_ARGS = vars(Inliner)


class BodyHelpers:
    """Mix-in with the ``Body`` methods used by directives and extensions."""

    explicit = Struct(patterns=Struct(
        target=re.compile(_TARGET_PATTERN % _INLINER_ARGS, re.VERBOSE),
        reference=re.compile(_REFERENCE_PATTERN % _INLINER_ARGS, re.VERBOSE),
        substitution=re.compile(_SUBSTITUTION_PATTERN % _INLINER_ARGS, re.VERBOSE)))
    attribution_pattern = re.compile("(---?(?!-)|—) *(?=[^ \\n])")
    double_width_pad_char = "\x00"

    # --- block quotes and attributions ------------------------------------------------

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
        """(quote lines, attribution lines, attribution offset, rest, rest offset)."""
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
        i = attribution_start + 1
        for i in range(attribution_start + 1, len(indented)):
            line = indented[i].rstrip()
            if not line:
                return i, indent or 0
            if indent is None:
                indent = len(line) - len(line.lstrip())
            elif len(line) - len(line.lstrip()) != indent:
                return None, None
        else:
            i += 1
        return i, indent or 0

    def parse_attribution(self, indented: statemachine.StringList,
                          line_offset: int) -> tuple[nodes.attribution, list]:
        text = "\n".join(indented).rstrip()
        lineno = 1 + line_offset
        textnodes, messages = self.inline_text(text, lineno)
        node = nodes.attribution(text, "", *textnodes)
        node.source, node.line = self.state_machine.get_source_and_line(lineno)
        return node, messages

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

    # --- hyperlink targets ---------------------------------------------------------------

    def make_target(self, block: list[str], block_text: str, lineno: int,
                    target_name: str) -> Any:
        target_type, data = self.parse_target(block, block_text, lineno)
        if target_type == "refname":
            target = nodes.target(block_text, "", refname=normalize_name(data))
            target.indirect_reference_name = data
            self.add_target(target_name, "", target, lineno)
            self.document.note_indirect_target(target)
            return target
        if target_type == "refuri":
            target = nodes.target(block_text, "")
            self.add_target(target_name, data, target, lineno)
            return target
        return data

    def parse_target(self, block: list[str], block_text: str, lineno: int) -> tuple[str, str]:
        """Determine the type of reference of a target: ("refname"|"refuri", data)."""
        if block and block[-1].strip()[-1:] == "_":  # possible indirect target
            reference = " ".join(line.strip() for line in block)
            refname = self.is_reference(reference)
            if refname:
                return "refname", refname
        ref_parts = split_escaped_whitespace(" ".join(block))
        return "refuri", " ".join("".join(unescape(part).split()) for part in ref_parts)

    def is_reference(self, reference: str) -> str | None:
        match = self.explicit.patterns.reference.match(whitespace_normalize_name(reference))
        if not match:
            return None
        return unescape(match.group("simple") or match.group("phrase"))

    def add_target(self, targetname: str, refuri: str, target: nodes.target,
                   lineno: int) -> None:
        target.line = lineno
        if not targetname:  # anonymous target
            if refuri:
                target["refuri"] = refuri
            target["anonymous"] = True
            self.document.note_anonymous_target(target)
            return
        target["names"].append(normalize_name(unescape(targetname)))
        if refuri:
            uri = self.inliner.adjust_uri(refuri)
            if not uri:
                raise ApplicationError("problem with URI: %r" % refuri)
            target["refuri"] = uri
        self.document.note_explicit_target(target, self.parent)

    def disallowed_inside_substitution_definitions(self, node: nodes.Element) -> str:
        if isinstance(node, nodes.reference) and node.get("anonymous"):
            return "Anonymous references"
        if isinstance(node, nodes.footnote_reference) and node.get("auto"):
            return "References to auto-numbered and auto-symbol footnotes"
        if node["names"] or node["ids"]:
            return "Targets (names and identifiers)"
        return ""

    # --- directives ---------------------------------------------------------------------

    def parse_directive_block(self, indented: statemachine.StringList, line_offset: int,
                              directive: Any, option_presets: dict[str, Any]) -> tuple:
        """Split a directive block into (arguments, options, content, content_offset)."""
        if indented and not indented[0].strip():
            indented.trim_start()
            line_offset += 1
        while indented and not indented[-1].strip():
            indented.trim_end()
        takes_args = directive.required_arguments or directive.optional_arguments
        i = 0
        if indented and (takes_args or directive.option_spec):
            i = next((n for n, line in enumerate(indented) if not line.strip()), len(indented))
            arg_block = indented[:i]
            content = indented[i + 1:]
            content_offset = line_offset + i + 1
        else:
            content = indented
            content_offset = line_offset
            arg_block = []
        options: dict[str, Any] = {}
        if directive.option_spec:
            options, arg_block = self.parse_directive_options(option_presets,
                                                              directive.option_spec, arg_block)
        if arg_block and not takes_args:
            content = arg_block + indented[i:]
            content_offset = line_offset
            arg_block = []
        while content and not content[0].strip():
            content.trim_start()
            content_offset += 1
        arguments = self.parse_directive_arguments(directive, arg_block) if takes_args else []
        if content and not directive.has_content:
            raise MarkupError("no content permitted")
        return arguments, options, content, content_offset

    def parse_directive_options(self, option_presets: dict[str, Any],
                                option_spec: dict[str, Any], arg_block: Any) -> tuple:
        options = option_presets.copy()
        opt_block: Any = []
        for i, line in enumerate(arg_block):
            if re.match(FIELD_MARKER, line):
                opt_block = arg_block[i:]
                arg_block = arg_block[:i]
                break
        if opt_block:
            success, data = self.parse_extension_options(option_spec, opt_block)
            if not success:
                raise MarkupError(data)
            options.update(data)
        return options, arg_block

    def parse_directive_arguments(self, directive: Any, arg_block: Any) -> list[str]:
        required = directive.required_arguments
        optional = directive.optional_arguments
        arg_text = "\n".join(arg_block)
        arguments = arg_text.split()
        if len(arguments) < required:
            raise MarkupError("%s argument(s) required, %s supplied"
                              % (required, len(arguments)))
        if len(arguments) > required + optional:
            if not directive.final_argument_whitespace:
                raise MarkupError("maximum %s argument(s) allowed, %s supplied"
                                  % (required + optional, len(arguments)))
            arguments = arg_text.split(None, required + optional - 1)
        return arguments

    def parse_extension_options(self, option_spec: dict[str, Any], datalines: Any) -> tuple:
        """(1, options) or (0, error text) for a directive option block."""
        node = nodes.field_list()
        newline_offset, blank_finish = self.nested_list_parse(
            datalines, 0, node, initial_state="ExtensionOptions", blank_finish=True)
        if newline_offset != len(datalines):  # incomplete parse of block
            return 0, "invalid option block"
        try:
            options = utils.extract_extension_options(node, option_spec)
        except KeyError as detail:
            return 0, 'unknown option: "%s"' % detail.args[0]
        except (ValueError, TypeError) as detail:
            return 0, "invalid option value: %s" % " ".join(detail.args)
        except utils.ExtensionOptionError as detail:
            return 0, "invalid option data: %s" % " ".join(detail.args)
        if blank_finish:
            return 1, options
        return 0, "option data incompletely parsed"
