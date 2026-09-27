"""ElementTree helpers, namespaces and small data classes of the ODF writer.

Everything public here is re-exported by `docutils.writers.odf_odt`.
"""

from __future__ import annotations

import itertools
import re
import weakref
from io import StringIO
from xml.etree import ElementTree as ET

VERSION = "1.0a"

IMAGE_NAME_COUNTER = itertools.count()

#
# ElementTree does not support getparent method (lxml does).
# This wrapper class and the following support functions provide
#   that support for the ability to get the parent of an element.
#
_parents = weakref.WeakKeyDictionary()
if isinstance(ET.Element, type):
    _ElementInterface = ET.Element
else:
    _ElementInterface = ET._ElementInterface


class _ElementInterfaceWrapper(_ElementInterface):
    def __init__(self, tag, attrib=None) -> None:
        _ElementInterface.__init__(self, tag, attrib)
        _parents[self] = None

    def setparent(self, parent) -> None:
        _parents[self] = parent

    def getparent(self):
        return _parents[self]


#
# Constants and globals

SPACES_PATTERN = re.compile(r"( +)")
TABS_PATTERN = re.compile(r"(\t+)")
FILL_PAT1 = re.compile(r"^ +")
FILL_PAT2 = re.compile(r" {2,}")

TABLESTYLEPREFIX = "rststyle-table-"
TABLENAMEDEFAULT = "%s0" % TABLESTYLEPREFIX
TABLEPROPERTYNAMES = (
    "border", "border-top", "border-left",
    "border-right", "border-bottom", )

GENERATOR_DESC = "Docutils.org/odf_odt"

NAME_SPACE_1 = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"

_OASIS = "urn:oasis:names:tc:opendocument:xmlns:"
_NS_CHART = _OASIS + "chart:1.0"
_NS_DC = "http://purl.org/dc/elements/1.1/"
_NS_DOM = "http://www.w3.org/2001/xml-events"
_NS_DR3D = _OASIS + "dr3d:1.0"
_NS_DRAW = _OASIS + "drawing:1.0"
_NS_FO = _OASIS + "xsl-fo-compatible:1.0"
_NS_FORM = _OASIS + "form:1.0"
_NS_MATH = "http://www.w3.org/1998/Math/MathML"
_NS_META = _OASIS + "meta:1.0"
_NS_NUMBER = _OASIS + "datastyle:1.0"
_NS_OOO = "http://openoffice.org/2004/office"
_NS_OOOC = "http://openoffice.org/2004/calc"
_NS_OOOW = "http://openoffice.org/2004/writer"
_NS_PRESENTATION = _OASIS + "presentation:1.0"
_NS_SCRIPT = _OASIS + "script:1.0"
_NS_STYLE = _OASIS + "style:1.0"
_NS_SVG = _OASIS + "svg-compatible:1.0"
_NS_TABLE = _OASIS + "table:1.0"
_NS_TEXT = _OASIS + "text:1.0"
_NS_XFORMS = "http://www.w3.org/2002/xforms"
_NS_XLINK = "http://www.w3.org/1999/xlink"
_NS_XSD = "http://www.w3.org/2001/XMLSchema"
_NS_XSI = "http://www.w3.org/2001/XMLSchema-instance"

CONTENT_NAMESPACE_DICT = CNSD = {
    "chart": _NS_CHART,
    "dc": _NS_DC,
    "dom": _NS_DOM,
    "dr3d": _NS_DR3D,
    "draw": _NS_DRAW,
    "fo": _NS_FO,
    "form": _NS_FORM,
    "math": _NS_MATH,
    "meta": _NS_META,
    "number": _NS_NUMBER,
    "office": NAME_SPACE_1,
    "ooo": _NS_OOO,
    "oooc": _NS_OOOC,
    "ooow": _NS_OOOW,
    "presentation": _NS_PRESENTATION,
    "script": _NS_SCRIPT,
    "style": _NS_STYLE,
    "svg": _NS_SVG,
    "table": _NS_TABLE,
    "text": _NS_TEXT,
    "xforms": _NS_XFORMS,
    "xlink": _NS_XLINK,
    "xsd": _NS_XSD,
    "xsi": _NS_XSI,
}

STYLES_NAMESPACE_DICT = SNSD = {
    "chart": _NS_CHART,
    "dc": _NS_DC,
    "dom": _NS_DOM,
    "dr3d": _NS_DR3D,
    "draw": _NS_DRAW,
    "fo": _NS_FO,
    "form": _NS_FORM,
    "math": _NS_MATH,
    "meta": _NS_META,
    "number": _NS_NUMBER,
    "office": NAME_SPACE_1,
    "presentation": _NS_PRESENTATION,
    "ooo": _NS_OOO,
    "oooc": _NS_OOOC,
    "ooow": _NS_OOOW,
    "script": _NS_SCRIPT,
    "style": _NS_STYLE,
    "svg": _NS_SVG,
    "table": _NS_TABLE,
    "text": _NS_TEXT,
    "xlink": _NS_XLINK,
}

MANIFEST_NAMESPACE_DICT = MANNSD = {
    "manifest": _OASIS + "manifest:1.0",
}

META_NAMESPACE_DICT = METNSD = {
    "dc": _NS_DC,
    "meta": _NS_META,
    "office": NAME_SPACE_1,
    "ooo": _NS_OOO,
    "xlink": _NS_XLINK,
}

# Attribute dictionaries for use with ElementTree, which
# does not support use of nsmap parameter on Element() and SubElement().

CONTENT_NAMESPACE_ATTRIB = {
    "xmlns:chart": _NS_CHART,
    "xmlns:dc": _NS_DC,
    "xmlns:dom": _NS_DOM,
    "xmlns:dr3d": _NS_DR3D,
    "xmlns:draw": _NS_DRAW,
    "xmlns:fo": _NS_FO,
    "xmlns:form": _NS_FORM,
    "xmlns:math": _NS_MATH,
    "xmlns:meta": _NS_META,
    "xmlns:number": _NS_NUMBER,
    "xmlns:office": NAME_SPACE_1,
    "xmlns:presentation": _NS_PRESENTATION,
    "xmlns:ooo": _NS_OOO,
    "xmlns:oooc": _NS_OOOC,
    "xmlns:ooow": _NS_OOOW,
    "xmlns:script": _NS_SCRIPT,
    "xmlns:style": _NS_STYLE,
    "xmlns:svg": _NS_SVG,
    "xmlns:table": _NS_TABLE,
    "xmlns:text": _NS_TEXT,
    "xmlns:xforms": _NS_XFORMS,
    "xmlns:xlink": _NS_XLINK,
    "xmlns:xsd": _NS_XSD,
    "xmlns:xsi": _NS_XSI,
}

STYLES_NAMESPACE_ATTRIB = {
    "xmlns:chart": _NS_CHART,
    "xmlns:dc": _NS_DC,
    "xmlns:dom": _NS_DOM,
    "xmlns:dr3d": _NS_DR3D,
    "xmlns:draw": _NS_DRAW,
    "xmlns:fo": _NS_FO,
    "xmlns:form": _NS_FORM,
    "xmlns:math": _NS_MATH,
    "xmlns:meta": _NS_META,
    "xmlns:number": _NS_NUMBER,
    "xmlns:office": NAME_SPACE_1,
    "xmlns:presentation": _NS_PRESENTATION,
    "xmlns:ooo": _NS_OOO,
    "xmlns:oooc": _NS_OOOC,
    "xmlns:ooow": _NS_OOOW,
    "xmlns:script": _NS_SCRIPT,
    "xmlns:style": _NS_STYLE,
    "xmlns:svg": _NS_SVG,
    "xmlns:table": _NS_TABLE,
    "xmlns:text": _NS_TEXT,
    "xmlns:xlink": _NS_XLINK,
}

MANIFEST_NAMESPACE_ATTRIB = {
    "xmlns:manifest": _OASIS + "manifest:1.0",
}

META_NAMESPACE_ATTRIB = {
    "xmlns:dc": _NS_DC,
    "xmlns:meta": _NS_META,
    "xmlns:office": NAME_SPACE_1,
    "xmlns:ooo": _NS_OOO,
    "xmlns:xlink": _NS_XLINK,
}


#
# ElementTree support functions.
# In order to be able to get the parent of elements, must use these
#   instead of the functions with same name provided by ElementTree.
#
def Element(tag, attrib=None, nsmap=None, nsdict=CNSD):  # noqa: N802 - docutils API name
    if attrib is None:
        attrib = {}
    tag, attrib = fix_ns(tag, attrib, nsdict)
    return _ElementInterfaceWrapper(tag, attrib)


def SubElement(parent, tag, attrib=None, nsmap=None, nsdict=CNSD):  # noqa: N802 - docutils API
    if attrib is None:
        attrib = {}
    tag, attrib = fix_ns(tag, attrib, nsdict)
    el = _ElementInterfaceWrapper(tag, attrib)
    parent.append(el)
    el.setparent(parent)
    return el


def fix_ns(tag, attrib, nsdict):
    nstag = add_ns(tag, nsdict)
    nsattrib = {add_ns(key, nsdict): val for key, val in attrib.items()}
    return nstag, nsattrib


def add_ns(tag, nsdict=CNSD):
    return tag


def ToString(et):  # noqa: N802 - docutils API name
    outstream = StringIO()
    et.write(outstream, encoding="unicode")
    s1 = outstream.getvalue()
    outstream.close()
    return s1


def escape_cdata(text):
    text = text.replace("&", "&amp;")
    text = text.replace("<", "&lt;")
    text = text.replace(">", "&gt;")
    return "".join("&#x%X;" % ord(char) if ord(char) >= 0x7F else char for char in text)


#
# Classes
#


class TableStyle:
    def __init__(self, border=None, backgroundcolor=None) -> None:
        self.border = border
        self.backgroundcolor = backgroundcolor

    def get_border_(self):
        return self.border_

    def set_border_(self, border) -> None:
        self.border_ = border

    border = property(get_border_, set_border_)

    def get_backgroundcolor_(self):
        return self.backgroundcolor_

    def set_backgroundcolor_(self, backgroundcolor) -> None:
        self.backgroundcolor_ = backgroundcolor

    backgroundcolor = property(get_backgroundcolor_, set_backgroundcolor_)


BUILTIN_DEFAULT_TABLE_STYLE = TableStyle(border="0.0007in solid #000000")


class ListLevel:
    """Information about the indentation level for lists nested inside
    other contexts, e.g. dictionary lists."""

    def __init__(self, level, sibling_level=True, nested_level=True) -> None:
        self.level = level
        self.sibling_level = sibling_level
        self.nested_level = nested_level

    def set_sibling(self, sibling_level) -> None:
        self.sibling_level = sibling_level

    def get_sibling(self):
        return self.sibling_level

    def set_nested(self, nested_level) -> None:
        self.nested_level = nested_level

    def get_nested(self):
        return self.nested_level

    def set_level(self, level) -> None:
        self.level = level

    def get_level(self):
        return self.level
