"""
Open Document Format (ODF) Writer.

This module is provisional:
the API is not settled and may change with any minor Docutils version.
"""

from __future__ import annotations

__docformat__ = "reStructuredText"

import locale
import os
import os.path
import re
import tempfile
import time
import zipfile
from configparser import ConfigParser
from io import StringIO  # noqa: F401 - re-exported like in docutils
from pathlib import Path  # noqa: F401 - re-exported like in docutils
from xml.dom import minidom
from xml.etree import ElementTree as ET

import docutils
import docutils.nodes
from docutils import frontend, languages, nodes, utils, writers
from docutils.parsers.rst.directives.images import PIL  # noqa: F401 - optional, re-exported
from docutils.readers import standalone
from docutils.transforms import references

from ._blocks import _BlocksMixin
from ._images import _ImageMixin
from ._notes import _NotesMixin
from ._page import _PageMixin
from ._tables import _TableMixin
from ._xml import (  # noqa: F401 - re-exported public names
    BUILTIN_DEFAULT_TABLE_STYLE,
    CNSD,
    CONTENT_NAMESPACE_ATTRIB,
    CONTENT_NAMESPACE_DICT,
    FILL_PAT1,
    FILL_PAT2,
    GENERATOR_DESC,
    IMAGE_NAME_COUNTER,
    MANIFEST_NAMESPACE_ATTRIB,
    MANIFEST_NAMESPACE_DICT,
    MANNSD,
    META_NAMESPACE_ATTRIB,
    META_NAMESPACE_DICT,
    METNSD,
    NAME_SPACE_1,
    SNSD,
    SPACES_PATTERN,
    STYLES_NAMESPACE_ATTRIB,
    STYLES_NAMESPACE_DICT,
    TABLENAMEDEFAULT,
    TABLEPROPERTYNAMES,
    TABLESTYLEPREFIX,
    TABS_PATTERN,
    VERSION,
    Element,
    ListLevel,
    SubElement,
    TableStyle,
    ToString,
    _ElementInterface,
    _ElementInterfaceWrapper,
    _parents,
    add_ns,
    escape_cdata,
    fix_ns,
)

# Import pygments and odtwriter pygments formatters if possible.
try:
    import pygments
    import pygments.lexers

    from .pygmentsformatter import OdtPygmentsLaTeXFormatter, OdtPygmentsProgFormatter
except (ImportError, SyntaxError):
    pygments = None

_STYLE_NS = "{urn:oasis:names:tc:opendocument:xmlns:style:1.0}"
_FO_NS = "{urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0}"

_REGION_WARNING = (
    "invalid language-region.\n"
    "  Could not find region with locale.normalize().\n"
    "  Please specify both language and region (ll-RR).\n"
    "  Examples: es-MX (Spanish, Mexico),\n"
    "  en-AU (English, Australia).")


def _bool_option(help_text, flag, dest, action, default=False):
    """Return a boolean ODF writer option specification."""
    return (help_text, [flag], {"default": default, "action": action, "dest": dest,
                                "validator": frontend.validate_boolean})


class Writer(writers.Writer):

    MIME_TYPE = "application/vnd.oasis.opendocument.text"
    EXTENSION = ".odt"

    supported = ("odt", )
    """Formats this writer supports."""

    default_stylesheet = "styles" + EXTENSION

    default_stylesheet_path = utils.relative_path(
        os.path.join(os.getcwd(), "dummy"),
        os.path.join(os.path.dirname(__file__), default_stylesheet))

    default_template = "template.txt"

    default_template_path = utils.relative_path(
        os.path.join(os.getcwd(), "dummy"),
        os.path.join(os.path.dirname(__file__), default_template))

    settings_spec = (
        "ODF-Specific Options.",
        None,
        (
            ('Specify a stylesheet.  Default: "%s"' % default_stylesheet_path,
             ["--stylesheet"],
             {"default": default_stylesheet_path,
              "dest": "stylesheet",
              "metavar": "<filename>"}),
            ("Specify an ODF-specific configuration/mapping file "
             "relative to the current working directory.",
             ["--odf-config-file"],
             {"metavar": "<file>"}),
            _bool_option("Obfuscate email addresses to confuse harvesters.",
                         "--cloak-email-addresses", "cloak_email_addresses",
                         "store_true"),
            _bool_option("Do not obfuscate email addresses.",
                         "--no-cloak-email-addresses", "cloak_email_addresses",
                         "store_false"),
            ("Specify the thickness of table borders in thousands of a cm. "
             "Default is 35.",
             ["--table-border-thickness"],
             {"default": None,
              "metavar": "<int>",
              "validator": frontend.validate_nonnegative_int}),
            _bool_option("Add syntax highlighting in literal code blocks.",
                         "--add-syntax-highlighting", "add_syntax_highlighting",
                         "store_true"),
            _bool_option("Do not add syntax highlighting in "
                         "literal code blocks. (default)",
                         "--no-syntax-highlighting", "add_syntax_highlighting",
                         "store_false"),
            _bool_option("Create sections for headers.  (default)",
                         "--create-sections", "create_sections",
                         "store_true", default=True),
            _bool_option("Do not create sections for headers.",
                         "--no-sections", "create_sections",
                         "store_false", default=True),
            _bool_option("Create links.",
                         "--create-links", "create_links", "store_true"),
            _bool_option("Do not create links.  (default)",
                         "--no-links", "create_links", "store_false"),
            _bool_option("Generate endnotes at end of document, not footnotes "
                         "at bottom of page.",
                         "--endnotes-end-doc", "endnotes_end_doc", "store_true"),
            _bool_option("Generate footnotes at bottom of page, not endnotes "
                         "at end of document. (default)",
                         "--no-endnotes-end-doc", "endnotes_end_doc", "store_false"),
            ("Generate a bullet list table of contents, "
             "not a native ODF table of contents.",
             ["--generate-list-toc"],
             {"action": "store_false",
              "dest": "generate_oowriter_toc",
              "validator": frontend.validate_boolean}),
            _bool_option("Generate a native ODF table of contents, "
                         "not a bullet list. (default)",
                         "--generate-oowriter-toc", "generate_oowriter_toc",
                         "store_true", default=True),
            ("Specify the contents of an custom header line.  "
             "See ODF/ODT writer documentation for details "
             "about special field character sequences.",
             ["--custom-odt-header"],
             {"default": "",
              "dest": "custom_header",
              "metavar": "<custom header>"}),
            ("Specify the contents of an custom footer line.  "
             "See ODF/ODT writer documentation for details.",
             ["--custom-odt-footer"],
             {"default": "",
              "dest": "custom_footer",
              "metavar": "<custom footer>"}),
        )
    )

    settings_defaults = {
        "output_encoding_error_handler": "xmlcharrefreplace",
    }

    relative_path_settings = ("odf_config_file", "stylesheet",)

    config_section = "odf_odt writer"
    config_section_dependencies = ("writers",)

    def __init__(self) -> None:
        writers.Writer.__init__(self)
        self.translator_class = ODFTranslator

    def translate(self) -> None:
        self.settings = self.document.settings
        self.visitor = self.translator_class(self.document)
        self.visitor.retrieve_styles(self.EXTENSION)
        self.document.walkabout(self.visitor)
        self.visitor.add_doc_title()
        self.assemble_my_parts()
        self.output = self.parts["whole"]

    def _language_and_region(self):
        """Return the (language, region) codes of the document to be generated.

        The language is specified by the -l/--language command line option.
        The format is described in BCP 47.  If region is omitted, we use
        local.normalize(ll) to obtain a region.
        """
        if not self.visitor.language_code:
            return None, None
        language_ids = self.visitor.language_code.replace("_", "-").split("-")
        # first tag is primary language tag
        language_code = language_ids[0].lower()
        region_code = None
        # 2-letter region subtag may follow in 2nd or 3rd position
        for subtag in language_ids[1:]:
            if len(subtag) == 2 and subtag.isalpha():
                return language_code, subtag.upper()
            if len(subtag) == 1:
                break  # 1-letter tag is never before valid region tag
        try:
            rcode = locale.normalize(language_code)
        except NameError:
            rcode = language_code
        rcode = rcode.split("_")
        if len(rcode) > 1:
            region_code = rcode[1].split(".")[0]
        if region_code is None:
            self.document.reporter.warning(_REGION_WARNING)
        return language_code, region_code

    def assemble_my_parts(self) -> None:
        """Assemble the `self.parts` dictionary.  Extend in subclasses.
        """
        writers.Writer.assemble_parts(self)
        f = tempfile.NamedTemporaryFile()
        zfile = zipfile.ZipFile(f, "w", zipfile.ZIP_DEFLATED)
        self.write_zip_str(zfile, "mimetype", self.MIME_TYPE,
                           compress_type=zipfile.ZIP_STORED)
        content = self.visitor.content_astext()
        self.write_zip_str(zfile, "content.xml", content)
        self.write_zip_str(zfile, "META-INF/manifest.xml", self.create_manifest())
        self.write_zip_str(zfile, "meta.xml", self.create_meta())
        s1 = self.get_stylesheet()
        language_code, region_code = self._language_and_region()
        # Update the style ElementTree with the language and region.
        # Note that we keep a reference to the modified node because
        # it is possible that ElementTree will throw away the Python
        # representation of the updated node if we do not.
        updated, new_dom_styles, _updated_node = self.update_stylesheet(
            self.visitor.get_dom_stylesheet(), language_code, region_code)
        if updated:
            s1 = ET.tostring(new_dom_styles)
        self.write_zip_str(zfile, "styles.xml", s1)
        self.store_embedded_files(zfile)
        self.copy_from_stylesheet(zfile)
        zfile.close()
        f.seek(0)
        whole = f.read()
        f.close()
        self.parts["whole"] = whole
        self.parts["encoding"] = self.document.settings.output_encoding
        self.parts["version"] = docutils.__version__

    def update_stylesheet(self, stylesheet_root, language_code, region_code):
        """Update xml style sheet element with language and region/country."""
        updated = False
        modified_nodes = set()
        if language_code is None and region_code is None:
            return updated, stylesheet_root, modified_nodes
        n1 = stylesheet_root.find("{%s}styles" % NAME_SPACE_1)
        if n1 is None:
            raise RuntimeError("Cannot find 'styles' element in styles.odt/styles.xml")
        n2_nodes = n1.findall(_STYLE_NS + "default-style")
        if not n2_nodes:
            raise RuntimeError("Cannot find 'default-style' element in styles.xml")
        for node in n2_nodes:
            family = node.attrib.get(_STYLE_NS + "family")
            if family not in ("paragraph", "graphic"):
                continue
            n3 = node.find(_STYLE_NS + "text-properties")
            if n3 is None:
                raise RuntimeError("Cannot find 'text-properties' element in styles.xml")
            for key, code in (("language", language_code), ("country", region_code)):
                if code is not None:
                    n3.attrib[_FO_NS + key] = code
                    n3.attrib[_STYLE_NS + key + "-complex"] = code
                    updated = True
                    modified_nodes.add(n3)
        return updated, stylesheet_root, modified_nodes

    def write_zip_str(self, zfile, name, bytes_, compress_type=zipfile.ZIP_DEFLATED) -> None:
        localtime = time.localtime(time.time())
        zinfo = zipfile.ZipInfo(name, localtime)
        # Add some standard UNIX file access permissions (-rw-r--r--).
        zinfo.external_attr = (0x81a4 & 0xFFFF) << 16
        zinfo.compress_type = compress_type
        zfile.writestr(zinfo, bytes_)

    def store_embedded_files(self, zfile) -> None:
        embedded_files = self.visitor.get_embedded_file_list()
        for source, destination in embedded_files:
            if source is None:
                continue
            try:
                zfile.write(source, destination)
            except OSError:
                self.document.reporter.warning("Can't open file %s." % (source, ))

    def get_settings(self):
        """
        modeled after get_stylesheet
        """
        stylespath = self.settings.stylesheet
        zfile = zipfile.ZipFile(stylespath, "r")
        s1 = zfile.read("settings.xml")
        zfile.close()
        return s1

    def get_stylesheet(self):
        """Get the stylesheet from the visitor.
        Ask the visitor to setup the page.
        """
        return self.visitor.setup_page()

    def copy_from_stylesheet(self, outzipfile) -> None:
        """Copy images, settings, etc from the stylesheet doc into target doc.
        """
        stylespath = self.settings.stylesheet
        if not stylespath.endswith(".odt"):
            return  # an '.xml' stylesheet does not have settings or images
        inzipfile = zipfile.ZipFile(stylespath, "r")
        # Copy the settings.
        s1 = inzipfile.read("settings.xml")
        self.write_zip_str(outzipfile, "settings.xml", s1)
        # Copy the images.
        for name in inzipfile.namelist():
            if name.startswith("Pictures/"):
                imageobj = inzipfile.read(name)
                outzipfile.writestr(name, imageobj)
        inzipfile.close()

    def assemble_parts(self) -> None:
        pass

    def create_manifest(self):
        root = Element(
            "manifest:manifest",
            attrib=MANIFEST_NAMESPACE_ATTRIB,
            nsdict=MANIFEST_NAMESPACE_DICT,
        )
        doc = ET.ElementTree(root)
        entries = ((self.MIME_TYPE, "/"), ("text/xml", "content.xml"),
                   ("text/xml", "styles.xml"), ("text/xml", "settings.xml"),
                   ("text/xml", "meta.xml"))
        for media_type, full_path in entries:
            SubElement(root, "manifest:file-entry", attrib={
                "manifest:media-type": media_type,
                "manifest:full-path": full_path,
            }, nsdict=MANNSD)
        s1 = ToString(doc)
        doc = minidom.parseString(s1)
        return doc.toprettyxml("  ")

    def create_meta(self):
        root = Element(
            "office:document-meta",
            attrib=META_NAMESPACE_ATTRIB,
            nsdict=META_NAMESPACE_DICT,
        )
        doc = ET.ElementTree(root)
        root = SubElement(root, "office:meta", nsdict=METNSD)
        s1 = os.environ.get("USER", "")
        s2 = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime())
        fields = (
            ("meta:generator", "Docutils/rst2odf.py/%s" % (VERSION, )),
            ("meta:initial-creator", s1),
            ("meta:creation-date", s2),
            ("dc:creator", s1),
            ("dc:date", s2),
            ("dc:language", "en-US"),
            ("meta:editing-cycles", "1"),
            ("meta:editing-duration", "PT00M01S"),
            ("dc:title", self.document.get("title", "[no title]")),
        )
        for tag, text in fields:
            SubElement(root, tag, nsdict=METNSD).text = text
        for prop, value in self.visitor.get_meta_dict().items():
            self._add_meta_property(root, prop, value)
        return ToString(doc)

    def _add_meta_property(self, root, prop, value) -> None:
        # 'keywords', 'description', and 'subject' have their own fields:
        if prop == "keywords":
            for keyword in re.split(", *", value):
                SubElement(root, "meta:keyword", nsdict=METNSD).text = keyword
        elif prop == "description":
            SubElement(root, "dc:description", nsdict=METNSD).text = value
        elif prop == "subject":
            SubElement(root, "dc:subject", nsdict=METNSD).text = value
        else:  # Store remaining properties as custom/user-defined
            el1 = SubElement(root, "meta:user-defined",
                             attrib={"meta:name": prop}, nsdict=METNSD)
            el1.text = value


class ODFTranslator(_PageMixin, _NotesMixin, _BlocksMixin, _ImageMixin, _TableMixin,
                    nodes.GenericNodeVisitor):

    used_styles = (
        "attribution", "blockindent", "blockquote", "blockquote-bulletitem",
        "blockquote-bulletlist", "blockquote-enumitem", "blockquote-enumlist",
        "bulletitem", "bulletlist",
        "caption", "legend",
        "centeredtextbody", "codeblock", "codeblock-indented",
        "codeblock-classname", "codeblock-comment", "codeblock-functionname",
        "codeblock-keyword", "codeblock-name", "codeblock-number",
        "codeblock-operator", "codeblock-string", "emphasis", "enumitem",
        "enumlist", "epigraph", "epigraph-bulletitem", "epigraph-bulletlist",
        "epigraph-enumitem", "epigraph-enumlist", "footer",
        "footnote", "citation",
        "header", "highlights", "highlights-bulletitem",
        "highlights-bulletlist", "highlights-enumitem", "highlights-enumlist",
        "horizontalline", "inlineliteral", "quotation", "rubric",
        "strong", "table-title", "textbody", "tocbulletlist", "tocenumlist",
        "title",
        "subtitle",
        "heading1", "heading2", "heading3", "heading4", "heading5", "heading6",
        "heading7",
        "admon-attention-hdr", "admon-attention-body",
        "admon-caution-hdr", "admon-caution-body",
        "admon-danger-hdr", "admon-danger-body",
        "admon-error-hdr", "admon-error-body",
        "admon-generic-hdr", "admon-generic-body",
        "admon-hint-hdr", "admon-hint-body",
        "admon-important-hdr", "admon-important-body",
        "admon-note-hdr", "admon-note-body",
        "admon-tip-hdr", "admon-tip-body",
        "admon-warning-hdr", "admon-warning-body",
        "tableoption",
        "tableoption.%c", "tableoption.%c%d", "Table%d", "Table%d.%c",
        "Table%d.%c%d",
        "lineblock1", "lineblock2", "lineblock3", "lineblock4", "lineblock5",
        "lineblock6",
        "image", "figureframe",
    )

    def __init__(self, document) -> None:
        nodes.GenericNodeVisitor.__init__(self, document)
        self.settings = document.settings
        if self.settings.output_encoding == "unicode":
            self.document.reporter.severe("The ODT writer returns `bytes` "
                                          "that cannot be decoded to `str`")
            # TODO: return document as "flat" XML?
        self.language_code = self.settings.language_code
        self.language = languages.get_language(self.language_code, document.reporter)
        self.format_map = {}
        if self.settings.odf_config_file:
            self._read_odf_config(self.settings.odf_config_file)
        self.section_level = 0
        self.section_count = 0
        # Create ElementTree content and styles documents.
        root = Element("office:document-content", attrib=CONTENT_NAMESPACE_ATTRIB)
        self.content_tree = ET.ElementTree(element=root)
        self.current_element = root
        SubElement(root, "office:scripts")
        SubElement(root, "office:font-face-decls")
        self.automatic_styles = SubElement(root, "office:automatic-styles")
        el = SubElement(root, "office:body")
        el = self.generate_content_element(el)
        self.current_element = el
        self.body_text_element = el
        self.paragraph_style_stack = [self.rststyle("textbody"), ]
        self._init_state()

    def _read_odf_config(self, path) -> None:
        """Read the style mapping ("Formats" section) of an ODF config file."""
        parser = ConfigParser()
        parser.read(path)
        for rststyle, format_ in parser.items("Formats"):
            if rststyle not in self.used_styles:
                self.document.reporter.warning(
                    'Style "%s" is not a style used by odtwriter.' % (rststyle, ))
            self.format_map[rststyle] = format_

    def _init_state(self) -> None:
        """Initialize the translation state attributes."""
        self.list_style_stack = []
        self.table_count = 0
        self.column_count = ord("A") - 1
        self.trace_level = -1
        self.optiontablestyles_generated = False
        self.field_name = None
        self.field_element = None
        self.title = None
        self.image_count = 0
        self.image_style_count = 0
        self.image_dict = {}
        self.embedded_file_list = []
        self.syntaxhighlighting = 1
        self.syntaxhighlight_lexer = "python"
        self.header_content = []
        self.footer_content = []
        self.in_header = False
        self.in_footer = False
        self.blockstyle = ""
        self.in_table_of_contents = False
        self.table_of_content_index_body = None
        self.list_level = 0
        self.def_list_level = 0
        self.footnote_ref_dict = {}
        self.footnote_list = []
        self.footnote_chars_idx = 0
        self.footnote_level = 0
        self.pending_ids = []
        self.in_paragraph = False
        self.found_doc_title = False
        self.bumped_list_level_stack = []
        self.meta_dict = {}
        self.line_block_level = 0
        self.line_indent_level = 0
        self.citation_id = None
        self.style_index = 0  # use to form unique style names
        self.str_stylesheet = ""
        self.str_stylesheetcontent = ""
        self.dom_stylesheet = None
        self.table_styles = None
        self.in_citation = False
        # Keep track of nested styling classes
        self.inline_style_count_stack = []

    def rststyle(self, name, parameters=()):
        """
        Returns the style name to use for the given style.

        If `parameters` is given `name` must contain a matching number of
        ``%`` and is used as a format expression with `parameters` as
        the value.
        """
        name1 = name % parameters
        return self.format_map.get(name1, "rststyle-%s" % name1)

    def generate_content_element(self, root):
        return SubElement(root, "office:text")

    def astext(self):
        root = self.content_tree.getroot()
        et = ET.ElementTree(root)
        return ToString(et)

    def content_astext(self):
        return self.astext()

    def set_title(self, title) -> None:
        self.title = title

    def get_title(self):
        return self.title

    def set_embedded_file_list(self, embedded_file_list) -> None:
        self.embedded_file_list = embedded_file_list

    def get_embedded_file_list(self):
        return self.embedded_file_list

    def get_meta_dict(self):
        return self.meta_dict

    #
    # Utility methods

    def append_child(self, tag, attrib=None, parent=None):
        if parent is None:
            parent = self.current_element
        return SubElement(parent, tag, attrib)

    def append_p(self, style, text=None):
        result = self.append_child("text:p", attrib={
            "text:style-name": self.rststyle(style)})
        self.append_pending_ids(result)
        if text is not None:
            result.text = text
        return result

    def append_pending_ids(self, el) -> None:
        if self.settings.create_links:
            for id_ in self.pending_ids:
                SubElement(el, "text:reference-mark", attrib={"text:name": id_})
        self.pending_ids = []

    def set_current_element(self, el) -> None:
        self.current_element = el

    def set_to_parent(self) -> None:
        self.current_element = self.current_element.getparent()

    def _append_strong_label(self, style, label):
        """Append a paragraph with style `style` holding a strong `label`."""
        el = self.append_p(style)
        el1 = SubElement(el, "text:span", attrib={"text:style-name": self.rststyle("strong")})
        el1.text = label
        return el1

    def generate_labeled_block(self, node, label):
        self._append_strong_label("textbody", "%s:" % (self.language.labels[label], ))
        return self.append_p("blockindent")

    def generate_labeled_line(self, node, label):
        el1 = self._append_strong_label("textbody", "%s:" % (self.language.labels[label], ))
        el1.tail = node.astext()
        return el1.getparent()

    def encode(self, text):
        return text.replace("\n", " ")

    #
    # Visitor functions
    #
    # In alphabetic order, more or less.
    #   See docutils.docutils.nodes.node_class_names.
    #

    def dispatch_visit(self, node) -> None:
        """Override to catch basic attributes which many nodes have."""
        self.handle_basic_atts(node)
        nodes.GenericNodeVisitor.dispatch_visit(self, node)

    def handle_basic_atts(self, node) -> None:
        if isinstance(node, nodes.Element) and node["ids"]:
            self.pending_ids += node["ids"]

    def default_visit(self, node) -> None:
        self.document.reporter.warning(f"missing visit_{node.tagname}", base_node=node)

    def default_departure(self, node) -> None:
        self.document.reporter.warning(f"missing depart_{node.tagname}", base_node=node)

    def visit_Text(self, node) -> None:  # noqa: N802 - docutils API name
        # Skip nodes whose text has been processed in parent nodes.
        if isinstance(node.parent, docutils.nodes.literal_block):
            return
        text = node.astext()
        # Are we in mixed content?  If so, add the text to the
        #   etree tail of the previous sibling element.
        if len(self.current_element) > 0:
            last = self.current_element[-1]
            last.tail = last.tail + text if last.tail else text
        else:
            el = self.current_element
            el.text = el.text + text if el.text else text

    def depart_Text(self, node) -> None:  # noqa: N802 - docutils API name
        pass

    #
    # Pre-defined fields
    #

    def visit_address(self, node) -> None:
        el = self.generate_labeled_block(node, "address")
        self.set_current_element(el)

    def depart_address(self, node) -> None:
        self.set_to_parent()

    def visit_author(self, node) -> None:
        if isinstance(node.parent, nodes.authors):
            el = self.append_p("blockindent")
        else:
            el = self.generate_labeled_block(node, "author")
        self.set_current_element(el)

    def depart_author(self, node) -> None:
        self.set_to_parent()

    def visit_authors(self, node) -> None:
        self._append_strong_label("textbody", "%s:" % (self.language.labels["authors"], ))

    def depart_authors(self, node) -> None:
        pass

    def visit_contact(self, node) -> None:
        el = self.generate_labeled_block(node, "contact")
        self.set_current_element(el)

    def depart_contact(self, node) -> None:
        self.set_to_parent()

    def visit_copyright(self, node) -> None:
        el = self.generate_labeled_block(node, "copyright")
        self.set_current_element(el)

    def depart_copyright(self, node) -> None:
        self.set_to_parent()

    def visit_date(self, node) -> None:
        self.generate_labeled_line(node, "date")

    def depart_date(self, node) -> None:
        pass

    def visit_organization(self, node) -> None:
        el = self.generate_labeled_block(node, "organization")
        self.set_current_element(el)

    def depart_organization(self, node) -> None:
        self.set_to_parent()

    def visit_status(self, node) -> None:
        el = self.generate_labeled_block(node, "status")
        self.set_current_element(el)

    def depart_status(self, node) -> None:
        self.set_to_parent()

    def visit_revision(self, node) -> None:
        self.generate_labeled_line(node, "revision")

    def depart_revision(self, node) -> None:
        pass

    def visit_version(self, node) -> None:
        self.generate_labeled_line(node, "version")

    def depart_version(self, node) -> None:
        pass

    def visit_attribution(self, node) -> None:
        self.append_p("attribution", node.astext())

    def depart_attribution(self, node) -> None:
        pass

    def visit_block_quote(self, node) -> None:
        if "epigraph" in node.attributes["classes"]:
            style = self.rststyle("epigraph")
        elif "highlights" in node.attributes["classes"]:
            style = self.rststyle("highlights")
        else:
            style = self.rststyle("blockquote")
        self.paragraph_style_stack.append(style)
        self.blockstyle = style
        self.line_indent_level += 1

    def depart_block_quote(self, node) -> None:
        self.paragraph_style_stack.pop()
        self.blockstyle = ""
        self.line_indent_level -= 1

    def visit_caption(self, node):
        raise nodes.SkipChildren

    def depart_caption(self, node) -> None:
        pass

    def visit_comment(self, node) -> None:
        el = self.append_p("textbody")
        el1 = SubElement(el, "office:annotation", attrib={})
        el2 = SubElement(el1, "dc:creator", attrib={})
        el2.text = os.environ.get("USER", "")
        el2 = SubElement(el1, "text:p", attrib={})
        el2.text = node.astext()

    def depart_comment(self, node) -> None:
        pass

    def visit_compound(self, node) -> None:
        # The compound directive currently receives no special treatment.
        pass

    def depart_compound(self, node) -> None:
        pass

    def visit_container(self, node) -> None:
        styles = node.attributes.get("classes", ())
        if len(styles) > 0:
            self.paragraph_style_stack.append(self.rststyle(styles[0]))

    def depart_container(self, node) -> None:
        styles = node.attributes.get("classes", ())
        if len(styles) > 0:
            self.paragraph_style_stack.pop()

    def visit_decoration(self, node) -> None:
        pass

    def depart_decoration(self, node) -> None:
        pass

    def visit_definition_list(self, node):
        self.def_list_level += 1
        if self.list_level > 5:
            raise RuntimeError("max definition list nesting level exceeded")

    def depart_definition_list(self, node) -> None:
        self.def_list_level -= 1

    def visit_definition_list_item(self, node) -> None:
        pass

    def depart_definition_list_item(self, node) -> None:
        pass

    def visit_term(self, node):
        el = self.append_p("deflist-term-%d" % self.def_list_level)
        el.text = node.astext()
        self.set_current_element(el)
        raise nodes.SkipChildren

    def depart_term(self, node) -> None:
        self.set_to_parent()

    def visit_definition(self, node) -> None:
        self.paragraph_style_stack.append(
            self.rststyle("deflist-def-%d" % self.def_list_level))
        self.bumped_list_level_stack.append(ListLevel(1))

    def depart_definition(self, node) -> None:
        self.paragraph_style_stack.pop()
        self.bumped_list_level_stack.pop()

    def visit_classifier(self, node) -> None:
        if len(self.current_element) > 0:
            el = self.current_element[-1]
            el1 = SubElement(el, "text:span",
                             attrib={"text:style-name": self.rststyle("emphasis")})
            el1.text = " (%s)" % (node.astext(), )

    def depart_classifier(self, node) -> None:
        pass

    def visit_document(self, node) -> None:
        pass

    def depart_document(self, node) -> None:
        self.process_footnotes()

    def visit_docinfo(self, node) -> None:
        self.section_level += 1
        self.section_count += 1
        if self.settings.create_sections:
            el = self.append_child("text:section", attrib={
                "text:name": "Section%d" % self.section_count,
                "text:style-name": "Sect%d" % self.section_level,
            })
            self.set_current_element(el)

    def depart_docinfo(self, node) -> None:
        self.section_level -= 1
        if self.settings.create_sections:
            self.set_to_parent()

    def visit_emphasis(self, node) -> None:
        el = SubElement(self.current_element, "text:span",
                        attrib={"text:style-name": self.rststyle("emphasis")})
        self.set_current_element(el)

    def depart_emphasis(self, node) -> None:
        self.set_to_parent()

    def visit_header(self, node) -> None:
        self.in_header = True

    def depart_header(self, node) -> None:
        self.in_header = False

    def visit_footer(self, node) -> None:
        self.in_footer = True

    def depart_footer(self, node) -> None:
        self.in_footer = False

    def visit_field(self, node) -> None:
        pass

    def depart_field(self, node) -> None:
        pass

    def visit_field_list(self, node) -> None:
        pass

    def depart_field_list(self, node) -> None:
        pass

    def visit_field_name(self, node) -> None:
        self._append_strong_label("textbody", node.astext())

    def depart_field_name(self, node) -> None:
        pass

    def visit_field_body(self, node) -> None:
        self.paragraph_style_stack.append(self.rststyle("blockindent"))

    def depart_field_body(self, node) -> None:
        self.paragraph_style_stack.pop()

    def visit_figure(self, node) -> None:
        pass

    def depart_figure(self, node) -> None:
        pass

    def visit_generated(self, node) -> None:
        pass

    def depart_generated(self, node) -> None:
        pass

    def visit_legend(self, node) -> None:
        if isinstance(node.parent, docutils.nodes.figure):
            el1 = self.current_element[-1]
            el1 = el1[0][0]
            self.current_element = el1
            self.paragraph_style_stack.append(self.rststyle("legend"))

    def depart_legend(self, node) -> None:
        if isinstance(node.parent, docutils.nodes.figure):
            self.paragraph_style_stack.pop()
            self.set_to_parent()
            self.set_to_parent()
            self.set_to_parent()

    def visit_line_block(self, node) -> None:
        self.line_indent_level += 1
        self.line_block_level += 1

    def depart_line_block(self, node) -> None:
        self.line_indent_level -= 1
        self.line_block_level -= 1

    def visit_line(self, node) -> None:
        style = "lineblock%d" % self.line_indent_level
        el1 = SubElement(self.current_element, "text:p",
                         attrib={"text:style-name": self.rststyle(style), })
        self.current_element = el1

    def depart_line(self, node) -> None:
        self.set_to_parent()

    def visit_literal(self, node) -> None:
        el = SubElement(self.current_element, "text:span",
                        attrib={"text:style-name": self.rststyle("inlineliteral")})
        self.set_current_element(el)

    def depart_literal(self, node) -> None:
        self.set_to_parent()

    def visit_inline(self, node) -> None:
        styles = node.attributes.get("classes", ())
        if styles:
            el = self.current_element
            for inline_style in styles:
                el = SubElement(el, "text:span",
                                attrib={"text:style-name": self.rststyle(inline_style)})
            count = len(styles)
        else:
            # No style was specified so use a default style (old code
            # crashed if no style was given)
            el = SubElement(self.current_element, "text:span")
            count = 1
        self.set_current_element(el)
        self.inline_style_count_stack.append(count)

    def depart_inline(self, node) -> None:
        count = self.inline_style_count_stack.pop()
        for _x in range(count):
            self.set_to_parent()

    def _calculate_code_block_padding(self, line):
        matchobj = SPACES_PATTERN.match(line)
        if matchobj:
            return len(matchobj.group())
        matchobj = TABS_PATTERN.match(line)
        if matchobj:
            return len(matchobj.group()) * 8
        return 0

    def _add_syntax_highlighting(self, insource, language):
        lexer = pygments.lexers.get_lexer_by_name(language, stripall=True)
        if language in ("latex", "tex"):
            fmtr = OdtPygmentsLaTeXFormatter(self.rststyle, escape_function=escape_cdata)
        else:
            fmtr = OdtPygmentsProgFormatter(self.rststyle, escape_function=escape_cdata)
        return pygments.highlight(insource, lexer, fmtr)

    def fill_line(self, line):
        line = FILL_PAT1.sub(self.fill_func1, line)
        return FILL_PAT2.sub(self.fill_func2, line)

    def fill_func1(self, matchobj) -> str:
        spaces = matchobj.group(0)
        return '<text:s text:c="%d"/>' % (len(spaces), )

    def fill_func2(self, matchobj) -> str:
        spaces = matchobj.group(0)
        return ' <text:s text:c="%d"/>' % (len(spaces) - 1, )

    def visit_literal_block(self, node) -> None:
        if len(self.paragraph_style_stack) > 1:
            style = self.rststyle("codeblock-indented")
        else:
            style = self.rststyle("codeblock")
        wrapper1 = '<text:p text:style-name="%s">%%s</text:p>' % (style, )
        source = node.astext()
        if pygments and self.settings.add_syntax_highlighting:
            language = node.get("language", "python")
            source = self._add_syntax_highlighting(source, language)
        else:
            source = escape_cdata(source)
        lines = source.split("\n")
        # If there is an empty last line, remove it.
        if lines[-1] == "":
            del lines[-1]
        my_lines = [self.fill_line(my_line).replace("&#10;", "\n") for my_line in lines]
        s1 = ('<wrappertag1 xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">'
              + wrapper1 % ("<text:line-break/>".join(my_lines), )
              + "</wrappertag1>")
        el1 = ET.fromstring(s1.encode("utf-8"))
        for child in el1:
            self.current_element.append(child)

    def depart_literal_block(self, node) -> None:
        pass

    visit_doctest_block = visit_literal_block
    depart_doctest_block = depart_literal_block

    # placeholder for math (see docs/dev/todo.rst)
    def visit_math(self, node) -> None:
        self.document.reporter.warning('"math" role not supported', base_node=node)
        self.visit_literal(node)

    def depart_math(self, node) -> None:
        self.depart_literal(node)

    def visit_math_block(self, node) -> None:
        self.document.reporter.warning('"math" directive not supported', base_node=node)
        self.visit_literal_block(node)

    def depart_math_block(self, node) -> None:
        self.depart_literal_block(node)

    def visit_meta(self, node) -> None:
        name = node.attributes.get("name")
        content = node.attributes.get("content")
        if name is not None and content is not None:
            self.meta_dict[name] = content

    def depart_meta(self, node) -> None:
        pass

    def visit_paragraph(self, node) -> None:
        self.in_paragraph = True
        if self.in_header:
            el = self.append_p("header")
        elif self.in_footer:
            el = self.append_p("footer")
        else:
            style_name = self.paragraph_style_stack[-1]
            el = self.append_child("text:p", attrib={"text:style-name": style_name})
            self.append_pending_ids(el)
        self.set_current_element(el)

    def depart_paragraph(self, node) -> None:
        self.in_paragraph = False
        self.set_to_parent()
        if self.in_header:
            self.header_content.append(self.current_element[-1])
            self.current_element.remove(self.current_element[-1])
        elif self.in_footer:
            self.footer_content.append(self.current_element[-1])
            self.current_element.remove(self.current_element[-1])

    def visit_problematic(self, node) -> None:
        pass

    def depart_problematic(self, node) -> None:
        pass

    def visit_raw(self, node):
        if "format" in node.attributes and "odt" in node.attributes["format"].split():
            rawstr = node.astext()
            attrstr = " ".join('%s="%s"' % (k, v, )
                               for k, v in CONTENT_NAMESPACE_ATTRIB.items())
            contentstr = "<stuff %s>%s</stuff>" % (attrstr, rawstr, )
            content = ET.fromstring(contentstr.encode("utf-8"))
            if len(content) > 0 and not (self.in_header or self.in_footer):
                self.current_element.append(content[0])
        raise nodes.SkipChildren

    def depart_raw(self, node) -> None:
        pass

    def visit_reference(self, node) -> None:
        if self.settings.create_links:
            if "refuri" in node:
                href = node["refuri"]
                if self.settings.cloak_email_addresses and href.startswith("mailto:"):
                    href = self.cloak_mailto(href)
                el = self.append_child("text:a", attrib={
                    "xlink:href": "%s" % href,
                    "xlink:type": "simple",
                })
                self.set_current_element(el)
            elif "refid" in node:
                href = node["refid"]
                self.append_child("text:reference-ref", attrib={
                    "text:ref-name": "%s" % href,
                    "text:reference-format": "text",
                })
            else:
                self.document.reporter.warning(
                    'References must have "refuri" or "refid" attribute.',
                    base_node=node)
        if (self.in_table_of_contents
                and len(node.children) >= 1
                and isinstance(node.children[0], docutils.nodes.generated)):
            node.remove(node.children[0])

    def depart_reference(self, node) -> None:
        if self.settings.create_links and "refuri" in node:
            self.set_to_parent()

    def visit_rubric(self, node) -> None:
        style_name = self.rststyle("rubric")
        classes = node.get("classes")
        if classes and classes[0]:
            style_name = classes[0]
        el = SubElement(self.current_element, "text:h", attrib={
            "text:style-name": style_name,
        })
        el.text = self.encode(node.astext())

    def depart_rubric(self, node) -> None:
        pass

    def visit_section(self, node, move_ids=1) -> None:
        self.section_level += 1
        self.section_count += 1
        if self.settings.create_sections:
            el = self.append_child("text:section", attrib={
                "text:name": "Section%d" % self.section_count,
                "text:style-name": "Sect%d" % self.section_level,
            })
            self.set_current_element(el)

    def depart_section(self, node) -> None:
        self.section_level -= 1
        if self.settings.create_sections:
            self.set_to_parent()

    def visit_strong(self, node) -> None:
        el = SubElement(self.current_element, "text:span",
                        attrib={"text:style-name": self.rststyle("strong")})
        self.set_current_element(el)

    def depart_strong(self, node) -> None:
        self.set_to_parent()

    def visit_substitution_definition(self, node):
        raise nodes.SkipChildren

    def depart_substitution_definition(self, node) -> None:
        pass

    def visit_system_message(self, node) -> None:
        pass

    def depart_system_message(self, node) -> None:
        pass

    def visit_target(self, node) -> None:
        # I don't know how to implement targets in ODF.
        # How do we create a target in oowriter?  A cross-reference?
        pass

    def depart_target(self, node) -> None:
        pass

    def visit_title(self, node, move_ids=1, title_type="title") -> None:
        if isinstance(node.parent, docutils.nodes.section):
            section_level = self.section_level
            if section_level > 7:
                self.document.reporter.warning(
                    "Heading/section levels greater than 7 not supported."
                    '    Reducing to heading level 7 for heading: "%s"' % (
                        node.astext(), ), base_node=node)
                section_level = 7
            el1 = self.append_child("text:h", attrib={
                "text:outline-level": "%d" % section_level,
                "text:style-name": self.rststyle("heading%d", (section_level, )),
            })
            self.append_pending_ids(el1)
            self.set_current_element(el1)
        elif isinstance(node.parent, docutils.nodes.document):
            el1 = SubElement(self.current_element, "text:p", attrib={
                "text:style-name": self.rststyle(title_type),
            })
            self.append_pending_ids(el1)
            self.title = node.astext()
            self.found_doc_title = True
            self.set_current_element(el1)

    def depart_title(self, node) -> None:
        if isinstance(node.parent, (docutils.nodes.section, docutils.nodes.document)):
            self.set_to_parent()

    def visit_subtitle(self, node, move_ids=1) -> None:
        self.visit_title(node, move_ids, title_type="subtitle")

    def depart_subtitle(self, node) -> None:
        self.depart_title(node)

    def visit_title_reference(self, node):
        el = self.append_child("text:span", attrib={
            "text:style-name": self.rststyle("quotation")})
        el.text = self.encode(node.astext())
        raise nodes.SkipChildren

    def depart_title_reference(self, node) -> None:
        pass

    def visit_transition(self, node) -> None:
        self.append_p("horizontalline")

    def depart_transition(self, node) -> None:
        pass

    #
    # Roles (e.g. subscript, superscript, strong, ...
    #
    def visit_subscript(self, node) -> None:
        el = self.append_child("text:span", attrib={
            "text:style-name": "rststyle-subscript",
        })
        self.set_current_element(el)

    def depart_subscript(self, node) -> None:
        self.set_to_parent()

    def visit_superscript(self, node) -> None:
        el = self.append_child("text:span", attrib={
            "text:style-name": "rststyle-superscript",
        })
        self.set_current_element(el)

    def depart_superscript(self, node) -> None:
        self.set_to_parent()

    def visit_abbreviation(self, node) -> None:
        pass

    def depart_abbreviation(self, node) -> None:
        pass

    def visit_acronym(self, node) -> None:
        pass

    def depart_acronym(self, node) -> None:
        pass

    def visit_sidebar(self, node) -> None:
        pass

    def depart_sidebar(self, node) -> None:
        pass


# Use an own reader to modify transformations done.
class Reader(standalone.Reader):

    def get_transforms(self):
        transforms = super().get_transforms()
        if not self.settings.create_links:
            transforms.remove(references.DanglingReferences)
        return transforms
