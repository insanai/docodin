"""Directives for document parts."""

from __future__ import annotations

from docutils import languages, nodes
from docutils.parsers.rst import Directive, directives
from docutils.parsers.rst.directives.body import BasePseudoSection
from docutils.transforms import parts

__docformat__ = "reStructuredText"


class Contents(Directive):
    """Table of contents (a "pending" transform, processed later)."""

    backlinks_values = ("top", "entry", "none")

    def backlinks(arg: str) -> str | None:  # noqa: N805 - option converter
        value = directives.choice(arg, Contents.backlinks_values)
        return None if value == "none" else value

    optional_arguments = 1
    final_argument_whitespace = True
    option_spec = {"depth": directives.nonnegative_int, "local": directives.flag,
                   "backlinks": backlinks, "class": directives.class_option}

    def run(self) -> list[nodes.Node]:
        parent = self.state_machine.node
        if (not isinstance(parent, (nodes.Root, nodes.section, nodes.sidebar))
                and isinstance(parent, BasePseudoSection.invalid_parents)):
            raise self.error('The "%s" directive may not be used within topics or body '
                             "elements." % self.name)
        document = self.state_machine.document
        language = languages.get_language(document.settings.language_code, document.reporter)
        messages: list[nodes.Node] = []
        if self.arguments:
            title_text = self.arguments[0]
            text_nodes, messages = self.state.inline_text(title_text, self.lineno)
            title = nodes.title(title_text, "", *text_nodes)
        elif "local" in self.options:
            title = None
        else:
            title = nodes.title("", language.labels["contents"])
        topic = nodes.topic(classes=["contents"])
        topic["classes"] += self.options.get("class", [])
        # the latex2e writer needs source and line for a warning:
        topic.source, topic.line = self.state_machine.get_source_and_line()
        topic.line -= 1
        if "local" in self.options:
            topic["classes"].append("local")
        if title:
            name = title.astext()
            topic += title
        else:
            name = language.labels["contents"]
        name = nodes.fully_normalize_name(name)
        if not document.has_name(name):
            topic["names"].append(name)
        document.note_implicit_target(topic)
        pending = nodes.pending(parts.Contents, rawsource=self.block_text)
        pending.details.update(self.options)
        document.note_pending(pending)
        topic += pending
        return [topic, *messages]


class Sectnum(Directive):
    """Automatic section numbering."""

    option_spec = {"depth": int, "start": int, "prefix": directives.unchanged_required,
                   "suffix": directives.unchanged_required}

    def run(self) -> list[nodes.Node]:
        pending = nodes.pending(parts.SectNum)
        pending.details.update(self.options)
        self.state_machine.document.note_pending(pending)
        return [pending]


class Header(Directive):
    """Contents of document header."""

    has_content = True

    def run(self) -> list[nodes.Node]:
        self.assert_has_content()
        header = self.state_machine.document.get_decoration().get_header()
        self.state.nested_parse(self.content, self.content_offset, header)
        return []


class Footer(Directive):
    """Contents of document footer."""

    has_content = True

    def run(self) -> list[nodes.Node]:
        self.assert_has_content()
        footer = self.state_machine.document.get_decoration().get_footer()
        self.state.nested_parse(self.content, self.content_offset, footer)
        return []
