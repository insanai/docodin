"""Images and mathematics for the Docutils HTML writers.

Private auxiliary module of `docutils.writers._html_base`: the mixin class
`MediaTranslatorMixin` provides the `HTMLTranslator` methods for image and math nodes.
"""

from __future__ import annotations

import base64
import mimetypes
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

from docutils import nodes, utils
from docutils.parsers.rst.directives.images import PIL
from docutils.utils.math import (
    MathError,
    latex2mathml,
    math2html,
    tex2mathml_extern,
    unichar2tex,
    wrap_math_code,
)

__docformat__ = "reStructuredText"

SVG_NS = {"": "http://www.w3.org/2000/svg", "xlink": "http://www.w3.org/1999/xlink"}
"""SVG namespaces (registered to prevent namespace prefixes on all elements)."""


def scaled_size_atts(measures: dict[str, tuple[float, str]],
                     scaling_factor: float) -> dict[str, str]:
    """Scale `measures` and format as <img> attributes.

    Use "width" and "height" for unitless values and "style" else.
    """
    size_atts = {}
    declarations = []  # declarations for the "style" attribute
    for dimension, (value, unit) in measures.items():
        value *= scaling_factor
        if unit:
            declarations.append(f"{dimension}: {value:g}{unit};")
        else:
            size_atts[dimension] = f"{round(value)}"
    if declarations:
        size_atts["style"] = " ".join(declarations)
    return size_atts


def read_image_data(imagepath: Path | str, mimetype: str | None) -> str | bytes:
    """Return the content of an image file (SVG images as `str`)."""
    if mimetype == "image/svg+xml":
        return Path(imagepath).read_text(encoding="utf-8")
    return Path(imagepath).read_bytes()


def data_uri(imagedata: bytes, mimetype: str | None) -> str:
    """Return a "data:" URI for the image `imagedata`."""
    return f"data:{mimetype};base64,{base64.b64encode(imagedata).decode()}"


def merge_svg_attributes(code: str, node: nodes.Element, atts: dict[str, Any]) -> str:
    """Parse SVG source `code`, add attributes from `node` and `atts` to the root element.

    Comments and preamble code are ignored.
    Raise `xml.etree.ElementTree.ParseError` if `code` is not well-formed.
    """
    # don't add SVG namespace to all elements
    for key, value in SVG_NS.items():
        ET.register_namespace(key, value)
    svg = ET.fromstring(code)
    # Apply image node attributes:
    if "style" in atts:  # update style declarations
        declaration_dict = {}
        for declaration in svg.get("style", "").split(";") + atts["style"].split(";"):
            if not declaration.strip():
                continue
            key, _, value = declaration.partition(":")
            declaration_dict[key.strip()] = value.strip()
        svg.set("style", " ".join(f"{k}: {v};" for k, v in declaration_dict.items()))
    for dimension in ("width", "height"):
        if dimension in atts:
            svg.set(dimension, atts[dimension])
    if "classes" in atts or node["classes"]:
        classes = svg.get("class", "").split()
        classes += node["classes"] + atts.get("classes", [])
        svg.set("class", " ".join(classes))
    if "alt" in node and svg.find("title", SVG_NS) is None:
        svg_title = ET.Element("title")
        svg_title.text = node["alt"]
        svg.insert(0, svg_title)
    return ET.tostring(svg, encoding="unicode")


class MediaTranslatorMixin:
    """`HTMLTranslator` methods for images (still images and videos) and mathematics.

    Relies on the attributes and methods of `docutils.writers._html_base.HTMLTranslator`.
    """

    def image_size(self, node: nodes.image) -> dict[str, str]:
        """Determine the image size from node arguments or the image file.

        Return as dictionary of <img> attributes,
        e.g., ``{height': '32', 'style': 'width: 4 em;'}``.

        Auxiliary method called from `self.visit_image()`.
        Provisional.
        """
        dimensions = ("width", "height")
        measures = {}  # (value, unit)-tuples) for width and height
        for dimension in dimensions:
            if dimension in node:
                measures[dimension] = nodes.parse_measure(node[dimension])
        if "scale" in node and len(measures) < 2:
            # supplement with (unitless) values read from image file
            imgsize = self.read_size_with_PIL(node)
            if imgsize:
                for dimension, value in zip(dimensions, imgsize, strict=False):
                    measures.setdefault(dimension, (value, ""))
        return scaled_size_atts(measures, node.get("scale", 100) / 100)

    def read_size_with_PIL(self, node: nodes.image) -> tuple[int, int] | None:
        # Try reading size from image file.
        # Internal auxiliary method called from `self.image_size()`.
        reading_problems = []
        uri = node["uri"]
        if not PIL:
            reading_problems.append("Requires Python Imaging Library.")
        if mimetypes.guess_type(uri)[0] in self.videotypes:
            reading_problems.append("PIL cannot read video images.")
        if not self.settings.file_insertion_enabled:
            reading_problems.append("Reading external files disabled.")
        if not reading_problems:
            try:
                imagepath = self.uri2path(uri)
                with PIL.Image.open(imagepath) as img:
                    imgsize = img.size
            except (ValueError, OSError, UnicodeEncodeError) as err:
                reading_problems.append(str(err))
            else:
                self.settings.record_dependencies.add(imagepath)
        if reading_problems:
            msg = ["Cannot scale image!", f'Could not get size from "{uri}":',
                   *reading_problems]
            self.messages.append(self.document.reporter.warning(
                                     "\n  ".join(msg), base_node=node))
            return None
        return imgsize

    def prepare_svg(self, code: str, node: nodes.Element, atts: dict) -> str:
        # Parse SVG source `code` (ignoring comments and preamble code),
        # add relevant attributes from `node` and `atts` to the root element.
        #
        # Internal auxiliary method called from `self.visit_image()`.
        try:
            return merge_svg_attributes(code, node, atts)
        except ET.ParseError as err:
            self.messages.append(self.document.reporter.error(
                f'Cannot parse SVG image "{node["uri"]}":\n  {err}', base_node=node))
            return code

    def visit_image(self, node: nodes.image) -> None:
        # reference/embed images (still images and videos)
        uri = node["uri"]
        mimetype = mimetypes.guess_type(uri)[0]
        element = ""  # the HTML element (including potential children)
        # attributes for the HTML tag:
        atts = self.image_size(node)
        # alignment is handled by CSS rules
        if "align" in node:
            atts["classes"] = [f"align-{node['align']}"]
        # ``:loading:`` option (embed, link, lazy), default from setting,
        # exception: only embed videos if told via directive option
        loading = "link" if mimetype in self.videotypes else self.image_loading
        loading = node.get("loading", loading)
        if loading == "lazy":
            atts["loading"] = "lazy"
        elif loading == "embed":
            uri, element = self._embed_image(node, mimetype, atts)
        # No newlines around inline images (but all images may be nested
        # in a `reference` node which is a `TextElement` instance):
        if (not isinstance(node.parent, nodes.TextElement)
                or isinstance(node.parent, nodes.reference)
                and not isinstance(node.parent.parent, nodes.TextElement)):
            suffix = "\n"
        else:
            suffix = ""
        self.body.append(self._image_element(node, uri, mimetype, element, suffix, atts))
        if suffix:  # block-element
            self.report_messages(node)

    def _embed_image(self, node: nodes.image, mimetype: str | None,
                     atts: dict) -> tuple[str, str]:
        # Return (possibly "data:") URI and element code (embedded SVG) for `node`.
        uri = node["uri"]
        try:
            imagepath = self.uri2path(uri)
            imagedata = read_image_data(imagepath, mimetype)
        except (ValueError, OSError, UnicodeError) as err:
            self.messages.append(self.document.reporter.error(
                f'Cannot embed image "{uri}":\n  {err}', base_node=node))
            # TODO: get external files with urllib.request (cf. odtwriter)?
            return uri, ""
        self.settings.record_dependencies.add(imagepath)
        if mimetype == "image/svg+xml":
            return uri, self.prepare_svg(imagedata, node, atts)
        return data_uri(imagedata, mimetype), ""

    def _image_element(self, node: nodes.image, uri: str, mimetype: str | None,
                       element: str, suffix: str, atts: dict) -> str:
        # Return the HTML element for the image `node`.
        alt = node.get("alt", node["uri"])
        if mimetype in self.videotypes:
            atts["title"] = alt
            if "controls" in node["classes"]:
                node["classes"].remove("controls")
                atts["controls"] = "controls"
            return (self.starttag(node, "video", suffix, src=uri, **atts)
                    + f'<a href="{node["uri"]}">{alt}</a>{suffix}'
                    + f"</video>{suffix}")
        if mimetype == "application/x-shockwave-flash":
            atts["type"] = mimetype
            return (self.starttag(node, "object", "", data=uri, **atts)
                    + f"{alt}</object>{suffix}")
        if element:  # embedded SVG, see above
            return element + suffix
        atts["alt"] = alt
        return self.emptytag(node, "img", suffix, src=uri, **atts)

    def depart_image(self, node: nodes.image) -> None:
        pass

    # Mathematics:
    # As there is no native HTML math support, we provide alternatives for the math-output:
    # LaTeX and MathJax simply wrap the content, HTML and MathML also convert the math_code.
    # HTML element:
    math_tags = {  # format: (inline, block, [class arguments])
                 "html": ("span", "div", ["formula"]),
                 "latex": ("tt", "pre", ["math"]),
                 "mathjax": ("span", "div", ["math"]),
                 "mathml": ("", "div", []),
                 "problematic": ("span", "pre", ["math", "problematic"]),
                 }

    def visit_math(self, node: nodes.Element) -> None:
        # Also called from `visit_math_block()`:
        is_block = isinstance(node, nodes.math_block)
        fmt = self.math_output
        math_code = node.astext().translate(unichar2tex.uni2tex_table)
        # preamble code and conversion
        if fmt == "html":
            math_code = self._math2html(math_code, is_block)
        elif fmt == "latex":
            math_code = self.encode(math_code)
        elif fmt == "mathjax":
            math_code = self._math2mathjax(node, math_code, is_block)
        elif fmt == "mathml":
            math_code, fmt = self._math2mathml(node, math_code, is_block)
        # append to document body
        tag = self.math_tags[fmt][is_block]
        suffix = "\n" if is_block else ""
        if tag:
            self.body.append(self.starttag(node, tag, suffix=suffix,
                                           classes=self.math_tags[fmt][2]))
        self.body.extend([math_code, suffix])
        if tag:
            self.body.append(f"</{tag}>{suffix}")
        # Content already processed:
        raise nodes.SkipChildren

    def _math2html(self, math_code: str, is_block: bool) -> str:
        # Convert LaTeX `math_code` to HTML, set up the math stylesheet(s).
        if self.math_options and not self.math_header:
            self.math_header = [
                self.stylesheet_call(utils.find_file_in_dirs(s, self.settings.stylesheet_dirs),
                                     adjust_path=True)
                for s in self.math_options.split(",")]
        math2html.DocumentParameters.displaymode = is_block
        # TODO: fix display mode in matrices and fractions
        math_code = wrap_math_code(math_code, is_block)
        return math2html.math2html(math_code)

    def _math2mathjax(self, node: nodes.Element, math_code: str, is_block: bool) -> str:
        # Wrap and encode `math_code` for MathJax, set up the MathJax script.
        if not self.math_header:
            if self.math_options:
                self.mathjax_url = self.math_options
            else:
                self.document.reporter.warning(
                    "No MathJax URL specified, using local fallback (see config.html).",
                    base_node=node)
            # append MathJax configuration (input LaTeX with AMS, output common HTML):
            if "?" not in self.mathjax_url:
                self.mathjax_url += "?config=TeX-AMS_CHTML"
            self.math_header = [self.mathjax_script % self.mathjax_url]
        if is_block:
            math_code = wrap_math_code(math_code, is_block)
        else:
            math_code = rf"\({math_code}\)"
        return self.encode(math_code)

    def _math2mathml(self, node: nodes.Element, math_code: str,
                     is_block: bool) -> tuple[str, str]:
        # Convert `math_code` to MathML. Return code and (fallback) format.
        if "XHTML 1" in self.doctype:
            self.content_type = self.content_type_mathml
        if self.math_options:
            converter = getattr(tex2mathml_extern, self.math_options)
        else:
            converter = latex2mathml.tex2mathml
        try:
            return converter(math_code, as_block=is_block), "mathml"
        except (MathError, OSError) as err:
            details = getattr(err, "details", [])
            self.messages.append(self.document.reporter.warning(
                err, *details, base_node=node))
            fallback = "problematic" if self.settings.report_level <= 2 else "latex"
            if isinstance(err, OSError):
                # report missing converter only once
                self.math_output = fallback
            return self.encode(node.astext()), fallback

    def depart_math(self, node: nodes.Element) -> None:
        pass

    def visit_math_block(self, node: nodes.Element) -> None:
        self.visit_math(node)

    def depart_math_block(self, node: nodes.Element) -> None:
        self.report_messages(node)
