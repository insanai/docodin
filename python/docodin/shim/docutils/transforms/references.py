"""Transforms for resolving references."""

from __future__ import annotations

from collections.abc import Callable, Iterable
from typing import Any

from docutils import nodes, utils
from docutils.transforms import Transform

__docformat__ = "reStructuredText"


def _problematic(document: nodes.document, msg: nodes.system_message, msgid: str,
                 ref: nodes.Element) -> None:
    """Replace `ref` by a problematic element linked with `msg`."""
    prb = nodes.problematic(ref.rawsource, ref.rawsource, refid=msgid)
    msg.add_backref(document.set_id(prb))
    ref.replace_self(prb)


class PropagateTargets(Transform):
    """Propagate empty internal targets to the next element."""

    default_priority = 260

    def apply(self) -> None:
        for target in self.document.findall(nodes.target):
            if (isinstance(target.parent, nodes.TextElement) or target.hasattr("refid")
                    or target.hasattr("refuri") or target.hasattr("refname")):
                continue
            assert len(target) == 0, "error: block-level target has children"
            next_node = target.next_node(ascend=True)
            while isinstance(next_node, nodes.system_message):
                next_node = next_node.next_node(ascend=True, descend=False)
            if next_node is None or (isinstance(next_node, (nodes.Invisible, nodes.Targetable))
                                     and not isinstance(next_node, nodes.target)):
                continue
            self._propagate(target, next_node)

    def _propagate(self, target: nodes.target, next_node: nodes.Element) -> None:
        next_node["ids"].extend(target["ids"])
        next_node["names"].extend(target["names"])
        if not hasattr(next_node, "expect_referenced_by_name"):
            next_node.expect_referenced_by_name = {}
        if not hasattr(next_node, "expect_referenced_by_id"):
            next_node.expect_referenced_by_id = {}
        for id in target["ids"]:
            self.document.ids[id] = next_node
            next_node.expect_referenced_by_id[id] = target
        for name in target["names"]:
            next_node.expect_referenced_by_name[name] = target
        next_node.expect_referenced_by_name.update(
            getattr(target, "expect_referenced_by_name", {}))
        next_node.expect_referenced_by_id.update(getattr(target, "expect_referenced_by_id", {}))
        if isinstance(target.parent, nodes.figure) and isinstance(next_node, nodes.caption):
            target.parent.remove(target)
            return
        target["refid"] = target["ids"][0]
        target["ids"] = []
        target["names"] = []
        self.document.note_refid(target)


class AnonymousHyperlinks(Transform):
    """Link anonymous references to targets, in document order."""

    default_priority = 440

    def apply(self) -> None:
        anonymous_refs = [node for node in self.document.findall(nodes.reference)
                          if node.get("anonymous")]
        anonymous_targets = [node for node in self.document.findall(nodes.target)
                             if node.get("anonymous")]
        if len(anonymous_refs) != len(anonymous_targets):
            msg = self.document.reporter.error(
                'Anonymous hyperlink mismatch: %s references but %s targets.\n'
                'See "backrefs" attribute for IDs.' % (len(anonymous_refs),
                                                       len(anonymous_targets)))
            msgid = self.document.set_id(msg)
            for ref in anonymous_refs:
                _problematic(self.document, msg, msgid, ref)
            return
        for ref, target in zip(anonymous_refs, anonymous_targets, strict=True):
            if not (ref.hasattr("refid") or ref.hasattr("refuri")):
                self._link(ref, target)

    def _link(self, ref: nodes.reference, target: nodes.target) -> None:
        target.referenced = True
        while True:
            if target.hasattr("refuri"):
                ref["refuri"] = target["refuri"]
                ref.resolved = True
                return
            if not target["ids"]:
                target = self.document.ids[target["refid"]]
                continue
            ref["refid"] = target["ids"][0]
            self.document.note_refid(ref)
            return


class IndirectHyperlinks(Transform):
    """Resolve indirect targets and the references to them."""

    default_priority = 460

    def apply(self) -> None:
        for target in self.document.indirect_targets:
            if not target.resolved:
                self.resolve_indirect_target(target)
            self.resolve_indirect_references(target)

    def resolve_indirect_target(self, target: nodes.target) -> None:
        refname = target.get("refname")
        if refname is None:
            reftarget_id = target["refid"]
        else:
            reftarget_id = self.document.nameids.get(refname)
            if not reftarget_id:
                for resolver_function in self.document.transformer.unknown_reference_resolvers:
                    if resolver_function(target):
                        break
                else:
                    self.nonexistent_indirect_target(target)
                return
        reftarget = self.document.ids[reftarget_id]
        reftarget.note_referenced_by(id=reftarget_id)
        if (isinstance(reftarget, nodes.target) and not reftarget.resolved
                and reftarget.hasattr("refname")):
            if hasattr(target, "multiply_indirect"):
                self.circular_indirect_reference(target)
                return
            target.multiply_indirect = 1
            self.resolve_indirect_target(reftarget)
            del target.multiply_indirect
        if not self._copy_reference(target, reftarget, reftarget_id):
            self.nonexistent_indirect_target(target)
            return
        if refname is not None:
            del target["refname"]
        target.resolved = True

    def _copy_reference(self, target: nodes.target, reftarget: nodes.Element,
                        reftarget_id: str) -> bool:
        if reftarget.hasattr("refuri"):
            target["refuri"] = reftarget["refuri"]
            if "refid" in target:
                del target["refid"]
        elif reftarget.hasattr("refid"):
            target["refid"] = reftarget["refid"]
            self.document.note_refid(target)
        elif reftarget["ids"]:
            target["refid"] = reftarget_id
            self.document.note_refid(target)
        else:
            return False
        return True

    def nonexistent_indirect_target(self, target: nodes.target) -> None:
        if target["refname"] in self.document.nameids:
            self.indirect_target_error(
                target, "which is a duplicate, and cannot be used as a unique reference")
        else:
            self.indirect_target_error(target, "which does not exist")

    def circular_indirect_reference(self, target: nodes.target) -> None:
        self.indirect_target_error(target, "forming a circular reference")

    def indirect_target_error(self, target: nodes.target, explanation: str) -> None:
        naming = ""
        reflist: list[nodes.Element] = []
        if target["names"]:
            naming = '"%s" ' % target["names"][0]
        for name in target["names"]:
            reflist.extend(self.document.refnames.get(name, []))
        for id in target["ids"]:
            reflist.extend(self.document.refids.get(id, []))
        if target["ids"]:
            naming += '(id="%s")' % target["ids"][0]
        msg = self.document.reporter.error(
            'Indirect hyperlink target %s refers to target "%s", %s.'
            % (naming, target["refname"], explanation), base_node=target)
        msgid = self.document.set_id(msg)
        for ref in utils.uniq(reflist):
            _problematic(self.document, msg, msgid, ref)
        target.resolved = True

    def resolve_indirect_references(self, target: nodes.target) -> None:
        if target.hasattr("refid"):
            attname, call_method = "refid", self.document.note_refid
        elif target.hasattr("refuri"):
            attname, call_method = "refuri", None
        else:
            return
        attval = target[attname]
        for name in target["names"]:
            reflist = self.document.refnames.get(name, [])
            if reflist:
                target.note_referenced_by(name=name)
            self._redirect(reflist, "refname", attname, attval, call_method)
        for id in target["ids"]:
            reflist = self.document.refids.get(id, [])
            if reflist:
                target.note_referenced_by(id=id)
            self._redirect(reflist, "refid", attname, attval, call_method)

    def _redirect(self, reflist: Iterable[nodes.Element], old_attr: str, attname: str,
                  attval: str, call_method: Callable[[nodes.Element], None] | None) -> None:
        for ref in reflist:
            if ref.resolved:
                continue
            del ref[old_attr]
            ref[attname] = attval
            if call_method:
                call_method(ref)
            ref.resolved = True
            if isinstance(ref, nodes.target):
                self.resolve_indirect_references(ref)


class ExternalTargets(Transform):
    """Resolve references to external targets (with a refuri)."""

    default_priority = 640

    def apply(self) -> None:
        for target in self.document.findall(nodes.target):
            if not target.hasattr("refuri"):
                continue
            refuri = target["refuri"]
            for name in target["names"]:
                reflist = self.document.refnames.get(name, [])
                if reflist:
                    target.note_referenced_by(name=name)
                for ref in reflist:
                    if ref.resolved:
                        continue
                    del ref["refname"]
                    ref["refuri"] = refuri
                    ref.resolved = True


class InternalTargets(Transform):
    """Resolve references to internal targets."""

    default_priority = 660

    def apply(self) -> None:
        for target in self.document.findall(nodes.target):
            if not target.hasattr("refuri") and not target.hasattr("refid"):
                self.resolve_reference_ids(target)

    def resolve_reference_ids(self, target: nodes.target) -> None:
        for name in target["names"]:
            refid = self.document.nameids.get(name)
            reflist = self.document.refnames.get(name, [])
            if reflist:
                target.note_referenced_by(name=name)
            for ref in reflist:
                if ref.resolved:
                    continue
                if refid:
                    del ref["refname"]
                    ref["refid"] = refid
                ref.resolved = True


class Footnotes(Transform):
    """Number and symbolize footnotes; link footnote and citation references."""

    default_priority = 620
    autofootnote_labels: list[str] | None = None
    symbols = ["*", "†", "‡", "§", "¶", "#", "♠", "♥", "♦", "♣"]

    def apply(self) -> None:
        self.autofootnote_labels = []
        startnum = self.document.autofootnote_start
        self.document.autofootnote_start = self.number_footnotes(startnum)
        self.number_footnote_references(startnum)
        self.symbolize_footnotes()
        self.resolve_footnotes_and_citations()

    def number_footnotes(self, startnum: int) -> int:
        """Assign numbers to auto-numbered footnotes (and named references)."""
        for footnote in self.document.autofootnotes:
            while True:
                label = str(startnum)
                startnum += 1
                if label not in self.document.nameids:
                    break
            footnote.insert(0, nodes.label("", label))
            for name in footnote["names"]:
                for ref in self.document.footnote_refs.get(name, []):
                    self._link_named(ref, footnote, label)
            if not footnote["names"] and not footnote["dupnames"]:
                footnote["names"].append(label)
                self.document.note_explicit_target(footnote, footnote)
                self.autofootnote_labels.append(label)
        return startnum

    def _link_named(self, ref: nodes.footnote_reference, footnote: nodes.footnote,
                    label: str) -> None:
        ref += nodes.Text(label)
        ref.delattr("refname")
        assert len(footnote["ids"]) == len(ref["ids"]) == 1
        ref["refid"] = footnote["ids"][0]
        footnote.add_backref(ref["ids"][0])
        self.document.note_refid(ref)
        ref.resolved = True

    def number_footnote_references(self, startnum: int) -> None:
        """Assign numbers to anonymous auto-numbered footnote references."""
        i = 0
        for ref in self.document.autofootnote_refs:
            if ref.resolved or ref.hasattr("refid"):
                continue
            if i >= len(self.autofootnote_labels):
                self._too_many_autofootnote_refs(ref, i)
                break
            label = self.autofootnote_labels[i]
            ref += nodes.Text(label)
            id = self.document.nameids[label]
            ref["refid"] = id
            self.document.note_refid(ref)
            assert len(ref["ids"]) == 1
            self.document.ids[id].add_backref(ref["ids"][0])
            ref.resolved = True
            i += 1

    def _too_many_autofootnote_refs(self, ref: nodes.footnote_reference, i: int) -> None:
        n = len(self.autofootnote_labels)
        s = "s" if n > 1 else ""
        msg = self.document.reporter.error(
            f"Too many autonumbered footnote references: only {n} corresponding "
            f"footnote{s} available.", base_node=ref)
        msgid = self.document.set_id(msg)
        for other in self.document.autofootnote_refs[i:]:
            if not (other.resolved or other.hasattr("refname")):
                _problematic(self.document, msg, msgid, other)

    def symbolize_footnotes(self) -> None:
        """Add symbols to symbol footnotes and their references."""
        labels = []
        for footnote in self.document.symbol_footnotes:
            reps, index = divmod(self.document.symbol_footnote_start, len(self.symbols))
            labeltext = self.symbols[index] * (reps + 1)
            labels.append(labeltext)
            footnote.insert(0, nodes.label("", labeltext))
            self.document.symbol_footnote_start += 1
            self.document.set_id(footnote)
        for i, ref in enumerate(self.document.symbol_footnote_refs):
            if i >= len(labels):
                self._too_many_symbol_refs(ref, i, len(labels))
                break
            ref += nodes.Text(labels[i])
            footnote = self.document.symbol_footnotes[i]
            assert len(footnote["ids"]) == 1
            ref["refid"] = footnote["ids"][0]
            self.document.note_refid(ref)
            footnote.add_backref(ref["ids"][0])

    def _too_many_symbol_refs(self, ref: nodes.footnote_reference, i: int, n: int) -> None:
        msg = self.document.reporter.error(
            "Too many symbol footnote references: only %s corresponding footnotes available."
            % n, base_node=ref)
        msgid = self.document.set_id(msg)
        for other in self.document.symbol_footnote_refs[i:]:
            if not (other.resolved or other.hasattr("refid")):
                _problematic(self.document, msg, msgid, other)

    def resolve_footnotes_and_citations(self) -> None:
        """Link manually-labeled footnotes and citations to their references."""
        for footnote in self.document.footnotes:
            for label in footnote["names"]:
                if label in self.document.footnote_refs:
                    self.resolve_references(footnote, self.document.footnote_refs[label])
        for citation in self.document.citations:
            for label in citation["names"]:
                if label in self.document.citation_refs:
                    self.resolve_references(citation, self.document.citation_refs[label])

    def resolve_references(self, note: nodes.Element, reflist: list[nodes.Element]) -> None:
        assert len(note["ids"]) == 1
        id = note["ids"][0]
        for ref in reflist:
            if ref.resolved:
                continue
            ref.delattr("refname")
            ref["refid"] = id
            assert len(ref["ids"]) == 1
            note.add_backref(ref["ids"][0])
            ref.resolved = True
        note.resolved = True


class CircularSubstitutionDefinitionError(Exception):
    pass


class Substitutions(Transform):
    """Replace substitution references with the substitution definitions."""

    default_priority = 220

    def apply(self) -> None:
        self.nested: dict[str, list[str]] = {}
        subreflist = list(self.document.findall(nodes.substitution_reference))
        for ref in subreflist:
            key, subdef = self._definition(ref)
            if subdef is None:
                continue
            self._trim(ref, subdef)
            subdef_copy = subdef.deepcopy()
            try:
                self._queue_nested(ref, key, subdef_copy, subreflist)
            except CircularSubstitutionDefinitionError:
                self._circular(ref)
                continue
            ref.replace_self(subdef_copy.children)
            for node in subdef_copy.children:
                if isinstance(node, nodes.Referential) and "refname" in node:
                    self.document.note_refname(node)

    def _definition(self, ref: nodes.substitution_reference) -> tuple[str, Any]:
        """The definition for `ref`, or (_, None) after reporting an error."""
        refname = ref["refname"]
        defs = self.document.substitution_defs
        key = refname if refname in defs else self.document.substitution_names.get(
            refname.lower())
        if key is None:
            msg = self.document.reporter.error('Undefined substitution referenced: "%s".'
                                               % refname, base_node=ref)
        else:
            limit = getattr(self.document.settings, "line_length_limit", 10000)
            if len(defs[key].astext()) <= limit:
                return key, defs[key]
            msg = self.document.reporter.error(
                'Substitution definition "%s" exceeds the line-length-limit.' % key)
        _problematic(self.document, msg, self.document.set_id(msg), ref)
        return "", None

    def _trim(self, ref: nodes.Element, subdef: nodes.Element) -> None:
        parent = ref.parent
        index = parent.index(ref)
        if "ltrim" in subdef.attributes or "trim" in subdef.attributes:
            if index > 0 and isinstance(parent[index - 1], nodes.Text):
                parent[index - 1] = parent[index - 1].rstrip()
        if "rtrim" in subdef.attributes or "trim" in subdef.attributes:
            if len(parent) > index + 1 and isinstance(parent[index + 1], nodes.Text):
                parent[index + 1] = parent[index + 1].lstrip()

    def _queue_nested(self, ref: nodes.Element, key: str, subdef_copy: nodes.Element,
                      subreflist: list[nodes.Element]) -> None:
        normed = self.document.substitution_names
        for nested_ref in subdef_copy.findall(nodes.substitution_reference):
            nested_name = normed[nested_ref["refname"].lower()]
            if nested_name in self.nested.setdefault(nested_name, []):
                raise CircularSubstitutionDefinitionError
            self.nested[nested_name].append(key)
            nested_ref["ref-origin"] = ref
            subreflist.append(nested_ref)

    def _circular(self, ref: nodes.Element) -> None:
        parent = ref.parent
        if isinstance(parent, nodes.substitution_definition):
            msg = self.document.reporter.error(
                "Circular substitution definition detected:",
                nodes.literal_block(parent.rawsource, parent.rawsource),
                line=parent.line, base_node=parent)
            parent.replace_self(msg)
            return
        ref_origin = ref
        while ref_origin.hasattr("ref-origin"):
            ref_origin = ref_origin["ref-origin"]
        msg = self.document.reporter.error('Circular substitution definition referenced: "%s".'
                                           % ref["refname"], base_node=ref_origin)
        _problematic(self.document, msg, self.document.set_id(msg), ref)


class TargetNotes(Transform):
    """Create footnotes for external targets ("target-notes" directive)."""

    default_priority = 540

    def __init__(self, document: Any, startnode: Any) -> None:
        Transform.__init__(self, document, startnode=startnode)
        self.classes = startnode.details.get("class", [])

    def apply(self) -> None:
        notes: dict[str, nodes.footnote] = {}
        nodelist: list[nodes.footnote] = []
        for target in self.document.findall(nodes.target):
            if not target.hasattr("refuri"):
                continue
            refs: list[nodes.Element] = []
            for name in target["names"]:
                refs.extend(self.document.refnames.get(name, []))
            if refs:
                self._note(target["refuri"], refs, notes, nodelist)
        for ref in self.document.findall(nodes.reference):
            if ref.get("anonymous") and ref.hasattr("refuri"):
                self._note(ref["refuri"], [ref], notes, nodelist)
        self.startnode.replace_self(nodelist)

    def _note(self, refuri: str, refs: list[nodes.Element], notes: dict[str, nodes.footnote],
              nodelist: list[nodes.footnote]) -> None:
        footnote = self.make_target_footnote(refuri, refs, notes)
        if refuri not in notes:
            notes[refuri] = footnote
            nodelist.append(footnote)

    def make_target_footnote(self, refuri: str, refs: list[nodes.Element],
                             notes: dict[str, nodes.footnote]) -> nodes.footnote:
        if refuri in notes:
            footnote = notes[refuri]
            assert len(footnote["names"]) == 1
            footnote_name = footnote["names"][0]
        else:
            footnote = nodes.footnote()
            footnote_name = "TARGET_NOTE: " + self.document.set_id(footnote)
            footnote["auto"] = 1
            footnote["names"] = [footnote_name]
            footnote_paragraph = nodes.paragraph()
            footnote_paragraph += nodes.reference("", refuri, refuri=refuri)
            footnote += footnote_paragraph
            self.document.note_autofootnote(footnote)
            self.document.note_explicit_target(footnote, footnote)
        for ref in refs:
            if not isinstance(ref, nodes.target):
                self._add_reference(ref, footnote_name)
        return footnote

    def _add_reference(self, ref: nodes.Element, footnote_name: str) -> None:
        refnode = nodes.footnote_reference(refname=footnote_name, auto=1)
        refnode["classes"] += self.classes
        self.document.note_autofootnote_ref(refnode)
        self.document.note_footnote_ref(refnode)
        index = ref.parent.index(ref) + 1
        reflist: list[nodes.Node] = [refnode]
        if not utils.get_trim_footnote_ref_space(self.document.settings):
            if self.classes:
                reflist.insert(0, nodes.inline(text=" ", Classes=self.classes))
            else:
                reflist.insert(0, nodes.Text(" "))
        ref.parent.insert(index, reflist)


class CitationReferences(Transform):
    """Mark citation references resolved when a BibTeX database is used."""

    default_priority = 770

    def apply(self) -> None:
        if not getattr(self.document.settings, "use_bibtex", []):
            return
        for node in self.document.findall(nodes.citation_reference):
            if node.resolved or self.document.nameids.get(node.get("refname")):
                continue
            if node.astext():
                node.delattr("refname")
                node.resolved = True


class DanglingReferences(Transform):
    """Report unresolvable references and unreferenced targets."""

    default_priority = 850

    def apply(self) -> None:
        visitor = DanglingReferencesVisitor(
            self.document, self.document.transformer.unknown_reference_resolvers)
        self.document.walk(visitor)
        for target in self.document.findall(nodes.target):
            if target.referenced or target.get("anonymous"):
                continue
            if target["names"]:
                naming = target["names"][0]
            elif target["ids"]:
                naming = target["ids"][0]
            else:
                naming = target["refid"]
            self.document.reporter.info('Hyperlink target "%s" is not referenced.' % naming,
                                        base_node=target)


def _embedded_uri_hint(refname: str) -> list[nodes.Node]:
    """Explain a probably mistyped embedded URI or alias."""
    if "<" not in refname and ">" not in refname:
        return []
    hint = "Did you want to embed a URI or alias?"
    if "<" not in refname:
        hint += "\nOpening bracket missing."
    elif " <" not in refname:
        hint += "\nThe embedded reference must be preceded by whitespace."
    if ">" not in refname:
        hint += "\nClosing bracket missing."
    elif not refname.endswith(">"):
        hint += "\nThe embedded reference must be the last text before the end string."
    if "< " in refname or " >" in refname:
        hint += "\nWhitespace around the embedded reference is not allowed."
    return [nodes.paragraph("", hint)]


class DanglingReferencesVisitor(nodes.SparseNodeVisitor):
    """Resolve remaining references by name or report them."""

    def __init__(self, document: nodes.document, unknown_reference_resolvers: list[Any]) -> None:
        nodes.SparseNodeVisitor.__init__(self, document)
        self.document = document
        self.unknown_reference_resolvers = unknown_reference_resolvers

    def unknown_visit(self, node: nodes.Node) -> None:
        pass

    def visit_reference(self, node: nodes.Element) -> None:
        if node.resolved or not node.hasattr("refname"):
            return
        refname = node["refname"]
        id = self.document.nameids.get(refname)
        if id is not None:
            del node["refname"]
            node["refid"] = id
            self.document.ids[id].note_referenced_by(id=id)
            node.resolved = True
            return
        for resolver_function in self.unknown_reference_resolvers:
            if resolver_function(node):
                return
        if refname in self.document.nameids:
            msg = self.document.reporter.error(
                f'Duplicate target name, cannot be used as a unique reference: "{refname}".',
                base_node=node)
        else:
            msg = self.document.reporter.error(f'Unknown target name: "{refname}".',
                                               *_embedded_uri_hint(refname), base_node=node)
        msgid = self.document.set_id(msg)
        prb = nodes.problematic(node.rawsource, node.rawsource, refid=msgid)
        prbid = node["ids"][0] if node["ids"] else self.document.set_id(prb)
        msg.add_backref(prbid)
        node.replace_self(prb)

    visit_footnote_reference = visit_citation_reference = visit_reference
