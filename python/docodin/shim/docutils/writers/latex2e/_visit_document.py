"""Visitor methods of the `LaTeXTranslator` for document structure and bibliographic data."""

from __future__ import annotations

import warnings
from typing import TYPE_CHECKING, Any

from docutils import nodes
from docutils.utils._roman_numerals import RomanNumeral
from docutils.writers.latex2e._preamble import PreambleCmds

if TYPE_CHECKING:
    from docutils.writers.latex2e._babel import Babel
    from docutils.writers.latex2e._tables import DocumentClass, Table

__docformat__ = "reStructuredText"


class _DocumentVisitors:
    """Visitor methods for the document, sections, titles, topics, and docinfo.

    Mixin class for `LaTeXTranslator`.
    """

    # attributes provided by `LaTeXTranslator`:
    out: list
    context: list
    requirements: dict
    fallbacks: dict
    settings: Any
    document: nodes.document
    babel: Babel
    d_class: DocumentClass
    active_table: Table

    def visit_address(self, node: nodes.Element) -> None:
        self.insert_newline = True  # preserve newlines
        self.visit_docinfo_item(node)

    def depart_address(self, node: nodes.Element) -> None:
        self.depart_docinfo_item(node)
        self.insert_newline = False

    def visit_author(self, node: nodes.Element) -> None:
        self.pdfauthor.append(self.attval(node.astext()))
        if isinstance(node.parent, nodes.authors):
            # ensure output is one item per <author> element (see depart…)
            self.push_output_collector([])
        else:
            self.visit_docinfo_item(node)

    def depart_author(self, node: nodes.Element) -> None:
        if isinstance(node.parent, nodes.authors):
            author_name = self.pop_output_collector()
            self.out.append("".join(author_name))
        else:
            self.depart_docinfo_item(node)

    def visit_authors(self, node: nodes.Element) -> None:
        self.visit_docinfo_item(node)

    def depart_authors(self, node: nodes.Element) -> None:
        self.depart_docinfo_item(node)

    def visit_contact(self, node: nodes.Element) -> None:
        self.visit_docinfo_item(node)

    def depart_contact(self, node: nodes.Element) -> None:
        self.depart_docinfo_item(node)

    def visit_copyright(self, node: nodes.Element) -> None:
        self.visit_docinfo_item(node)

    def depart_copyright(self, node: nodes.Element) -> None:
        self.depart_docinfo_item(node)

    def visit_date(self, node: nodes.Element) -> None:
        self.visit_docinfo_item(node)

    def depart_date(self, node: nodes.Element) -> None:
        self.depart_docinfo_item(node)

    def visit_organization(self, node: nodes.Element) -> None:
        self.visit_docinfo_item(node)

    def depart_organization(self, node: nodes.Element) -> None:
        self.depart_docinfo_item(node)

    def visit_revision(self, node: nodes.Element) -> None:
        self.visit_docinfo_item(node)

    def depart_revision(self, node: nodes.Element) -> None:
        self.depart_docinfo_item(node)

    def visit_status(self, node: nodes.Element) -> None:
        self.visit_docinfo_item(node)

    def depart_status(self, node: nodes.Element) -> None:
        self.depart_docinfo_item(node)

    def visit_version(self, node: nodes.Element) -> None:
        self.visit_docinfo_item(node)

    def depart_version(self, node: nodes.Element) -> None:
        self.depart_docinfo_item(node)

    def visit_docinfo(self, node: nodes.Element) -> None:
        self.push_output_collector(self.docinfo)

    def depart_docinfo(self, node: nodes.Element) -> None:
        self.pop_output_collector()
        # Some itmes (e.g. author) end up at other places
        if self.docinfo:
            # tabularx: automatic width of columns, no page breaks allowed.
            self.requirements["tabularx"] = r"\usepackage{tabularx}"
            self.provide_fallback("providelength", "_providelength")
            self.provide_fallback("docinfo")
            #
            self.docinfo.insert(0, "\n% Docinfo\n"
                                "\\begin{center}\n"
                                "\\begin{tabularx}{\\DUdocinfowidth}{lX}\n")
            self.docinfo.append("\\end{tabularx}\n"
                                "\\end{center}\n")

    def visit_docinfo_item(self, node: nodes.Element, name: str | None = None) -> None:
        # auxiliary method, called by the visitors of "bibliographic elements"
        if name is not None:
            warnings.warn('visit_docinfo_item(): argument "name" is obsolete'
                          " and will be removed in Docutils 0.24",
                          DeprecationWarning, stacklevel=2)
        if self.use_latex_docinfo and isinstance(node, self.TITLEDATA_NODES):
            self.push_output_collector([])  # see depart_docinfo_item()
        else:
            label = self.language_label(node.tagname)
            self.out.append("\\textbf{%s}: &" % label)
            if isinstance(node, nodes.address):
                self.out.append(" {\\raggedright\n")
            elif len(label) + len(node.astext()) > 64:
                self.out.append("\n  ")
            else:
                self.out.append(" ")
            if isinstance(node, nodes.authors):
                self.push_output_collector([])  # collect author names

    def depart_docinfo_item(self, node: nodes.Element) -> None:
        if self.use_latex_docinfo and isinstance(node, self.TITLEDATA_NODES):
            self._store_titledata(node)
        else:
            if isinstance(node, nodes.address):
                self.out.append("}")
            elif isinstance(node, nodes.authors):
                author_names = self.pop_output_collector()
                # get last "author separator" that is not in any author name
                for sep in reversed(self.language_module.author_separators):
                    if not any(sep in name for name in author_names):
                        break
                self.out.append((sep+" ").join(author_names))
            self.out.append(" \\\\\n")

    def _store_titledata(self, node: nodes.Element) -> None:
        # Prepare data for use in `self.make_title()`
        if isinstance(node, nodes.authors):
            # join author names with "\and" or,
            # if there is shared author info, with "\quad"
            # (cf. https://tex.stackexchange.com/a/11656/288060)
            s = r" \and "
            for nn in node.findall(include_self=False, descend=False, siblings=True):
                if isinstance(nn, (nodes.author, nodes.authors)):
                    break
                if isinstance(nn, (nodes.address, nodes.contact, nodes.organization)):
                    s = r" \quad "
        else:
            s = ""
        text = s.join(self.pop_output_collector())

        if isinstance(node, nodes.date):
            self.date.append(text)
        elif isinstance(node, (nodes.author, nodes.authors)):
            # Insert author name(s) as first item of an "author info" list,
            # starting a new list if author name already set:
            if self.author_stack[-1][0]:
                self.author_stack.append([text])
            else:
                self.author_stack[-1][0] = text
        else:
            # Append affiliation & contact info to current "author info".
            self.author_stack[-1].append(text)

    def visit_document(self, node: nodes.Element) -> None:
        # titled document?
        if self.use_latex_docinfo or isinstance(node.next_node(), nodes.title):
            protect = (self.settings.documentclass == "memoir")
            self.title_labels += self.ids_to_labels(node, set_anchor=False,
                                                    protect=protect)

    def depart_document(self, node: nodes.Element) -> None:
        # Complete "parts" with information gained from walkabout
        # * language setup
        if self.babel.otherlanguages or self.babel.language not in ("", "english"):
            self.requirements["babel"] = self.babel()
        # * PDF properties
        self._complete_pdfsetup()
        # * title (including author(s) and date if using "latex_docinfo")
        if self.title or self.date or self.author_stack != [[""]]:
            self.make_title()  # see below
        # * bibliography
        if self._bibitems:
            self.append_bibliogaphy()  # see below
        # * make sure to generate a toc file if needed for local contents:
        if "minitoc" in self.requirements and not self.has_latex_toc:
            self.out.append("\n\\faketableofcontents % for local ToCs\n")
        # * conditional requirements (before style sheet)
        self.requirements = [self.requirements[key]
                             for key in sorted(self.requirements.keys())]
        # * coditional fallback definitions (after style sheet)
        self.fallbacks = [self.fallbacks[key]
                          for key in sorted(self.fallbacks.keys())]

    def _complete_pdfsetup(self) -> None:
        self.pdfsetup.append(PreambleCmds.linking % self.hyperref_options)
        if self.document.get("title", ""):
            self.pdfinfo.insert(0, "  pdftitle={%s},"
                                % self.encode(self.document.get("title", "")))
        if self.pdfauthor:
            authors = (self.author_separator + " ").join(self.pdfauthor)
            self.pdfinfo.append("  pdfauthor={%s}" % authors)
        if self.pdfinfo:
            self.pdfsetup += [r"\hypersetup{", *self.pdfinfo, "}"]

    def make_title(self) -> None:
        # Auxiliary function called by `self.depart_document()`.
        #
        # The document title is stored in the "titledata" document part.
        # Date and author info is included with "use_latex_docinfo".
        # However, we need the ``\title``, ``\author``, and ``\date``
        # macros even if empty, to prevent errors and/or automatic
        # display of the current date by ``\maketitle``.

        # \title
        title_arg = ["".join(self.title)]  # ensure len == 1
        if self.title:
            title_arg += self.title_labels
        if self.subtitle:
            title_arg += [r"\\",
                          r"\DUdocumentsubtitle{%s}" % "".join(self.subtitle),
                          *self.subtitle_labels]
        self.titledata.append(r"\title{%s}" % "%\n  ".join(title_arg))
        # \author
        # author name(s) and optional affiliation and contact info
        # cf. https://tex.stackexchange.com/a/377030/288060.
        authors = ["\\\\\n".join(filter(None, author_entry))
                   for author_entry in self.author_stack]
        self.titledata.append(r"\author{%s}" % " \\and\n".join(authors))
        # \date
        self.titledata.append(r"\date{%s}" % ", ".join(self.date))
        # \maketitle
        # Must be in the document body.  Append to "body_pre_docinfo" part
        # so templates may use the "titledata" part in the document preamble.
        self.body_pre_docinfo.append("\\maketitle\n")

    def append_bibliogaphy(self) -> None:
        # Add bibliography at end of document.
        # TODO insertion point should be configurable.
        # Auxiliary function called by `depart_document`.
        if self.bibtex:
            self.out.append("\n\\bibliographystyle{%s}\n" % self.bibtex[0])
            self.out.append("\\bibliography{%s}\n" % ",".join(self.bibtex[1:]))
        elif self.use_latex_citations:
            # TODO: insert citations at point of definition.
            widest_label = ""
            for bibitem in self._bibitems:
                if len(widest_label) < len(bibitem[0]):
                    widest_label = bibitem[0]
            self.out.append("\n\\begin{thebibliography}{%s}\n" % widest_label)
            for bibitem in self._bibitems:
                # cite_key: underscores must not be escaped
                cite_key = bibitem[0].replace(r"\_", "_")
                self.out.append("\\bibitem[%s]{%s}{%s}\n" % (bibitem[0], cite_key, bibitem[1]))
            self.out.append("\\end{thebibliography}\n")

    def visit_section(self, node: nodes.Element) -> None:
        # Update counter-prefix for compound enumerators
        self.section_level += 1
        # initialize counter for potential subsections
        self._section_number.append(0)
        # counter for this section's level (initialized by parent section)
        self._section_number[self.section_level - 1] += 1

        # Section numbering configuration
        if "sectnum" in self.requirements:
            return  # already done
        # sectnum_depth values:
        #    0    no section numbering or section numbering by Docutils
        #   >0    value of "sectnum"'s :depth: option (1 = top level section)
        #   None  "sectnum" directive without depth arg -> keep default
        if self.settings.sectnum_xform:  # section numbering by Docutils
            sectnum_depth = 0  # suppress LaTeX section numbers
        else:
            sectnum_depth = self._latex_sectnum_setup()
        if sectnum_depth is not None:
            self.requirements["sectnum"] = r"\setcounter{secnumdepth}{%d}" % (
                self.d_class.latex_section_depth(sectnum_depth))

    def _latex_sectnum_setup(self) -> int | None:
        """Configure section numbering by LaTeX, return the "sectnum_depth"."""
        sectnum_depth = getattr(self.settings, "sectnum_depth", 0)
        if isinstance(sectnum_depth, str):
            sectnum_depth = 0  # ignore values from config files
        sectnum_start = getattr(self.settings, "sectnum_start", 1)
        if isinstance(sectnum_start, str):
            sectnum_start = 1  # ignore values from config files
        if sectnum_start != 1:
            self.requirements["sectnum_start"] = r"\setcounter{%s}{%d}" % (
                self.d_class.sections[0], sectnum_start-1)
        # TODO: currently ignored (configure in a stylesheet):
        # settings.sectnum_prefix
        # settings.sectnum_suffix
        return sectnum_depth

    def depart_section(self, node: nodes.Element) -> None:
        # Remove counter for potential subsections:
        self._section_number.pop()
        self.section_level -= 1

    def visit_subtitle(self, node: nodes.Element) -> None:
        if isinstance(node.parent, nodes.document):
            self.push_output_collector(self.subtitle)
            self.provide_fallback("documentsubtitle")
            protect = (self.settings.documentclass == "memoir")
            self.subtitle_labels += self.ids_to_labels(node, set_anchor=False,
                                                       protect=protect)
        # section subtitle: "starred" (no number, not in ToC)
        elif isinstance(node.parent, nodes.section):
            self.out.append(r"\%s*{" % self.d_class.section(self.section_level + 1))
        else:
            self.provide_fallback("subtitle")
            self.out.append("\n\\DUsubtitle{")

    def depart_subtitle(self, node: nodes.Element) -> None:
        if isinstance(node.parent, nodes.document):
            self.pop_output_collector()
        else:
            self.out.append("}\n")

    def visit_system_message(self, node: nodes.Element) -> None:
        self.requirements["color"] = PreambleCmds.color
        self.provide_fallback("title")
        if self.settings.legacy_class_functions:
            self.fallbacks["title"] = PreambleCmds.title_legacy
        node["classes"] = ["system-message"]
        self.out.append("\n")
        self.append_hypertargets(node)
        self.visit_admonition(node)
        if self.settings.legacy_class_functions:
            self.out.append("\n\\DUtitle[system-message]"
                            "{\\color{red}System Message}\n")
        else:
            self.out.append("\n\\DUtitle{\\color{red}System Message}\n")
        try:
            line = f", line~{node['line']}"
        except KeyError:
            line = ""
        self.out.append(f"\n{node['type']}/{node['level']} in "
                        f"\\texttt{{{self.encode(node['source'])}}}{line}\n")
        if len(node["backrefs"]) == 1:
            self.out.append(f"\n\\hyperlink{{{node['backrefs'][0]}}}{{")
            self.context.append("}\n")
        else:
            backrefs = [f"\\hyperlink{{{href}}}{{{i+1}}}\n"
                        for (i, href) in enumerate(node["backrefs"])]
            self.context.append("backrefs: " + " ".join(backrefs))

    def depart_system_message(self, node: nodes.Element) -> None:
        self.out.append(self.context.pop())
        self.depart_admonition(node)

    def visit_title(self, node: nodes.Element) -> None:
        """Append section and other titles."""
        # Document title
        if isinstance(node.parent, nodes.document):
            self.push_output_collector(self.title)
            self.context.append("")
        # Topic titles (topic, admonition, sidebar)
        elif isinstance(node.parent, (nodes.topic, nodes.admonition, nodes.sidebar)):
            classes = node.parent["classes"] or [node.parent.tagname]
            if self.settings.legacy_class_functions:
                self.fallbacks["title"] = PreambleCmds.title_legacy
                self.out.append("\n\\DUtitle[%s]{" % ",".join(classes))
            else:
                self.provide_fallback("title")
                self.out.append("\n\\DUtitle{")
            self.context.append("}\n")
        # Table caption
        elif isinstance(node.parent, nodes.table):
            self.push_output_collector(self.active_table.caption)
            self.context.append("")
        # Section title
        else:
            self._visit_section_title(node)

    def _visit_section_title(self, node: nodes.Element) -> None:
        level = self.section_level
        section_name = self.d_class.section(level)
        self.out.append("\n\n")
        unsupported_level = level > len(self.d_class.sections)
        if unsupported_level:
            # section level not supported by LaTeX
            if self.settings.legacy_class_functions:
                self.fallbacks["title"] = PreambleCmds.title_legacy
                section_name += "[section%s]" % RomanNumeral(level)
            else:
                self.provide_fallback("title")
                self.provide_fallback("duclass", "DUclass")
                self.out.append("\\begin{DUclass}{section%s}\n" % RomanNumeral(level))

        # System messages heading in red:
        if "system-messages" in node.parent["classes"]:
            self.requirements["color"] = PreambleCmds.color
            section_title = self.encode(node.astext())
            self.out.append(r"\%s[%s]{\color{red}" % (section_name, section_title))
        else:
            self.out.append(r"\%s{" % section_name)

        # label and ToC entry:
        bookmark = [""]
        # add sections with unsupported level to toc and pdfbookmarks?
        bookmark += self.ids_to_labels(node.parent, set_anchor=False)
        self.context.append("%\n  ".join(bookmark) + "%\n}\n")
        if unsupported_level and not self.settings.legacy_class_functions:
            self.context[-1] += "\\end{DUclass}\n"
        # MAYBE postfix paragraph and subparagraph with \leavevmode to
        # ensure floats stay in the section and text starts on a new line.

    def depart_title(self, node: nodes.Element) -> None:
        self.out.append(self.context.pop())
        if isinstance(node.parent, (nodes.table, nodes.document)):
            self.pop_output_collector()

    def visit_contents(self, node: nodes.Element):
        """Write the table of contents.

        Called from visit_topic() for "contents" topics.
        """
        # requirements/setup for local ToC with package "minitoc",
        if self.use_latex_toc and "local" in node["classes"]:
            mtc_name = self._minitoc_name(node)

        # labels and PDF bookmark (sidebar entry)
        self.out.append("\n")  # start new paragraph
        if len(node["names"]) > 1:  # don't add labels just for the auto-id
            self.out += self.ids_to_labels(node, newline=True)
        if (isinstance(node.next_node(), nodes.title)
            and "local" not in node["classes"]
            and self.settings.documentclass != "memoir"):
            self.out.append("\\pdfbookmark[%d]{%s}{%s}\n"
                            % (self.section_level+1,
                               node.next_node().astext(),
                               node.get("ids", ["contents"])[0]))

        # Docutils generated contents list (no page numbers)
        if not self.use_latex_toc:
            self.fallbacks["toc-list"] = PreambleCmds.toc_list
            self.duclass_open(node)
            return

        # ToC by LaTeX
        try:
            details = node.next_node(nodes.pending).details
        except AttributeError:
            self.warn('Setting "use_latex_toc" is True but "contents" details '
                      "are missing. Directive option values may be lost.")
            details = {}
        depth = details.get("depth", 0)
        if isinstance(node.next_node(), nodes.title):
            title = self.encode(node[0].astext())
        else:
            title = ""
        if "local" in node["classes"]:
            self._local_latex_toc(mtc_name, depth, title)
        else:
            if depth:
                self.out.append("\\setcounter{tocdepth}{%d}\n"
                                % self.d_class.latex_section_depth(depth))
            if title != "Contents":
                self.out.append("\\renewcommand{\\contentsname}{%s}\n" % title)
            self.out.append("\\tableofcontents\n")
            self.has_latex_toc = True
        # ignore rest of node content
        raise nodes.SkipNode

    def _minitoc_name(self, node: nodes.Element) -> str:
        """Return the "minitoc" name for a local ToC at the current level."""
        section_name = self.d_class.section(self.section_level)
        # minitoc only supports "part" and toplevel sections
        minitoc_names = {"part": "part",
                         "chapter": "mini",
                         "section": "sect"}
        if "chapter" in self.d_class.sections:
            del minitoc_names["section"]
        try:
            return minitoc_names[section_name]
        except KeyError:
            self.warn('Skipping local ToC at "%s" level.\n'
                      '  Feature not supported with option "use-latex-toc"'
                      % section_name, base_node=node)
            raise nodes.SkipNode from None

    def _local_latex_toc(self, mtc_name: str, depth: int, title: str) -> None:
        # use the "minitoc" package
        maxdepth = len(self.d_class.sections)
        self.requirements["minitoc"] = PreambleCmds.minitoc
        self.requirements["minitoc-"+mtc_name] = r"\do%stoc" % mtc_name
        self.requirements["minitoc-%s-depth" % mtc_name] = (
            r"\mtcsetdepth{%stoc}{%d}" % (mtc_name, maxdepth))
        # "depth" option: Docutils stores a relative depth while
        # minitoc  expects an absolute depth!:
        offset = {"sect": 1, "mini": 0, "part": 0}
        if "chapter" in self.d_class.sections:
            offset["part"] = -1
        if depth:
            self.out.append("\\setcounter{%stocdepth}{%d}" % (mtc_name, depth + offset[mtc_name]))
        # title:
        self.out.append("\\mtcsettitle{%stoc}{%s}\n" % (mtc_name, title))
        # the toc-generating command:
        self.out.append("\\%stoc\n" % mtc_name)

    def visit_topic(self, node: nodes.Element) -> None:
        # Topic nodes can be generic topic, abstract, dedication, or ToC.
        # table of contents:
        if "contents" in node["classes"]:
            self.visit_contents(node)
        elif "abstract" in node["classes"] and self.settings.use_latex_abstract:
            self.push_output_collector(self.abstract)
            self.out.append("\\begin{abstract}")
            if isinstance(node.next_node(), nodes.title):
                node.pop(0)  # LaTeX provides its own title
        else:
            # special topics:
            if "abstract" in node["classes"]:
                self.provide_fallback("abstract")
                if self.settings.legacy_class_functions:
                    self.fallbacks["abstract"] = PreambleCmds.abstract_legacy
                self.push_output_collector(self.abstract)
            elif "dedication" in node["classes"]:
                self.provide_fallback("dedication")
                self.push_output_collector(self.dedication)
            else:
                node["classes"].insert(0, "topic")
            self.visit_block_quote(node)

    def depart_topic(self, node: nodes.Element) -> None:
        if "abstract" in node["classes"] and self.settings.use_latex_abstract:
            self.out.append("\\end{abstract}\n")
        elif "contents" in node["classes"]:
            self.duclass_close(node)
        else:
            self.depart_block_quote(node)
        if "abstract" in node["classes"] or "dedication" in node["classes"]:
            self.pop_output_collector()
