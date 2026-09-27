"""The LaTeX translator: document tree to LaTeX code."""

from __future__ import annotations

import re
import warnings
from pathlib import Path
from typing import Any

from docutils import languages, nodes, utils, writers
from docutils.writers.latex2e._babel import Babel
from docutils.writers.latex2e._charmaps import CharMaps
from docutils.writers.latex2e._preamble import PreambleCmds
from docutils.writers.latex2e._tables import DocumentClass, Table
from docutils.writers.latex2e._visit_body import _BodyVisitors
from docutils.writers.latex2e._visit_document import _DocumentVisitors
from docutils.writers.latex2e._visit_table import _TableVisitors

__docformat__ = "reStructuredText"

# Docutils' output-encoding => TeX input encoding
_LATEX_ENCODINGS = {
    "iso-8859-1": "latin1",     # west european
    "iso-8859-2": "latin2",     # east european
    "iso-8859-3": "latin3",     # esperanto, maltese
    "iso-8859-4": "latin4",     # north european
    "iso-8859-5": "iso88595",   # cyrillic (ISO)
    "iso-8859-9": "latin5",     # turkish
    "iso-8859-15": "latin9",    # latin9, update to latin1.
    "mac_cyrillic": "maccyr",   # cyrillic (on Mac)
    "windows-1251": "cp1251",   # cyrillic (on Windows)
    "koi8-r": "koi8-r",         # cyrillic (Russian)
    "koi8-u": "koi8-u",         # cyrillic (Ukrainian)
    "windows-1250": "cp1250",   #
    "windows-1252": "cp1252",   #
    "us-ascii": "ascii",        # ASCII (US)
    # unmatched encodings
    # "": "applemac",
    # "": "ansinew",  # windows 3.1 ansi
    # "": "ascii",    # ASCII encoding for the range 32--127.
    # "": "cp437",    # dos latin us
    # "": "cp850",    # dos latin 1
    # "": "cp852",    # dos latin 2
    # "": "decmulti",
    # "": "latin10",
    # "iso-8859-6": ""   # arabic
    # "iso-8859-7": ""   # greek
    # "iso-8859-8": ""   # hebrew
    # "iso-8859-10": ""  # latin6, more complete iso-8859-4
    }


class LaTeXTranslator(_DocumentVisitors, _TableVisitors, _BodyVisitors,
                      writers.DoctreeTranslator):
    """
    Generate code for 8-bit LaTeX from a Docutils document tree.

    See the docstring of docutils.writers._html_base.HTMLTranslator for
    notes on and examples of safe subclassing.
    """

    # When options are given to the documentclass, latex will pass them
    # to other packages, as done with babel.
    # Dummy settings might be taken from document settings

    # Generate code for typesetting with 8-bit latex/pdflatex vs.
    # xelatex/lualatex engine. Overwritten by the XeTeX writer
    is_xetex = False

    # Config setting defaults
    # -----------------------

    # Use compound enumerations (1.A.1.)
    compound_enumerators = False

    # If using compound enumerations, include section information.
    section_prefix_for_enumerators = False

    # This is the character that separates the section ("." subsection ...)
    # prefix from the regular list enumerator.
    section_enumerator_separator = "-"

    # Auxiliary variables
    # -------------------

    has_latex_toc = False  # is there a toc in the doc? (needed by minitoc)
    section_level = 0

    # Flags to encode():
    # inside citation reference labels underscores dont need to be escaped
    inside_citation_reference_label = False
    verbatim = False                    # do not encode
    insert_non_breaking_blanks = False  # replace blanks by "~"
    insert_newline = False              # add latex newline commands
    literal = False                     # literal text (block or inline)
    alltt = False                       # inside `alltt` environment

    # Nodes to be stored in the "titledata" part if "use_latex_docinfo" is true
    TITLEDATA_NODES = (nodes.address, nodes.author, nodes.authors,
                       nodes.contact, nodes.date, nodes.organization)

    attribution_formats = {"dash": ("—", ""),  # EM DASH
                           "parentheses": ("(", ")"),
                           "parens": ("(", ")"),
                           "none": ("", "")}

    _thead_depth = 0

    def __init__(self, document: nodes.document, babel_class: type = Babel) -> None:
        super().__init__(document)
        # Reporter
        self.warn = self.document.reporter.warning
        self.error = self.document.reporter.error
        # Settings
        self._check_deprecated_settings(self.settings)
        self._init_settings(self.settings, babel_class)
        # Output collection stacks
        self._init_parts(self.settings)
        # Process settings
        self._init_font_requirements()
        self._init_stylesheets(self.settings)
        self._init_hyperref(self.settings)

    def _check_deprecated_settings(self, settings: Any) -> None:
        # warn of deprecated settings and changing defaults:
        if settings.use_latex_citations is None and not settings.use_bibtex:
            settings.use_latex_citations = False
            warnings.warn('The default for the setting "use_latex_citations" '
                          'will change to "True" in Docutils 1.0.',
                          FutureWarning, stacklevel=8)
        if settings.legacy_column_widths is None:
            settings.legacy_column_widths = True
            warnings.warn('The default for the setting "legacy_column_widths" '
                          'will change to "False" in Docutils 1.0.)',
                          FutureWarning, stacklevel=8)
        if settings.use_verbatim_when_possible is not None:
            warnings.warn(
                'The configuration setting "use_verbatim_when_possible" '
                "will be removed in Docutils 2.0. "
                'Use "literal_block_env: verbatim".',
                FutureWarning, stacklevel=8)

    def _init_settings(self, settings: Any, babel_class: type) -> None:
        self.latex_encoding = self.to_latex_encoding(settings.output_encoding)
        self.use_latex_toc = settings.use_latex_toc
        self.use_latex_docinfo = settings.use_latex_docinfo
        self.use_latex_citations = settings.use_latex_citations
        self.reference_label = settings.reference_label
        self.hyperlink_color = settings.hyperlink_color
        self.compound_enumerators = settings.compound_enumerators
        self.font_encoding = getattr(settings, "font_encoding", "")
        self.section_prefix_for_enumerators = settings.section_prefix_for_enumerators
        self.section_enumerator_separator = (
            settings.section_enumerator_separator.replace("_", r"\_"))
        # literal blocks:
        self.literal_block_env = ""
        self.literal_block_options = ""
        if settings.literal_block_env:
            (_none,
             self.literal_block_env,
             self.literal_block_options,
             _none) = re.split(r"(\w+)(.*)", settings.literal_block_env)
        elif settings.use_verbatim_when_possible:
            self.literal_block_env = "verbatim"

        if settings.use_bibtex:
            self.use_latex_citations = True
        self.bibtex = settings.use_bibtex
        # language module for Docutils-generated text
        # (labels, bibliographic_fields, and author_separators)
        self.language_module = languages.get_language(settings.language_code,
                                                      self.document.reporter)
        self.babel = babel_class(settings.language_code, self.document.reporter)
        self.author_separator = self.language_module.author_separators[0]
        d_options = [settings.documentoptions]
        if self.babel.language not in ("english", ""):
            d_options.append(self.babel.language)
        self.documentoptions = ",".join(filter(None, d_options))
        self.d_class = DocumentClass(settings.documentclass,
                                     settings.use_part_section)
        # graphic package options:
        if settings.graphicx_option == "":
            self.graphicx_package = r"\usepackage{graphicx}"
        else:
            self.graphicx_package = r"\usepackage[%s]{graphicx}" % settings.graphicx_option
        # footnotes: TODO: implement LaTeX footnotes
        self.docutils_footnotes = settings.docutils_footnotes

    def _init_parts(self, settings: Any) -> None:
        # Document parts
        self.head_prefix = [f"\\documentclass[{self.documentoptions}]"
                            f"{{{settings.documentclass}}}"]
        self.requirements = {}  # converted to a list in depart_document()
        self.latex_preamble = [settings.latex_preamble]
        self.fallbacks = {}  # converted to a list in depart_document()
        self.pdfsetup = []  # PDF properties (hyperref package)
        self.title = []
        self.subtitle = []
        self.titledata = []  # \title, \author, \date
        self.body_pre_docinfo = []  # \maketitle
        self.docinfo = []
        self.dedication = []
        self.abstract = []
        self.body = []

        self.context = []
        """Heterogeneous stack.

        Used by visit_* and depart_* functions in conjunction with the tree
        traversal. Make sure that the pops correspond to the pushes."""

        # Title metadata:
        self.title_labels = []
        self.subtitle_labels = []
        # with "use_latex_docinfo", we also need
        self.author_stack = [[""]]  # first item reserved for author name
        self.date = []

        # PDF properties:
        self.pdfauthor = []
        self.pdfinfo = []
        if settings.language_code != "en":
            self.pdfinfo.append("  pdflang={%s}," % settings.language_code)

        # Stack of section counters so that we don't have to use_latex_toc.
        # This will grow and shrink as processing occurs.
        # Initialized for potential first-level sections.
        self._section_number = [0]

        # The current stack of enumerations so that we can expand
        # them into a compound enumeration.
        self._enumeration_counters = []
        # The maximum number of enumeration counters we've used.
        # If we go beyond this number, we need to create a new
        # counter; otherwise, just reuse an old one.
        self._max_enumeration_counters = 0

        self._bibitems = []

        # object for a table while processing.
        self.table_stack = []
        self.active_table = Table(self, "longtable")

        # Where to collect the output of visitor methods (default: body)
        self.out = self.body
        self.out_stack = []  # stack of output collectors

    def _init_font_requirements(self) -> None:
        # Encodings:
        # Docutils' output-encoding => TeX input encoding
        if self.latex_encoding not in ("ascii", "unicode", "utf8"):
            self.requirements["_inputenc"] = (r"\usepackage[%s]{inputenc}"
                                              % self.latex_encoding)
        # TeX font encoding
        if not self.is_xetex:
            if self.font_encoding:
                self.requirements["_fontenc"] = (r"\usepackage[%s]{fontenc}"
                                                 % self.font_encoding)
            # ensure \textquotedbl is defined:
            for enc in self.font_encoding.split(","):
                enc = enc.strip()
                if enc == "OT1":
                    self.requirements["_textquotedblOT1"] = (
                        r"\DeclareTextSymbol{\textquotedbl}{OT1}{`\"}")
                elif enc not in ("T1", "T2A", "T2B", "T2C", "T4", "T5"):
                    self.requirements["_textquotedbl"] = (
                        r"\DeclareTextSymbolDefault{\textquotedbl}{T1}")
        # page layout with typearea (if there are relevant document options)
        if (not self.settings.documentclass.startswith("scr")
            and ("DIV" in self.documentoptions
                 or "BCOR" in self.documentoptions)):
            self.requirements["typearea"] = r"\usepackage{typearea}"

    def _init_stylesheets(self, settings: Any) -> None:
        # Stylesheets
        # (the name `self.stylesheet` is singular because only one
        # stylesheet was supported before Docutils 0.6).
        stylesheet_list = utils.get_stylesheet_list(settings)
        self.fallback_stylesheet = "docutils" in stylesheet_list
        if self.fallback_stylesheet:
            stylesheet_list.remove("docutils")
            if settings.legacy_class_functions:
                # docutils.sty is incompatible with legacy functions
                self.fallback_stylesheet = False
            else:
                # require a minimal version:
                self.fallbacks["_docutils.sty"] = r"\usepackage{docutils}[2025-08-06]"

        self.stylesheet = [self.stylesheet_call(path) for path in stylesheet_list]

    def _init_hyperref(self, settings: Any) -> None:
        # PDF setup
        # avoid warnings about empty anchors with \DUfootnotetext:
        self.hyperref_options = ["hyperfootnotes=false"]
        # link color (default is "blue"):
        if self.hyperlink_color.lower() not in ("0", "off", "no", "false", ""):
            self.hyperref_options.append("colorlinks=true,"
                                         f"linkcolor={self.hyperlink_color},"
                                         f"urlcolor={self.hyperlink_color}")
        if settings.hyperref_options:
            self.hyperref_options.append(settings.hyperref_options)
        # wrap and align (cf. PreambleCmds.linking):
        self.hyperref_options = ",\n              ".join(self.hyperref_options)

    # Auxiliary Methods
    # -----------------

    def stylesheet_call(self, path: str | Path) -> str:
        """Return code to reference or embed stylesheet file `path`."""
        path = Path(path)
        # is it a package (no extension or *.sty) or "normal" tex code:
        is_package = path.suffix in (".sty", "")
        # Embed content of style file:
        if self.settings.embed_stylesheet:
            return self._embed_stylesheet(path, is_package)
        # Link to style file:
        if is_package:
            path = path.parent / path.stem  # drop extension
            cmd = r"\usepackage{%s}"
        else:
            cmd = r"\input{%s}"
        if self.settings.stylesheet_path:
            # adapt path relative to output (cf. config.html#stylesheet-path)
            return cmd % utils.relative_path(self.settings.output_path, path)
        return cmd % path.as_posix()

    def _embed_stylesheet(self, path: Path, is_package: bool) -> str:
        if is_package:
            path = path.with_suffix(".sty")  # ensure extension
        try:
            content = path.read_text(encoding="utf-8")
        except OSError as err:
            msg = f"Cannot embed stylesheet:\n {err}".replace("\\\\", "/")
            self.document.reporter.error(msg)
            return "% " + msg.replace("\n", "\n% ")
        else:
            self.settings.record_dependencies.add(path.as_posix())
        if is_package:
            # allow '@' in macro names:
            content = f"\\makeatletter\n{content}\n\\makeatother"
        return (f"% embedded stylesheet: {path.as_posix()}\n"
                f"{content}")

    def to_latex_encoding(self, docutils_encoding: str) -> str:
        """Translate docutils encoding name into LaTeX's.

        Default method is remove "-" and "_" chars from docutils_encoding.
        """
        encoding = docutils_encoding.lower()  # normalize case
        encoding = encoding.split(":")[0]     # strip the error handler
        if encoding in _LATEX_ENCODINGS:
            return _LATEX_ENCODINGS[encoding]
        # drop HYPHEN or LOW LINE from "latin_1", "utf-8" and similar
        return encoding.replace("_", "").replace("-", "")

    def language_label(self, docutil_label: str) -> str:
        return self.language_module.labels[docutil_label]

    def encode(self, text: str) -> str:
        """Return text with 'problematic' characters escaped.

        * Escape the special printing characters ``# $ % & ~ _ ^ \\ { }``,
          square brackets ``[ ]``, double quotes and (in OT1) ``< | >``.
        * Translate non-supported Unicode characters.
        * Separate ``-`` (and more in literal text) to prevent input ligatures.
        """
        if self.verbatim:
            return text
        text = text.translate(self._encoding_table(text))
        # Break up input ligatures e.g. '--' to '-{}-'.
        if not self.is_xetex:  # Not required with xetex/luatex
            separate_chars = "-"
            # In monospace-font, we also separate ',,', '``' and "''" and some
            # other characters which can't occur in non-literal text.
            if self.literal:
                separate_chars += ",`'\"<>"
            for char in separate_chars * 2:
                # Do it twice ("* 2") because otherwise we would replace
                # '---' by '-{}--'.
                text = text.replace(char + char, char + "{}" + char)
        # Literal line breaks (in address or literal blocks):
        if self.insert_newline:
            lines = text.split("\n")
            # Add a protected space to blank lines (except the last)
            # to avoid ``! LaTeX Error: There's no line here to end.``
            for i, line in enumerate(lines[:-1]):
                if not line.lstrip():
                    lines[i] += "~"
            text = (r"\\" + "\n").join(lines)
        if self.literal and not self.insert_non_breaking_blanks:
            # preserve runs of spaces but allow wrapping
            text = text.replace("  ", " ~")
        return text

    def _encoding_table(self, text: str) -> dict[int, str]:
        """Set up the translation table for `encode()`."""
        table = CharMaps.alltt.copy()
        if not self.alltt:
            table.update(CharMaps.special)
        # keep the underscore in citation references
        if self.inside_citation_reference_label and not self.alltt:
            del table[ord("_")]
        # Workarounds for OT1 font-encoding
        if self.font_encoding in ["OT1", ""] and not self.is_xetex:
            self._ot1_workarounds(table)
        if self.insert_non_breaking_blanks:
            table[ord(" ")] = "~"
            # tab chars may occur in included files (literal or code)
            # quick-and-dirty replacement with spaces
            # (for better results use `--literal-block-env=lstlisting`)
            table[ord("\t")] = "~" * self.settings.tab_width
        # Unicode replacements for 8-bit tex engines (not required with XeTeX)
        if not self.is_xetex:
            if not self.latex_encoding.startswith("utf8"):
                table.update(CharMaps.unsupported_unicode)
                table.update(CharMaps.utf8_supported_unicode)
                table.update(CharMaps.textcomp)
            table.update(CharMaps.pifont)
            self._require_character_support(text)
        return table

    def _ot1_workarounds(self, table: dict[int, str]) -> None:
        # * out-of-order characters in cmtt
        if self.literal:
            # replace underscore by underlined blank,
            # because this has correct width.
            table[ord("_")] = "\\underline{~}"
            # the backslash doesn't work, so we use a mirrored slash.
            # \reflectbox is provided by graphicx:
            self.requirements["graphicx"] = self.graphicx_package
            table[ord("\\")] = "\\reflectbox{/}"
        # * ``< | >`` come out as different chars (except for cmtt):
        else:
            table[ord("|")] = "\\textbar{}"
            table[ord("<")] = "\\textless{}"
            table[ord(">")] = "\\textgreater{}"

    def _require_character_support(self, text: str) -> None:
        # Characters that require a feature/package to render
        for ch in text:
            cp = ord(ch)
            if cp in CharMaps.textcomp and not self.fallback_stylesheet:
                self.requirements["textcomp"] = PreambleCmds.textcomp
            elif cp in CharMaps.pifont:
                self.requirements["pifont"] = "\\usepackage{pifont}"
            # preamble-definitions for unsupported Unicode characters
            elif (self.latex_encoding == "utf8"
                  and cp in CharMaps.unsupported_unicode):
                self.requirements["_inputenc"+str(cp)] = (
                    "\\DeclareUnicodeCharacter{%04X}{%s}"
                    % (cp, CharMaps.unsupported_unicode[cp]))

    def attval(self, text: str, whitespace: re.Pattern = re.compile("[\n\r\t\v\f]")) -> str:
        """Cleanse, encode, and return attribute value text."""
        return self.encode(whitespace.sub(" ", text))

    def is_inline(self, node: nodes.Node) -> bool:
        """Check whether a node represents an inline or block-level element"""
        return isinstance(node.parent, nodes.TextElement)

    def append_hypertargets(self, node: nodes.Element) -> None:
        """Append hypertargets for all ids of `node`"""
        # hypertarget places the anchor at the target's baseline,
        # so we raise it explicitly
        self.out.append("%\n".join("\\raisebox{1em}{\\hypertarget{%s}{}}" % id_
                                   for id_ in node["ids"]))

    def ids_to_labels(self, node: nodes.Element, set_anchor: bool = True,
                      protect: bool = False, newline: bool = False,
                      pre_nl: bool = False) -> list[str]:
        """Return label definitions for all ids of `node`.

        If `set_anchor` is True, an anchor is set with \\phantomsection.
        If `protect` is True, the \\label cmd is made robust.
        If `newline` is True, a newline is added if there are labels.
        If `pre_nl` is True, a newline is prepended if there are labels.

        Provisional.
        """
        prefix = "\\protect" if protect else ""
        labels = [f"{prefix}\\label{{{id_}}}" for id_ in node["ids"]]
        if labels:
            if set_anchor:
                labels.insert(0, "\\phantomsection")
            if newline:
                labels.append("\n")
            if pre_nl:
                labels.insert(0, "\n")
        return labels

    def set_align_from_classes(self, node: nodes.Element) -> None:
        """Convert ``align-*`` class arguments into alignment args."""
        # separate:
        align = [cls for cls in node["classes"] if cls.startswith("align-")]
        if align:
            node["align"] = align[-1].removeprefix("align-")
            node["classes"] = [cls for cls in node["classes"]
                               if not cls.startswith("align-")]

    def insert_align_declaration(self, node: nodes.Element, default: str | None = None) -> None:
        align = node.get("align", default)
        if align == "left":
            self.out.append("\\raggedright\n")
        elif align == "center":
            self.out.append("\\centering\n")
        elif align == "right":
            self.out.append("\\raggedleft\n")

    def provide_fallback(self, feature: str, key: str | None = None) -> None:
        if key is None:
            key = feature
        if self.fallback_stylesheet:
            return  # provided by the included style sheet
        self.fallbacks[key] = getattr(PreambleCmds, feature)

    def _is_table_style_class(self, node: nodes.Element, cls: str) -> bool:
        from docutils.writers.latex2e import Writer  # circular import

        return (isinstance(node, nodes.table)
                and cls in [*Writer.table_style_values, "colwidths-given"])

    def duclass_open(self, node: nodes.Element) -> None:
        """Open a group and insert declarations for class values."""
        if not isinstance(node.parent, nodes.compound):
            self.out.append("\n")
        for cls in node["classes"]:
            if cls.startswith("language-"):
                language = self.babel.language_name(cls[9:])
                if language:
                    self.babel.otherlanguages[language] = True
                    self.out.append("\\begin{selectlanguage}{%s}\n" % language)
            elif self._is_table_style_class(node, cls):
                pass
            else:
                self.provide_fallback("duclass", "DUclass")
                self.out.append("\\begin{DUclass}{%s}\n" % cls)

    def duclass_close(self, node: nodes.Element) -> None:
        """Close a group of class declarations."""
        for cls in reversed(node["classes"]):
            if cls.startswith("language-"):
                language = self.babel.language_name(cls[9:])
                if language:
                    self.out.append("\\end{selectlanguage}\n")
            elif self._is_table_style_class(node, cls):
                pass
            else:
                self.provide_fallback("duclass", "DUclass")
                self.out.append("\\end{DUclass}\n")

    def push_output_collector(self, new_out: list) -> None:
        self.out_stack.append(self.out)
        self.out = new_out

    def pop_output_collector(self) -> list:
        old_out = self.out
        self.out = self.out_stack.pop()
        return old_out

    def term_postfix(self, node: nodes.Element) -> str:
        """
        Return LaTeX code required between term or field name and content.

        In a LaTeX "description" environment (used for definition
        lists and non-docinfo field lists), a ``\\leavevmode``
        between an item's label and content ensures the correct
        placement of certain block constructs.
        """
        for child in node:
            if not isinstance(child, (nodes.Invisible, nodes.footnote,
                                      nodes.citation)):
                break
        else:
            return ""
        if isinstance(child, (nodes.container, nodes.compound)):
            return self.term_postfix(child)
        if isinstance(child, nodes.image):
            return "\\leavevmode\n"  # Images get an additional newline.
        if not isinstance(child, (nodes.paragraph, nodes.math_block)):
            return "\\leavevmode"
        return ""

    def to_latex_length(self, length_str: str, node: nodes.Node | None = None) -> str:
        """Convert "measure" `length_str` to LaTeX length specification.

        Note: the default length unit will change from "bp"
        (Postscript point) to "px" in Docutils 1.0.
        """
        value, unit = nodes.parse_measure(length_str)
        if unit in ("em", "ex", "cm", "mm", "in", "pc", "px",
                    "bp", "cc", "dd", "sp", "mu"):  # TeX unit == CSS unit
            return length_str
        if unit in ("", "pt"):  # no unit or "Postscript points"
            return f"{value}bp"  # LaTeX uses symbol "bp"
        if unit == "Q":
            return f"{value/4}mm"
        relative = {"%": "\\linewidth",   # percentage: relate to current line width
                    "vw": "\\paperwidth",  # viewport width: relate to page width
                    "vh": "\\paperheight"}  # viewport height: relate to page height
        if unit in relative:
            return f"{value/100:g}{relative[unit]}"
        # emulate with macro modelled on pdfLaTeX's \pdfpxdimen
        if not hasattr(PreambleCmds, unit):
            self.warn(f'Unit "{unit}" not supported by LaTeX.\n'
                      f'  Define lenght "\\DU{unit}dimen" in preamble,'
                      " raw LaTeX, or custom stylesheet.",
                      base_node=node)
        elif unit == "ch":
            self.fallbacks["ch"] = PreambleCmds.ch
        else:
            self.provide_fallback("providelength", "_providelength")
            self.provide_fallback(unit)
        return f"{value}\\DU{unit}dimen"

    def is_plaintext(self, node: nodes.Element) -> bool:
        """Check whether `node` contains only text"""
        return (len(node) == 1) and isinstance(node[0], nodes.Text)

    def has_unbalanced_braces(self, string: str) -> bool:
        """Test whether there are unmatched '{' or '}' characters."""
        level = 0
        for ch in string:
            if ch == "{":
                level += 1
            if ch == "}":
                level -= 1
            if level < 0:
                return True
        return level != 0

    def thead_depth(self) -> int:
        return self._thead_depth

    def unimplemented_visit(self, node: nodes.Node):
        raise NotImplementedError("visiting unimplemented node type: %s"
                                  % node.__class__.__name__)
