"""Lists, topics (table of contents) and admonitions of the ODF translator."""

from __future__ import annotations

import docutils.nodes

from ._xml import SubElement


class _BlocksMixin:
    """Visitor methods for lists, topics and admonitions."""

    #
    # Lists

    def _block_list_styles(self, kind):
        """Return (list style, item style) of a `kind` list in a block quote.

        `kind` is "bullet" or "enum". Return None outside of block quotes.
        """
        for block in ("blockquote", "highlights", "epigraph"):
            if self.blockstyle == self.rststyle(block):
                return (self.rststyle("%s-%slist" % (block, kind)),
                        self.rststyle("%s-%sitem" % (block, kind)))
        return None

    def _open_list(self, list_style, item_style) -> None:
        el = SubElement(self.current_element, "text:list", attrib={
            "text:style-name": list_style,
        })
        self.list_style_stack.append(item_style)
        self.set_current_element(el)

    def visit_bullet_list(self, node) -> None:
        self.list_level += 1
        if self.in_table_of_contents:
            if self.settings.generate_oowriter_toc:
                return
            if "classes" in node and "auto-toc" in node.attributes["classes"]:
                styles = self.rststyle("tocenumlist"), self.rststyle("enumitem")
            else:
                styles = self.rststyle("tocbulletlist"), self.rststyle("bulletitem")
        else:
            styles = self._block_list_styles("bullet") or (
                self.rststyle("bulletlist"), self.rststyle("bulletitem"))
        self._open_list(*styles)

    def depart_bullet_list(self, node) -> None:
        if not (self.in_table_of_contents and self.settings.generate_oowriter_toc):
            self.set_to_parent()
            self.list_style_stack.pop()
        self.list_level -= 1

    def visit_enumerated_list(self, node) -> None:
        styles = self._block_list_styles("enum")
        if styles is None:
            liststylename = "enumlist-%s" % (node.get("enumtype", "arabic"), )
            styles = self.rststyle(liststylename), self.rststyle("enumitem")
        self._open_list(*styles)

    def depart_enumerated_list(self, node) -> None:
        self.set_to_parent()
        self.list_style_stack.pop()

    def visit_list_item(self, node) -> None:
        # If we are in a "bumped" list level, then wrap this
        #   list in an outer lists in order to increase the
        #   indentation level.
        if self.in_table_of_contents:
            if self.settings.generate_oowriter_toc:
                self.paragraph_style_stack.append(
                    self.rststyle("contents-%d" % (self.list_level, )))
            else:
                el1 = self.append_child("text:list-item")
                self.set_current_element(el1)
            return
        el3 = self.append_child("text:list-item")
        if self.bumped_list_level_stack:
            level_obj = self.bumped_list_level_stack[-1]
            if level_obj.get_sibling():
                level_obj.set_nested(False)
                for level_obj1 in self.bumped_list_level_stack:
                    for _idx in range(level_obj1.get_level()):
                        el2 = self.append_child("text:list", parent=el3)
                        el3 = self.append_child("text:list-item", parent=el2)
        self.paragraph_style_stack.append(self.list_style_stack[-1])
        self.set_current_element(el3)

    def depart_list_item(self, node) -> None:
        if self.in_table_of_contents:
            if self.settings.generate_oowriter_toc:
                self.paragraph_style_stack.pop()
            else:
                self.set_to_parent()
            return
        if self.bumped_list_level_stack:
            level_obj = self.bumped_list_level_stack[-1]
            if level_obj.get_sibling():
                level_obj.set_nested(True)
                for level_obj1 in self.bumped_list_level_stack:
                    for _idx in range(level_obj1.get_level()):
                        self.set_to_parent()
                        self.set_to_parent()
        self.paragraph_style_stack.pop()
        self.set_to_parent()

    #
    # Topics and table of contents

    def generate_table_of_content_entry_template(self, el1) -> None:
        for idx in range(1, 11):
            el2 = SubElement(el1, "text:table-of-content-entry-template", attrib={
                "text:outline-level": "%d" % (idx, ),
                "text:style-name": self.rststyle("contents-%d" % (idx, )),
            })
            SubElement(el2, "text:index-entry-chapter")
            SubElement(el2, "text:index-entry-text")
            SubElement(el2, "text:index-entry-tab-stop", attrib={
                "style:leader-char": ".",
                "style:type": "right",
            })
            SubElement(el2, "text:index-entry-page-number")

    def find_title_label(self, node, class_type, label_key):
        for child in node.children:
            if isinstance(child, class_type):
                return child.astext()
        return self.language.labels[label_key]

    def _generate_oowriter_toc(self, label) -> None:
        """Start a native ODF table of contents titled `label`."""
        el1 = self.append_child("text:table-of-content", attrib={
            "text:name": "Table of Contents1",
            "text:protected": "true",
            "text:style-name": "Sect1",
        })
        el2 = SubElement(el1, "text:table-of-content-source",
                         attrib={"text:outline-level": "10"})
        el3 = SubElement(el2, "text:index-title-template", attrib={
            "text:style-name": "Contents_20_Heading",
        })
        el3.text = label
        self.generate_table_of_content_entry_template(el2)
        el4 = SubElement(el1, "text:index-body")
        el5 = SubElement(el4, "text:index-title")
        el6 = SubElement(el5, "text:p", attrib={
            "text:style-name": self.rststyle("contents-heading"),
        })
        el6.text = label
        self.save_current_element = self.current_element
        self.table_of_content_index_body = el4
        self.set_current_element(el4)

    def _generate_topic_heading(self, label) -> None:
        """Append a horizontal line and the centered strong `label`."""
        self.append_p("horizontalline")
        self._append_strong_label("centeredtextbody", label)

    def visit_topic(self, node) -> None:
        if "classes" not in node.attributes:
            return
        classes = node.attributes["classes"]
        if "contents" in classes:
            label = self.find_title_label(node, docutils.nodes.title, "contents")
            if self.settings.generate_oowriter_toc:
                self._generate_oowriter_toc(label)
            else:
                self._generate_topic_heading(label)
            self.in_table_of_contents = True
        elif "abstract" in classes:
            self._generate_topic_heading(
                self.find_title_label(node, docutils.nodes.title, "abstract"))
        elif "dedication" in classes:
            self._generate_topic_heading(
                self.find_title_label(node, docutils.nodes.title, "dedication"))

    def depart_topic(self, node) -> None:
        if "classes" in node.attributes and "contents" in node.attributes["classes"]:
            if self.settings.generate_oowriter_toc:
                self.update_toc_page_numbers(self.table_of_content_index_body)
                self.set_current_element(self.save_current_element)
            else:
                self.append_p("horizontalline")
            self.in_table_of_contents = False

    def update_toc_page_numbers(self, el) -> None:
        collection = []
        self.update_toc_collect(el, 0, collection)
        self.update_toc_add_numbers(collection)

    def update_toc_collect(self, el, level, collection) -> None:
        collection.append((level, el))
        level += 1
        for child_el in el:
            if child_el.tag != "text:index-body":
                self.update_toc_collect(child_el, level, collection)

    def update_toc_add_numbers(self, collection) -> None:
        for _level, el1 in collection:
            if el1.tag == "text:p" and el1.text != "Table of Contents":
                el2 = SubElement(el1, "text:tab")
                el2.tail = "9999"

    #
    # Admonitions
    #
    def visit_warning(self, node) -> None:
        self.generate_admonition(node, "warning")

    def depart_warning(self, node) -> None:
        self.paragraph_style_stack.pop()

    def visit_attention(self, node) -> None:
        self.generate_admonition(node, "attention")

    depart_attention = depart_warning

    def visit_caution(self, node) -> None:
        self.generate_admonition(node, "caution")

    depart_caution = depart_warning

    def visit_danger(self, node) -> None:
        self.generate_admonition(node, "danger")

    depart_danger = depart_warning

    def visit_error(self, node) -> None:
        self.generate_admonition(node, "error")

    depart_error = depart_warning

    def visit_hint(self, node) -> None:
        self.generate_admonition(node, "hint")

    depart_hint = depart_warning

    def visit_important(self, node) -> None:
        self.generate_admonition(node, "important")

    depart_important = depart_warning

    def visit_note(self, node) -> None:
        self.generate_admonition(node, "note")

    depart_note = depart_warning

    def visit_tip(self, node) -> None:
        self.generate_admonition(node, "tip")

    depart_tip = depart_warning

    def visit_admonition(self, node) -> None:
        title = None
        for child in node.children:
            if child.tagname == "title":
                title = child.astext()
        if title is None:
            classes1 = node.get("classes")
            if classes1:
                title = classes1[0]
        self.generate_admonition(node, "generic", title)

    depart_admonition = depart_warning

    def generate_admonition(self, node, label, title=None) -> None:
        if hasattr(self.language, "labels"):
            translated_label = self.language.labels.get(label, label)
        else:
            translated_label = label
        el1 = SubElement(self.current_element, "text:p", attrib={
            "text:style-name": self.rststyle("admon-%s-hdr", (label, )),
        })
        if title:
            el1.text = title
        else:
            el1.text = "%s!" % (translated_label.capitalize(), )
        s1 = self.rststyle("admon-%s-body", (label, ))
        self.paragraph_style_stack.append(s1)
