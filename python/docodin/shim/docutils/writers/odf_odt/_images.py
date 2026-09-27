"""Image and figure handling of the ODF translator."""

from __future__ import annotations

import os
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import docutils.nodes
from docutils import nodes, utils
from docutils.parsers.rst.directives.images import PIL  # optional

from . import _xml
from ._xml import SNSD, SubElement

_FO = "{urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0}"
_PAGE_LAYOUT_PROPERTIES = (
    ".//{urn:oasis:names:tc:opendocument:xmlns:style:1.0}page-layout/"
    "{urn:oasis:names:tc:opendocument:xmlns:style:1.0}page-layout-properties")

# conversion factors from units to centimeters, see
# http://www.unitconversion.org/unit_converter/typography-ex.html
_CM_FACTORS = (("px", 0.026), ("in", 2.54), ("pt", 0.035), ("pc", 0.423),
               ("mm", 0.1), ("Q", 0.25), ("cm", 1))

_DEFAULT_IMAGE_GRAPHIC_PROPERTIES = {
    "style:vertical-pos": "top",
    "style:vertical-rel": "paragraph",
    "style:horizontal-rel": "paragraph",
    "style:mirror": "none",
    "fo:clip": "rect(0cm 0cm 0cm 0cm)",
    "draw:luminance": "0%",
    "draw:contrast": "0%",
    "draw:red": "0%",
    "draw:green": "0%",
    "draw:blue": "0%",
    "draw:gamma": "100%",
    "draw:color-inversion": "false",
    "draw:image-opacity": "100%",
    "draw:color-mode": "standard",
}


def _wrap_style(classes) -> str:
    return "dynamic" if classes and "wrap" in classes else "none"


class _ImageMixin:
    """Visitor methods and helpers for <image> and <figure> elements."""

    def check_file_exists(self, path) -> int:
        return 1 if os.path.exists(path) else 0

    def _local_image_path(self, node, path) -> str:
        """Resolve the local image `path` (root prefix or document relative)."""
        source = urllib.parse.unquote(path)
        if self.settings.root_prefix and source.startswith("/"):
            root_prefix = Path(self.settings.root_prefix)
            return (root_prefix / source[1:]).as_posix()
        # adapt relative paths
        docsource, _line = utils.get_source_line(node)
        if docsource:
            dirname = os.path.dirname(docsource)
            if dirname:
                source = os.path.join(dirname, source)
        return source

    def _register_image(self, node, source, local):
        """Schedule `source` for embedding; return (source, destination) or None."""
        if source in self.image_dict:
            return self.image_dict[source]
        self.image_count += 1
        filename = os.path.split(source)[1]
        destination = "Pictures/1%08x%s" % (self.image_count, filename)
        if not local:
            try:
                with urllib.request.urlopen(source) as imgfile:
                    content = imgfile.read()
            except urllib.error.URLError as err:
                self.document.reporter.warning(
                    f'Cannot open image URL "{source}". {err}', base_node=node)
                return None
            with tempfile.NamedTemporaryFile("wb", delete=False) as imgfile2:
                imgfile2.write(content)
            source = imgfile2.name
        spec = (os.path.abspath(source) if local else source, destination,)
        self.embedded_file_list.append(spec)
        self.image_dict[source] = (source, destination,)
        return source, destination

    def visit_image(self, node) -> None:
        # Capture the image file.
        source = node["uri"]
        uri_parts = urllib.parse.urlparse(source)
        local = uri_parts.scheme in ("", "file")
        if local:
            source = self._local_image_path(node, uri_parts.path)
            if not self.check_file_exists(source):
                self.document.reporter.warning(
                    f'Cannot find image file "{source}".', base_node=node)
                return
        registered = self._register_image(node, source, local)
        if registered is None:
            return
        source, destination = registered
        # Is this a figure (containing an image) or just a plain image?
        if self.in_paragraph:
            el1 = self.current_element
        else:
            el1 = SubElement(
                self.current_element, "text:p",
                attrib={"text:style-name": self.rststyle("textbody")})
        if isinstance(node.parent, docutils.nodes.figure):
            _el3, _el4, el5, caption = self.generate_figure(node, source, destination, el1)
            el6, _width = self.generate_image(node, source, destination, el5, {})
            if caption is not None:
                el6.tail = caption
        else:
            self.generate_image(node, source, destination, el1)

    def depart_image(self, node) -> None:
        pass

    def get_image_width_height(self, node, attr):
        size = None
        unit = None
        if attr in node.attributes:
            size = node.attributes[attr].strip()
            try:
                if size.endswith("%"):
                    if attr == "height":
                        # Percentage allowed for width but not height.
                        raise ValueError("percentage not allowed for height")
                    size = size.rstrip(" %")
                    size = float(size) / 100.0
                    unit = "%"
                else:
                    size, unit = self.convert_to_cm(size)
            except ValueError as exp:
                self.document.reporter.warning(
                    f'Invalid {attr} for image: "{node.attributes[attr]}".  '
                    f'Error: "{exp}".', base_node=node)
                size, unit = 0.5, "cm"  # fallback to avoid consequential error
        return size, unit

    def convert_to_cm(self, size):
        """Convert various units to centimeters.

        Note that a call to this method should be wrapped in:
            try: except ValueError:
        """
        size = size.strip()
        for suffix, factor in _CM_FACTORS:
            if size.endswith(suffix):
                return float(size[:-len(suffix)]) * factor, "cm"
        if size[-1:] in "0123456789.":  # no unit, use px
            return float(size) * 0.026, "cm"
        raise ValueError("unit not supported with ODT")

    def get_image_scale(self, node):
        if "scale" not in node.attributes:
            return 1.0
        scale = node.attributes["scale"]
        if scale < 1:
            self.document.reporter.warning(
                f"scale out of range ({scale}), using 1.", base_node=node)
            scale = 1
        return scale * 0.01

    def _image_pixel_size(self, source):
        """Return the image size in pixels (read with PIL)."""
        filename, _destination = self.image_dict[source]
        with PIL.Image.open(filename, "r") as img:
            return img.size

    def get_image_scaled_width_height(self, node, source):
        """Return the image size in centimeters adjusted by image attrs."""
        scale = self.get_image_scale(node)
        width, width_unit = self.get_image_width_height(node, "width")
        height, _ = self.get_image_width_height(node, "height")
        if width is None or height is None:
            if PIL is None:
                self.document.reporter.warning(
                    "image size not fully specified and PIL not installed",
                    base_node=node)
                return "0.5cm", "0.5cm"  # prevent consequential error
            # TODO: use dpi when converting px to cm
            img_size = self._image_pixel_size(source)
        if width is None:
            width = img_size[0] * 0.026  # convert px to cm
        if height is None and width_unit != "%":
            height = img_size[1] * 0.026  # convert px to cm
        if width_unit == "%":
            factor = width
            line_width = self.get_page_width()
            width = factor * line_width
            if height is None:
                # scale proportionally
                image_width = img_size[0] * 0.026  # convert px to cm
                image_height = img_size[1] * 0.026  # convert px to cm
                factor = (factor * line_width) / image_width
                height = factor * image_height
        width *= scale
        height *= scale
        return "%.2fcm" % width, "%.2fcm" % height

    def get_page_width(self):
        """Return the document's page width in centimeters."""
        root = self.get_dom_stylesheet()
        width = None
        for node in root.iterfind(_PAGE_LAYOUT_PROPERTIES):
            page_width = node.get(_FO + "page-width")
            margin_left = node.get(_FO + "margin-left")
            margin_right = node.get(_FO + "margin-right")
            if page_width is None or margin_left is None or margin_right is None:
                continue
            try:
                page_width, _ = self.convert_to_cm(page_width)
                margin_left, _ = self.convert_to_cm(margin_left)
                margin_right, _ = self.convert_to_cm(margin_right)
            except ValueError:
                self.document.reporter.warning(
                    "Stylesheet file contains invalid page width "
                    "or margin size.")
            width = page_width - margin_left - margin_right
        if width is None:
            # We can't find the width in styles, so we make a guess.
            # Use a width of 6 in = 15.24 cm.
            width = 15.24
        return width

    def _add_caption_style(self) -> None:
        el1 = SubElement(self.automatic_styles, "style:style", attrib={
            "style:class": "extra",
            "style:family": "paragraph",
            "style:name": "Caption",
            "style:parent-style-name": "Standard",
        }, nsdict=SNSD)
        SubElement(el1, "style:paragraph-properties", attrib={
            "fo:margin-bottom": "0.0835in",
            "fo:margin-top": "0.0835in",
            "text:line-number": "0",
            "text:number-lines": "false",
        }, nsdict=SNSD)
        SubElement(el1, "style:text-properties", attrib={
            "fo:font-size": "12pt",
            "fo:font-style": "italic",
            "style:font-name": "Times",
            "style:font-name-complex": "Lucidasans1",
            "style:font-size-asian": "12pt",
            "style:font-size-complex": "12pt",
            "style:font-style-asian": "italic",
            "style:font-style-complex": "italic",
        }, nsdict=SNSD)

    def generate_figure(self, node, source, destination, current_element):
        caption = None
        width, height = self.get_image_scaled_width_height(node, source)
        for node1 in node.parent.children:
            if node1.tagname == "caption":
                caption = node1.astext()
        self.image_style_count += 1
        # Add the style for the caption.
        if caption is not None:
            self._add_caption_style()
        style_name = "rstframestyle%d" % self.image_style_count
        draw_name = "graphics%d" % next(_xml.IMAGE_NAME_COUNTER)
        # Add the styles
        el1 = SubElement(self.automatic_styles, "style:style", attrib={
            "style:name": style_name,
            "style:family": "graphic",
            "style:parent-style-name": self.rststyle("figureframe"),
        }, nsdict=SNSD)
        wrap = _wrap_style(node.parent.attributes.get("classes"))
        SubElement(el1, "style:graphic-properties",
                   attrib={"style:wrap": wrap}, nsdict=SNSD)
        el3 = SubElement(current_element, "draw:frame", attrib={
            "draw:style-name": style_name,
            "draw:name": draw_name,
            "text:anchor-type": "paragraph",
            "draw:z-index": "0",
            "svg:width": width,
        })
        el4 = SubElement(el3, "draw:text-box", attrib={})
        el5 = SubElement(el4, "text:p", attrib={
            "text:style-name": self.rststyle("caption"),
        })
        return el3, el4, el5, caption

    @staticmethod
    def _image_alignment(node):
        """Return the (horizontal, vertical) alignment of image `node`."""
        halign = None
        valign = None
        for val in node.attributes.get("align", "").split():
            if val in ("left", "center", "right"):
                halign = val
            elif val in ("top", "middle", "bottom"):
                valign = val
        return halign, valign

    def generate_image(self, node, source, destination, current_element,
                       frame_attrs=None):
        width, height = self.get_image_scaled_width_height(node, source)
        self.image_style_count += 1
        style_name = "rstframestyle%d" % self.image_style_count
        # Add the style.
        el1 = SubElement(self.automatic_styles, "style:style", attrib={
            "style:name": style_name,
            "style:family": "graphic",
            "style:parent-style-name": self.rststyle("image"),
        }, nsdict=SNSD)
        halign, valign = self._image_alignment(node)
        if frame_attrs is None:
            attrib = dict(_DEFAULT_IMAGE_GRAPHIC_PROPERTIES)
        else:
            attrib = frame_attrs
        if halign is not None:
            attrib["style:horizontal-pos"] = halign
        if valign is not None:
            attrib["style:vertical-pos"] = valign
        # If there is a classes/wrap directive or we are
        #   inside a table, add a no-wrap style.
        attrib["style:wrap"] = _wrap_style(node.attributes.get("classes"))
        if self.is_in_table(node):
            attrib["style:wrap"] = "none"
        SubElement(el1, "style:graphic-properties", attrib=attrib, nsdict=SNSD)
        draw_name = "graphics%d" % next(_xml.IMAGE_NAME_COUNTER)
        # Add the content.
        anchor_type = "as-char" if isinstance(node.parent, nodes.TextElement) else "paragraph"
        el1 = SubElement(current_element, "draw:frame", attrib={
            "draw:style-name": style_name,
            "draw:name": draw_name,
            "draw:z-index": "1",
            "text:anchor-type": anchor_type,
            "svg:width": width,
            "svg:height": height,
        })
        SubElement(el1, "draw:image", attrib={
            "xlink:href": "%s" % (destination, ),
            "xlink:type": "simple",
            "xlink:show": "embed",
            "xlink:actuate": "onLoad",
        })
        return el1, width

    def is_in_table(self, node) -> bool:
        node1 = node.parent
        while node1:
            if isinstance(node1, docutils.nodes.entry):
                return True
            node1 = node1.parent
        return False
