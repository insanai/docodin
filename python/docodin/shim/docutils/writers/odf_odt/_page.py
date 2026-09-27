"""Stylesheet, page, header and footer handling of the ODF translator."""

from __future__ import annotations

import os
import re
import subprocess
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

from ._xml import (
    CNSD,
    NAME_SPACE_1,
    SNSD,
    STYLES_NAMESPACE_ATTRIB,
    STYLES_NAMESPACE_DICT,
    TABLEPROPERTYNAMES,
    TABLESTYLEPREFIX,
    Element,
    SubElement,
    TableStyle,
    add_ns,
)

_LONG = {"number:style": "long"}
_TIME_HM = [("number:hours", _LONG), ("number:text", ":"), ("number:minutes", _LONG)]
_TIME_S = [("number:text", ":"), ("number:seconds", _LONG)]
_TIME_AMPM = [("number:text", " "), ("number:am-pm", None)]

# Children of the <number:time-style> elements for the %t1% ... %t4% fields.
_TIME_FIELDS = {
    "t1": _TIME_HM,
    "t2": _TIME_HM + _TIME_S,
    "t3": _TIME_HM + _TIME_AMPM,
    "t4": _TIME_HM + _TIME_S + _TIME_AMPM,
}

# Children of the <number:date-style> elements for the %d1% ... %d5% fields.
_DATE_FIELDS = {
    "d1": [("number:month", _LONG), ("number:text", "/"),
           ("number:day", _LONG), ("number:text", "/"), ("number:year", None)],
    "d2": [("number:month", _LONG), ("number:text", "/"),
           ("number:day", _LONG), ("number:text", "/"), ("number:year", _LONG)],
    "d3": [("number:month", {"number:textual": "true"}), ("number:text", " "),
           ("number:day", None), ("number:text", ", "), ("number:year", _LONG)],
    "d4": [("number:month", {"number:textual": "true", "number:style": "long"}),
           ("number:text", " "),
           ("number:day", None), ("number:text", ", "), ("number:year", _LONG)],
    "d5": [("number:year", _LONG), ("number:text", "-"),
           ("number:month", _LONG), ("number:text", "-"), ("number:day", _LONG)],
}

_FIELD_SPECS = ("p", "P", "t1", "t2", "t3", "t4",
                "d1", "d2", "d3", "d4", "d5", "s", "t", "a")


def _add_number_children(parent, children) -> None:
    """Append the `children` (tag, attrib-or-text) specs to `parent`."""
    for tag, value in children:
        if isinstance(value, str):
            SubElement(parent, tag).text = value
        else:
            SubElement(parent, tag, attrib=value)


class _PageMixin:
    """Stylesheet retrieval, page setup and custom header/footer fields."""

    code_none, code_field, code_text = list(range(3))
    field_pat = re.compile(r"%(..?)%")

    def get_str_stylesheet(self):
        return self.str_stylesheet

    def retrieve_styles(self, extension):
        """Retrieve the stylesheet from a .xml or .odt (zip) file.

        Store in `self.*_styles*` attributes.
        """
        stylespath = self.settings.stylesheet
        ext = os.path.splitext(stylespath)[1]
        if ext == ".xml":
            s1 = Path(stylespath).read_text(encoding="utf-8")
            s2 = ""
        elif ext == extension:
            zfile = zipfile.ZipFile(stylespath, "r")
            s1 = zfile.read("styles.xml")
            s2 = zfile.read("content.xml")
            zfile.close()
        else:
            raise RuntimeError("stylesheet path (%s) must be %s or "
                               ".xml file" % (stylespath, extension))
        self.str_stylesheet = s1
        self.str_stylesheetcontent = s2
        self.dom_stylesheet = ET.fromstring(self.str_stylesheet)
        if not s2:
            return
        # TODO: dom_stylesheetcontent is never used. Remove?
        self.dom_stylesheetcontent = ET.fromstring(self.str_stylesheetcontent)
        self.table_styles = self.extract_table_styles(s2)

    def extract_table_styles(self, styles_str):
        root = ET.fromstring(styles_str)
        table_styles = {}
        auto_styles = root.find("{%s}automatic-styles" % (CNSD["office"], ))
        for stylenode in auto_styles:
            name = stylenode.get("{%s}name" % (CNSD["style"], ))
            if not name.startswith(TABLESTYLEPREFIX):
                continue
            tablename = name.split(".")[0]
            tablestyle = table_styles.get(tablename)
            if tablestyle is None:
                tablestyle = TableStyle()
                table_styles[tablename] = tablestyle
            self._update_table_style(tablestyle, stylenode)
        return table_styles

    def _update_table_style(self, tablestyle, stylenode) -> None:
        """Take background color or border of `tablestyle` from `stylenode`."""
        family = stylenode.get("{%s}family" % (CNSD["style"], ))
        if family == "table":
            properties = stylenode.find("{%s}table-properties" % (CNSD["style"], ))
            property_ = properties.get("{%s}%s" % (CNSD["fo"], "background-color", ))
            if property_ is not None and property_ != "none":
                tablestyle.backgroundcolor = property_
        elif family == "table-cell":
            properties = stylenode.find("{%s}table-cell-properties" % (CNSD["style"], ))
            if properties is not None:
                border = self.get_property(properties)
                if border is not None:
                    tablestyle.border = border

    def get_property(self, stylenode):
        border = None
        for propertyname in TABLEPROPERTYNAMES:
            border = stylenode.get("{%s}%s" % (CNSD["fo"], propertyname, ))
            if border is not None and border != "none":
                return border
        return border

    def add_doc_title(self) -> None:
        text = self.settings.title
        if text:
            self.title = text
            if not self.found_doc_title:
                el = Element("text:p", attrib={
                    "text:style-name": self.rststyle("title"),
                })
                el.text = text
                self.body_text_element.insert(0, el)
        el = self.find_first_text_p(self.body_text_element)
        if el is not None:
            self.attach_page_style(el)

    def find_first_text_p(self, el):
        """Search the generated doc and return the first <text:p> element."""
        if el.tag in ("text:p", "text:h"):
            return el
        for child in el:
            el1 = self.find_first_text_p(child)
            if el1 is not None:
                return el1
        return None

    def attach_page_style(self, el) -> None:
        """Attach the default page style.

        Create an automatic-style that refers to the current style
        of this element and that refers to the default page style.
        """
        current_style = el.get("text:style-name")
        style_name = "P1003"
        el1 = SubElement(
            self.automatic_styles, "style:style", attrib={
                "style:name": style_name,
                "style:master-page-name": "rststyle-pagedefault",
                "style:family": "paragraph",
            }, nsdict=SNSD)
        if current_style:
            el1.set("style:parent-style-name", current_style)
        el.set("text:style-name", style_name)

    def setup_page(self):
        self.setup_paper(self.dom_stylesheet)
        if (len(self.header_content) > 0
                or len(self.footer_content) > 0
                or self.settings.custom_header
                or self.settings.custom_footer):
            self.add_header_footer(self.dom_stylesheet)
        return ET.tostring(self.dom_stylesheet)

    def get_dom_stylesheet(self):
        return self.dom_stylesheet

    def setup_paper(self, root_el) -> None:
        # TODO: only call paperconf, if it is actually used
        # (i.e. page size removed from "styles.odt" with rst2odt_prepstyles.py
        # cf. conditional in walk() below)?
        try:
            dimensions = subprocess.check_output(("paperconf", "-s"),
                                                 stderr=subprocess.STDOUT)
            w, h = (float(s) for s in dimensions.split())
        except (subprocess.CalledProcessError, FileNotFoundError, ValueError):
            self.document.reporter.info("Cannot use `paperconf`, defaulting to Letter.")
            w, h = 612, 792  # default to Letter
        fo = SNSD["fo"]

        def walk(el) -> None:
            if (el.tag == "{%s}page-layout-properties" % SNSD["style"]
                    and "{%s}page-width" % fo not in el.attrib):
                el.attrib["{%s}page-width" % fo] = "%.3fpt" % w
                el.attrib["{%s}page-height" % fo] = "%.3fpt" % h
                el.attrib["{%s}margin-left" % fo] = \
                    el.attrib["{%s}margin-right" % fo] = "%.3fpt" % (.1 * w)
                el.attrib["{%s}margin-top" % fo] = \
                    el.attrib["{%s}margin-bottom" % fo] = "%.3fpt" % (.1 * h)
            else:
                for subel in el:
                    walk(subel)
        walk(root_el)

    def _find_master_page(self, root_el):
        """Return the default master page element of `root_el` or None."""
        master_el = root_el.find("{%s}master-styles" % (NAME_SPACE_1, ))
        if master_el is None:
            return None
        target_attrib = "{%s}name" % (SNSD["style"], )
        target_name = self.rststyle("pagedefault")
        for el in master_el.findall("{%s}master-page" % (SNSD["style"], )):
            if el.get(target_attrib) == target_name:
                return el
        return None

    def add_header_footer(self, root_el) -> None:
        automatic_styles = root_el.find("{%s}automatic-styles" % SNSD["office"])
        master_el = self._find_master_page(root_el)
        if master_el is None:
            return
        self._add_headfoot(master_el, "header", self.header_content,
                           self.settings.custom_header, automatic_styles)
        self._add_headfoot(master_el, "footer", self.footer_content,
                           self.settings.custom_footer, automatic_styles)

    def _add_headfoot(self, master_el, kind, content, custom, automatic_styles) -> None:
        """Add a <style:header> or <style:footer> (`kind`) to `master_el`."""
        if not (content or custom):
            return
        el2 = SubElement(master_el, "style:%s" % kind,
                         attrib=STYLES_NAMESPACE_ATTRIB,
                         nsdict=STYLES_NAMESPACE_DICT)
        for el in content:
            attrkey = add_ns("text:style-name", nsdict=SNSD)
            el.attrib[attrkey] = self.rststyle(kind)
            el2.append(el)
        if custom:
            self.create_custom_headfoot(el2, custom, kind, automatic_styles)

    def create_custom_headfoot(self, parent, text, style_name, automatic_styles):
        parent = SubElement(parent, "text:p", attrib={
            "text:style-name": self.rststyle(style_name),
        })
        current_element = None
        for code, value in self.split_field_specifiers_iter(text):
            if code == self.code_field:
                el1 = None
                if value in _FIELD_SPECS:
                    el1 = self.make_field_element(
                        parent, value, style_name, automatic_styles)
                if el1 is None:
                    raise RuntimeError("bad field spec: %%%s%%" % (value, ))
                current_element = el1
            elif current_element is None:
                parent.text = value
            else:
                current_element.tail = value

    def make_field_element(self, parent, text, style_name, automatic_styles):
        if text in _TIME_FIELDS:
            return self._make_time_field(parent, text, style_name, automatic_styles)
        if text in _DATE_FIELDS:
            return self._make_date_field(parent, text, style_name, automatic_styles)
        if text == "p":
            return SubElement(parent, "text:page-number", attrib={
                "text:select-page": "current",
            })
        if text == "P":
            return SubElement(parent, "text:page-count", attrib={})
        if text in ("s", "t"):
            tag = "text:subject" if text == "s" else "text:title"
            return SubElement(parent, tag, attrib={
                "text:style-name": self.rststyle(style_name),
            })
        if text == "a":
            return SubElement(parent, "text:author-name", attrib={
                "text:fixed": "false",
            })
        return None

    def _make_time_field(self, parent, text, style_name, automatic_styles):
        self.style_index += 1
        el1 = SubElement(parent, "text:time", attrib={
            "text:style-name": self.rststyle(style_name),
            "text:fixed": "true",
            "style:data-style-name": "rst-time-style-%d" % self.style_index,
        })
        el2 = SubElement(automatic_styles, "number:time-style", attrib={
            "style:name": "rst-time-style-%d" % self.style_index,
            "xmlns:number": SNSD["number"],
            "xmlns:style": SNSD["style"],
        })
        _add_number_children(el2, _TIME_FIELDS[text])
        return el1

    def _make_date_field(self, parent, text, style_name, automatic_styles):
        self.style_index += 1
        el1 = SubElement(parent, "text:date", attrib={
            "text:style-name": self.rststyle(style_name),
            "style:data-style-name": "rst-date-style-%d" % self.style_index,
        })
        attrib = {"style:name": "rst-date-style-%d" % self.style_index}
        if text != "d5":
            attrib["number:automatic-order"] = "true"
        attrib["xmlns:number"] = SNSD["number"]
        attrib["xmlns:style"] = SNSD["style"]
        el2 = SubElement(automatic_styles, "number:date-style", attrib=attrib)
        _add_number_children(el2, _DATE_FIELDS[text])
        return el1

    def split_field_specifiers_iter(self, text):
        pos1 = 0
        while mo := self.field_pat.search(text, pos1):
            pos2 = mo.start()
            if pos2 > pos1:
                yield self.code_text, text[pos1:pos2]
            yield self.code_field, mo.group(1)
            pos1 = mo.end()
        trailing = text[pos1:]
        if trailing:
            yield self.code_text, trailing
