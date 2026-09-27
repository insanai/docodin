"""Directives for additional body elements."""

from __future__ import annotations

from typing import Any

from docutils import nodes
from docutils.parsers.rst import Directive, directives
from docutils.parsers.rst.roles import normalize_options
from docutils.utils.code_analyzer import Lexer, LexerError, NumberLines

__docformat__ = "reStructuredText"

_CLASS_NAME = {"class": directives.class_option, "name": directives.unchanged}


class BasePseudoSection(Directive):
    final_argument_whitespace = True
    option_spec = dict(_CLASS_NAME)
    has_content = True
    node_class: type | None = None
    """Node class to be used (must be set in subclasses)."""
    invalid_parents = (nodes.SubStructural, nodes.Bibliographic, nodes.Decorative, nodes.Body,
                       nodes.Part, nodes.topic)

    def run(self) -> list[nodes.Node]:
        parent = self.state_machine.node
        if (not isinstance(parent, (nodes.Root, nodes.section, nodes.sidebar))
                and isinstance(parent, self.invalid_parents)):
            raise self.error('The "%s" directive may not be used within topics or body '
                             "elements." % self.name)
        self.assert_has_content()
        titles, messages = self._titles()
        text = "\n".join(self.content)
        node = self.node_class(text, *titles, *messages)
        node["classes"] += self.options.get("class", [])
        node.source, node.line = self.state_machine.get_source_and_line(self.lineno)
        self.add_name(node)
        if text:
            self.state.nested_parse(self.content, self.content_offset, node)
        return [node]

    def _titles(self) -> tuple[list[nodes.Element], list[nodes.system_message]]:
        if not self.arguments:  # title (in sidebars optional)
            return [], []
        title_text = self.arguments[0]
        textnodes, messages = self.state.inline_text(title_text, self.lineno)
        titles = [nodes.title(title_text, "", *textnodes)]
        if "subtitle" in self.options:  # sidebar
            textnodes, more_messages = self.state.inline_text(self.options["subtitle"],
                                                              self.lineno)
            titles.append(nodes.subtitle(self.options["subtitle"], "", *textnodes))
            messages.extend(more_messages)
        return titles, messages


class Topic(BasePseudoSection):
    required_arguments = 1
    node_class = nodes.topic


class Sidebar(BasePseudoSection):
    optional_arguments = 1
    node_class = nodes.sidebar
    option_spec = BasePseudoSection.option_spec | {"subtitle": directives.unchanged_required}

    def run(self) -> list[nodes.Node]:
        if isinstance(self.state_machine.node, nodes.sidebar):
            raise self.error('The "%s" directive may not be used within a sidebar element.'
                             % self.name)
        if "subtitle" in self.options and not self.arguments:
            raise self.error('The "subtitle" option may not be used without a title.')
        return BasePseudoSection.run(self)


class LineBlock(Directive):
    option_spec = dict(_CLASS_NAME)
    has_content = True

    def run(self) -> list[nodes.Node]:
        self.assert_has_content()
        block = nodes.line_block(classes=self.options.get("class", []))
        block.source, block.line = self.state_machine.get_source_and_line(self.lineno)
        self.add_name(block)
        node_list: list[nodes.Node] = [block]
        for i, line_text in enumerate(self.content):
            text_nodes, messages = self.state.inline_text(line_text.strip(),
                                                          self.lineno + self.content_offset)
            line = nodes.line(line_text, "", *text_nodes)
            line.source = block.source
            line.line = block.line + i
            if line_text.strip():
                line.indent = len(line_text) - len(line_text.lstrip())
            block += line
            node_list.extend(messages)
            self.content_offset += 1
        self.state.nest_line_block_lines(block)
        return node_list


class ParsedLiteral(Directive):
    option_spec = dict(_CLASS_NAME)
    has_content = True

    def run(self) -> list[nodes.Node]:
        options = normalize_options(self.options)
        self.assert_has_content()
        text = "\n".join(self.content)
        text_nodes, messages = self.state.inline_text(text, self.lineno)
        node = nodes.literal_block(text, "", *text_nodes, **options)
        node.line = self.content_offset + 1
        self.add_name(node)
        return [node, *messages]


class CodeBlock(Directive):
    """Parse and mark up content of a code block."""

    optional_arguments = 1
    option_spec = {**_CLASS_NAME, "number-lines": directives.unchanged}
    has_content = True

    def run(self) -> list[nodes.Node]:
        self.assert_has_content()
        language = self.arguments[0] if self.arguments else ""
        options = normalize_options(self.options)
        classes = ["code"]
        if language:
            classes.append(language)
        if "classes" in options:
            classes.extend(options["classes"])
        tokens = self._tokens(language)
        if "number-lines" in options:
            try:
                startline = int(options["number-lines"] or 1)
            except ValueError:
                raise self.error(":number-lines: with non-integer start value") from None
            tokens = NumberLines(tokens, startline, startline + len(self.content))
        node = nodes.literal_block("\n".join(self.content), classes=classes)
        self.add_name(node)
        if "source" in options:
            node.attributes["source"] = options["source"]
        for token_classes, value in tokens:
            if token_classes:
                node += nodes.inline(value, value, classes=token_classes)
            else:  # insert as Text to decrease the verbosity of the output
                node += nodes.Text(value)
        return [node]

    def _tokens(self, language: str) -> Any:
        code = "\n".join(self.content)
        try:
            return Lexer(code, language, self.state.document.settings.syntax_highlight)
        except LexerError as error:
            if self.state.document.settings.report_level > 2:
                # don't report warnings -> insert without syntax highlight
                return Lexer(code, language, "none")
            raise self.warning(error) from None


class MathBlock(Directive):
    option_spec = dict(_CLASS_NAME)
    has_content = True

    def run(self) -> list[nodes.Node]:
        options = normalize_options(self.options)
        self.assert_has_content()
        # join lines, separate blocks
        blocks = "\n".join(self.content).split("\n\n")
        math_nodes = []
        for block in blocks:
            if not block:
                continue
            node = nodes.math_block(self.block_text, block, **options)
            node.source, node.line = self.state_machine.get_source_and_line(self.lineno)
            self.add_name(node)
            math_nodes.append(node)
        return math_nodes


class Rubric(Directive):
    required_arguments = 1
    optional_arguments = 0
    final_argument_whitespace = True
    option_spec = dict(_CLASS_NAME)

    def run(self) -> list[nodes.Node]:
        options = normalize_options(self.options)
        rubric_text = self.arguments[0]
        textnodes, messages = self.state.inline_text(rubric_text, self.lineno)
        rubric = nodes.rubric(rubric_text, "", *textnodes, **options)
        self.add_name(rubric)
        return [rubric, *messages]


class BlockQuote(Directive):
    has_content = True
    classes: list[str] = []

    def run(self) -> list[nodes.Node]:
        self.assert_has_content()
        elements = self.state.block_quote(self.content, self.content_offset)
        for element in elements:
            if isinstance(element, nodes.block_quote):
                element["classes"] += self.classes
        return elements


class Epigraph(BlockQuote):
    classes = ["epigraph"]


class Highlights(BlockQuote):
    classes = ["highlights"]


class PullQuote(BlockQuote):
    classes = ["pull-quote"]


class Compound(Directive):
    option_spec = dict(_CLASS_NAME)
    has_content = True

    def run(self) -> list[nodes.Node]:
        self.assert_has_content()
        text = "\n".join(self.content)
        node = nodes.compound(text)
        node["classes"] += self.options.get("class", [])
        node.source, node.line = self.state_machine.get_source_and_line(self.lineno)
        self.add_name(node)
        self.state.nested_parse(self.content, self.content_offset, node)
        return [node]


class Container(Directive):
    optional_arguments = 1
    final_argument_whitespace = True
    option_spec = {"name": directives.unchanged}
    has_content = True

    def run(self) -> list[nodes.Node]:
        self.assert_has_content()
        text = "\n".join(self.content)
        try:
            classes = directives.class_option(self.arguments[0]) if self.arguments else []
        except ValueError:
            raise self.error('Invalid class attribute value for "%s" directive: "%s".'
                             % (self.name, self.arguments[0])) from None
        node = nodes.container(text)
        node["classes"].extend(classes)
        node.source, node.line = self.state_machine.get_source_and_line(self.lineno)
        self.add_name(node)
        self.state.nested_parse(self.content, self.content_offset, node)
        return [node]
