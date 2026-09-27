"""Transforms for PEP processing."""

from __future__ import annotations

import os
import re
import time
from typing import Any

from docutils import DataError, languages, nodes, utils
from docutils.transforms import Transform, misc, parts, references

__docformat__ = "reStructuredText"


class Headers(Transform):
    """Process the fields of a PEP's RFC 2822 header."""

    default_priority = 360
    pep_url = "pep-%04d"
    pep_cvs_url = "http://hg.python.org/peps/file/default/pep-%04d.txt"
    rcs_keyword_substitutions = (
        (re.compile(r"\$RCSfile: (.+),v \$$", re.IGNORECASE), r"\1"),
        (re.compile(r"\$[a-zA-Z]+: (.+) \$$"), r"\1"),
    )

    def apply(self) -> None:
        if not len(self.document):
            raise DataError("Document tree is empty.")
        header = self.document[0]
        if not isinstance(header, nodes.field_list) or "rfc2822" not in header["classes"]:
            raise DataError("Document does not begin with an RFC-2822 header; it is not a PEP.")
        pep, cvs_url = self._pep_number(header)
        if pep == 0:
            pending = nodes.pending(PEPZero)
            self.document.insert(1, pending)
            self.document.note_pending(pending)
        if len(header) < 2 or header[1][0].astext().lower() != "title":
            raise DataError("No title!")
        for field in header:
            self._process_field(field, pep, cvs_url)

    def _pep_number(self, header: nodes.field_list) -> tuple[Any, str | None]:
        for field in header:
            if field[0].astext().lower() != "pep":
                continue
            value = field[1].astext()
            try:
                pep = int(value)
            except ValueError:
                self._invalid_pep(field, value)
                return value, None
            return pep, self.pep_cvs_url % pep
        raise DataError('Document does not contain an RFC-2822 "PEP" header.')

    def _invalid_pep(self, field: nodes.field, value: str) -> None:
        msg = self.document.reporter.warning(
            '"PEP" header must contain an integer; "%s" is an invalid value.' % value,
            base_node=field)
        msgid = self.document.set_id(msg)
        prb = nodes.problematic(value, value or "(none)", refid=msgid)
        msg.add_backref(self.document.set_id(prb))
        if len(field[1]):
            field[1][0][:] = [prb]
        else:
            field[1] += nodes.paragraph("", "", prb)

    def _process_field(self, field: nodes.field, pep: Any, cvs_url: str | None) -> None:
        name = field[0].astext().lower()
        body = field[1]
        if len(body) > 1:
            raise DataError("PEP header field body contains multiple elements:\n%s"
                            % field.pformat(level=1))
        if len(body) == 1:
            if not isinstance(body[0], nodes.paragraph):
                raise DataError("PEP header field body may only contain a single paragraph:\n%s"
                                % field.pformat(level=1))
        elif name == "last-modified":
            try:
                date = time.strftime("%d-%b-%Y",
                                     time.localtime(os.stat(self.document["source"])[8]))
            except OSError:
                date = "unknown"
            if cvs_url:
                body += nodes.paragraph("", "", nodes.reference("", date, refuri=cvs_url))
        else:
            return
        self._process_paragraph(name, body, pep, cvs_url)

    def _process_paragraph(self, name: str, body: nodes.field_body, pep: Any,
                           cvs_url: str | None) -> None:
        para = body[0]
        settings = self.document.settings
        if name in ("author", "discussions-to"):
            pepno = pep if name == "discussions-to" else None
            for node in para:
                if isinstance(node, nodes.reference):
                    node.replace_self(mask_email(node, pepno))
        elif name in ("replaces", "replaced-by", "requires"):
            newbody: list[nodes.Node] = []
            space = nodes.Text(" ")
            for refpep in re.split(r",?\s+", body.astext()):
                pepno = int(refpep)
                newbody.extend((nodes.reference(refpep, refpep,
                                                refuri=settings.pep_base_url
                                                + self.pep_url % pepno), space))
            para[:] = newbody[:-1]
        elif name == "last-modified":
            utils.clean_rcs_keywords(para, self.rcs_keyword_substitutions)
            if cvs_url:
                para[:] = [nodes.reference("", para.astext(), refuri=cvs_url)]
        elif name == "content-type":
            uri = settings.pep_base_url + self.pep_url % 12
            para[:] = [nodes.reference("", para.astext(), refuri=uri)]
        elif name == "version" and len(body):
            utils.clean_rcs_keywords(para, self.rcs_keyword_substitutions)


class Contents(Transform):
    """Insert an empty table of contents topic and a transform placeholder."""

    default_priority = 380

    def apply(self) -> None:
        language = languages.get_language(self.document.settings.language_code,
                                          self.document.reporter)
        name = language.labels["contents"]
        topic = nodes.topic("", nodes.title("", name), classes=["contents"])
        name = nodes.fully_normalize_name(name)
        if not self.document.has_name(name):
            topic["names"].append(name)
        self.document.note_implicit_target(topic)
        pending = nodes.pending(parts.Contents)
        topic += pending
        self.document.insert(1, topic)
        self.document.note_pending(pending)


class TargetNotes(Transform):
    """Locate or create the "References" section; insert target notes."""

    default_priority = 520

    def apply(self) -> None:
        doc = self.document
        i = len(doc) - 1
        refsect = copyright_ = None
        while i >= 0 and isinstance(doc[i], nodes.section):
            title_words = doc[i][0].astext().lower().split()
            if "references" in title_words:
                refsect = doc[i]
                break
            if "copyright" in title_words:
                copyright_ = i
            i -= 1
        if not refsect:
            refsect = nodes.section()
            refsect += nodes.title("", "References")
            doc.set_id(refsect)
            if copyright_:
                doc.insert(copyright_, refsect)
            else:
                doc.append(refsect)
        pending = nodes.pending(references.TargetNotes)
        refsect.append(pending)
        self.document.note_pending(pending, 0)
        pending = nodes.pending(misc.CallBack, details={"callback": self.cleanup_callback})
        refsect.append(pending)
        self.document.note_pending(pending, 1)

    def cleanup_callback(self, pending: nodes.pending) -> None:
        """Remove the "References" section if it contains nothing but the title."""
        if len(pending.parent) == 2:
            pending.parent.parent.remove(pending.parent)


class PEPZero(Transform):
    """Special processing for PEP 0."""

    default_priority = 760

    def apply(self) -> None:
        self.document.walk(PEPZeroSpecial(self.document))
        self.startnode.parent.remove(self.startnode)


class PEPZeroSpecial(nodes.SparseNodeVisitor):
    """Mask e-mail addresses and link PEP numbers in the PEP index tables."""

    pep_url = Headers.pep_url

    def unknown_visit(self, node: nodes.Node) -> None:
        pass

    def visit_reference(self, node: nodes.Element) -> None:
        node.replace_self(mask_email(node))

    def visit_field_list(self, node: nodes.Element) -> None:
        if "rfc2822" in node["classes"]:
            raise nodes.SkipNode

    def visit_tgroup(self, node: nodes.Element) -> None:
        self.pep_table = node["cols"] == 4
        self.entry = 0

    def visit_colspec(self, node: nodes.Element) -> None:
        self.entry += 1
        if self.pep_table and self.entry == 2:
            node["classes"].append("num")

    def visit_row(self, node: nodes.Element) -> None:
        self.entry = 0

    def visit_entry(self, node: nodes.Element) -> None:
        self.entry += 1
        if self.pep_table and self.entry == 2 and len(node) == 1:
            node["classes"].append("num")
            p = node[0]
            if isinstance(p, nodes.paragraph) and len(p) == 1:
                text = p.astext()
                try:
                    pep = int(text)
                except ValueError:
                    return
                ref = self.document.settings.pep_base_url + self.pep_url % pep
                p[0] = nodes.reference(text, text, refuri=ref)


non_masked_addresses = ("peps@python.org", "python-list@python.org", "python-dev@python.org")


def mask_email(ref: nodes.Element, pepno: Any = None) -> nodes.Node:
    """Mask the e-mail address of a mailto reference (PEP style)."""
    if not (ref.hasattr("refuri") and ref["refuri"].startswith("mailto:")):
        return ref
    if ref["refuri"][8:] in non_masked_addresses:
        replacement = ref[0]
    else:
        replacement_text = ref.astext().replace("@", "&#32;&#97;t&#32;")
        replacement = nodes.raw("", replacement_text, format="html")
    if pepno is None:
        return replacement
    ref["refuri"] += "?subject=PEP%%20%s" % pepno
    ref[:] = [replacement]
    return ref
