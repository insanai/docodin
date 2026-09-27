"""The `document` root element and its name/id registry."""

from __future__ import annotations

import os
from collections import Counter
from typing import Any

from ._base import (
    Element,
    Root,
    Titular,
    ValidationError,
    dupname,
    fully_normalize_name,
    make_id,
    whitespace_normalize_name,
)
from ._elements import (
    Body,
    decoration,
    docinfo,
    meta,
    section,
    sidebar,
    subtitle,
    target,
    title,
    topic,
    transition,
)


class document(Root, Element):  # noqa: N801 - docutils tag name
    """The document root (create with `docutils.utils.new_document`)."""

    valid_attributes = Element.valid_attributes + ("title",)
    content_model = (
        (title, "?"), (subtitle, "?"), (meta, "*"), (decoration, "?"), (docinfo, "?"),
        (transition, "?"), ((Body, topic, sidebar, transition), "*"),
        ((section, transition), "*"),
    )

    def __init__(self, settings: Any, reporter: Any, *args: Any, **kwargs: Any) -> None:
        Element.__init__(self, *args, **kwargs)
        self.current_source: str | None = None
        self.current_line: int | None = None
        self.settings = settings
        self.reporter = reporter
        self.indirect_targets: list = []
        self.substitution_defs: dict[str, Element] = {}
        self.substitution_names: dict[str, str] = {}
        self.refnames: dict[str, list[Element]] = {}
        self.refids: dict[str, list[Element]] = {}
        self.nameids: dict[str, str | None] = {}
        self.nametypes: dict[str, bool] = {}
        self.ids: dict[str, Element] = {}
        self.footnote_refs: dict[str, list[Element]] = {}
        self.citation_refs: dict[str, list[Element]] = {}
        self.autofootnotes: list[Element] = []
        self.autofootnote_refs: list[Element] = []
        self.symbol_footnotes: list[Element] = []
        self.symbol_footnote_refs: list[Element] = []
        self.footnotes: list[Element] = []
        self.citations: list[Element] = []
        self.autofootnote_start = 1
        self.symbol_footnote_start = 0
        self.id_counter: Counter[str] = Counter()
        self.parse_messages: list[Element] = []
        self.transform_messages: list[Element] = []
        import docutils.transforms

        self.transformer = docutils.transforms.Transformer(self)
        self.include_log: list[tuple[str, tuple]] = []
        self.decoration: decoration | None = None
        self._document = self

    def __getstate__(self) -> dict[str, Any]:
        state = self.__dict__.copy()
        state["reporter"] = None
        state["transformer"] = None
        return state

    def asdom(self, dom: Any = None) -> Any:
        """Return a DOM representation of this document."""
        if dom is None:
            import xml.dom.minidom as dom
        domroot = dom.Document()
        domroot.appendChild(self._dom_node(domroot))
        return domroot

    def set_id(self, node: Element, msgnode: Element | None = None,
               suggested_prefix: str = "") -> str:
        """Register (or create) the id of `node`; return it."""
        if node["ids"]:
            return self._register_ids(node, msgnode)
        id, base_id, last_id = self._name_based_id(node)
        if not id:
            id = self._counter_id(node, suggested_prefix, base_id, last_id)
        node["ids"].append(id)
        self.ids[id] = node
        return id

    def _register_ids(self, node: Element, msgnode: Element | None) -> str:
        for id in node["ids"]:
            self.ids.setdefault(id, node)
            if self.ids[id] is not node:
                msg = self.reporter.error(f'Duplicate ID: "{id}" used by '
                                          f"{self.ids[id].starttag()} and {node.starttag()}",
                                          base_node=node)
                if msgnode is not None:
                    msgnode += msg
        return id

    def _name_based_id(self, node: Element) -> tuple[str, str, str]:
        """(free id from the node's names or '', last base id, last id tried)."""
        id_prefix = self.settings.id_prefix
        base_id = id = ""
        for name in node["names"]:
            base_id = make_id("x" + name)[1:] if id_prefix else make_id(name)
            id = id_prefix + base_id
            if base_id and id not in self.ids:
                return id, base_id, id
        return "", base_id, id

    def _counter_id(self, node: Element, suggested_prefix: str, base_id: str,
                    last_id: str) -> str:
        id_prefix = self.settings.id_prefix
        auto_id_prefix = self.settings.auto_id_prefix
        if base_id and auto_id_prefix.endswith("%"):
            prefix = last_id + "-"
        else:
            prefix = id_prefix + auto_id_prefix
            if prefix.endswith("%"):
                prefix = f"{prefix[:-1]}{suggested_prefix or make_id(node.tagname)}-"
        while True:
            self.id_counter[prefix] += 1
            id = f"{prefix}{self.id_counter[prefix]}"
            if id not in self.ids:
                return id

    def set_name_id_map(self, node: Element, id: str, msgnode: Element | None = None,
                        explicit: bool = False) -> None:
        """Map the names of `node` to `id` (``None`` marks a dupname)."""
        for name in tuple(node["names"]):
            if name in self.nameids:
                self.set_duplicate_name_id(node, id, name, msgnode, explicit)
            else:
                self.nameids[name] = id
                self.nametypes[name] = explicit

    def set_duplicate_name_id(self, node: Element, id: str, name: str,
                              msgnode: Element | None, explicit: bool) -> None:
        """Resolve a name clash; report it at INFO or WARNING level."""
        old_id = self.nameids[name]
        old_explicit = self.nametypes[name]
        old_node = self.ids.get(old_id)
        self.nametypes[name] = old_explicit or explicit
        if old_id is not None and _same_reference(node, old_node):
            ref = node.get("refuri") or node.get("refname")
            level, text = 1, f'Duplicate name "{name}" for external target "{ref}".'
            dupname(node, name)
        elif explicit:
            level, text = self._explicit_duplicate(node, id, name, old_id, old_node, old_explicit)
        else:
            level, text = 1, f'Duplicate implicit target name: "{name}".'
            dupname(node, name)
            if old_id is not None and not old_explicit:
                dupname(old_node, name)
                self.nameids[name] = None
        if level:
            self._report_duplicate(node, id, level, text, msgnode)

    def _explicit_duplicate(self, node: Element, id: str, name: str, old_id: str | None,
                            old_node: Element | None, old_explicit: bool) -> tuple[int, str]:
        if old_explicit:
            dupname(node, name)
            if old_id is not None:
                dupname(old_node, name)
                self.nameids[name] = None
            return 2, f'Duplicate explicit target name: "{name}".'
        self.nameids[name] = id
        if old_id is None:
            return 0, ""
        dupname(old_node, name)
        return 1, f'Target name overrides implicit target name "{name}".'

    def _report_duplicate(self, node: Element, id: str, level: int, text: str,
                          msgnode: Element | None) -> None:
        backrefs = [] if isinstance(node, target) and "refuri" in node else [id]
        msg = self.reporter.system_message(level, text, backrefs=backrefs, base_node=node)
        if msgnode is not None:
            msgnode += msg
            try:
                msgnode.validate(recursive=False)
            except ValidationError:
                msgnode.pop()
                msg.parent = None

    def has_name(self, name: str) -> bool:
        return name in self.nameids

    def note_implicit_target(self, target: Element, msgnode: Element | None = None) -> None:
        id = self.set_id(target, msgnode)
        self.set_name_id_map(target, id, msgnode, explicit=False)

    def note_explicit_target(self, target: Element, msgnode: Element | None = None) -> None:
        id = self.set_id(target, msgnode)
        self.set_name_id_map(target, id, msgnode, explicit=True)

    def note_refname(self, node: Element) -> None:
        self.refnames.setdefault(node["refname"], []).append(node)

    def note_refid(self, node: Element) -> None:
        self.refids.setdefault(node["refid"], []).append(node)

    def note_indirect_target(self, target: Element) -> None:
        self.indirect_targets.append(target)
        if target["names"]:
            self.note_refname(target)

    def note_anonymous_target(self, target: Element) -> None:
        self.set_id(target)

    def note_autofootnote(self, footnote: Element) -> None:
        self.set_id(footnote)
        self.autofootnotes.append(footnote)

    def note_autofootnote_ref(self, ref: Element) -> None:
        self.set_id(ref)
        self.autofootnote_refs.append(ref)

    def note_symbol_footnote(self, footnote: Element) -> None:
        self.set_id(footnote)
        self.symbol_footnotes.append(footnote)

    def note_symbol_footnote_ref(self, ref: Element) -> None:
        self.set_id(ref)
        self.symbol_footnote_refs.append(ref)

    def note_footnote(self, footnote: Element) -> None:
        self.set_id(footnote)
        self.footnotes.append(footnote)

    def note_footnote_ref(self, ref: Element) -> None:
        self.set_id(ref)
        self.footnote_refs.setdefault(ref["refname"], []).append(ref)
        self.note_refname(ref)

    def note_citation(self, citation: Element) -> None:
        self.citations.append(citation)

    def note_citation_ref(self, ref: Element) -> None:
        self.set_id(ref)
        self.citation_refs.setdefault(ref["refname"], []).append(ref)
        self.note_refname(ref)

    def note_substitution_def(self, subdef: Element, def_name: str,
                              msgnode: Element | None = None) -> None:
        name = whitespace_normalize_name(def_name)
        if name in self.substitution_defs:
            msg = self.reporter.error('Duplicate substitution definition name: "%s".' % name,
                                      base_node=subdef)
            if msgnode is not None:
                msgnode += msg
            dupname(self.substitution_defs[name], name)
        self.substitution_defs[name] = subdef
        self.substitution_names[fully_normalize_name(name)] = name

    def note_substitution_ref(self, subref: Element, refname: str) -> None:
        subref["refname"] = whitespace_normalize_name(refname)

    def note_pending(self, pending: Element, priority: int | None = None) -> None:
        self.transformer.add_pending(pending, priority)

    def note_parse_message(self, message: Element) -> None:
        self.parse_messages.append(message)

    def note_transform_message(self, message: Element) -> None:
        self.transform_messages.append(message)

    def note_source(self, source: str | None, offset: int | None) -> None:
        self.current_source = source and os.fspath(source)
        self.current_line = None if offset is None else offset + 1

    def copy(self) -> document:
        obj = self.__class__(self.settings, self.reporter, **self.attributes)
        obj.source = self.source
        obj.line = self.line
        return obj

    def get_decoration(self) -> decoration:
        if not self.decoration:
            self.decoration = decoration()
            index = self.first_child_not_matching_class((Titular, meta))
            if index is None:
                self.append(self.decoration)
            else:
                self.insert(index, self.decoration)
        return self.decoration


def _same_reference(node: Element, old_node: Element | None) -> bool:
    """Whether both targets refer to the same URI or reference name."""
    old = old_node if old_node is not None else {}
    return ("refname" in node and node["refname"] == old.get("refname")
            or "refuri" in node and node["refuri"] == old.get("refuri"))
