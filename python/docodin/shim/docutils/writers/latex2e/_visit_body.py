"""Visitor methods of the `LaTeXTranslator` for body and inline elements."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from docutils import nodes
from docutils.utils._roman_numerals import RomanNumeral
from docutils.utils.math import pick_math_environment, unichar2tex
from docutils.writers.latex2e._preamble import PreambleCmds

if TYPE_CHECKING:
    from docutils.writers.latex2e._babel import Babel
    from docutils.writers.latex2e._tables import Table

__docformat__ = "reStructuredText"

# enumeration styles:
_ENUM_TYPES = {"": "",
               "arabic": "arabic",
               "loweralpha": "alph",
               "upperalpha": "Alph",
               "lowerroman": "roman",
               "upperroman": "Roman"}
# default LaTeX enumeration labels:
_DEFAULT_ENUM_LABELS = [
    # (präfix, enumtype, suffix)
    ("",  "arabic", "."),  # 1.
    ("(", "alph",   ")"),  # (a)
    ("",  "roman",  "."),  # i.
    ("",  "Alph",   ".")]  # A.

_IMAGE_ALIGN_CODES = {
    # inline images: by default latex aligns the bottom.
    "bottom": ("", ""),
    "middle": (r"\raisebox{-0.5\height}{", "}"),
    "top":    (r"\raisebox{-\height}{", "}"),
    # block level images:
    "center": (r"\noindent\makebox[\linewidth][c]{", "}"),
    "left":   (r"\noindent{", r"\hfill}"),
    "right":  (r"\noindent{\hfill", "}"),
    }

_LITERAL_BLOCK_PACKAGES = {"lstlisting": "\\usepackage{listings}\n"
                                         "\\lstset{xleftmargin=\\leftmargin}",
                           "listing": r"\usepackage{moreverb}",
                           "Verbatim": r"\usepackage{fancyvrb}",
                           "verbatimtab": r"\usepackage{moreverb}",
                           }


class _BodyVisitors:
    """Visitor methods for body and inline elements (mixin for `LaTeXTranslator`)."""

    # attributes provided by `LaTeXTranslator`:
    out: list
    context: list
    requirements: dict
    fallbacks: dict
    settings: Any
    document: nodes.document
    babel: Babel
    active_table: Table

    def visit_Text(self, node: nodes.Text) -> None:  # noqa: N802 - docutils API name
        self.out.append(self.encode(node.astext()))

    def depart_Text(self, node: nodes.Text) -> None:  # noqa: N802 - docutils API name
        pass

    def visit_abbreviation(self, node: nodes.Element) -> None:
        node["classes"].insert(0, "abbreviation")
        self.visit_inline(node)

    def depart_abbreviation(self, node: nodes.Element) -> None:
        self.depart_inline(node)

    def visit_acronym(self, node: nodes.Element) -> None:
        node["classes"].insert(0, "acronym")
        self.visit_inline(node)

    def depart_acronym(self, node: nodes.Element) -> None:
        self.depart_inline(node)

    def visit_admonition(self, node: nodes.Element) -> None:
        # strip the generic 'admonition' from the list of classes
        node["classes"] = [cls for cls in node["classes"] if cls != "admonition"]
        if self.settings.legacy_class_functions:
            self.fallbacks["admonition"] = PreambleCmds.admonition_legacy
            if "error" in node["classes"]:
                self.fallbacks["error"] = PreambleCmds.error_legacy
            self.out.append("\n\\DUadmonition[%s]{" % ",".join(node["classes"]))
            return
        self.provide_fallback("admonition")
        if "error" in node["classes"]:
            self.provide_fallback("error")
        if not isinstance(node, nodes.system_message):
            self.out += self.ids_to_labels(node, pre_nl=True)
        self.duclass_open(node)
        self.out.append("\\begin{DUadmonition}")

    def depart_admonition(self, node: nodes.Element) -> None:
        if self.settings.legacy_class_functions:
            self.out.append("}\n")
            return
        self.out.append("\\end{DUadmonition}\n")
        self.duclass_close(node)

    def visit_block_quote(self, node: nodes.Element) -> None:
        self.out += self.ids_to_labels(node, pre_nl=True)
        self.duclass_open(node)
        self.out.append("\\begin{quote}")

    def depart_block_quote(self, node: nodes.Element) -> None:
        self.out.append("\\end{quote}\n")
        self.duclass_close(node)

    def visit_bullet_list(self, node: nodes.Element) -> None:
        self.out += self.ids_to_labels(node, pre_nl=True)
        self.duclass_open(node)
        self.out.append("\\begin{itemize}")

    def depart_bullet_list(self, node: nodes.Element) -> None:
        self.out.append("\\end{itemize}\n")
        self.duclass_close(node)

    def visit_superscript(self, node: nodes.Element) -> None:
        self.out.append(r"\textsuperscript{")
        self.visit_inline(node)

    def depart_superscript(self, node: nodes.Element) -> None:
        self.depart_inline(node)
        self.out.append("}")

    def visit_subscript(self, node: nodes.Element) -> None:
        self.out.append(r"\textsubscript{")
        self.visit_inline(node)

    def depart_subscript(self, node: nodes.Element) -> None:
        self.depart_inline(node)
        self.out.append("}")

    def visit_caption(self, node: nodes.Element) -> None:
        self.out.append("\\caption{")
        self.visit_inline(node)

    def depart_caption(self, node: nodes.Element) -> None:
        self.depart_inline(node)
        self.out.append("}\n")

    def visit_title_reference(self, node: nodes.Element) -> None:
        self.provide_fallback("titlereference")
        self.out.append(r"\DUroletitlereference{")
        self.visit_inline(node)

    def depart_title_reference(self, node: nodes.Element) -> None:
        self.depart_inline(node)
        self.out.append("}")

    def visit_citation(self, node: nodes.Element) -> None:
        if self.use_latex_citations:
            self.push_output_collector([])
        else:
            self.out.append(r"\begin{figure}[b]")
            self.append_hypertargets(node)

    def depart_citation(self, node: nodes.Element) -> None:
        if self.use_latex_citations:
            # TODO: normalize label
            label = self.out[0]
            text = "".join(self.out[1:])
            self._bibitems.append([label, text])
            self.pop_output_collector()
        else:
            self.out.append("\\end{figure}\n")

    def visit_citation_reference(self, node: nodes.Element) -> None:
        if self.bibtex:
            self._bibitems.append([node.astext()])
        if self.use_latex_citations:
            if not self.inside_citation_reference_label:
                self.out.append(r"\cite{")
                self.inside_citation_reference_label = True
            else:
                assert self.out[-1] in (" ", "\n"), \
                        "unexpected non-whitespace while in reference label"
                del self.out[-1]
        else:
            href = ""
            if "refid" in node:
                href = node["refid"]
            elif "refname" in node:
                href = self.document.nameids[node["refname"]]
            self.out.append("\\hyperlink{%s}{[" % href)

    def depart_citation_reference(self, node: nodes.Element) -> None:
        # TODO: normalize labels
        if self.use_latex_citations:
            followup_citation = False
            # check for a following citation separated by a space or newline
            sibling = node.next_node(descend=False, siblings=True)
            if isinstance(sibling, nodes.Text) and sibling.astext() in (" ", "\n"):
                sibling2 = sibling.next_node(descend=False, siblings=True)
                if isinstance(sibling2, nodes.citation_reference):
                    followup_citation = True
            if followup_citation:
                self.out.append(",")
            else:
                self.out.append("}")
                self.inside_citation_reference_label = False
        else:
            self.out.append("]}")

    def visit_classifier(self, node: nodes.Element) -> None:
        self.out.append("(\\textbf{")

    def depart_classifier(self, node: nodes.Element) -> None:
        self.out.append("})")
        if node.next_node(nodes.term, descend=False, siblings=True):
            self.out.append("\n")

    def visit_comment(self, node: nodes.Element):
        if not isinstance(node.parent, nodes.compound):
            self.out.append("\n")
        # Precede every line with a comment sign, wrap in newlines
        self.out.append("%% %s\n" % node.astext().replace("\n", "\n% "))
        raise nodes.SkipNode

    def depart_comment(self, node: nodes.Element) -> None:
        pass

    def visit_compound(self, node: nodes.Element) -> None:
        if isinstance(node.parent, nodes.compound):
            self.out.append("\n")
        self.out += self.ids_to_labels(node, pre_nl=True)
        node["classes"].insert(0, "compound")
        self.duclass_open(node)

    def depart_compound(self, node: nodes.Element) -> None:
        self.duclass_close(node)

    def visit_container(self, node: nodes.Element) -> None:
        self.out += self.ids_to_labels(node, pre_nl=True)
        self.duclass_open(node)

    def depart_container(self, node: nodes.Element) -> None:
        self.duclass_close(node)

    def visit_decoration(self, node: nodes.Element) -> None:
        # header and footer
        pass

    def depart_decoration(self, node: nodes.Element) -> None:
        pass

    def visit_definition(self, node: nodes.Element) -> None:
        pass

    def depart_definition(self, node: nodes.Element) -> None:
        pass

    def visit_definition_list(self, node: nodes.Element) -> None:
        self.out += self.ids_to_labels(node, pre_nl=True)
        self.duclass_open(node)
        self.out.append("\\begin{description}\n")

    def depart_definition_list(self, node: nodes.Element) -> None:
        self.out.append("\\end{description}\n")
        self.duclass_close(node)

    def visit_definition_list_item(self, node: nodes.Element) -> None:
        self.out += self.ids_to_labels(node, newline=True)

    def depart_definition_list_item(self, node: nodes.Element) -> None:
        if node.next_node(descend=False, siblings=True) is not None:
            self.out.append("\n")                # TODO: just pass?

    def visit_description(self, node: nodes.Element) -> None:
        self.out.append(" ")

    def depart_description(self, node: nodes.Element) -> None:
        pass

    def visit_doctest_block(self, node: nodes.Element) -> None:
        self.visit_literal_block(node)

    def depart_doctest_block(self, node: nodes.Element) -> None:
        self.depart_literal_block(node)

    def visit_emphasis(self, node: nodes.Element) -> None:
        self.out.append("\\emph{")
        self.visit_inline(node)

    def depart_emphasis(self, node: nodes.Element) -> None:
        self.depart_inline(node)
        self.out.append("}")

    def visit_enumerated_list(self, node: nodes.Element) -> None:
        prefix = self._enumeration_prefix(node)
        enumtype = _ENUM_TYPES[node.get("enumtype", "arabic")]
        suffix = node.get("suffix", ".")

        enum_level = len(self._enumeration_counters)+1
        counter_name = "enum" + RomanNumeral(enum_level).to_lowercase()
        label = r"%s\%s{%s}%s" % (prefix, enumtype, counter_name, suffix)
        self._enumeration_counters.append(label)

        self.out += self.ids_to_labels(node, pre_nl=True)
        self.duclass_open(node)
        if enum_level <= 4:
            self.out.append("\\begin{enumerate}")
            if (prefix, enumtype, suffix) != _DEFAULT_ENUM_LABELS[enum_level-1]:
                self.out.append("\n\\renewcommand{\\label%s}{%s}" % (counter_name, label))
        else:
            self.fallbacks[counter_name] = "\\newcounter{%s}" % counter_name
            self.out.append("\\begin{list}")
            self.out.append("{%s}" % label)
            self.out.append("{\\usecounter{%s}}" % counter_name)
        if "start" in node:
            self.out.append("\n\\setcounter{%s}{%d}" % (counter_name, node["start"]-1))

    def _enumeration_prefix(self, node: nodes.Element) -> str:
        prefix = ""
        if self.compound_enumerators:
            if (self.section_prefix_for_enumerators and self.section_level
                and not self._enumeration_counters):
                prefix = ".".join(str(n) for n in
                                  self._section_number[:self.section_level]
                                  ) + self.section_enumerator_separator
            if self._enumeration_counters:
                prefix += self._enumeration_counters[-1]
        return prefix + node.get("prefix", "")

    def depart_enumerated_list(self, node: nodes.Element) -> None:
        if len(self._enumeration_counters) <= 4:
            self.out.append("\\end{enumerate}\n")
        else:
            self.out.append("\\end{list}\n")
        self.duclass_close(node)
        self._enumeration_counters.pop()

    def visit_field(self, node: nodes.Element) -> None:
        self.out += self.ids_to_labels(node, pre_nl=True)
        # output is done in field_body, field_name

    def depart_field(self, node: nodes.Element) -> None:
        pass

    def visit_field_body(self, node: nodes.Element) -> None:
        if not isinstance(node.parent.parent, nodes.docinfo):
            self.out.append(self.term_postfix(node))

    def depart_field_body(self, node: nodes.Element) -> None:
        if self.out is self.docinfo:
            self.out.append(r"\\"+"\n")

    def visit_field_list(self, node: nodes.Element) -> None:
        self.out += self.ids_to_labels(node, pre_nl=True)
        self.duclass_open(node)
        if self.out is not self.docinfo:
            self.provide_fallback("fieldlist")
            self.out.append("\\begin{DUfieldlist}")

    def depart_field_list(self, node: nodes.Element) -> None:
        if self.out is not self.docinfo:
            self.out.append("\\end{DUfieldlist}\n")
        self.duclass_close(node)

    def visit_field_name(self, node: nodes.Element) -> None:
        if self.out is self.docinfo:
            self.out.append("\\textbf{")
        else:
            # Commands with optional args inside an optional arg must be put
            # in a group, e.g. ``\item[{\hyperref[label]{text}}]``.
            self.out.append("\n\\item[{")

    def depart_field_name(self, node: nodes.Element) -> None:
        if self.out is self.docinfo:
            self.out.append("}: &")
        else:
            self.out.append(":}]")

    def visit_figure(self, node: nodes.Element) -> None:
        self.requirements["float"] = PreambleCmds.float
        self.out += self.ids_to_labels(node, pre_nl=True)
        self.duclass_open(node)
        # The 'align' attribute sets the "outer alignment",
        # for "inner alignment" use LaTeX default alignment (similar to HTML)
        alignment = node.attributes.get("align", "center")
        if alignment != "center":
            # The LaTeX "figure" environment always uses the full linewidth,
            # so "outer alignment" is ignored. Just write a comment.
            # TODO: use the wrapfigure environment?
            self.out.append('\\begin{figure} %% align = "%s"' % alignment)
        else:
            self.out.append("\\begin{figure}")

    def depart_figure(self, node: nodes.Element) -> None:
        self.out.append("\\end{figure}\n")
        self.duclass_close(node)

    def visit_footer(self, node: nodes.Element) -> None:
        self.push_output_collector([])
        self.out.append(r"\newcommand{\DUfooter}{")

    def depart_footer(self, node: nodes.Element) -> None:
        self.out.append("}")
        self.requirements["~footer"] = "".join(self.out)
        self.pop_output_collector()

    def visit_footnote(self, node: nodes.Element) -> None:
        try:
            backref = node["backrefs"][0]
        except IndexError:
            backref = node["ids"][0]  # no backref, use self-ref instead
        if self.docutils_footnotes:
            self.provide_fallback("footnotes")
            num = node[0].astext()
            if self.settings.footnote_references == "brackets":
                num = "[%s]" % num
            self.out.append("%%\n\\DUfootnotetext{%s}{%s}{%s}{"
                            % (node["ids"][0], backref, self.encode(num)))
            # prevent spurious whitespace if footnote starts with paragraph:
            if len(node) > 1 and isinstance(node[1], nodes.paragraph):
                self.out.append("%")
        # TODO: "real" LaTeX \footnote{}s (see visit_footnotes_reference())

    def depart_footnote(self, node: nodes.Element) -> None:
        self.out.append("}\n")

    def visit_footnote_reference(self, node: nodes.Element) -> None:
        href = ""
        if "refid" in node:
            href = node["refid"]
        elif "refname" in node:
            href = self.document.nameids[node["refname"]]
        # TODO: insert footnote content at (or near) this place
        #       if not self.docutils_footnotes (see also docs/dev/todo.rst)
        if self.settings.footnote_references == "brackets":
            self.append_hypertargets(node)
            self.out.append("\\hyperlink{%s}{[" % href)
            self.context.append("]}")
        else:
            self.provide_fallback("footnotes")
            self.out.append(r"\DUfootnotemark{%s}{%s}{" % (node["ids"][0], href))
            self.context.append("}")

    def depart_footnote_reference(self, node: nodes.Element) -> None:
        self.out.append(self.context.pop())

    # footnote/citation label
    def label_delim(self, node: nodes.Element, bracket: str, superscript: str) -> None:
        if isinstance(node.parent, nodes.footnote):
            raise nodes.SkipNode
        else:
            assert isinstance(node.parent, nodes.citation)
            if not self.use_latex_citations:
                self.out.append(bracket)

    def visit_label(self, node: nodes.Element) -> None:
        """footnote or citation label: in brackets or as superscript"""
        self.label_delim(node, "[", "\\textsuperscript{")

    def depart_label(self, node: nodes.Element) -> None:
        self.label_delim(node, "]", "}")

    # elements generated by the framework e.g. section numbers.
    def visit_generated(self, node: nodes.Element) -> None:
        pass

    def depart_generated(self, node: nodes.Element) -> None:
        pass

    def visit_header(self, node: nodes.Element) -> None:
        self.push_output_collector([])
        self.out.append(r"\newcommand{\DUheader}{")

    def depart_header(self, node: nodes.Element) -> None:
        self.out.append("}")
        self.requirements["~header"] = "".join(self.out)
        self.pop_output_collector()

    def visit_image(self, node: nodes.Element) -> None:
        # <image> can be inline element, body element, or nested in a <figure>
        # in all three cases the <image> may also be nested in a <reference>
        # TODO: "classes" attribute currently ignored!
        self.requirements["graphicx"] = self.graphicx_package
        attrs = node.attributes
        # convert image URI to filesystem path, do not adjust relative path:
        imagepath = self.uri2path(attrs["uri"], output_path="")
        # alignment defaults:
        if "align" not in attrs:
            # Set default align of image in a figure to 'center'
            if (isinstance(node.parent, nodes.figure)
                or isinstance(node.parent, nodes.reference)
                    and isinstance(node.parent.parent, nodes.figure)):
                attrs["align"] = "center"
            self.set_align_from_classes(node)
        # pre- and postfix (prefix inserted in reverse order)
        pre = []
        post = []
        if isinstance(node.parent, nodes.reference):
            pre.append(self.out.pop())  # move \href behind alignment code
        if "align" in attrs and attrs["align"] in _IMAGE_ALIGN_CODES:
            # TODO: warn or ignore non-applicable alignment settings?
            align_code = _IMAGE_ALIGN_CODES[attrs["align"]]
            pre.append(align_code[0])
            post.append(align_code[1])
        options = self._include_graphics_options(node)
        pre.append("".join(self.ids_to_labels(node, newline=True)))
        if not (self.is_inline(node) or isinstance(node.parent, nodes.compound)):
            pre.append("\n")
        if not self.is_inline(node):
            post.append("\n")
        pre.reverse()
        # now insert image code
        self.out.extend(pre)
        if imagepath.suffix == ".svg" and "svg" in self.settings.stylesheet:
            cmd = "includesvg"
        else:
            cmd = "includegraphics"
        self.out.append(f"\\{cmd}{options}{{{imagepath.as_posix()}}}")
        self.out.extend(post)

    def _include_graphics_options(self, node: nodes.Element) -> str:
        """Return the optional argument of the \\includegraphics command."""
        attrs = node.attributes
        options = []
        if "height" in attrs:
            options.append(f"height={self.to_latex_length(attrs['height'], node)}")
        if "scale" in attrs:
            options.append(f"scale={attrs['scale']/100:g}")
        if "width" in attrs:
            options.append(f"width={self.to_latex_length(attrs['width'], node)}")
        if options:
            return f"[{','.join(options)}]"
        return ""

    def depart_image(self, node: nodes.Element) -> None:
        pass

    def visit_inline(self, node: nodes.Element) -> None:
        # This function is also called by the visiting functions for
        # specific inline elements, <caption>, and <paragraph>.

        # Handle "ids" attribute:
        # do we need a \phantomsection?
        anchor_nodes = (nodes.caption, nodes.subtitle, nodes.title)
        set_anchor = not (isinstance(node.parent, anchor_nodes)
                          or isinstance(node, anchor_nodes))
        add_newline = isinstance(node, nodes.paragraph)
        self.out += self.ids_to_labels(node, set_anchor, newline=add_newline)
        # Handle "classes" attribute:
        for cls in node["classes"]:
            if cls.startswith("language-"):
                language = self.babel.language_name(cls[9:])
                if language:
                    self.babel.otherlanguages[language] = True
                    self.out.append(r"\foreignlanguage{%s}{" % language)
            else:
                self.provide_fallback("inline")
                self.out.append(r"\DUrole{%s}{" % cls)

    def depart_inline(self, node: nodes.Element) -> None:
        self.out.append("}" * len(node["classes"]))

    def visit_legend(self, node: nodes.Element) -> None:
        self.provide_fallback("legend")
        self.out.append("\\begin{DUlegend}")

    def depart_legend(self, node: nodes.Element) -> None:
        self.out.append("\\end{DUlegend}\n")

    def visit_line(self, node: nodes.Element) -> None:
        self.out.append(r"\item[] ")

    def depart_line(self, node: nodes.Element) -> None:
        self.out.append("\n")

    def visit_line_block(self, node: nodes.Element) -> None:
        self.provide_fallback("providelength", "_providelength")
        self.provide_fallback("lineblock")
        self.set_align_from_classes(node)
        if isinstance(node.parent, nodes.line_block):
            self.out.append("\\item[]\n"
                            "\\begin{DUlineblock}{\\DUlineblockindent}\n")
            # In rST, nested line-blocks cannot be given class arguments
        else:
            self.out += self.ids_to_labels(node, pre_nl=True)
            self.duclass_open(node)
            self.out.append("\\begin{DUlineblock}{0em}\n")
            self.insert_align_declaration(node)

    def depart_line_block(self, node: nodes.Element) -> None:
        self.out.append("\\end{DUlineblock}\n")
        self.duclass_close(node)

    def visit_list_item(self, node: nodes.Element) -> None:
        self.out += self.ids_to_labels(node, pre_nl=True)
        self.out.append("\n\\item ")

    def depart_list_item(self, node: nodes.Element) -> None:
        pass

    def visit_literal(self, node: nodes.Element) -> None:
        self.literal = True
        if "code" in node["classes"] and self.settings.syntax_highlight != "none":
            self.requirements["color"] = PreambleCmds.color
            self.provide_fallback("highlight_rules", "code")
        self.out.append("\\texttt{")
        self.visit_inline(node)

    def depart_literal(self, node: nodes.Element) -> None:
        self.literal = False
        self.depart_inline(node)
        self.out.append("}")

    # <literal_block> elements are used
    # for literal blocks (where content is not parsed),
    # for the "code" directive (where content may be parsed by Pygments), and
    # for the "parsed-literal" directive (where rST inline markup is parsed).
    #
    # In all cases, we want to use a monospaced typeface.
    # If the <literal_block> contains only text, we can use a "verbatim-like"
    # environment, for mixed content we must use \ttfamily and \raggedright.
    #
    # We can distinguish between the use cases looking at the element's
    # children: if there is a single <Text> child, it is either
    # * a "real" literal block or
    # * a parsed-literal that does not contain any markup.

    def visit_literal_block(self, node: nodes.Element) -> None:
        """Render a literal block.

        Corresponding rST elements: literal block, parsed-literal, code.
        """
        # Check, if it is possible to use a literal-block environment
        plaintext = self.is_plaintext(node)
        in_table = self.active_table.is_open()
        # TODO: fails if normal text precedes the literal block.
        #       Check parent node instead?
        autowidth_table = in_table and self.active_table.colwidths_auto
        no_env_nodes = (nodes.footnote, nodes.sidebar)
        if self.settings.legacy_class_functions:
            no_env_nodes += (nodes.admonition, nodes.system_message)
        use_env = plaintext and not isinstance(node.parent, no_env_nodes)
        use_listings = (self.literal_block_env == "lstlisting") and use_env

        # Labels and classes:
        self.out += self.ids_to_labels(node, pre_nl=True)
        self.duclass_open(node)
        # Highlight code?
        if (not plaintext
            and "code" in node["classes"]
            and self.settings.syntax_highlight != "none"):
            self.requirements["color"] = PreambleCmds.color
            self.provide_fallback("highlight_rules", "code")
        # Wrap?
        if in_table and use_env and not autowidth_table:
            # Wrap in minipage to prevent extra vertical space
            # with alltt and verbatim-like environments:
            self.fallbacks["ttem"] = PreambleCmds.ttem
            self.out.append("\\begin{minipage}{%d\\ttemwidth}\n"
                            % (max(len(line) for line in node.astext().split("\n"))))
            self.context.append("\n\\end{minipage}\n")
        elif not in_table and not use_listings:
            # Wrap in quote to set off vertically and indent
            self.out.append("\\begin{quote}\n")
            self.context.append("\n\\end{quote}\n")
        else:
            self.context.append("\n")
        self._open_literal_block_env(in_table, use_env, autowidth_table, use_listings)

    def _open_literal_block_env(self, in_table: bool, use_env: bool,
                                autowidth_table: bool, use_listings: bool) -> None:
        # Use verbatim-like environment, if defined and possible
        # (in an auto-width table, only listings works):
        literal_env = self.literal_block_env
        if literal_env and use_env and (not autowidth_table or use_listings):
            if literal_env in _LITERAL_BLOCK_PACKAGES:
                self.requirements["literal_block"] = _LITERAL_BLOCK_PACKAGES[literal_env]
            self.verbatim = True
            if in_table and use_listings:
                self.out.append("\\lstset{xleftmargin=0pt}\n")
            self.out.append("\\begin{%s}%s\n" % (literal_env, self.literal_block_options))
            self.context.append("\n\\end{%s}" % literal_env)
        elif use_env and not autowidth_table:
            self.alltt = True
            self.requirements["alltt"] = r"\usepackage{alltt}"
            self.out.append("\\begin{alltt}\n")
            self.context.append("\n\\end{alltt}")
        else:
            self.literal = True
            self.insert_newline = True
            self.insert_non_breaking_blanks = True
            # \raggedright ensures leading blanks are respected but
            # leads to additional leading vspace if the first line
            # of the block is overfull :-(
            self.out.append("\\ttfamily\\raggedright\n")
            self.context.append("")

    def depart_literal_block(self, node: nodes.Element) -> None:
        self.insert_non_breaking_blanks = False
        self.insert_newline = False
        self.literal = False
        self.verbatim = False
        self.alltt = False
        self.out.append(self.context.pop())
        self.out.append(self.context.pop())
        self.duclass_close(node)

    def visit_meta(self, node: nodes.Element) -> None:
        if "name" not in node or "content" not in node:
            raise nodes.SkipNode  # HTML specific or empty metadata
        # TODO: Filter nodes with additional fields ("lang", "http-equiv", …)?
        #       They are HTML-specific and may override equally named keys.
        #       Only if name already present?  See also ODT writer.
        name = node["name"]
        content = self.encode(node["content"])
        if name in ("author", "keywords", "producer", "subject", "title"):
            # fields with dedicated hyperref options:
            self.pdfinfo.append("  pdf%s={%s}," % (name, content))
        elif name == "creator":
            self.pdfinfo.append("  addtopdfcreator={%s}," % content)
        else:
            # generic interface (case sensitive!)
            self.pdfinfo.append("  pdfinfo={%s={%s}}," % (name, content))

    def depart_meta(self, node: nodes.Element) -> None:
        pass

    def visit_math(self, node: nodes.Element, math_env: str = "$") -> None:
        """
        Provisional: the `math_env` argument will be dropped in Docutils 2.0.
        """
        self.requirements["amsmath"] = r"\usepackage{amsmath}"
        self.visit_inline(node)
        math_code = node.astext().translate(unichar2tex.uni2tex_table)
        if self.alltt:
            self.out += ["\\(", math_code, "\\)"]
        else:
            self.out += ["$", math_code, "$"]
        self.depart_inline(node)
        raise nodes.SkipNode  # content already processed

    def depart_math(self, node: nodes.Element) -> None:
        pass  # never reached

    def visit_math_block(self, node: nodes.Element) -> None:
        self.requirements["amsmath"] = r"\usepackage{amsmath}"
        math_env = pick_math_environment(node.astext())
        self.out.append("%\n")
        if node["ids"] and math_env.endswith("*"):  # non-numbered equation
            self.out.append("\\phantomsection\n")
        for cls in node["classes"]:
            self.provide_fallback("inline")
            self.out.append(f"\\DUrole{{{cls}}}{{%\n")
        self.out += [f"\\begin{{{math_env}}}\n",
                     node.astext().translate(unichar2tex.uni2tex_table),
                     "\n",
                     *self.ids_to_labels(node, set_anchor=False, newline=True),
                     f"\\end{{{math_env}}}"]
        if node["classes"]:
            self.out.append("\n" + "}" * len(node["classes"]))
        raise nodes.SkipNode  # content already processed

    def depart_math_block(self, node: nodes.Element) -> None:
        pass  # never reached

    def visit_option(self, node: nodes.Element) -> None:
        if self.context[-1]:
            # this is not the first option
            self.out.append(", ")

    def depart_option(self, node: nodes.Element) -> None:
        # flag that the first option is done.
        self.context[-1] += 1

    def visit_option_argument(self, node: nodes.Element) -> None:
        """Append the delimiter between an option and its argument to body."""
        self.out.append(node.get("delimiter", " "))

    def depart_option_argument(self, node: nodes.Element) -> None:
        pass

    def visit_option_group(self, node: nodes.Element) -> None:
        self.out.append("\\item[")
        # flag for first option
        self.context.append(0)

    def depart_option_group(self, node: nodes.Element) -> None:
        self.context.pop()  # the flag
        self.out.append("] ")

    def visit_option_list(self, node: nodes.Element) -> None:
        self.provide_fallback("providelength", "_providelength")
        self.provide_fallback("optionlist")
        self.out += self.ids_to_labels(node, pre_nl=True)
        self.duclass_open(node)
        self.out.append("\\begin{DUoptionlist}\n")

    def depart_option_list(self, node: nodes.Element) -> None:
        self.out.append("\\end{DUoptionlist}\n")
        self.duclass_close(node)

    def visit_option_list_item(self, node: nodes.Element) -> None:
        self.out += self.ids_to_labels(node, newline=True)

    def depart_option_list_item(self, node: nodes.Element) -> None:
        pass

    def visit_option_string(self, node: nodes.Element) -> None:
        pass

    def depart_option_string(self, node: nodes.Element) -> None:
        pass

    def visit_paragraph(self, node: nodes.Element) -> None:
        # insert blank line, unless
        # * the paragraph is first in a list item, compound, or container
        # * follows a non-paragraph node in a compound,
        # * is in a table with auto-width columns
        index = node.parent.index(node)
        if index == 0 and isinstance(node.parent,
                                     (nodes.list_item, nodes.description,
                                      nodes.compound, nodes.container)):
            pass
        elif (index > 0
              and isinstance(node.parent, nodes.compound)
              and not isinstance(node.parent[index - 1],
                                 (nodes.paragraph, nodes.compound))):
            pass
        elif self.active_table.colwidths_auto:
            if index == 1:  # second paragraph
                self.warn("LaTeX merges paragraphs in tables "
                          "with auto-sized columns!", base_node=node)
            if index > 0:
                self.out.append("\n")
        else:
            self.out.append("\n")
        self.visit_inline(node)

    def depart_paragraph(self, node: nodes.Element) -> None:
        self.depart_inline(node)
        if not self.active_table.colwidths_auto:
            self.out.append("\n")

    def visit_problematic(self, node: nodes.Element) -> None:
        self.requirements["color"] = PreambleCmds.color
        self.out.append("%\n")
        self.append_hypertargets(node)
        self.out.append(r"\hyperlink{%s}{\textbf{\color{red}" % node["refid"])

    def depart_problematic(self, node: nodes.Element) -> None:
        self.out.append("}}")

    def visit_raw(self, node: nodes.Element):
        if "latex" not in node.get("format", "").split():
            raise nodes.SkipNode
        if not (self.is_inline(node) or isinstance(node.parent, nodes.compound)):
            self.out.append("\n")
        self.visit_inline(node)
        # append "as-is" skipping any LaTeX-encoding
        self.verbatim = True

    def depart_raw(self, node: nodes.Element) -> None:
        self.verbatim = False
        self.depart_inline(node)
        if not self.is_inline(node):
            self.out.append("\n")

    def visit_reference(self, node: nodes.Element):
        # We need to escape #, \, and % if we use the URL in a command.
        special_chars = {ord("#"): "\\#",
                         ord("%"): "\\%",
                         ord("\\"): "\\\\",
                         }
        if not self.is_inline(node):
            self.out.append("\n")
        # external reference (URL)
        if "refuri" in node:
            href = str(node["refuri"]).translate(special_chars)
            # problematic chars double caret and unbalanced braces:
            if "^^" in href or self.has_unbalanced_braces(href):
                self.error(
                    f'External link "{href}" not supported by LaTeX.\n'
                    ' (Must not contain "^^" or unbalanced braces.)')
            if node["refuri"] == node.astext():
                self.out.append(r"\url{%s}" % href)
                raise nodes.SkipNode
            self.out.append(r"\href{%s}{" % href)
            return
        # internal reference
        if "refid" in node:
            href = node["refid"]
        elif "refname" in node:
            href = self.document.nameids[node["refname"]]
        else:
            raise AssertionError("Unknown reference.")
        if self.reference_label:
            self.out.append("\\%s{%s}" % (self.reference_label, href.replace("#", "")))
            raise nodes.SkipNode
        self.out.append("\\hyperref[%s]{" % href)

    def depart_reference(self, node: nodes.Element) -> None:
        self.out.append("}")
        if not self.is_inline(node):
            self.out.append("\n")

    def visit_rubric(self, node: nodes.Element) -> None:
        self.provide_fallback("rubric")
        # class wrapper would interfere with ``\section*"`` type commands
        # (spacing/indent of first paragraph)
        self.out += self.ids_to_labels(node, pre_nl=True)
        self.duclass_open(node)
        self.out.append("\\DUrubric{")

    def depart_rubric(self, node: nodes.Element) -> None:
        self.out.append("}\n")
        self.duclass_close(node)

    def visit_sidebar(self, node: nodes.Element) -> None:
        self.out += self.ids_to_labels(node, pre_nl=True)
        self.duclass_open(node)
        self.requirements["color"] = PreambleCmds.color
        self.provide_fallback("sidebar")
        self.out.append("\\DUsidebar{")

    def depart_sidebar(self, node: nodes.Element) -> None:
        self.out.append("}\n")
        self.duclass_close(node)

    def visit_attribution(self, node: nodes.Element) -> None:
        prefix, suffix = self.attribution_formats[self.settings.attribution]
        self.out.append("\\nopagebreak\n")
        self.out += self.ids_to_labels(node, pre_nl=True)
        self.duclass_open(node)
        self.out.append(f"\\raggedleft {prefix}")
        self.context.append(suffix)

    def depart_attribution(self, node: nodes.Element) -> None:
        self.out.append(self.context.pop() + "\n")
        self.duclass_close(node)

    def visit_strong(self, node: nodes.Element) -> None:
        self.out.append("\\textbf{")
        self.visit_inline(node)

    def depart_strong(self, node: nodes.Element) -> None:
        self.depart_inline(node)
        self.out.append("}")

    def visit_substitution_definition(self, node: nodes.Element):
        raise nodes.SkipNode

    def visit_substitution_reference(self, node: nodes.Element) -> None:
        self.unimplemented_visit(node)

    def visit_target(self, node: nodes.Element) -> None:
        # Skip indirect targets:
        if ("refuri" in node        # external hyperlink
            or "refid" in node      # resolved internal link
            or "refname" in node):  # unresolved internal link
            return
        if self.is_inline(node):
            self.out.append("%")
        self.out.append("\n")
        self.visit_inline(node)

    def depart_target(self, node: nodes.Element) -> None:
        self.depart_inline(node)

    def visit_term(self, node: nodes.Element) -> None:
        """definition list term"""
        # Commands with optional args inside an optional arg must be put
        # in a group, e.g. ``\item[{\hyperref[label]{text}}]``.
        self.out.append("\\item[{")

    def depart_term(self, node: nodes.Element) -> None:
        self.out.append("}] ")
        # Do we need a \leavevmode (line break if the field body begins
        # with a list or environment)?
        next_node = node.next_node(descend=False, siblings=True)
        if isinstance(next_node, nodes.term):
            self.out.append("\n")
        elif not isinstance(next_node, nodes.classifier):
            self.out.append(self.term_postfix(next_node))

    def visit_transition(self, node: nodes.Element) -> None:
        self.provide_fallback("transition")
        self.out.append("\n%" + "_" * 75 + "\n")
        self.out.append("\\DUtransition\n")

    def depart_transition(self, node: nodes.Element) -> None:
        pass
