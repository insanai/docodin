#!/usr/bin/env python3

"""
Adapt a word-processor-generated styles.odt for odtwriter use:

Drop page size specifications from styles.xml in STYLE_FILE.odt.
See https://docutils.sourceforge.io/docs/user/odt.html#page-size
"""

# Author: Michael Schutte <michi@uiae.at>

from __future__ import annotations

import os
import shutil
import sys
import zipfile
from tempfile import mkstemp
from xml.etree import ElementTree as ET

NAMESPACES = {
    "style": "urn:oasis:names:tc:opendocument:xmlns:style:1.0",
    "fo": "urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0",
}


def _parse_styles(zin: zipfile.ZipFile) -> ET.Element:
    """Parse styles.xml, registering its namespace prefixes to preserve them."""
    root = None
    with zin.open("styles.xml") as styles:
        for event, elem in ET.iterparse(styles, events=("start", "start-ns")):
            if event == "start-ns":
                ET.register_namespace(elem[0], elem[1])
            elif root is None:
                root = elem
    return root


def prepstyle(filename) -> None:
    zin = zipfile.ZipFile(filename)
    root = _parse_styles(zin)
    fo_prefix = "{%s}" % NAMESPACES["fo"]
    for el in root.findall(".//style:page-layout-properties", namespaces=NAMESPACES):
        for attr in list(el.attrib):
            if attr.startswith(fo_prefix):
                del el.attrib[attr]

    tempname = mkstemp()
    zout = zipfile.ZipFile(os.fdopen(tempname[0], "wb"), "w", zipfile.ZIP_DEFLATED)
    for item in zin.infolist():
        if item.filename == "styles.xml":
            zout.writestr(item, ET.tostring(root, encoding="UTF-8"))
        else:
            zout.writestr(item, zin.read(item.filename))
    zout.close()
    zin.close()
    shutil.move(tempname[1], filename)


def main() -> None:
    args = sys.argv[1:]
    if len(args) != 1 or args[0] in ("-h", "--help"):
        print(__doc__, file=sys.stderr)
        print("Usage: %s STYLE_FILE.odt\n" % sys.argv[0], file=sys.stderr)
        sys.exit(1)
    filename = args[0]
    prepstyle(filename)


if __name__ == "__main__":
    main()
