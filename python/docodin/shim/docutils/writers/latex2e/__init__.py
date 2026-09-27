"""LaTeX2e document tree Writer."""

# code contributions from several people included, thanks to all.
# some named: David Abrahams, Julien Letessier, Lele Gaifax, and others.
#
# The implementation is split into private submodules:
#
# * `_babel`: language specifics (`Babel`),
# * `_preamble`: building blocks for the LaTeX preamble (`PreambleCmds`),
# * `_charmaps`: LaTeX representations of special characters (`CharMaps`),
# * `_tables`: `DocumentClass` and `Table` helpers,
# * `_translator` and the `_visit_*` mixins: the `LaTeXTranslator`.

from __future__ import annotations

import re  # noqa: F401 - part of the module namespace
import string
import warnings  # noqa: F401 - part of the module namespace
from pathlib import Path

from docutils import frontend, languages, nodes, utils, writers  # noqa: F401
from docutils.transforms import references, writer_aux
from docutils.utils._roman_numerals import RomanNumeral  # noqa: F401
from docutils.utils.math import pick_math_environment, unichar2tex  # noqa: F401
from docutils.writers.latex2e._babel import Babel as Babel
from docutils.writers.latex2e._charmaps import CharMaps as CharMaps
from docutils.writers.latex2e._preamble import LATEX_WRITER_DIR
from docutils.writers.latex2e._preamble import PreambleCmds as PreambleCmds
from docutils.writers.latex2e._preamble import SortableDict as SortableDict
from docutils.writers.latex2e._preamble import _read_block as _read_block
from docutils.writers.latex2e._tables import DocumentClass as DocumentClass
from docutils.writers.latex2e._tables import Table as Table
from docutils.writers.latex2e._translator import LaTeXTranslator

__docformat__ = "reStructuredText"


class Writer(writers.Writer):

    supported = ("latex", "latex2e")
    """Formats this writer supports."""

    default_template = "default.tex"
    default_template_path = LATEX_WRITER_DIR
    default_preamble = ("% PDF Standard Fonts\n"
                        "\\usepackage{mathptmx} % Times\n"
                        "\\usepackage[scaled=.90]{helvet}\n"
                        "\\usepackage{courier}")
    table_style_values = [  # TODO: align-left, align-center, align-right, ??
                          "booktabs", "borderless", "colwidths-auto",
                          "nolines", "standard"]

    settings_spec = (
        "LaTeX-Specific Options",
        None,
        (('Specify LaTeX documentclass.  Default: "article".',
          ["--documentclass"],
          {"metavar": "<documentclass>", "default": "article"}),
         ("Specify document options.  Multiple options can be given, "
          'separated by commas.  Default: "a4paper".',
          ["--documentoptions"],
          {"metavar": "<options>", "default": "a4paper"}),
         ('Format for footnote references: one of "superscript" or '
          '"brackets".  Default: "superscript".',
          ["--footnote-references"],
          {"choices": ["superscript", "brackets"], "default": "superscript",
           "metavar": "<format>",
           "overrides": "trim_footnote_reference_space"}),
         ("Use \\cite command for citations. (future default)",
          ["--use-latex-citations"],
          {"default": None, "action": "store_true",
           "validator": frontend.validate_boolean}),
         ("Use figure floats for citations "
          "(might get mixed with real figures). (provisional default)",
          ["--figure-citations"],
          {"dest": "use_latex_citations", "action": "store_false",
           "validator": frontend.validate_boolean}),
         ('Format for block quote attributions: one of "dash" (em-dash '
          'prefix), "parentheses"/"parens", or "none".  Default: "dash".',
          ["--attribution"],
          {"choices": ["dash", "parentheses", "parens", "none"],
           "default": "dash", "metavar": "<format>"}),
         ("Specify LaTeX packages/stylesheets. "
          'A style is referenced with "\\usepackage" if extension is '
          '".sty" or omitted and with "\\input" else. '
          " Overrides previous --stylesheet and --stylesheet-path settings.",
          ["--stylesheet"],
          {"default": "", "metavar": "<file[,file,...]>",
           "overrides": "stylesheet_path",
           "validator": frontend.validate_comma_separated_list}),
         ("Comma separated list of LaTeX packages/stylesheets. "
          "Relative paths are expanded if a matching file is found in "
          "the --stylesheet-dirs. With --link-stylesheet, "
          "the path is rewritten relative to the output *.tex file. ",
          ["--stylesheet-path"],
          {"metavar": "<file[,file,...]>", "overrides": "stylesheet",
           "validator": frontend.validate_comma_separated_list}),
         ("Link to the stylesheet(s) in the output file. (default)",
          ["--link-stylesheet"],
          {"dest": "embed_stylesheet", "action": "store_false"}),
         ("Embed the stylesheet(s) in the output file. "
          "Stylesheets must be accessible during processing. ",
          ["--embed-stylesheet"],
          {"default": False, "action": "store_true",
           "validator": frontend.validate_boolean}),
         ("Comma-separated list of directories where stylesheets are found. "
          "Used by --stylesheet-path when expanding relative path arguments. "
          'Default: ".".',
          ["--stylesheet-dirs"],
          {"metavar": "<dir[,dir,...]>",
           "validator": frontend.validate_comma_separated_list,
           "default": ["."]}),
         ("Customization by LaTeX code in the preamble. "
          "Default: select PDF standard fonts (Times, Helvetica, Courier).",
          ["--latex-preamble"],
          {"metavar": "<preamble>", "default": default_preamble}),
         ('Specify the template file. Default: "%s".' % default_template,
          ["--template"],
          {"default": default_template, "metavar": "<file>"}),
         ("Table of contents by LaTeX. (default)",
          ["--use-latex-toc"],
          {"default": True, "action": "store_true",
           "validator": frontend.validate_boolean}),
         ("Table of contents by Docutils (without page numbers).",
          ["--use-docutils-toc"],
          {"dest": "use_latex_toc", "action": "store_false",
           "validator": frontend.validate_boolean}),
         ("Add parts on top of the section hierarchy.",
          ["--use-part-section"],
          {"default": False, "action": "store_true",
           "validator": frontend.validate_boolean}),
         ("Attach author and date to the document info table. (default)",
          ["--use-docutils-docinfo"],
          {"dest": "use_latex_docinfo", "action": "store_false",
           "validator": frontend.validate_boolean}),
         ("Attach author and date to the document title.",
          ["--use-latex-docinfo"],
          {"default": False, "action": "store_true",
           "validator": frontend.validate_boolean}),
         ("Typeset abstract as topic. (default)",
          ["--topic-abstract"],
          {"dest": "use_latex_abstract", "action": "store_false",
           "validator": frontend.validate_boolean}),
         ("Use LaTeX abstract environment for the document's abstract.",
          ["--use-latex-abstract"],
          {"default": False, "action": "store_true",
           "validator": frontend.validate_boolean}),
         ("Color of any hyperlinks embedded in text. "
          'Default: "blue" (use "false" to disable).',
          ["--hyperlink-color"],
          {"metavar": "<color>", "default": "blue"}),
         ('Additional options to the "hyperref" package.',
          ["--hyperref-options"],
          {"metavar": "<options>", "default": ""}),
         ("Enable compound enumerators for nested enumerated lists "
          '(e.g. "1.2.a.ii").',
          ["--compound-enumerators"],
          {"default": False, "action": "store_true",
           "validator": frontend.validate_boolean}),
         ("Disable compound enumerators for nested enumerated lists. "
          "(default)",
          ["--no-compound-enumerators"],
          {"action": "store_false", "dest": "compound_enumerators"}),
         ('Enable section ("." subsection ...) prefixes for compound '
          "enumerators.  This has no effect without --compound-enumerators.",
          ["--section-prefix-for-enumerators"],
          {"default": None, "action": "store_true",
           "validator": frontend.validate_boolean}),
         ("Disable section prefixes for compound enumerators. (default)",
          ["--no-section-prefix-for-enumerators"],
          {"action": "store_false", "dest": "section_prefix_for_enumerators"}),
         ("Set the separator between section number and enumerator "
          'for compound enumerated lists.  Default: "-".',
          ["--section-enumerator-separator"],
          {"default": "-", "metavar": "<char>"}),
         ("When possible, use the specified environment for literal-blocks. "
          'Default: "" (fall back to "alltt").',
          ["--literal-block-env"],
          {"metavar": "<environment>", "default": ""}),
         (frontend.SUPPRESS_HELP,  # deprecated legacy option
          ["--use-verbatim-when-possible"],
          {"action": "store_true",
           "validator": frontend.validate_boolean}),
         ('Table style. "standard" with horizontal and vertical lines, '
          '"booktabs" (LaTeX booktabs style) only horizontal lines '
          'above and below the table and below the header, or "borderless". '
          'Default: "standard"',
          ["--table-style"],
          {"default": ["standard"],
           "metavar": "<format>",
           "action": "append",
           "validator": frontend.validate_comma_separated_list,
           "choices": table_style_values}),
         ('LaTeX graphicx package option. Default: "".',
          ["--graphicx-option"],
          {"metavar": "<option>", "default": ""}),
         ("LaTeX font encoding. "
          'Possible values are "", "T1" (default), "OT1", "LGR,T1" or '
          "any other combination of options to the `fontenc` package. ",
          ["--font-encoding"],
          {"metavar": "<encoding>", "default": "T1"}),
         ("Per default the latex-writer puts the reference title into "
          'hyperreferences. Specify "ref" or "pageref" to get the section '
          "number or the page number.",
          ["--reference-label"],
          {"metavar": "<command name>", "default": ""}),
         ("Specify style and database(s) for bibtex, for example "
          '"--use-bibtex=unsrt,mydb1,mydb2". Provisional!',
          ["--use-bibtex"],
          {"default": "",
           "metavar": "<style,bibfile[,bibfile,...]>",
           "validator": frontend.validate_comma_separated_list}),
         ("Use legacy functions with class value list for "
          "\\DUtitle and \\DUadmonition.",
          ["--legacy-class-functions"],
          {"default": False,
           "action": "store_true",
           "validator": frontend.validate_boolean}),
         ('Use \\DUrole and "DUclass" wrappers for class values. '
          "Place admonition content in an environment. (default)",
          ["--new-class-functions"],
          {"dest": "legacy_class_functions",
           "action": "store_false",
           "validator": frontend.validate_boolean}),
         ("Use legacy algorithm to determine table column widths. "
          "(provisional default)",
          ["--legacy-column-widths"],
          {"default": None,
           "action": "store_true",
           "validator": frontend.validate_boolean}),
         ("Use new algorithm to determine table column widths. "
          "(future default)",
          ["--new-column-widths"],
          {"dest": "legacy_column_widths",
           "action": "store_false",
           "validator": frontend.validate_boolean}),
         # TODO: implement "latex footnotes" alternative
         ("Footnotes with numbers/symbols by Docutils. (default) "
          "(The alternative, --latex-footnotes, is not implemented yet.)",
          ["--docutils-footnotes"],
          {"default": True,
           "action": "store_true",
           "validator": frontend.validate_boolean}),
         ),
        )

    relative_path_settings = ("template",)
    settings_defaults = {}
    config_section = "latex2e writer"
    config_section_dependencies = ("writers", "latex writers")

    head_parts = ("head_prefix", "requirements", "latex_preamble",
                  "stylesheet", "fallbacks", "pdfsetup", "titledata")
    visitor_attributes = head_parts + ("title", "subtitle",
                                       "body_pre_docinfo", "docinfo",
                                       "dedication", "abstract", "body")

    output = None
    """Final translated form of `document`."""

    def __init__(self) -> None:
        writers.Writer.__init__(self)
        self.translator_class = LaTeXTranslator

    def get_transforms(self):
        # Override parent method to add latex-specific transforms
        return [*super().get_transforms(),
                # Convert specific admonitions to generic one
                writer_aux.Admonitions,
                references.CitationReferences]

    def translate(self) -> None:
        visitor = self.translator_class(self.document)
        self.document.walkabout(visitor)
        # copy parts
        for part in self.visitor_attributes:
            setattr(self, part, getattr(visitor, part))
        # fill template
        self.assemble_parts()  # create dictionary of parts
        self.output = string.Template(self.parts["template"]).substitute(self.parts)

    def assemble_parts(self) -> None:
        """Assemble the `self.parts` dictionary of output fragments."""
        super().assemble_parts()
        for part in self.visitor_attributes:
            if part in self.parts:
                continue  # make the function idempotent
            lines = getattr(self, part)
            if part in self.head_parts:
                if lines:
                    lines.append("")  # to get a trailing newline
                self.parts[part] = "\n".join(lines)
            else:
                # body contains inline elements, so join without newline
                self.parts[part] = "".join(lines)
        # get template string from file
        templatepath = Path(self.document.settings.template)
        if not templatepath.exists():
            templatepath = self.default_template_path / templatepath.name
        self.parts["template"] = templatepath.read_text(encoding="utf-8")
