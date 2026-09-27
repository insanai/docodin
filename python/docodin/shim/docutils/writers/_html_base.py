"""Common definitions for Docutils HTML writers."""

from __future__ import annotations

import os
import os.path
import re
import warnings
from pathlib import Path
from typing import TYPE_CHECKING, Any

import docutils
from docutils import frontend, languages, nodes, utils, writers
from docutils.parsers.rst.directives import length_or_percentage_or_unitless
from docutils.parsers.rst.directives.images import PIL
from docutils.transforms import writer_aux
from docutils.utils.math import (
    MathError,
    latex2mathml,
    math2html,
    tex2mathml_extern,
    unichar2tex,
    wrap_math_code,
)
from docutils.writers._html_base_docinfo import DocinfoTranslatorMixin
from docutils.writers._html_base_media import MediaTranslatorMixin
from docutils.writers._html_base_tables import TableTranslatorMixin

if TYPE_CHECKING:
    from docutils.transforms import Transform

__docformat__ = "reStructuredText"

__all__ = [
    # public API
    "HTMLTranslator", "SimpleListChecker", "Writer",
    # re-exported for backwards compatibility
    "PIL", "MathError", "latex2mathml", "math2html", "tex2mathml_extern", "unichar2tex",
    "wrap_math_code",
]


class Writer(writers.Writer):
    supported = ("html", "xhtml")  # update in subclass
    """Formats this writer supports."""

    settings_spec = (
        "HTML Writer Options",
        None,
        (("Specify the template file (UTF-8 encoded). (default: writer dependent)",
          ["--template"],
          {"metavar": "<file>"}),
         ("Comma separated list of stylesheet URLs. "
          "Overrides previous --stylesheet and --stylesheet-path settings.",
          ["--stylesheet"],
          {"metavar": "<URL[,URL,...]>", "overrides": "stylesheet_path",
           "validator": frontend.validate_comma_separated_list}),
         ("Comma separated list of stylesheet paths. "
          "Relative paths are expanded if a matching file is found in "
          "the --stylesheet-dirs. With --link-stylesheet, "
          "the path is rewritten relative to the output HTML file. "
          "(default: writer dependent)",
          ["--stylesheet-path"],
          {"metavar": "<file[,file,...]>", "overrides": "stylesheet",
           "validator": frontend.validate_comma_separated_list}),
         ("Comma-separated list of directories where stylesheets are found. "
          "Used by --stylesheet-path when expanding relative path arguments. "
          "(default: writer dependent)",
          ["--stylesheet-dirs"],
          {"metavar": "<dir[,dir,...]>",
           "validator": frontend.validate_comma_separated_list}),
         ("Embed the stylesheet(s) in the output HTML file.  The stylesheet "
          "files must be accessible during processing. (default)",
          ["--embed-stylesheet"],
          {"default": True, "action": "store_true",
           "validator": frontend.validate_boolean}),
         ("Link to the stylesheet(s) in the output HTML file. ",
          ["--link-stylesheet"],
          {"dest": "embed_stylesheet", "action": "store_false"}),
         ("Specify the initial header level. "
          "Does not affect document title & subtitle (see --no-doc-title)."
          "(default: writer dependent).",
          ["--initial-header-level"],
          {"choices": "1 2 3 4 5 6 auto".split(), "default": "2",
           "metavar": "<level>"}),
         ('Format for footnote references: one of "superscript" or '
          '"brackets". (default: "brackets")',
          ["--footnote-references"],
          {"choices": ["superscript", "brackets"], "default": "brackets",
           "metavar": "<format>",
           "overrides": "trim_footnote_reference_space"}),
         ("Format for block quote attributions: "
          'one of "dash" (em-dash prefix), "parentheses"/"parens", or "none". '
          '(default: "dash")',
          ["--attribution"],
          {"choices": ["dash", "parentheses", "parens", "none"],
           "default": "dash", "metavar": "<format>"}),
         ('Remove extra vertical whitespace between items of "simple" bullet '
          "lists and enumerated lists. (default)",
          ["--compact-lists"],
          {"default": True, "action": "store_true",
           "validator": frontend.validate_boolean}),
         ("Disable compact simple bullet and enumerated lists.",
          ["--no-compact-lists"],
          {"dest": "compact_lists", "action": "store_false"}),
         ("Remove extra vertical whitespace between items of simple field "
          "lists. (default)",
          ["--compact-field-lists"],
          {"default": True, "action": "store_true",
           "validator": frontend.validate_boolean}),
         ("Disable compact simple field lists.",
          ["--no-compact-field-lists"],
          {"dest": "compact_field_lists", "action": "store_false"}),
         ("Class value(s) assigned to all tables. "
          "Defined styles: borderless, booktabs, "
          "align-left, align-center, align-right, "
          "colwidths-auto, colwidths-grid.",
          ["--table-style"],
          {"metavar": "<style>", "default": ""}),
         ('Math output format (one of "MathML", "HTML", "MathJax", '
          'or "LaTeX") and option(s). (default: "MathML")',
          ["--math-output"],
          {"metavar": "<format [option(s)]>", "default": "MathML",
           "validator": frontend.validate_math_output}),
         ("Prepend an XML declaration. ",
          ["--xml-declaration"],
          {"default": False, "action": "store_true",
           "validator": frontend.validate_boolean}),
         ("Omit the XML declaration.",
          ["--no-xml-declaration"],
          {"dest": "xml_declaration", "action": "store_false"}),
         ("Obfuscate email addresses to confuse harvesters while still "
          "keeping email links usable with standards-compliant browsers.",
          ["--cloak-email-addresses"],
          {"action": "store_true", "validator": frontend.validate_boolean}),
         ),
    )

    settings_defaults = {"output_encoding_error_handler": "xmlcharrefreplace"}

    relative_path_settings = ("template",)

    config_section = "html base writer"  # overwrite in subclass
    config_section_dependencies = ("writers", "html writers")

    visitor_attributes = (
        "head_prefix", "head", "stylesheet", "body_prefix",
        "body_pre_docinfo", "docinfo", "body", "body_suffix",
        "title", "subtitle", "header", "footer", "meta", "fragment",
        "html_prolog", "html_head", "html_title", "html_subtitle",
        "html_body")

    def get_transforms(self) -> list[type[Transform]]:
        return [*super().get_transforms(), writer_aux.Admonitions]

    def translate(self) -> None:
        self.visitor = visitor = self.translator_class(self.document)
        self.document.walkabout(visitor)
        for attr in self.visitor_attributes:
            setattr(self, attr, getattr(visitor, attr))
        self.output = self.apply_template()

    def apply_template(self) -> str:
        template_path = Path(self.document.settings.template)
        template = template_path.read_text(encoding="utf-8")
        return template % self.interpolation_dict()

    def interpolation_dict(self) -> dict[str, Any]:
        subs = {attr: "".join(getattr(self, attr)).rstrip("\n")
                for attr in self.visitor_attributes}
        subs["encoding"] = self.document.settings.output_encoding
        subs["version"] = docutils.__version__
        return subs

    def assemble_parts(self) -> None:
        super().assemble_parts()
        for part in self.visitor_attributes:
            self.parts[part] = "".join(getattr(self, part))


class HTMLTranslator(DocinfoTranslatorMixin, MediaTranslatorMixin, TableTranslatorMixin,
                     writers.DoctreeTranslator):
    """Generic Docutils to HTML translator.

    See the `html4css1` and `html5_polyglot` writers for full featured HTML translators.

    .. IMPORTANT::
      The `visit_*` and `depart_*` methods use a heterogeneous stack, `self.context`.
      When subclassing, make sure to be consistent in its use!

      Examples for robust coding:

      a) Override both `visit_*` and `depart_*` methods, don't call the parent functions.

      b) Extend both and unconditionally call the parent functions::

           def visit_example(self, node):
               if foo:
                   self.body.append('<div class="foo">')
               html4css1.HTMLTranslator.visit_example(self, node)

           def depart_example(self, node):
               html4css1.HTMLTranslator.depart_example(self, node)
               if foo:
                   self.body.append('</div>')

      c) Extend both, calling the parent functions under the same conditions::

           def visit_example(self, node):
               if foo:
                   self.body.append('<div class="foo">\\n')
               else: # call the parent method
                   _html_base.HTMLTranslator.visit_example(self, node)

           def depart_example(self, node):
               if foo:
                   self.body.append('</div>\\n')
               else: # call the parent method
                   _html_base.HTMLTranslator.depart_example(self, node)

      d) Extend one method (call the parent), but don't otherwise use the `self.context`
         stack::

           def depart_example(self, node):
               _html_base.HTMLTranslator.depart_example(self, node)
               if foo:
                   # implementation-specific code
                   # that does not use `self.context`
                   self.body.append('</div>\\n')

      This way, changes in stack use will not bite you.
    """

    doctype = "<!DOCTYPE html>\n"

    head_prefix_template = ('<html xmlns="http://www.w3.org/1999/xhtml"'
                            ' xml:lang="%(lang)s" lang="%(lang)s">\n<head>\n')
    content_type = '<meta charset="%s" />\n'
    generator = (f'<meta name="generator" content="Docutils {docutils.__version__}: '
                 'https://docutils.sourceforge.io/" />\n')
    # `starttag()` arguments for the main document (HTML5 uses <main>)
    documenttag_args = {"tagname": "div", "CLASS": "document"}

    # Template for the MathJax script in the header:
    mathjax_script = '<script type="text/javascript" src="%s"></script>\n'

    mathjax_url = "file:/usr/share/javascript/mathjax/MathJax.js"
    """URL of the MathJax javascript library.

    The MathJax library ought to be installed on the same server as the rest of the deployed
    site files and specified in the `math-output` setting appended to "mathjax".
    See `Docutils Configuration`__.

    __ https://docutils.sourceforge.io/docs/user/config.html#math-output

    The fallback tries a local MathJax installation at
    ``/usr/share/javascript/mathjax/MathJax.js``.
    """

    stylesheet_link = '<link rel="stylesheet" href="%s" type="text/css" />\n'
    embedded_stylesheet = '<style type="text/css">\n\n%s\n</style>\n'
    words_and_spaces = re.compile(r"[^ \n]+| +|\n")
    # wrap point inside word:
    in_word_wrap_point = re.compile(r".+\W\W.+|[-?].+")
    lang_attribute = "lang"  # name changes to 'xml:lang' in XHTML 1.1

    special_characters = {ord("&"): "&amp;",
                          ord("<"): "&lt;",
                          ord('"'): "&quot;",
                          ord(">"): "&gt;",
                          ord("@"): "&#64;",  # may thwart address harvesters
                          }
    """Character references for characters with a special meaning in HTML."""

    videotypes = ("video/mp4", "video/webm", "video/ogg")
    """MIME types supported by the HTML5 <video> element."""

    def __init__(self, document: nodes.document) -> None:
        super().__init__(document)
        self._init_settings(document)
        self._init_parts()
        self._init_bookkeeping()

    def _init_settings(self, document: nodes.document) -> None:
        # Process settings.
        settings = self.settings
        self.language = languages.get_language(settings.language_code, document.reporter)
        if settings.initial_header_level == "auto":
            if len(document) and document[0].next_node(
                    nodes.title, include_self=True, descend=False):
                self.initial_header_level = 2
            else:
                self.initial_header_level = 1
        else:
            self.initial_header_level = int(settings.initial_header_level)
        # image_loading (only defined for HTML5 writer)
        image_loading_default = "link"
        # convert legacy setting embed_images:
        if getattr(settings, "embed_images", None) is not None:
            if settings.embed_images:
                image_loading_default = "embed"
            warnings.warn('The configuration setting "embed_images"\n'
                          "  will be removed in Docutils 2.0. "
                          f'Use "image_loading: {image_loading_default}".',
                          FutureWarning, stacklevel=9)
        self.image_loading = getattr(settings, "image_loading", image_loading_default)
        # backwards compatibiltiy: validate/convert programatically set strings
        if isinstance(self.settings.math_output, str):
            self.settings.math_output = frontend.validate_math_output(
                                            self.settings.math_output)
        self.math_output, self.math_options = self.settings.math_output

    def _init_parts(self) -> None:
        # Set up "parts" (cf. docs/api/publisher.html#publish-parts-details).
        settings = self.settings
        self.body = []  # equivalent to `fragment`, ≠ `html_body`
        self.body_prefix = ["</head>\n<body>\n"]  # + optional header
        self.body_pre_docinfo = []  # document heading (title and subtitle)
        self.body_suffix = ["</body>\n</html>\n"]  # + optional footer
        self.docinfo = []
        self.footer = []
        self.fragment = []  # main content of the document ("naked" body)
        self.head = []
        self.head_prefix = []  # everything up to and including <head>
        self.header = []
        self.html_body = []
        self.html_head = [self.content_type]  # charset not interpolated
        self.html_prolog = []
        self.html_subtitle = []
        self.html_title = []
        self.meta = [self.generator]
        self.stylesheet = [self.stylesheet_call(path)
                           for path in utils.get_stylesheet_list(settings)]
        self.title = []
        self.subtitle = []
        if settings.xml_declaration:
            self.head_prefix.append(utils.xml_declaration(settings.output_encoding))
            # encoding not interpolated:
            self.html_prolog.append(utils.xml_declaration("%s"))
        if settings.output_encoding and settings.output_encoding.lower() != "unicode":
            self.meta.insert(0, self.content_type % settings.output_encoding)

    def _init_bookkeeping(self) -> None:
        # Bookkeeping attributes; reflect state of translator.
        self.context = []
        """Heterogeneous stack.

        Used by visit_* and depart_* functions in conjunction with the tree traversal.
        Make sure that the pops correspond to the pushes.
        """
        self.section_level = 0
        self.colspecs = []
        self.compact_p = True
        self.compact_simple = False
        self.compact_field_list = False
        self.in_docinfo = False
        self.in_sidebar = False
        self.in_document_title = 0  # len(self.body) or 0
        self.in_mailto = False
        self.author_in_authors = False  # for html4css1
        self.math_header = []
        self.messages = []
        """Queue of system_message nodes (writing issues).

        Call `report_messages()` in `depart_*_block()` methods to clean up!
        """

    def astext(self) -> str:
        return "".join(self.head_prefix + self.head
                       + self.stylesheet + self.body_prefix
                       + self.body_pre_docinfo + self.docinfo
                       + self.body + self.body_suffix)

    def attval(self, text: str, whitespace: re.Pattern = re.compile("[\n\r\t\v\f]")) -> str:
        """Cleanse, HTML encode, and return attribute value text."""
        encoded = self.encode(whitespace.sub(" ", text))
        if self.in_mailto and self.settings.cloak_email_addresses:
            # Cloak at-signs ("%40") and periods with HTML entities.
            encoded = encoded.replace("%40", "&#37;&#52;&#48;")
            encoded = encoded.replace(".", "&#46;")
        return encoded

    def cloak_email(self, addr: str) -> str:
        """Try to hide the link text of a email link from harversters."""
        # Surround at-signs and periods with <span> tags.  ("@" has already been encoded to
        # "&#64;" by the `encode` method.)
        addr = addr.replace("&#64;", "<span>&#64;</span>")
        return addr.replace(".", "<span>&#46;</span>")

    def cloak_mailto(self, uri: str) -> str:
        """Try to hide a mailto: URL from harvesters."""
        # Encode "@" using a URL octet reference (see RFC 1738).
        # Further cloaking with HTML entities will be done in the `attval` function.
        return uri.replace("@", "%40")

    def encode(self, text: Any) -> str:
        """Encode special characters in `text` & return."""
        # Use only named entities known in both XML and HTML
        # other characters are automatically encoded "by number" if required.
        return str(text).translate(self.special_characters)

    def stylesheet_call(self, path: str, adjust_path: bool | None = None) -> str:
        """Return code to reference or embed stylesheet file `path`"""
        if adjust_path is None:
            adjust_path = bool(self.settings.stylesheet_path)
        if self.settings.embed_stylesheet:
            try:
                content = Path(path).read_text(encoding="utf-8")
            except OSError as err:
                msg = f"Cannot embed stylesheet: {err}"
                self.document.reporter.error(msg)
                return "<--- %s --->\n" % msg
            self.settings.record_dependencies.add(path)
            return self.embedded_stylesheet % content
        # else link to style file:
        if adjust_path:
            # rewrite path relative to output (cf. config.html#stylesheet-path)
            path = utils.relative_path(self.settings.output_path, path)
        return self.stylesheet_link % self.encode(path)

    def starttag(self, node: nodes.Element | dict, tagname: str, suffix: str = "\n",
                 empty: bool = False, **attributes: Any) -> str:
        """Construct and return a start tag given a node (id & class attributes are
        extracted), tag name, and optional attributes.
        """
        tagname = tagname.lower()
        atts = {name.lower(): value for name, value in attributes.items()}
        self._starttag_classes(node, atts)
        assert "id" not in atts
        prefix, suffix = self._starttag_ids(node, atts, suffix, empty)
        parts = [tagname]
        for name, value in sorted(atts.items()):
            # value=None was used for boolean attributes without value,
            # but this isn't supported by XHTML.
            assert value is not None
            if isinstance(value, list):
                value = " ".join(str(v) for v in value)
            parts.append(f'{name.lower()}="{self.attval(str(value))}"')
        infix = " /" if empty else ""
        return f"{prefix}<{' '.join(parts)}{infix}>{suffix}"

    def _starttag_classes(self, node: nodes.Element | dict, atts: dict) -> None:
        # Unify class arguments in `atts` and move language specification.
        classes = atts.pop("classes", [])
        langs = []
        for cls in node.get("classes", []) + atts.pop("class", "").split():
            if cls.startswith("language-"):
                langs.append(cls.removeprefix("language-"))
            elif cls.strip() and cls not in classes:
                classes.append(cls)
        if langs:
            # attribute name is 'lang' in XHTML 1.0 but 'xml:lang' in 1.1
            atts[self.lang_attribute] = langs[0]
        # filter classes that are processed by the writer:
        internal = ("colwidths-auto", "colwidths-given", "colwidths-grid")
        if isinstance(node, nodes.table):
            classes = [cls for cls in classes if cls not in internal]
        if classes:
            atts["class"] = " ".join(classes)

    @staticmethod
    def _starttag_ids(node: nodes.Element | dict, atts: dict, suffix: str,
                      empty: bool) -> tuple[str, str]:
        # Set the "id" attribute and return `prefix` and `suffix` with auxiliary
        # <span> elements for additional IDs.
        prefix = ""
        ids = node.get("ids", [])
        ids.extend(atts.pop("ids", []))
        if not ids:
            return prefix, suffix
        atts["id"] = ids[0]
        # Note that we cannot use empty "a" elements because there may be targets inside of
        # references, but nested "a" elements aren't allowed in XHTML (even if they do not
        # all have a "href" attribute).
        outside = empty or isinstance(node, (nodes.Sequential, nodes.docinfo, nodes.table))
        for id_ in ids[1:]:
            if outside:  # Insert target right in front of element.
                prefix += f'<span id="{id_}"></span>'
            else:  # Place the auxiliary <span> tag *inside* the element (first child).
                suffix += f'<span id="{id_}"></span>'
        return prefix, suffix

    def emptytag(self, node: nodes.Element | dict, tagname: str, suffix: str = "\n",
                 **attributes: Any) -> str:
        """Construct and return an XML-compatible empty tag."""
        return self.starttag(node, tagname, suffix, empty=True, **attributes)

    def report_messages(self, node: nodes.Element) -> None:
        if isinstance(node.parent, (nodes.system_message, nodes.entry)):
            return
        while self.messages:
            message = self.messages.pop(0)
            if self.settings.report_level <= message["level"]:
                message.walkabout(self)

    def set_class_on_child(self, node: nodes.Element, class_: str, index: int = 0) -> None:
        """Set class `class_` on the visible child no. index of `node`.

        Do nothing if node has fewer children than `index`.
        """
        children = [n for n in node if not isinstance(n, nodes.Invisible)]
        try:
            child = children[index]
        except IndexError:
            return
        child["classes"].append(class_)

    # Visitor methods
    # ---------------

    def visit_Text(self, node: nodes.Text) -> None:
        encoded = self.encode(node.astext())
        if self.in_mailto and self.settings.cloak_email_addresses:
            encoded = self.cloak_email(encoded)
        self.body.append(encoded)

    def depart_Text(self, node: nodes.Text) -> None:
        pass

    def visit_abbreviation(self, node: nodes.Element) -> None:
        # @@@ implementation incomplete ("title" attribute)
        self.body.append(self.starttag(node, "abbr", ""))

    def depart_abbreviation(self, node: nodes.Element) -> None:
        self.body.append("</abbr>")

    def visit_acronym(self, node: nodes.Element) -> None:
        # @@@ implementation incomplete ("title" attribute)
        self.body.append(self.starttag(node, "acronym", ""))

    def depart_acronym(self, node: nodes.Element) -> None:
        self.body.append("</acronym>")

    def visit_admonition(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "aside", classes=["admonition"]))

    def depart_admonition(self, node: nodes.Element | None = None) -> None:
        self.body.append("</aside>\n")

    attribution_formats = {"dash": ("—", ""),
                           "parentheses": ("(", ")"),
                           "parens": ("(", ")"),
                           "none": ("", "")}

    def visit_attribution(self, node: nodes.Element) -> None:
        prefix, suffix = self.attribution_formats[self.settings.attribution]
        self.context.append(suffix)
        self.body.append(self.starttag(node, "p", prefix, CLASS="attribution"))

    def depart_attribution(self, node: nodes.Element) -> None:
        self.body.append(self.context.pop() + "</p>\n")

    def visit_block_quote(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "blockquote"))

    def depart_block_quote(self, node: nodes.Element) -> None:
        self.body.append("</blockquote>\n")

    def check_simple_list(self, node: nodes.Element) -> bool:
        """Check for a simple list that can be rendered compactly."""
        visitor = SimpleListChecker(self.document)
        try:
            node.walk(visitor)
        except nodes.NodeFound:
            return False
        return True

    # Compact lists
    # -------------
    # Include definition lists and field lists (in addition to ordered and unordered lists)
    # in the test if a list is "simple"  (cf. the html4css1.HTMLTranslator docstring and the
    # SimpleListChecker class at the end of this file).

    def is_compactable(self, node: nodes.Element) -> bool:
        # explicit class arguments have precedence
        if "compact" in node["classes"]:
            return True
        if "open" in node["classes"]:
            return False
        # check config setting:
        if (isinstance(node, (nodes.field_list, nodes.definition_list))
                and not self.settings.compact_field_lists):
            return False
        if (isinstance(node, (nodes.enumerated_list, nodes.bullet_list))
                and not self.settings.compact_lists):
            return False
        # Table of Contents:
        if "contents" in node.parent["classes"]:
            return True
        # check the list items:
        return self.check_simple_list(node)

    def visit_bullet_list(self, node: nodes.Element) -> None:
        atts = {}
        old_compact_simple = self.compact_simple
        self.context.append((self.compact_simple, self.compact_p))
        self.compact_p = None
        self.compact_simple = self.is_compactable(node)
        if self.compact_simple and not old_compact_simple:
            atts["class"] = "simple"
        self.body.append(self.starttag(node, "ul", **atts))

    def depart_bullet_list(self, node: nodes.Element) -> None:
        self.compact_simple, self.compact_p = self.context.pop()
        self.body.append("</ul>\n")

    def visit_caption(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "p", "", CLASS="caption"))

    def depart_caption(self, node: nodes.Element) -> None:
        self.body.append("</p>\n")

    # Use semantic tag and DPub role (HTML4 uses a table)
    def visit_citation(self, node: nodes.Element) -> None:
        # role 'doc-bibloentry' requires wrapping in an element with role 'list' and an
        # element with role 'doc-bibliography'
        # https://www.w3.org/TR/dpub-aria-1.0/#doc-biblioentry)
        if not isinstance(node.previous_sibling(), type(node)):
            self.body.append('<div role="list" class="citation-list">\n')
        self.body.append(self.starttag(node, "div", classes=[node.tagname],
                                       role="doc-biblioentry"))

    def depart_citation(self, node: nodes.Element) -> None:
        self.body.append("</div>\n")
        if not isinstance(node.next_node(descend=False, siblings=True), type(node)):
            self.body.append("</div>\n")

    # Use DPub role (overwritten in HTML4)
    def visit_citation_reference(self, node: nodes.Element) -> None:
        href = "#"
        if "refid" in node:
            href += node["refid"]
        elif "refname" in node:
            href += self.document.nameids[node["refname"]]
        # else: # TODO system message (or already in the transform)?
        # 'Citation reference missing.'
        self.body.append(self.starttag(node, "a", suffix="[", href=href,
                                       classes=["citation-reference"],
                                       role="doc-biblioref"))

    def depart_citation_reference(self, node: nodes.Element) -> None:
        self.body.append("]</a>")

    def visit_classifier(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "span", "", CLASS="classifier"))

    def depart_classifier(self, node: nodes.Element) -> None:
        self.body.append("</span>")
        self.depart_term(node)  # close the term element after last classifier

    def visit_comment(self, node: nodes.Element, sub=re.compile("-(?=-)").sub) -> None:
        """Escape double-dashes in comment text."""
        self.body.append("<!-- %s -->\n" % sub("- ", node.astext()))
        # Content already processed:
        raise nodes.SkipNode

    def visit_compound(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "div", CLASS="compound"))

    def depart_compound(self, node: nodes.Element) -> None:
        self.body.append("</div>\n")

    def visit_container(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "div", CLASS="docutils container"))

    def depart_container(self, node: nodes.Element) -> None:
        self.body.append("</div>\n")

    def visit_decoration(self, node: nodes.Element) -> None:
        pass

    def depart_decoration(self, node: nodes.Element) -> None:
        pass

    def visit_definition(self, node: nodes.Element) -> None:
        if "details" not in node.parent.parent["classes"]:
            self.body.append(self.starttag(node, "dd", ""))

    def depart_definition(self, node: nodes.Element) -> None:
        if "details" not in node.parent.parent["classes"]:
            self.body.append("</dd>\n")

    def visit_definition_list(self, node: nodes.Element) -> None:
        if "details" in node["classes"]:
            self.body.append(self.starttag(node, "div"))
        else:
            classes = ["simple"] if self.is_compactable(node) else []
            self.body.append(self.starttag(node, "dl", classes=classes))

    def depart_definition_list(self, node: nodes.Element) -> None:
        if "details" in node["classes"]:
            self.body.append("</div>\n")
        else:
            self.body.append("</dl>\n")

    # Use a "details" disclosure element if parent has "class" arg "details".
    def visit_definition_list_item(self, node: nodes.Element) -> None:
        if "details" in node.parent["classes"]:
            atts = {}
            if "open" in node.parent["classes"]:
                atts["open"] = "open"
            self.body.append(self.starttag(node, "details", **atts))

    def depart_definition_list_item(self, node: nodes.Element) -> None:
        if "details" in node.parent["classes"]:
            self.body.append("</details>\n")

    def visit_description(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "dd", ""))

    def depart_description(self, node: nodes.Element) -> None:
        self.body.append("</dd>\n")

    def visit_doctest_block(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "pre", suffix="",
                                       classes=["code", "python", "doctest"]))

    def depart_doctest_block(self, node: nodes.Element) -> None:
        self.body.append("\n</pre>\n")

    def visit_document(self, node: nodes.document) -> None:
        title = (node.get("title")
                 or os.path.basename(node.get("source") or "")
                 or "untitled Docutils document")
        self.head.append(f"<title>{self.encode(title)}</title>\n")

    def depart_document(self, node: nodes.document) -> None:
        lang = self.settings.language_code
        self.head_prefix.extend([self.doctype, self.head_prefix_template % {"lang": lang}])
        self.html_prolog.append(self.doctype)
        self.head = self.meta[:] + self.head
        if 'name="dcterms.' in "".join(self.meta):
            self.head.append('<link rel="schema.dcterms" href="http://purl.org/dc/terms/"/>')
        if self.math_header:
            if self.math_output == "mathjax":
                self.head.extend(self.math_header)
            else:
                self.stylesheet.extend(self.math_header)
        if (self.settings.output_encoding  # may be None
                and self.settings.output_encoding.lower() != "unicode"):
            # skip content-type meta tag with interpolated charset value:
            self.html_head.extend(self.head[1:])
        else:
            self.html_head.extend(self.head)
        self.body_prefix.append(self.starttag(node, **self.documenttag_args))
        self.body_suffix.insert(0, f'</{self.documenttag_args["tagname"]}>\n')
        self.fragment.extend(self.body)  # self.fragment is the "naked" body
        self.html_body.extend(self.body_prefix[1:] + self.body_pre_docinfo
                              + self.docinfo + self.body
                              + self.body_suffix[:-1])
        assert not self.context, f"len(context) = {len(self.context)}"

    def visit_emphasis(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "em", ""))

    def depart_emphasis(self, node: nodes.Element) -> None:
        self.body.append("</em>")

    def visit_enumerated_list(self, node: nodes.Element) -> None:
        atts = {"classes": []}
        if "start" in node:
            atts["start"] = node["start"]
        if "enumtype" in node:
            atts["classes"].append(node["enumtype"])
        if self.is_compactable(node):
            atts["classes"].append("simple")
        self.body.append(self.starttag(node, "ol", **atts))

    def depart_enumerated_list(self, node: nodes.Element) -> None:
        self.body.append("</ol>\n")

    def visit_field_list(self, node: nodes.Element) -> None:
        atts = {}
        classes = node.setdefault("classes", [])
        for i, cls in enumerate(classes):
            if cls.startswith("field-indent-"):
                try:
                    indent_length = length_or_percentage_or_unitless(
                        cls.removeprefix("field-indent-"), "px")
                except ValueError:
                    break
                atts["style"] = "--field-indent: %s;" % indent_length
                classes.pop(i)
                break
        classes.append("field-list")
        if self.is_compactable(node):
            classes.append("simple")
        self.body.append(self.starttag(node, "dl", **atts))

    def depart_field_list(self, node: nodes.Element) -> None:
        self.body.append("</dl>\n")

    def visit_field(self, node: nodes.Element) -> None:
        # Insert children (<field_name> and <field_body>) directly.
        # Transfer "id" attribute to the <field_name> child node.
        for child in node:
            if isinstance(child, nodes.field_name):
                child["ids"].extend(node["ids"])

    def depart_field(self, node: nodes.Element) -> None:
        pass

    # as field is ignored, pass class arguments to field-name and field-body:
    def visit_field_name(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "dt", "", classes=node.parent["classes"]))

    def depart_field_name(self, node: nodes.Element) -> None:
        self.body.append('<span class="colon">:</span></dt>\n')

    def visit_field_body(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "dd", "", classes=node.parent["classes"]))
        # prevent misalignment of following content if the field is empty:
        if not node.children:
            self.body.append("<p></p>")

    def depart_field_body(self, node: nodes.Element) -> None:
        self.body.append("</dd>\n")

    def visit_figure(self, node: nodes.Element) -> None:
        atts = {"class": "figure"}
        if node.get("width"):
            atts["style"] = "width: %s" % node["width"]
        if node.get("align"):
            atts["class"] += " align-" + node["align"]
        self.body.append(self.starttag(node, "div", **atts))

    def depart_figure(self, node: nodes.Element) -> None:
        self.body.append("</div>\n")

    def visit_footer(self, node: nodes.Element) -> None:
        self.context.append(len(self.body))

    def depart_footer(self, node: nodes.Element) -> None:
        start = self.context.pop()
        footer = [self.starttag(node, "div", CLASS="footer"), '<hr class="footer" />\n',
                  *self.body[start:], "\n</div>\n"]
        self.footer.extend(footer)
        self.body_suffix[:0] = footer
        del self.body[start:]

    def visit_footnote(self, node: nodes.Element) -> None:
        # No native HTML element: use <aside> with ARIA role (html4css1 uses tables).
        # Wrap groups of footnotes for easier styling.
        label_style = self.settings.footnote_references  # brackets/superscript
        if not isinstance(node.previous_sibling(), type(node)):
            self.body.append(f'<aside class="footnote-list {label_style}">\n')
        self.body.append(self.starttag(node, "aside", classes=[node.tagname, label_style],
                                       role="doc-footnote"))

    def depart_footnote(self, node: nodes.Element) -> None:
        self.body.append("</aside>\n")
        if not isinstance(node.next_node(descend=False, siblings=True), type(node)):
            self.body.append("</aside>\n")

    def visit_footnote_reference(self, node: nodes.Element) -> None:
        href = "#" + node["refid"]
        classes = [self.settings.footnote_references]
        self.body.append(self.starttag(node, "a", suffix="", classes=classes,
                                       role="doc-noteref", href=href))
        self.body.append('<span class="fn-bracket">[</span>')

    def depart_footnote_reference(self, node: nodes.Element) -> None:
        self.body.append('<span class="fn-bracket">]</span>')
        self.body.append("</a>")

    # Docutils-generated text: put section numbers in a span for CSS styling:
    def visit_generated(self, node: nodes.Element) -> None:
        if "sectnum" in node["classes"]:
            # get section number (strip trailing no-break-spaces)
            sectnum = node.astext().rstrip(" ")
            self.body.append('<span class="sectnum">%s </span>' % self.encode(sectnum))
            # Content already processed:
            raise nodes.SkipNode

    def depart_generated(self, node: nodes.Element) -> None:
        pass

    def visit_header(self, node: nodes.Element) -> None:
        self.context.append(len(self.body))

    def depart_header(self, node: nodes.Element) -> None:
        start = self.context.pop()
        header = [self.starttag(node, "div", CLASS="header"), *self.body[start:],
                  '\n<hr class="header"/>\n</div>\n']
        self.body_prefix.extend(header)
        self.header.extend(header)
        del self.body[start:]

    def visit_inline(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "span", ""))

    def depart_inline(self, node: nodes.Element) -> None:
        self.body.append("</span>")

    # footnote and citation labels:
    def visit_label(self, node: nodes.Element) -> None:
        self.body.append('<span class="label">')
        self.body.append('<span class="fn-bracket">[</span>')
        # footnote/citation backrefs:
        if self.settings.footnote_backlinks:
            backrefs = node.parent.get("backrefs", [])
            if len(backrefs) == 1:
                self.body.append('<a role="doc-backlink" href="#%s">' % backrefs[0])

    def depart_label(self, node: nodes.Element) -> None:
        backrefs = []
        if self.settings.footnote_backlinks:
            backrefs = node.parent.get("backrefs", backrefs)
        if len(backrefs) == 1:
            self.body.append("</a>")
        self.body.append('<span class="fn-bracket">]</span></span>\n')
        if len(backrefs) > 1:
            backlinks = ['<a role="doc-backlink" href="#%s">%s</a>' % (ref, i)
                         for (i, ref) in enumerate(backrefs, 1)]
            self.body.append('<span class="backrefs">(%s)</span>\n' % ",".join(backlinks))

    def visit_legend(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "div", CLASS="legend"))

    def depart_legend(self, node: nodes.Element) -> None:
        self.body.append("</div>\n")

    def visit_line(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "div", suffix="", CLASS="line"))
        if not len(node):
            self.body.append("<br />")

    def depart_line(self, node: nodes.Element) -> None:
        self.body.append("</div>\n")

    def visit_line_block(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "div", CLASS="line-block"))

    def depart_line_block(self, node: nodes.Element) -> None:
        self.body.append("</div>\n")

    def visit_list_item(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "li", ""))

    def depart_list_item(self, node: nodes.Element) -> None:
        self.body.append("</li>\n")

    # inline literal
    def visit_literal(self, node: nodes.Element) -> None:
        # special case: "code" role
        classes = node["classes"]
        if "code" in classes:
            # filter 'code' from class arguments
            classes.pop(classes.index("code"))
            self.body.append(self.starttag(node, "code", ""))
            return
        self.body.append(self.starttag(node, "span", "", CLASS="docutils literal"))
        self._literal_text(node)
        self.body.append("</span>")
        raise nodes.SkipNode  # content already processed

    def _literal_text(self, node: nodes.Element) -> None:
        # Append the encoded text of the inline literal `node` to the body.
        text = node.astext()
        # remove hard line breaks (except if in a parsed-literal block)
        if not isinstance(node.parent, nodes.literal_block):
            text = text.replace("\n", " ")
        # Protect text like ``--an-option`` and the regular expression
        # ``[+]?(\d+(\.\d*)?|\.\d+)`` from bad line wrapping
        for token in self.words_and_spaces.findall(text):
            if token.strip() and self.in_word_wrap_point.search(token):
                self.body.append('<span class="pre">%s</span>' % self.encode(token))
            else:
                self.body.append(self.encode(token))

    def depart_literal(self, node: nodes.Element) -> None:
        # skipped unless literal element is from "code" role:
        self.body.append("</code>")

    def visit_literal_block(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "pre", "", CLASS="literal-block"))
        if "code" in node["classes"]:
            self.body.append("<code>")

    def depart_literal_block(self, node: nodes.Element) -> None:
        if "code" in node["classes"]:
            self.body.append("</code>")
        self.body.append("</pre>\n")

    # Meta tags: 'lang' attribute replaced by 'xml:lang' in XHTML 1.1
    # HTML5/polyglot recommends using both
    def visit_meta(self, node: nodes.Element) -> None:
        self.meta.append(self.emptytag(node, "meta", **node.non_default_attributes()))

    def depart_meta(self, node: nodes.Element) -> None:
        pass

    def visit_option(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "span", "", CLASS="option"))

    def depart_option(self, node: nodes.Element) -> None:
        self.body.append("</span>")
        if isinstance(node.next_node(descend=False, siblings=True), nodes.option):
            self.body.append(", ")

    def visit_option_argument(self, node: nodes.Element) -> None:
        self.body.append(node.get("delimiter", " "))
        self.body.append(self.starttag(node, "var", ""))

    def depart_option_argument(self, node: nodes.Element) -> None:
        self.body.append("</var>")

    def visit_option_group(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "dt", ""))
        self.body.append("<kbd>")

    def depart_option_group(self, node: nodes.Element) -> None:
        self.body.append("</kbd></dt>\n")

    def visit_option_list(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "dl", CLASS="option-list"))

    def depart_option_list(self, node: nodes.Element) -> None:
        self.body.append("</dl>\n")

    def visit_option_list_item(self, node: nodes.Element) -> None:
        pass

    def depart_option_list_item(self, node: nodes.Element) -> None:
        pass

    def visit_option_string(self, node: nodes.Element) -> None:
        pass

    def depart_option_string(self, node: nodes.Element) -> None:
        pass

    # Do not omit <p> tags
    # --------------------
    #
    # The HTML4CSS1 writer does this to "produce visually compact lists (less vertical
    # whitespace)". This writer relies on CSS rules for visual compactness.
    #
    # * In XHTML 1.1, e.g., a <blockquote> element may not contain character data, so you
    #   cannot drop the <p> tags.
    # * Keeping simple paragraphs in the field_body enables a CSS rule to start the
    #   field-body on a new line if the label is too long
    # * it makes the code simpler.
    #
    # TODO: omit paragraph tags in simple table cells?

    def visit_paragraph(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "p", ""))

    def depart_paragraph(self, node: nodes.Element) -> None:
        self.body.append("</p>")
        if not (isinstance(node.parent, (nodes.list_item, nodes.entry))
                and (len(node.parent) == 1)):
            self.body.append("\n")
            self.report_messages(node)

    def visit_problematic(self, node: nodes.Element) -> None:
        if node.hasattr("refid"):
            self.body.append('<a href="#%s">' % node["refid"])
            self.context.append("</a>")
        else:
            self.context.append("")
        self.body.append(self.starttag(node, "span", "", CLASS="problematic"))

    def depart_problematic(self, node: nodes.Element) -> None:
        self.body.append("</span>")
        self.body.append(self.context.pop())

    def visit_raw(self, node: nodes.Element) -> None:
        if "html" in node.get("format", "").split():
            tagname = "span" if isinstance(node.parent, nodes.TextElement) else "div"
            if node["classes"]:
                self.body.append(self.starttag(node, tagname, suffix=""))
            self.body.append(node.astext())
            if node["classes"]:
                self.body.append("</%s>" % tagname)
        # Keep non-HTML raw text out of output:
        raise nodes.SkipNode

    def visit_reference(self, node: nodes.Element) -> None:
        atts = {"classes": ["reference"]}
        suffix = ""
        if "refuri" in node:
            atts["href"] = node["refuri"]
            if self.settings.cloak_email_addresses and atts["href"].startswith("mailto:"):
                atts["href"] = self.cloak_mailto(atts["href"])
                self.in_mailto = True
            atts["classes"].append("external")
        else:
            assert "refid" in node, 'References must have "refuri" or "refid" attribute.'
            atts["href"] = "#" + node["refid"]
            atts["classes"].append("internal")
        if len(node) == 1 and isinstance(node[0], nodes.image):
            atts["classes"].append("image-reference")
        if not isinstance(node.parent, nodes.TextElement):
            suffix = "\n"
        self.body.append(self.starttag(node, "a", suffix, **atts))

    def depart_reference(self, node: nodes.Element) -> None:
        self.body.append("</a>")
        if not isinstance(node.parent, nodes.TextElement):
            self.body.append("\n")
        self.in_mailto = False

    def visit_rubric(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "p", "", CLASS="rubric"))

    def depart_rubric(self, node: nodes.Element) -> None:
        self.body.append("</p>\n")

    def visit_section(self, node: nodes.Element) -> None:
        self.section_level += 1
        self.body.append(self.starttag(node, "div", CLASS="section"))

    def depart_section(self, node: nodes.Element) -> None:
        self.section_level -= 1
        self.body.append("</div>\n")

    # TODO: use the new HTML5 element <aside>
    def visit_sidebar(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "div", CLASS="sidebar"))
        self.in_sidebar = True

    def depart_sidebar(self, node: nodes.Element) -> None:
        self.body.append("</div>\n")
        self.in_sidebar = False

    def visit_strong(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "strong", ""))

    def depart_strong(self, node: nodes.Element) -> None:
        self.body.append("</strong>")

    def visit_subscript(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "sub", ""))

    def depart_subscript(self, node: nodes.Element) -> None:
        self.body.append("</sub>")

    def visit_substitution_definition(self, node: nodes.Element) -> None:
        """Internal only."""
        raise nodes.SkipNode

    def visit_substitution_reference(self, node: nodes.Element) -> None:
        self.unimplemented_visit(node)

    # h1–h6 elements must not be used to markup subheadings, subtitles, alternative titles
    # and taglines unless intended to be the heading for a new section or subsection.
    # -- http://www.w3.org/TR/html51/sections.html#headings-and-sections
    def visit_subtitle(self, node: nodes.Element) -> None:
        if isinstance(node.parent, nodes.sidebar):
            classes = ["sidebar-subtitle"]
        elif isinstance(node.parent, nodes.document):
            classes = ["subtitle"]
            self.in_document_title = len(self.body) + 1
        elif isinstance(node.parent, nodes.section):
            classes = ["section-subtitle"]
        self.body.append(self.starttag(node, "p", "", classes=classes))

    def depart_subtitle(self, node: nodes.Element) -> None:
        self.body.append("</p>\n")
        if isinstance(node.parent, nodes.document):
            self.subtitle = self.body[self.in_document_title:-1]
            self.in_document_title = 0
            self.body_pre_docinfo.extend(self.body)
            self.html_subtitle.extend(self.body)
            del self.body[:]

    def visit_superscript(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "sup", ""))

    def depart_superscript(self, node: nodes.Element) -> None:
        self.body.append("</sup>")

    def visit_system_message(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "aside", CLASS="system-message"))
        self.body.append('<p class="system-message-title">')
        self.body.append(self._system_message_title(
            node, '<span class="docutils literal">%s</span>'))

    def _system_message_title(self, node: nodes.Element, literal: str) -> str:
        # Return the text of the system message title ("literal" wraps the source).
        backref_text = ""
        backrefs = node["backrefs"]
        if len(backrefs) == 1:
            backref_text = '; <em><a href="#%s">backlink</a></em>' % backrefs[0]
        elif backrefs:
            backlinks = ['<a href="#%s">%s</a>' % (backref, i)
                         for i, backref in enumerate(backrefs, 1)]
            backref_text = "; <em>backlinks: %s</em>" % ", ".join(backlinks)
        line = ", line %s" % node["line"] if node.hasattr("line") else ""
        source = literal % self.encode(node["source"])
        return "System Message: %s/%s (%s%s)%s</p>\n" % (
            node["type"], node["level"], source, line, backref_text)

    def depart_system_message(self, node: nodes.Element) -> None:
        self.body.append("</aside>\n")

    def visit_target(self, node: nodes.Element) -> None:
        if "refuri" not in node and "refid" not in node and "refname" not in node:
            self.body.append(self.starttag(node, "span", "", CLASS="target"))
            self.context.append("</span>")
        else:
            self.context.append("")

    def depart_target(self, node: nodes.Element) -> None:
        self.body.append(self.context.pop())

    def visit_term(self, node: nodes.Element) -> None:
        if "details" in node.parent.parent["classes"]:
            self.body.append(self.starttag(node, "summary", suffix=""))
        else:
            # The parent node (definition_list_item) is omitted in HTML.
            self.body.append(self.starttag(node, "dt", suffix="",
                                           classes=node.parent["classes"],
                                           ids=node.parent["ids"]))

    def depart_term(self, node: nodes.Element) -> None:
        # Nest (optional) classifier(s) in the <dt> element
        if node.next_node(nodes.classifier, descend=False, siblings=True):
            return  # skip (depart_classifier() calls this function again)
        if "details" in node.parent.parent["classes"]:
            self.body.append("</summary>\n")
        else:
            self.body.append("</dt>\n")

    def section_title_tags(self, node: nodes.Element) -> tuple[str, str]:
        atts = {}
        h_level = self.section_level + self.initial_header_level - 1
        # Only 6 heading levels have dedicated HTML tags.
        tagname = "h%i" % min(h_level, 6)
        if h_level > 6:
            atts["aria-level"] = h_level
        start_tag = self.starttag(node, tagname, "", **atts)
        if node.hasattr("refid"):
            atts = {"class": "toc-backref",
                    "role": "doc-backlink",  # HTML5 only
                    "href": "#" + node["refid"]}
            start_tag += self.starttag(nodes.reference(), "a", "", **atts)
            close_tag = "</a></%s>\n" % tagname
        else:
            close_tag = "</%s>\n" % tagname
        return start_tag, close_tag

    def visit_title(self, node: nodes.Element) -> None:
        close_tag = "</p>\n"
        if isinstance(node.parent, nodes.topic):
            # TODO: use role="heading" or <h1>? (HTML5 only)
            self.body.append(self.starttag(node, "p", "", CLASS="topic-title"))
            if self.settings.toc_backlinks and "contents" in node.parent["classes"]:
                self.body.append('<a class="reference internal" href="#top">')
                close_tag = "</a></p>\n"
        elif isinstance(node.parent, nodes.sidebar):
            # TODO: use role="heading" or <h1>? (HTML5 only)
            self.body.append(self.starttag(node, "p", "", CLASS="sidebar-title"))
        elif isinstance(node.parent, nodes.Admonition):
            self.body.append(self.starttag(node, "p", "", CLASS="admonition-title"))
        elif isinstance(node.parent, nodes.table):
            self.body.append(self.starttag(node, "caption", ""))
            close_tag = "</caption>\n"
        elif isinstance(node.parent, nodes.document):
            self.body.append(self.starttag(node, "h1", "", CLASS="title"))
            close_tag = "</h1>\n"
            self.in_document_title = len(self.body)
        else:
            assert isinstance(node.parent, nodes.section)
            # Get correct heading and evt. backlink tags
            start_tag, close_tag = self.section_title_tags(node)
            self.body.append(start_tag)
        self.context.append(close_tag)

    def depart_title(self, node: nodes.Element) -> None:
        self.body.append(self.context.pop())
        if self.in_document_title:
            self.title = self.body[self.in_document_title:-1]
            self.in_document_title = 0
            self.body_pre_docinfo.extend(self.body)
            self.html_title.extend(self.body)
            del self.body[:]

    def visit_title_reference(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "cite", ""))

    def depart_title_reference(self, node: nodes.Element) -> None:
        self.body.append("</cite>")

    def visit_topic(self, node: nodes.Element) -> None:
        self.body.append(self.starttag(node, "div", CLASS="topic"))

    def depart_topic(self, node: nodes.Element) -> None:
        self.body.append("</div>\n")

    def visit_transition(self, node: nodes.Element) -> None:
        self.body.append(self.emptytag(node, "hr", CLASS="docutils"))

    def depart_transition(self, node: nodes.Element) -> None:
        pass

    def unimplemented_visit(self, node: nodes.Node) -> None:
        raise NotImplementedError("visiting unimplemented node type: %s"
                                  % node.__class__.__name__)


class SimpleListChecker(nodes.GenericNodeVisitor):
    """Raise `nodes.NodeFound` if non-simple list item is encountered.

    Here "simple" means a list item containing nothing other than a single paragraph, a simple
    list, or a paragraph followed by a simple list.

    This version also checks for simple field lists and docinfo.
    """

    def default_visit(self, node: nodes.Node) -> None:
        raise nodes.NodeFound

    def default_departure(self, node: nodes.Node) -> None:
        pass

    def visit_list_item(self, node: nodes.Element) -> None:
        children = [child for child in node.children
                    if not isinstance(child, nodes.Invisible)]
        if (children and isinstance(children[0], nodes.paragraph)
                and isinstance(children[-1], (nodes.bullet_list, nodes.enumerated_list,
                                              nodes.field_list))):
            children.pop()
        if len(children) > 1:
            raise nodes.NodeFound

    def pass_node(self, node: nodes.Node) -> None:
        pass

    def ignore_node(self, node: nodes.Node) -> None:
        # ignore nodes that are never complex (can contain only inline nodes)
        raise nodes.SkipNode

    # Paragraphs and text
    visit_Text = ignore_node
    visit_paragraph = ignore_node

    # Lists
    visit_bullet_list = pass_node
    visit_enumerated_list = pass_node
    visit_docinfo = pass_node

    # Docinfo nodes:
    visit_author = ignore_node
    visit_authors = visit_list_item
    visit_address = visit_list_item
    visit_contact = pass_node
    visit_copyright = ignore_node
    visit_date = ignore_node
    visit_organization = ignore_node
    visit_status = ignore_node
    visit_version = visit_list_item

    # Definition list:
    visit_definition_list = pass_node
    visit_definition_list_item = pass_node
    visit_term = ignore_node
    visit_classifier = pass_node
    visit_definition = visit_list_item

    # Field list:
    visit_field_list = pass_node
    visit_field = pass_node
    # the field body corresponds to a list item
    visit_field_body = visit_list_item
    visit_field_name = ignore_node

    # Invisible nodes should be ignored.
    visit_comment = ignore_node
    visit_substitution_definition = ignore_node
    visit_target = ignore_node
    visit_pending = ignore_node
