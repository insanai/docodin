"""Transforms of the document front matter: title, subtitle, bibliographic data."""

from __future__ import annotations

import re
from typing import Any

from docutils import nodes, parsers, utils
from docutils.transforms import Transform, TransformError

__docformat__ = "reStructuredText"


class TitlePromoter(Transform):
    """Abstract base class for DocTitle and SectionSubTitle transforms."""

    def promote_title(self, node: nodes.Element) -> bool:
        """Promote the title of a lone top-level section to `node`'s title."""
        if not isinstance(node, nodes.Element):
            raise TypeError("node must be of Element-derived type.")
        assert not (len(node) and isinstance(node[0], nodes.title))
        section, index = self.candidate_index(node)
        if index is None:
            return False
        node.update_all_atts_concatenating(section, replace=True, and_source=True)
        node[:] = section[:1] + node[:index] + section[1:]
        assert isinstance(node[0], nodes.title)
        return True

    def promote_subtitle(self, node: nodes.Element) -> bool:
        """Promote the title of a lone subsection to `node`'s subtitle."""
        if not isinstance(node, nodes.Element):
            raise TypeError("node must be of Element-derived type.")
        subsection, index = self.candidate_index(node)
        if index is None:
            return False
        subtitle = nodes.subtitle()
        subtitle.update_all_atts_concatenating(subsection, replace=True, and_source=True)
        subtitle[:] = subsection[0][:]
        node[:] = node[:1] + [subtitle] + node[1:index] + subsection[1:]
        return True

    def candidate_index(self, node: nodes.Element) -> tuple[Any, int | None]:
        """(section, index) if `node` has a lone section after its front matter."""
        index = node.first_child_not_matching_class(nodes.PreBibliographic)
        if index is None or len(node) > index + 1 or not isinstance(node[index], nodes.section):
            return None, None
        return node[index], index


class DocTitle(TitlePromoter):
    """Promote a lone top-level section title to the document title."""

    default_priority = 320

    def set_metadata(self) -> None:
        """Set the document's "title" attribute (metadata)."""
        if self.document.hasattr("title"):
            return
        if self.document.settings.title is not None:
            self.document["title"] = self.document.settings.title
        elif len(self.document) and isinstance(self.document[0], nodes.title):
            self.document["title"] = self.document[0].astext()

    def apply(self) -> None:
        if self.document.settings.setdefault("doctitle_xform", True):
            if self.promote_title(self.document):
                self.promote_subtitle(self.document)
        self.set_metadata()


class SectionSubTitle(TitlePromoter):
    """Promote lone subsection titles to section subtitles."""

    default_priority = 350

    def apply(self) -> None:
        if not self.document.settings.setdefault("sectsubtitle_xform", True):
            return
        for section in self.document.findall(nodes.section):
            self.promote_subtitle(section)


_RCS_KEYWORD_SUBSTITUTIONS = [
    (re.compile(r"\$Date: (\d\d\d\d)[-/](\d\d)[-/](\d\d)[ T][\d:]+[^$]* \$", re.IGNORECASE),
     r"\1-\2-\3"),
    (re.compile(r"\$RCSfile: (.+),v \$", re.IGNORECASE), r"\1"),
    (re.compile(r"\$[a-zA-Z]+: (.+) \$"), r"\1"),
]


class DocInfo(Transform):
    """Transform a leading field list into a docinfo element."""

    default_priority = 340
    biblio_nodes = {
        "author": nodes.author, "authors": nodes.authors, "organization": nodes.organization,
        "address": nodes.address, "contact": nodes.contact, "version": nodes.version,
        "revision": nodes.revision, "status": nodes.status, "date": nodes.date,
        "copyright": nodes.copyright, "dedication": nodes.topic, "abstract": nodes.topic,
    }
    rcs_keyword_substitutions = _RCS_KEYWORD_SUBSTITUTIONS

    def apply(self) -> None:
        if not self.document.settings.setdefault("docinfo_xform", True):
            return
        document = self.document
        index = document.first_child_not_matching_class(nodes.PreBibliographic)
        if index is None:
            return
        candidate = document[index]
        if isinstance(candidate, nodes.field_list):
            biblioindex = document.first_child_not_matching_class(
                (nodes.Titular, nodes.decoration, nodes.meta))
            nodelist = self.extract_bibliographic(candidate)
            del document[index]
            document[biblioindex:biblioindex] = nodelist

    def extract_bibliographic(self, field_list: nodes.field_list) -> list[nodes.Element]:
        """Split `field_list` into a docinfo element and dedication/abstract topics."""
        docinfo = nodes.docinfo()
        topics: dict[str, Any] = {"dedication": None, "abstract": None}
        for field in field_list:
            normedname = ""
            try:
                name = field[0][0].astext()
                normedname = nodes.fully_normalize_name(name)
                if not (len(field) == 2 and normedname in self.language.bibliographic_fields
                        and self.check_empty_biblio_field(field, name)):
                    raise TransformError
                self._extract_field(field, name, normedname, docinfo, topics)
            except TransformError:
                self._keep_generic_field(field, normedname, docinfo)
        nodelist = [docinfo] if len(docinfo) else []
        nodelist.extend(topic for topic in (topics["dedication"], topics["abstract"]) if topic)
        return nodelist

    def _extract_field(self, field: nodes.field, name: str, normedname: str,
                       docinfo: nodes.docinfo, topics: dict[str, Any]) -> None:
        canonical = self.language.bibliographic_fields[normedname]
        biblioclass = self.biblio_nodes[canonical]
        if issubclass(biblioclass, nodes.TextElement):
            if not self.check_compound_biblio_field(field, name):
                raise TransformError
            utils.clean_rcs_keywords(field[1][0], self.rcs_keyword_substitutions)
            docinfo.append(biblioclass("", "", *field[1][0]))
        elif issubclass(biblioclass, nodes.authors):
            self.extract_authors(field, name, docinfo)
        elif issubclass(biblioclass, nodes.topic):
            if topics[canonical]:
                field[-1] += self.document.reporter.warning(
                    'There can only be one "%s" field.' % name, base_node=field)
                raise TransformError
            label = self.language.labels[canonical]
            title = nodes.title(name, label)
            title[0].rawsource = label
            topics[canonical] = biblioclass("", title, *field[1].children, classes=[canonical])
        else:
            docinfo.append(biblioclass("", *field[1].children))

    def _keep_generic_field(self, field: nodes.field, normedname: str,
                            docinfo: nodes.docinfo) -> None:
        if len(field[-1]) == 1 and isinstance(field[-1][0], nodes.paragraph):
            utils.clean_rcs_keywords(field[-1][0], self.rcs_keyword_substitutions)
        classvalue = nodes.make_id(normedname)
        if classvalue:
            field["classes"].append(classvalue)
        docinfo.append(field)

    def check_empty_biblio_field(self, field: nodes.field, name: str) -> bool:
        if len(field[-1]) < 1:
            field[-1] += self.document.reporter.warning(
                f'Cannot extract empty bibliographic field "{name}".', base_node=field)
            return False
        return True

    def check_compound_biblio_field(self, field: nodes.field, name: str) -> bool:
        """Whether the field body is a single paragraph (repairing a lone enumerator)."""
        f_body = field[-1]
        if len(f_body) == 1 and isinstance(f_body[0], nodes.paragraph):
            return True
        if (isinstance(f_body[0], nodes.enumerated_list)
                and "\n" not in f_body.rawsource.strip()):
            # "Date: 2001." is parsed as an enumerated list: parse it as text
            _document = utils.new_document("*DocInfo transform*", field.document.settings)
            parsers.rst.Parser().parse("\\" + f_body.rawsource, _document)
            if len(_document.children) == 1 and isinstance(_document.children[0],
                                                           nodes.paragraph):
                f_body.children = _document.children
                return True
        content = [f"<{e.tagname}>" for e in f_body.children
                   if not isinstance(e, nodes.system_message)]
        described = "[" + ", ".join(content) + "]" if len(content) > 1 else "a " + content[0]
        f_body += self.document.reporter.warning(
            f'Bibliographic field "{name}"\nmust contain a single <paragraph>, not {described}.',
            base_node=field)
        return False

    def extract_authors(self, field: nodes.field, name: str, docinfo: nodes.docinfo) -> None:
        """Append an authors element built from the field body."""
        try:
            authors = self._authors(field)
            authornodes = [nodes.author("", "", *author) for author in authors if author]
            if not authornodes:
                raise TransformError
            docinfo.append(nodes.authors("", *authornodes))
        except TransformError:
            separators = "".join(self.language.author_separators)
            field[-1] += self.document.reporter.warning(
                f'Cannot extract "{name}" from bibliographic field:\n'
                f'Bibliographic field "{name}" must contain either\n'
                f" a single paragraph (with author names separated by a character from the set "
                f'"{separators}"),\n multiple paragraphs (one per author),\n'
                " or a bullet list with one author name per item.\n"
                "Note: Leading initials can cause (mis)recognizing names as enumerated list.",
                base_node=field)
            raise

    def _authors(self, field: nodes.field) -> list[list[nodes.Node]]:
        if len(field[1]) != 1:
            return self.authors_from_paragraphs(field)
        if isinstance(field[1][0], nodes.paragraph):
            return self.authors_from_one_paragraph(field)
        if isinstance(field[1][0], nodes.bullet_list):
            return self.authors_from_bullet_list(field)
        raise TransformError

    def authors_from_one_paragraph(self, field: nodes.field) -> list[list[nodes.Node]]:
        """Author names separated by one of the language's author separators."""
        text = "".join(str(node) for node in field[1].findall(nodes.Text))
        if not text:
            raise TransformError
        for authorsep in self.language.author_separators:
            authornames = re.split("(?<!\x00)%s" % authorsep, text)
            if len(authornames) > 1:
                break
        names = (name.strip() for name in authornames)
        return [[nodes.Text(name)] for name in names if name]

    def authors_from_bullet_list(self, field: nodes.field) -> list[list[nodes.Node]]:
        authors = []
        for item in field[1][0]:
            if isinstance(item, nodes.comment):
                continue
            if len(item) != 1 or not isinstance(item[0], nodes.paragraph):
                raise TransformError
            authors.append(item[0].children)
        if not authors:
            raise TransformError
        return authors

    def authors_from_paragraphs(self, field: nodes.field) -> list[list[nodes.Node]]:
        for item in field[1]:
            if not isinstance(item, (nodes.paragraph, nodes.comment)):
                raise TransformError
        return [item.children for item in field[1] if not isinstance(item, nodes.comment)]
