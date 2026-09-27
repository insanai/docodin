"""Footnote and citation handling of the ODF translator."""

from __future__ import annotations

import copy

import docutils.nodes
from docutils import nodes

from ._xml import SNSD, Element, ListLevel, SubElement, add_ns


class _NotesMixin:
    """Visitor methods for footnotes, citations and their references."""

    def process_footnotes(self) -> None:
        for node, el1 in self.footnote_list:
            backrefs = node.attributes.get("backrefs", [])
            first = True
            for ref in backrefs:
                el2 = self.footnote_ref_dict.get(ref)
                if el2 is None:
                    continue
                if first:
                    first = False
                    el2.append(copy.deepcopy(el1))
                elif len(el2) > 0:
                    self._make_note_ref(el2)

    def _make_note_ref(self, el2) -> None:
        """Turn the additional footnote reference `el2` into a note-ref."""
        ref1 = el2[0].text
        id1 = el2.get(add_ns("text:id", nsdict=SNSD), "footnote-error")
        if id1 is None:
            id1 = ""
        el2.tag = add_ns("text:note-ref", nsdict=SNSD)
        note_class = "endnote" if self.settings.endnotes_end_doc else "footnote"
        el2.attrib.clear()
        el2.attrib[add_ns("text:note-class", nsdict=SNSD)] = note_class
        el2.attrib[add_ns("text:ref-name", nsdict=SNSD)] = id1
        el2.attrib[add_ns("text:reference-format", nsdict=SNSD)] = "page"
        el2.text = ref1

    def visit_footnote(self, node) -> None:
        self.footnote_level += 1
        self.save_footnote_current = self.current_element
        el1 = Element("text:note-body")
        self.current_element = el1
        self.footnote_list.append((node, el1))
        if isinstance(node, docutils.nodes.citation):
            self.paragraph_style_stack.append(self.rststyle("citation"))
        else:
            self.paragraph_style_stack.append(self.rststyle("footnote"))

    def depart_footnote(self, node) -> None:
        self.paragraph_style_stack.pop()
        self.current_element = self.save_footnote_current
        self.footnote_level -= 1

    footnote_chars = [
        "*", "**", "***",
        "++", "+++",
        "##", "###",
        "@@", "@@@",
    ]

    def _footnote_citation_label(self, node):
        """Return the label of the note citation for footnote reference `node`."""
        if isinstance(node, docutils.nodes.citation_reference):
            return "[%s]" % node.astext()
        note_auto = str(node.attributes.get("auto", 1))
        if note_auto == "1":
            return node.astext()
        if note_auto == "*":
            if self.footnote_chars_idx >= len(_NotesMixin.footnote_chars):
                self.footnote_chars_idx = 0
            footnote_char = _NotesMixin.footnote_chars[self.footnote_chars_idx]
            self.footnote_chars_idx += 1
            return footnote_char
        return None

    def visit_footnote_reference(self, node):
        if self.footnote_level <= 0:
            id_ = node.attributes["ids"][0]
            refid = node.attributes.get("refid")
            if refid is None:
                refid = ""
            note_class = "endnote" if self.settings.endnotes_end_doc else "footnote"
            el1 = self.append_child("text:note", attrib={
                "text:id": "%s" % (refid, ),
                "text:note-class": note_class,
            })
            label = self._footnote_citation_label(node)
            if label is not None:
                el2 = SubElement(el1, "text:note-citation", attrib={"text:label": label})
                el2.text = label
            self.footnote_ref_dict[id_] = el1
        raise nodes.SkipChildren

    def depart_footnote_reference(self, node) -> None:
        pass

    def visit_citation(self, node) -> None:
        self.in_citation = True
        for id_ in node.attributes["ids"]:
            self.citation_id = id_
            break
        self.paragraph_style_stack.append(self.rststyle("blockindent"))
        self.bumped_list_level_stack.append(ListLevel(1))

    def depart_citation(self, node) -> None:
        self.citation_id = None
        self.paragraph_style_stack.pop()
        self.bumped_list_level_stack.pop()
        self.in_citation = False

    def visit_citation_reference(self, node) -> None:
        if self.settings.create_links:
            id_ = node.attributes["refid"]
            el = self.append_child("text:reference-ref", attrib={
                "text:ref-name": "%s" % (id_, ),
                "text:reference-format": "text",
            })
            el.text = "["
            self.set_current_element(el)
        elif self.current_element.text is None:
            self.current_element.text = "["
        else:
            self.current_element.text += "["

    def depart_citation_reference(self, node) -> None:
        self.current_element.text += "]"
        if self.settings.create_links:
            self.set_to_parent()

    def visit_label(self, node):
        if isinstance(node.parent, docutils.nodes.footnote):
            raise nodes.SkipChildren
        if self.citation_id is None:
            return
        el = self.append_p("textbody")
        self.set_current_element(el)
        if self.settings.create_links:
            el0 = SubElement(el, "text:span")
            el0.text = "["
            self.append_child("text:reference-mark-start", attrib={
                "text:name": "%s" % (self.citation_id, ),
            })
        else:
            el.text = "["

    def depart_label(self, node) -> None:
        if isinstance(node.parent, docutils.nodes.footnote) or self.citation_id is None:
            return
        if self.settings.create_links:
            self.append_child("text:reference-mark-end", attrib={
                "text:name": "%s" % (self.citation_id, ),
            })
            el0 = SubElement(self.current_element, "text:span")
            el0.text = "]"
        else:
            self.current_element.text += "]"
        self.set_to_parent()
