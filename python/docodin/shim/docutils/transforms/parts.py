"""Transforms for the "sectnum" and "contents" directives."""

from __future__ import annotations

import sys
from typing import Any

from docutils import nodes
from docutils.transforms import Transform

__docformat__ = "reStructuredText"


class SectNum(Transform):
    """Automatically assign numbers to the titles of document sections."""

    default_priority = 710

    def apply(self) -> None:
        details = self.startnode.details
        self.maxdepth = details.get("depth", None)
        self.startvalue = details.get("start", 1)
        self.prefix = details.get("prefix", "")
        self.suffix = details.get("suffix", "")
        self.startnode.parent.remove(self.startnode)
        settings = self.document.settings
        if settings.sectnum_xform:
            if self.maxdepth is None:
                self.maxdepth = sys.maxsize
            self.update_section_numbers(self.document)
        else:  # the writer numbers the sections
            settings.sectnum_depth = self.maxdepth
            settings.sectnum_start = self.startvalue
            settings.sectnum_prefix = self.prefix
            settings.sectnum_suffix = self.suffix

    def update_section_numbers(self, node: nodes.Element, prefix: tuple[str, ...] = (),
                               depth: int = 0) -> None:
        depth += 1
        sectnum = 1 if prefix else self.startvalue
        for child in node:
            if not isinstance(child, nodes.section):
                continue
            numbers = (*prefix, str(sectnum))
            title = child[0]
            generated = nodes.generated(
                "", self.prefix + ".".join(numbers) + self.suffix + "\xa0" * 3,
                classes=["sectnum"])
            title.insert(0, generated)
            title["auto"] = 1
            if depth < self.maxdepth:
                self.update_section_numbers(child, numbers, depth)
            sectnum += 1


class Contents(Transform):
    """Generate a table of contents from the section titles."""

    default_priority = 720

    def apply(self) -> None:
        if getattr(self.document.settings, "use_latex_toc", False):
            return
        details = self.startnode.details
        if "local" in details:
            startnode = self.startnode.parent.parent
            while not isinstance(startnode, (nodes.section, nodes.document)):
                startnode = startnode.parent
        else:
            startnode = self.document
        self.toc_id = self.startnode.parent["ids"][0]
        self.backlinks = details.get("backlinks", self.document.settings.toc_backlinks)
        contents = self.build_contents(startnode)
        if len(contents):
            self.startnode.replace_self(contents)
        else:
            self.startnode.parent.parent.remove(self.startnode.parent)

    def build_contents(self, node: nodes.Element, level: int = 0) -> Any:
        level += 1
        sections = [sect for sect in node if isinstance(sect, nodes.section)]
        entries = []
        auto = None
        depth = self.startnode.details.get("depth", sys.maxsize)
        for section in sections:
            title = section[0]
            auto = title.get("auto")
            entries.append(self._entry(section, title, level, depth))
        if not entries:
            return []
        contents = nodes.bullet_list("", *entries)
        if auto:
            contents["classes"].append("auto-toc")
        return contents

    def _entry(self, section: nodes.section, title: nodes.title, level: int,
               depth: int) -> nodes.list_item:
        entrytext = self.copy_and_filter(title)
        reference = nodes.reference("", "", *entrytext, refid=section["ids"][0])
        ref_id = self.document.set_id(reference, suggested_prefix="toc-entry")
        item = nodes.list_item("", nodes.paragraph("", "", reference))
        if self.backlinks in ("entry", "top") and title.next_node(nodes.reference) is None:
            title["refid"] = ref_id if self.backlinks == "entry" else self.toc_id
        if level < depth:
            item += self.build_contents(section, level)
        return item

    def copy_and_filter(self, node: nodes.Element) -> list[nodes.Node]:
        """Copy of `node`'s children without references, footnote references etc."""
        visitor = ContentsFilter(self.document)
        node.walkabout(visitor)
        return visitor.get_entry_text()


class ContentsFilter(nodes.TreeCopyVisitor):
    """Copy a title for the table of contents (dropping links and notes)."""

    def get_entry_text(self) -> list[nodes.Node]:
        return self.get_tree_copy().children

    def visit_citation_reference(self, node: nodes.Node) -> None:
        raise nodes.SkipNode

    def visit_footnote_reference(self, node: nodes.Node) -> None:
        raise nodes.SkipNode

    def visit_image(self, node: nodes.Element) -> None:
        if node.hasattr("alt"):
            self.parent.append(nodes.Text(node["alt"]))
        raise nodes.SkipNode

    def ignore_node_but_process_children(self, node: nodes.Node) -> None:
        raise nodes.SkipDeparture

    visit_problematic = ignore_node_but_process_children
    visit_reference = ignore_node_but_process_children
    visit_target = ignore_node_but_process_children
