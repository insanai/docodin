"""Helpers of the reStructuredText ``Body`` state: explicit markup.

`ExplicitHelpers` parses the constructs that start with ".." (footnotes,
citations, hyperlink targets, substitution definitions, directives and
comments) and anonymous targets ("__").  Directives and extensions call
the directive helpers (``parse_directive_block`` ...) directly.
"""

from __future__ import annotations

import re
from types import FunctionType, MethodType
from types import SimpleNamespace as Struct
from typing import Any

from docutils import ApplicationError, nodes, statemachine, utils
from docutils.nodes import fully_normalize_name as normalize_name
from docutils.nodes import unescape, whitespace_normalize_name
from docutils.parsers.rst import directives
from docutils.utils import escape2null, split_escaped_whitespace

from ._body import FIELD_MARKER, MarkupError
from ._inliner import Inliner

_INLINER_ARGS = vars(Inliner)

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

_FOOTNOTE_START = r"""
    \.\.[ ]+          # explicit markup start
    \[
    (                 # footnote label:
        [0-9]+          # manually numbered footnote
      |               # *OR*
        \#              # anonymous auto-numbered footnote
      |               # *OR*
        \#%s            # auto-numbered footnote with a label
      |               # *OR*
        \*              # auto-symbol footnote
    )
    \]
    ([ ]+|$)          # whitespace or end of line
    """ % Inliner.simplename

_CITATION_START = r"""
    \.\.[ ]+          # explicit markup start
    \[(%s)\]          # citation label
    ([ ]+|$)          # whitespace or end of line
    """ % Inliner.simplename

_TARGET_START = r"""
    \.\.[ ]+          # explicit markup start
    _                 # target indicator
    (?![ ]|$)         # first char. not space or EOL
    """

_SUBSTITUTION_START = r"""
    \.\.[ ]+          # explicit markup start
    \|                # substitution indicator
    (?![ ]|$)         # first char. not space or EOL
    """

_DIRECTIVE_START = r"""
    \.\.[ ]+          # explicit markup start
    (%s)              # directive name
    [ ]?              # optional space
    ::                # directive delimiter
    ([ ]+|$)          # whitespace or end of line
    """ % Inliner.simplename


def _match_joined(pattern: re.Pattern[str], lines: list[str], separator: str,
                  error: str) -> tuple[re.Match[str], int, str]:
    """Match `pattern` against the first lines of `lines`, joined one by one.

    Returns (match, number of lines added, joined text); MarkupError(`error`)
    when no prefix of the lines matches.
    """
    joined = lines[0]
    index = 0
    while True:
        match = pattern.match(joined)
        if match:
            return match, index, joined
        index += 1
        try:
            joined += separator + lines[index]
        except IndexError:
            raise MarkupError(error) from None


class ExplicitHelpers:
    """Mix-in of ``Body``: explicit markup constructs and directives."""

    explicit = Struct(patterns=Struct(
        target=re.compile(_TARGET_PATTERN % _INLINER_ARGS, re.VERBOSE),
        reference=re.compile(_REFERENCE_PATTERN % _INLINER_ARGS, re.VERBOSE),
        substitution=re.compile(_SUBSTITUTION_PATTERN % _INLINER_ARGS, re.VERBOSE)))

    # --- footnotes and citations ----------------------------------------------------

    def footnote(self, match: re.Match[str]) -> tuple[list, bool]:
        src, srcline = self.state_machine.get_source_and_line()
        indented, _indent, offset, blank_finish = (
            self.state_machine.get_first_known_indented(match.end()))
        label = match.group(1)
        name = normalize_name(label)
        footnote = nodes.footnote("\n".join(indented))
        footnote.source = src
        footnote.line = srcline
        if name[0] == "#":  # auto-numbered
            name = name[1:]
            footnote["auto"] = 1
            if name:
                footnote["names"].append(name)
            self.document.note_autofootnote(footnote)
        elif name == "*":  # auto-symbol
            name = ""
            footnote["auto"] = "*"
            self.document.note_symbol_footnote(footnote)
        else:  # manually numbered
            footnote += nodes.label("", label)
            footnote["names"].append(name)
            self.document.note_footnote(footnote)
        if name:
            self.document.note_explicit_target(footnote, footnote)
        else:
            self.document.set_id(footnote, footnote)
        if indented:
            self.nested_parse(indented, input_offset=offset, node=footnote)
        else:
            footnote += self.reporter.warning("Footnote content expected.")
        return [footnote], blank_finish

    def citation(self, match: re.Match[str]) -> tuple[list, bool]:
        src, srcline = self.state_machine.get_source_and_line()
        indented, _indent, offset, blank_finish = (
            self.state_machine.get_first_known_indented(match.end()))
        label = match.group(1)
        name = normalize_name(label)
        citation = nodes.citation("\n".join(indented))
        citation.source = src
        citation.line = srcline
        citation += nodes.label("", label)
        citation["names"].append(name)
        self.document.note_citation(citation)
        self.document.note_explicit_target(citation, citation)
        if indented:
            self.nested_parse(indented, input_offset=offset, node=citation)
        else:
            citation += self.reporter.warning("Citation content expected.")
        return [citation], blank_finish

    # --- hyperlink targets ---------------------------------------------------------------

    def hyperlink_target(self, match: re.Match[str]) -> tuple[list, bool]:
        lineno = self.state_machine.abs_line_number()
        block, _indent, _offset, blank_finish = self.state_machine.get_first_known_indented(
            match.end(), until_blank=True, strip_indent=False)
        blocktext = match.string[:match.end()] + "\n".join(block)
        block = [escape2null(line) for line in block]
        targetmatch, index, escaped = _match_joined(
            self.explicit.patterns.target, block, "", "malformed hyperlink target.")
        del block[:index]
        block[0] = (block[0] + " ")[targetmatch.end() - len(escaped) - 1:].strip()
        target = self.make_target(block, blocktext, lineno, targetmatch.group("name"))
        return [target], blank_finish

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

    def anonymous_target(self, match: re.Match[str]) -> tuple[list, bool]:
        lineno = self.state_machine.abs_line_number()
        block, _indent, _offset, blank_finish = self.state_machine.get_first_known_indented(
            match.end(), until_blank=True)
        blocktext = match.string[:match.end()] + "\n".join(block)
        block = [escape2null(line) for line in block]
        target = self.make_target(block, blocktext, lineno, "")
        return [target], blank_finish

    # --- substitution definitions ---------------------------------------------------

    def substitution_def(self, match: re.Match[str]) -> tuple[list, bool]:
        src, srcline = self.state_machine.get_source_and_line()
        block, _indent, offset, blank_finish = self.state_machine.get_first_known_indented(
            match.end(), strip_indent=False)
        blocktext = match.string[:match.end()] + "\n".join(block)
        block.disconnect()
        stripped = [escape2null(block[0].rstrip())]
        stripped += [escape2null(line.strip()) for line in block[1:]]
        subdefmatch, index, escaped = _match_joined(
            self.explicit.patterns.substitution, stripped, " ",
            "malformed substitution definition.")
        del block[:index]  # strip out the substitution marker
        block[0] = (block[0].strip() + " ")[subdefmatch.end() - len(escaped) - 1:-1]
        if not block[0]:
            del block[0]
            offset += 1
        while block and not block[-1].strip():
            block.pop()
        subname = subdefmatch.group("name")
        substitution_node = nodes.substitution_definition(blocktext)
        substitution_node.source = src
        substitution_node.line = srcline
        if not block:
            msg = self.reporter.warning(
                'Substitution definition "%s" missing contents.' % subname,
                nodes.literal_block(blocktext, blocktext), source=src, line=srcline)
            return [msg], blank_finish
        block[0] = block[0].strip()
        substitution_node["names"].append(whitespace_normalize_name(subname))
        _new_offset, blank_finish = self.nested_list_parse(
            block, input_offset=offset, node=substitution_node,
            initial_state="SubstitutionDef", blank_finish=blank_finish)
        return self._check_substitution(substitution_node, subname, blocktext,
                                        src, srcline), blank_finish

    def _check_substitution(self, substitution_node: nodes.substitution_definition,
                            subname: str, blocktext: str, src: Any, srcline: Any) -> list:
        """Move block elements out of a parsed substitution definition and
        validate its content; [definition] or [error message]."""
        i = 0
        for node in substitution_node[:]:
            if isinstance(node, (nodes.Inline, nodes.Text)):
                i += 1
            else:
                self.parent += substitution_node[i]
                del substitution_node[i]
        for node in substitution_node.findall(nodes.Element, include_self=False):
            if isinstance(node, nodes.problematic):
                msg = self.reporter.error(
                    "Problematic content in substitution definition",
                    nodes.literal_block("", blocktext), source=src, line=srcline)
                msg.append(nodes.block_quote(
                    "", nodes.paragraph("", "", *substitution_node.children)))
                return [msg]
            illegal = self.disallowed_inside_substitution_definitions(node)
            if illegal:
                return [self.reporter.error(
                    f"{illegal} are not supported in a substitution definition.",
                    nodes.literal_block("", blocktext), source=src, line=srcline)]
        if len(substitution_node) == 0:
            return [self.reporter.warning(
                'Substitution definition "%s" empty or invalid.' % subname,
                nodes.literal_block(blocktext, blocktext), source=src, line=srcline)]
        self.document.note_substitution_def(substitution_node, subname, self.parent)
        return [substitution_node]

    def disallowed_inside_substitution_definitions(self, node: nodes.Element) -> str:
        if isinstance(node, nodes.reference) and node.get("anonymous"):
            return "Anonymous references"
        if isinstance(node, nodes.footnote_reference) and node.get("auto"):
            return "References to auto-numbered and auto-symbol footnotes"
        if node["names"] or node["ids"]:
            return "Targets (names and identifiers)"
        return ""

    # --- directives ---------------------------------------------------------------------

    def directive(self, match: re.Match[str], **option_presets: Any) -> tuple[list, bool]:
        """Returns a 2-tuple: list of nodes, and a "blank finish" boolean."""
        type_name = match.group(1)
        directive_class, messages = directives.directive(
            type_name, self.memo.language, self.document)
        self.parent += messages
        if directive_class:
            return self.run_directive(directive_class, match, type_name, option_presets)
        return self.unknown_directive(type_name)

    def run_directive(self, directive: Any, match: re.Match[str], type_name: str,
                      option_presets: dict[str, Any]) -> tuple[list, bool]:
        """Parse a directive block, then run the directive (class or function).

        `option_presets` are default option values (substitution definitions
        pass "alt").  Returns (nodes, blank_finish).
        """
        from docutils.parsers.rst import DirectiveError, convert_directive_function

        if isinstance(directive, (FunctionType, MethodType)):
            directive = convert_directive_function(directive)
        machine = self.state_machine
        lineno = machine.abs_line_number()
        initial_line_offset = machine.line_offset
        indented, _indent, line_offset, blank_finish = machine.get_first_known_indented(
            match.end(), strip_top=0)
        block_text = "\n".join(machine.input_lines[initial_line_offset:machine.line_offset + 1])
        try:
            arguments, options, content, content_offset = self.parse_directive_block(
                indented, line_offset, directive, option_presets)
        except MarkupError as detail:
            error = self.reporter.error(
                'Error in "%s" directive:\n%s.' % (type_name, " ".join(detail.args)),
                nodes.literal_block(block_text, block_text), line=lineno)
            return [error], blank_finish
        directive_instance = directive(type_name, arguments, options, content, lineno,
                                       content_offset, block_text, self, machine)
        try:
            result = directive_instance.run()
        except DirectiveError as error:
            msg_node = self.reporter.system_message(error.level, error.msg, line=lineno)
            msg_node += nodes.literal_block(block_text, block_text)
            result = [msg_node]
        assert isinstance(result, list), 'Directive "%s" must return a list of nodes.' % type_name
        for i, node in enumerate(result):
            assert isinstance(node, nodes.Node), (
                'Directive "%s" returned non-Node object (index %s): %r' % (type_name, i, node))
        return result, blank_finish or machine.is_next_line_blank()

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

    def unknown_directive(self, type_name: str) -> tuple[list, bool]:
        lineno = self.state_machine.abs_line_number()
        indented, _indent, _offset, blank_finish = (
            self.state_machine.get_first_known_indented(0, strip_indent=False))
        text = "\n".join(indented)
        error = self.reporter.error('Unknown directive type "%s".' % type_name,
                                    nodes.literal_block(text, text), line=lineno)
        return [error], blank_finish

    # --- comments and construct dispatch ---------------------------------------------------

    def comment(self, match: re.Match[str]) -> tuple[list, bool]:
        if self.state_machine.is_next_line_blank():
            first_comment_line = match.string[match.end():]
            if not first_comment_line.strip():  # empty comment
                return [nodes.comment()], True  # "A tiny but practical wart."
            if first_comment_line.startswith('end of inclusion from "'):
                # the end marker of parsers.rst.directives.misc.Include
                self.document.include_log.pop()
                return [], True
        indented, _indent, _offset, blank_finish = (
            self.state_machine.get_first_known_indented(match.end()))
        while indented and not indented[-1].strip():
            indented.trim_end()
        text = "\n".join(indented)
        return [nodes.comment(text, text)], blank_finish

    def explicit_construct(self, match: re.Match[str]) -> tuple[list, bool]:
        """Determine which explicit construct this is, parse & return it."""
        errors = []
        for method, pattern in self.explicit.constructs:
            expmatch = pattern.match(match.string)
            if expmatch:
                try:
                    return method(self, expmatch)
                except MarkupError as error:
                    lineno = self.state_machine.abs_line_number()
                    errors.append(self.reporter.warning(" ".join(error.args), line=lineno))
                    break
        nodelist, blank_finish = self.comment(match)
        return nodelist + errors, blank_finish

    def explicit_list(self, blank_finish: bool) -> None:
        """Parse a series of explicit markup constructs (and anonymous targets)
        in a nested ``Explicit`` state machine."""
        offset = self.state_machine.line_offset + 1  # next line
        newline_offset, blank_finish = self.nested_list_parse(
            self.state_machine.input_lines[offset:],
            input_offset=self.state_machine.abs_line_offset() + 1,
            node=self.parent, initial_state="Explicit", blank_finish=blank_finish)
        self.goto_line(newline_offset)
        if not blank_finish:
            self.parent += self.unindent_warning("Explicit markup")


# Like docutils, the constructs hold the helper functions themselves:
# replacing a method on a state class does not change the dispatch.
ExplicitHelpers.explicit.constructs = [
    (ExplicitHelpers.footnote, re.compile(_FOOTNOTE_START, re.VERBOSE)),
    (ExplicitHelpers.citation, re.compile(_CITATION_START, re.VERBOSE)),
    (ExplicitHelpers.hyperlink_target, re.compile(_TARGET_START, re.VERBOSE)),
    (ExplicitHelpers.substitution_def, re.compile(_SUBSTITUTION_START, re.VERBOSE)),
    (ExplicitHelpers.directive, re.compile(_DIRECTIVE_START, re.VERBOSE)),
]
