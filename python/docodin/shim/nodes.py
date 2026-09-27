"""Docutils nodes drop-in implementation for docodin."""

from __future__ import annotations

import re
from typing import Any, Callable, Iterator


class Node:
    parent: Element | None = None
    _document: Any = None
    source: str | None = None
    line: int | None = None

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        pass

    @property
    def document(self) -> Any:
        if self._document is not None:
            return self._document
        if self.parent is not None:
            return self.parent.document
        return None

    @document.setter
    def document(self, doc: Any) -> None:
        self._document = doc

    def walk(self, visitor: NodeVisitor) -> bool:
        visitor.dispatch_visit(self)
        stop = False
        if hasattr(self, "children"):
            for child in getattr(self, "children"):
                if child.walk(visitor):
                    stop = True
                    break
        visitor.dispatch_departure(self)
        return stop

    def walkabout(self, visitor: NodeVisitor) -> bool:
        call_depart = True
        try:
            visitor.dispatch_visit(self)
        except StopIteration:
            return False
        except SkipNode:
            return False
        except SkipChildren:
            pass
        except SkipDeparture:
            call_depart = False
        else:
            if hasattr(self, "children"):
                for child in getattr(self, "children"):
                    if child.walkabout(visitor):
                        return True
        if call_depart:
            visitor.dispatch_departure(self)
        return False

    def findall(self, condition: Any = None, include_self: bool = True) -> Iterator[Node]:
        if include_self:
            if condition is None or (isinstance(condition, type) and isinstance(self, condition)) or (callable(condition) and condition(self)):
                yield self
        if hasattr(self, "children"):
            for child in getattr(self, "children"):
                yield from child.findall(condition, include_self=True)

    def traverse(self, condition: Any = None, include_self: bool = True) -> list[Node]:
        return list(self.findall(condition, include_self=include_self))

    def next_node(self, condition: Any = None, include_self: bool = False, siblings: bool = False, ascend: bool = False) -> Node | None:
        for node in self.findall(condition, include_self=include_self):
            if node is not self:
                return node
        return None

    def asdom(self, dom: Any = None) -> Any:
        return None

    def astext(self) -> str:
        return ""


class Text(str, Node):
    tagname = "#text"

    def __new__(cls, data: str, rawsource: str = "") -> Text:
        t = str.__new__(cls, data)
        t.rawsource = rawsource
        t.parent = None
        t._document = None
        t.source = None
        t.line = None
        return t

    def __init__(self, data: str, rawsource: str = "") -> None:
        pass

    def astext(self) -> str:
        return str(self)

    def copy(self) -> Text:
        return self.__class__(str(self))

    def deepcopy(self) -> Text:
        return self.copy()


class Element(Node):
    tagname: str = ""
    list_attributes = ("ids", "classes", "names", "dupnames", "backrefs")

    def __init__(self, rawsource: str = "", *children: Node, **attributes: Any) -> None:
        self.rawsource = rawsource
        self.children = list(children)
        self.attributes: dict[str, Any] = {
            "ids": [],
            "classes": [],
            "names": [],
            "dupnames": [],
            "backrefs": [],
        }
        self.attributes.update(attributes)
        for child in self.children:
            child.parent = self

    def hasattr(self, attr: str) -> bool:
        return attr in self.attributes

    def __getitem__(self, key: str | int) -> Any:
        if isinstance(key, int):
            return self.children[key]
        return self.attributes[key]

    def __setitem__(self, key: str | int, value: Any) -> None:
        if isinstance(key, int):
            self.children[key] = value
        else:
            self.attributes[key] = value

    def __delitem__(self, key: str | int) -> None:
        if isinstance(key, int):
            del self.children[key]
        else:
            del self.attributes[key]

    def __contains__(self, key: str) -> bool:
        return key in self.attributes

    def get(self, key: str, default: Any = None) -> Any:
        return self.attributes.get(key, default)

    def setdefault(self, key: str, default: Any = None) -> Any:
        return self.attributes.setdefault(key, default)

    def __len__(self) -> int:
        return len(self.children)

    def __iadd__(self, other: Any) -> Element:
        if isinstance(other, Node):
            self.append(other)
        elif other is not None:
            self.extend(other)
        return self

    def section_hierarchy(self) -> list[Element]:
        sections: list[Element] = []
        node: Node | None = self
        while node is not None and node.parent is not None:
            if isinstance(node, section):
                sections.append(node)
            node = node.parent
        sections.reverse()
        return sections

    def append(self, item: Node) -> None:
        item.parent = self
        if self.document is not None:
            item.document = self.document
            if item.source is None:
                item.source = self.document.current_source
            if item.line is None:
                item.line = self.document.current_line
        self.children.append(item)

    def extend(self, items: list[Node]) -> None:
        for item in items:
            self.append(item)

    def insert(self, index: int, item: Node) -> None:
        item.parent = self
        if self.document is not None:
            item.document = self.document
            if item.source is None:
                item.source = self.document.current_source
            if item.line is None:
                item.line = self.document.current_line
        self.children.insert(index, item)

    def remove(self, item: Node) -> None:
        self.children.remove(item)

    def index(self, item: Node) -> int:
        return self.children.index(item)

    def replace_self(self, new_nodes: Node | list[Node]) -> None:
        if isinstance(new_nodes, Node):
            new_nodes = [new_nodes]
        if self.parent:
            idx = self.parent.children.index(self)
            self.parent.children[idx:idx + 1] = new_nodes
            for n in new_nodes:
                n.parent = self.parent

    def first_child_matching_class(self, childclass: type) -> int | None:
        for i, child in enumerate(self.children):
            if isinstance(child, childclass):
                return i
        return None

    def astext(self) -> str:
        return "".join(child.astext() for child in self.children)

    def pformat(self, indent: str = "    ", level: int = 0) -> str:
        res = [f"{indent * level}<{self.tagname}"]
        for k, v in sorted(self.attributes.items()):
            if v:
                res.append(f" {k}={v!r}")
        res.append(">\n")
        for child in self.children:
            if isinstance(child, Element):
                res.append(child.pformat(indent, level + 1))
            else:
                res.append(f"{indent * (level + 1)}{child!s}\n")
        return "".join(res)

    def copy(self) -> Element:
        e = self.__class__(self.rawsource, **self.attributes)
        return e

    def deepcopy(self) -> Element:
        e = self.__class__(self.rawsource, **{k: (v.copy() if hasattr(v, "copy") else v) for k, v in self.attributes.items()})
        e.children = [child.deepcopy() if hasattr(child, "deepcopy") else child for child in self.children]
        for child in e.children:
            child.parent = e
        return e


class TextElement(Element):
    def __init__(self, rawsource: str = "", text: str = "", *children: Node, **attributes: Any) -> None:
        if text:
            children = (Text(text),) + children
        super().__init__(rawsource, *children, **attributes)


class FixedTextElement(TextElement):
    pass


class PureTextElement(TextElement):
    pass


class Part(Element): pass
class Structural(Element): pass
class Body(Element): pass
class Inline(Element): pass
class Root(Element): pass


class document(Root, Structural):
    tagname = "document"

    def __init__(self, settings: Any = None, reporter: Any = None, *children: Node, **attributes: Any) -> None:
        super().__init__("", *children, **attributes)
        self._document = self
        self.settings = settings
        self.reporter = reporter
        self.current_source: str | None = None
        self.current_line: int | None = None
        self.ids: dict[str, Element] = {}
        self.names: dict[str, Element] = {}
        self.nameids: dict[str, str] = {}
        self.nametypes: dict[str, bool] = {}
        self.substitution_defs: dict[str, Element] = {}
        self.refnames: dict[str, list[Element]] = {}
        self.refids: dict[str, list[Element]] = {}
        self.indirect_targets: list[Element] = []
        self.substitution_names: dict[str, str] = {}
        self.autofootnotes: list[Element] = []
        self.autofootnote_refs: list[Element] = []
        self.symbol_footnotes: list[Element] = []
        self.symbol_footnote_refs: list[Element] = []
        self.footnotes: list[Element] = []
        self.citations: list[Element] = []

    def note_implicit_target(self, target: Element, msgnode: Element | None = None) -> None:
        for name in target.get("names", []):
            self.names[name] = target

    def set_id(self, node: Element, msgnode: Element | None = None) -> str:
        for id_candidate in node.get("ids", []):
            if id_candidate not in self.ids:
                self.ids[id_candidate] = node
                return id_candidate
        new_id = f"id{len(self.ids) + 1}"
        node["ids"].append(new_id)
        self.ids[new_id] = node
        return new_id

    def note_refname(self, node: Element) -> None:
        refname = node.get("refname")
        if refname:
            self.refnames.setdefault(refname, []).append(node)

    def note_refid(self, node: Element) -> None:
        refid = node.get("refid")
        if refid:
            self.refids.setdefault(refid, []).append(node)

    def note_footnote(self, node: Element) -> None:
        self.footnotes.append(node)

    def note_autofootnote(self, node: Element) -> None:
        self.autofootnotes.append(node)

    def note_autofootnote_ref(self, node: Element) -> None:
        self.autofootnote_refs.append(node)

    def note_citation(self, node: Element) -> None:
        self.citations.append(node)

    def note_substitution_def(self, node: Element, subname: str, msgnode: Element | None = None) -> None:
        self.substitution_defs[subname] = node

    def note_indirect_target(self, target: Element) -> None:
        self.indirect_targets.append(target)

    def set_name_id_mapping(self, node: Element, id_: str, msgnode: Element | None = None) -> None:
        for name in node.get("names", []):
            self.nameids[name] = id_

    def set_class_id(self, node: Element, class_id: str | None = None, msgnode: Element | None = None) -> None:
        pass

    def note_source(self, source: str | None, offset: int = -1) -> None:
        self.current_source = source
        if offset >= 0:
            self.current_line = offset

    def copy(self) -> document:
        doc = self.__class__(self.settings, self.reporter, **self.attributes)
        doc.current_source = self.current_source
        doc.current_line = self.current_line
        return doc


# Structural and Body elements
class section(Structural): tagname = "section"
class title(TextElement): tagname = "title"
class subtitle(TextElement): tagname = "subtitle"
class paragraph(TextElement): tagname = "paragraph"
class bullet_list(Body): tagname = "bullet_list"
class enumerated_list(Body): tagname = "enumerated_list"
class list_item(Part): tagname = "list_item"
class definition_list(Body): tagname = "definition_list"
class definition_list_item(Part): tagname = "definition_list_item"
class term(TextElement): tagname = "term"
class classifier(TextElement): tagname = "classifier"
class definition(Part): tagname = "definition"
class field_list(Body): tagname = "field_list"
class field(Part): tagname = "field"
class field_name(TextElement): tagname = "field_name"
class field_body(Part): tagname = "field_body"
class option_list(Body): tagname = "option_list"
class option_list_item(Part): tagname = "option_list_item"
class option_group(Part): tagname = "option_group"
class option(Part): tagname = "option"
class option_string(TextElement): tagname = "option_string"
class option_argument(TextElement): tagname = "option_argument"
class description(Part): tagname = "description"
class literal_block(FixedTextElement): tagname = "literal_block"
class doctest_block(FixedTextElement): tagname = "doctest_block"
class line_block(Body): tagname = "line_block"
class line(TextElement): tagname = "line"
class block_quote(Body): tagname = "block_quote"
class attribution(TextElement): tagname = "attribution"
class transition(Structural): tagname = "transition"
class table(Body): tagname = "table"
class tgroup(Part): tagname = "tgroup"
class colspec(Part): tagname = "colspec"
class thead(Part): tagname = "thead"
class tbody(Part): tagname = "tbody"
class row(Part): tagname = "row"
class entry(Part): tagname = "entry"
class footnote(Body): tagname = "footnote"
class citation(Body): tagname = "citation"
class label(TextElement): tagname = "label"
class target(Inline): tagname = "target"
class substitution_definition(Body): tagname = "substitution_definition"
class comment(Body): tagname = "comment"
class system_message(Body): tagname = "system_message"
class problematic(TextElement): tagname = "problematic"
class emphasis(Inline, TextElement): tagname = "emphasis"
class strong(Inline, TextElement): tagname = "strong"
class literal(Inline, TextElement): tagname = "literal"
class reference(Inline, TextElement): tagname = "reference"
class footnote_reference(Inline, TextElement): tagname = "footnote_reference"
class citation_reference(Inline, TextElement): tagname = "citation_reference"
class substitution_reference(Inline, TextElement): tagname = "substitution_reference"
class title_reference(Inline, TextElement): tagname = "title_reference"
class inline(Inline, TextElement): tagname = "inline"
class raw(FixedTextElement): tagname = "raw"
class pending(Element): tagname = "pending"
class image(Inline, Element): tagname = "image"
class figure(Body): tagname = "figure"
class caption(TextElement): tagname = "caption"
class legend(Part): tagname = "legend"
class rubric(TextElement): tagname = "rubric"
class topic(Structural): tagname = "topic"
class sidebar(Structural): tagname = "sidebar"
class admonition(Body): tagname = "admonition"
class attention(admonition): tagname = "attention"
class caution(admonition): tagname = "caution"
class danger(admonition): tagname = "danger"
class error(admonition): tagname = "error"
class hint(admonition): tagname = "hint"
class important(admonition): tagname = "important"
class note(admonition): tagname = "note"
class tip(admonition): tagname = "tip"
class warning(admonition): tagname = "warning"
class compound(Body): tagname = "compound"
class container(Body): tagname = "container"

# Bibliographic / Docinfo nodes
class docinfo(Structural): tagname = "docinfo"
class author(TextElement): tagname = "author"
class authors(Part): tagname = "authors"
class organization(TextElement): tagname = "organization"
class address(FixedTextElement): tagname = "address"
class contact(TextElement): tagname = "contact"
class version(TextElement): tagname = "version"
class revision(TextElement): tagname = "revision"
class status(TextElement): tagname = "status"
class date(TextElement): tagname = "date"
class copyright(TextElement): tagname = "copyright"

# Extra inline and structural nodes
class abbreviation(Inline, TextElement): tagname = "abbreviation"
class acronym(Inline, TextElement): tagname = "acronym"
class subscript(Inline, TextElement): tagname = "subscript"
class superscript(Inline, TextElement): tagname = "superscript"
class math(Inline, TextElement): tagname = "math"
class math_block(FixedTextElement): tagname = "math_block"
class meta(Inline, Element): tagname = "meta"
class generated(Inline, TextElement): tagname = "generated"
class decoration(Structural): tagname = "decoration"
class header(Part): tagname = "header"
class footer(Part): tagname = "footer"


class NodeVisitor:
    def __init__(self, document: document) -> None:
        self.document = document

    def dispatch_visit(self, node: Node) -> None:
        node_name = node.__class__.__name__
        method = getattr(self, f"visit_{node_name}", self.unknown_visit)
        method(node)

    def dispatch_departure(self, node: Node) -> None:
        node_name = node.__class__.__name__
        method = getattr(self, f"depart_{node_name}", self.unknown_departure)
        method(node)

    def unknown_visit(self, node: Node) -> None:
        pass

    def unknown_departure(self, node: Node) -> None:
        pass


class SparseNodeVisitor(NodeVisitor): pass
class GenericNodeVisitor(NodeVisitor): pass
class SkipNode(Exception): pass
class SkipChildren(Exception): pass
class SkipDeparture(Exception): pass


def fully_normalize_name(name: str) -> str:
    return " ".join(name.strip().lower().split())


def whitespace_normalize_name(name: str) -> str:
    return " ".join(name.strip().split())


def make_id(string: str) -> str:
    id_str = re.sub(r"[^\w.-]+", "-", string.lower())
    id_str = re.sub(r"^[^a-zA-Z]+", "", id_str)
    return id_str.strip("-") or "id"


def dupname(node: Element, name: str) -> None:
    node["dupnames"].append(name)
    if "name" in node:
        del node["name"]


def unescape(text: str, restore_backslashes: bool = False) -> str:
    return text


def split_name_list(s: str) -> list[str]:
    return [name.strip() for name in s.split()]


def serial_escape(text: str) -> str:
    return text.replace("\\", "\\\\")


def pseudo_quoteattr(value: str) -> str:
    return f'"{value}"'


node_class_names: set[str] = {
    cls_name for cls_name, cls_obj in globals().items()
    if isinstance(cls_obj, type) and issubclass(cls_obj, Node)
}
