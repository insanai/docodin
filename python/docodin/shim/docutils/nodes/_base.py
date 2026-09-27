"""Base classes of the document tree: `Node`, `Text`, `Element` and mixins."""

from __future__ import annotations

import re
import sys
import unicodedata
import warnings
from collections.abc import Callable, Iterable, Iterator, Mapping
from typing import Any


class TreePruningException(Exception):
    """Base class of the exceptions that prune `Node.walk` traversals."""


class SkipChildren(TreePruningException):
    """Do not visit the children of the current node."""


class SkipSiblings(TreePruningException):
    """Do not visit the following siblings of the current node."""


class SkipNode(TreePruningException):
    """Skip the children and the ``depart_...`` call of the current node."""


class SkipDeparture(TreePruningException):
    """Do not call the ``depart_...`` method of the current node."""


class NodeFound(TreePruningException):
    """The target of a search has been found (caught by the caller)."""


class StopTraversal(TreePruningException):
    """Stop the traversal (departures of ancestors still run)."""


class ValidationError(ValueError):
    """Invalid Docutils Document Tree Element."""

    def __init__(self, msg: str, problematic_element: Any = None) -> None:
        super().__init__(msg)
        self.problematic_element = problematic_element


def _type_condition(cls: type) -> Callable[[Node], bool]:
    return lambda node: isinstance(node, cls)


class Node:
    """Abstract base class of nodes in a document tree."""

    parent: Element | None = None
    source: str | None = None
    line: int | None = None
    tagname: str
    children: Any
    _document: Any = None

    @property
    def document(self) -> Any:
        """The `document` root of the tree containing this node."""
        # ``self._document or self.parent.document``, without recursion
        node = self
        while True:
            document = node._document
            if document:
                return document
            node = node.parent
            if node is None:
                return None

    @document.setter
    def document(self, value: Any) -> None:
        self._document = value

    def __bool__(self) -> bool:
        return True

    def asdom(self, dom: Any = None) -> Any:
        """Return a DOM fragment representation of this node."""
        if dom is None:
            import xml.dom.minidom as dom
        return self._dom_node(dom.Document())

    def pformat(self, indent: str = "    ", level: int = 0) -> str:
        raise NotImplementedError

    def copy(self) -> Node:
        raise NotImplementedError

    def deepcopy(self) -> Node:
        raise NotImplementedError

    def astext(self) -> str:
        raise NotImplementedError

    def setup_child(self, child: Node) -> None:
        child.parent = self
        document = self.document
        if document:
            child.document = document
            if child.source is None:
                child.source = document.current_source
            if child.line is None:
                child.line = document.current_line

    def walk(self, visitor: Any) -> bool:
        """Traverse the tree calling ``visitor.dispatch_visit`` on entry.

        Return true if the traversal should stop.
        """
        reporter = visitor.document.reporter
        if getattr(reporter, "debug_flag", True):
            reporter.debug("docutils.nodes.Node.walk calling dispatch_visit for %s"
                           % self.__class__.__name__)
        try:
            try:
                visitor.dispatch_visit(self)
            except (SkipChildren, SkipNode):
                return False
            except SkipDeparture:
                pass
            try:
                for child in self.children[:]:
                    if child.walk(visitor):
                        return True
            except SkipSiblings:
                pass
        except StopTraversal:
            return True
        return False

    def walkabout(self, visitor: Any) -> bool:
        """Like `walk`, also calling ``visitor.dispatch_departure`` on exit."""
        call_depart = True
        stop = False
        # (the debug messages are only formatted when the reporter shows them)
        reporter = visitor.document.reporter
        if getattr(reporter, "debug_flag", True):
            reporter.debug("docutils.nodes.Node.walkabout calling dispatch_visit for %s"
                           % self.__class__.__name__)
        try:
            try:
                visitor.dispatch_visit(self)
            except SkipNode:
                return stop
            except SkipDeparture:
                call_depart = False
            try:
                for child in self.children[:]:
                    if child.walkabout(visitor):
                        stop = True
                        break
            except SkipSiblings:
                pass
        except SkipChildren:
            pass
        except StopTraversal:
            stop = True
        if call_depart:
            if getattr(reporter, "debug_flag", True):
                reporter.debug("docutils.nodes.Node.walkabout calling dispatch_departure for %s"
                               % self.__class__.__name__)
            visitor.dispatch_departure(self)
        return stop

    # The traversals below are the pre-order recursions
    #
    #     yield self; for child in self.children: yield from child.<traversal>()
    #
    # run on a stack of the children lists' iterators: nested generators cost
    # O(depth) per node.  Each list is iterated live and its iterator is
    # created after the parent has been yielded, as in the recursion, so
    # changes to the tree during the iteration have the same effect.

    def _fast_findall(self, cls: type, include_self: bool = True) -> Iterator[Node]:
        if include_self and isinstance(self, cls):
            yield self
        stack = [iter(self.children)]
        while stack:
            for node in stack[-1]:
                if isinstance(node, cls):
                    yield node
                children = node.children
                if children:
                    stack.append(iter(children))
                    break
            else:
                stack.pop()

    def _superfast_findall(self, include_self: bool = True) -> Iterator[Node]:
        if include_self:
            yield self
        stack = [iter(self.children)]
        while stack:
            for node in stack[-1]:
                yield node
                children = node.children
                if children:
                    stack.append(iter(children))
                    break
            else:
                stack.pop()

    def _predicate_findall(self, condition: Callable[[Node], bool],
                           include_self: bool = True) -> Iterator[Node]:
        if include_self and condition(self):
            yield self
        stack = [iter(self.children)]
        while stack:
            for node in stack[-1]:
                if condition(node):
                    yield node
                children = node.children
                if children:
                    stack.append(iter(children))
                    break
            else:
                stack.pop()

    def _descendants(self, condition: type | Callable[[Node], bool] | None,
                     include_self: bool) -> Iterator[Node]:
        """Pre-order traversal of `self` (if `include_self`) and its descendants."""
        if condition is None:
            return self._superfast_findall(include_self)
        if isinstance(condition, type):
            return self._fast_findall(condition, include_self)
        return self._predicate_findall(condition, include_self)

    def findall(self, condition: type | Callable[[Node], bool] | None = None,
                include_self: bool = True, descend: bool = True,
                siblings: bool = False, ascend: bool = False) -> Iterator[Node]:
        """Iterate over `self`, its descendants and (optionally) following nodes.

        ``condition`` is a node class or a predicate; ``ascend`` implies
        ``siblings``.  Nothing runs before the first item is requested.
        """
        if ascend:
            siblings = True
        if descend and not siblings:
            return self._descendants(condition, include_self)
        return self._findall(condition, include_self, descend, siblings, ascend)

    def _findall(self, condition: type | Callable[[Node], bool] | None, include_self: bool,
                 descend: bool, siblings: bool, ascend: bool) -> Iterator[Node]:
        if isinstance(condition, type):
            condition = _type_condition(condition)
        if descend:
            yield from self._descendants(condition, include_self)
        elif include_self and (condition is None or condition(self)):
            yield self
        if siblings:
            yield from self._following(condition, descend, ascend)

    def _following(self, condition: Callable[[Node], bool] | None, descend: bool,
                   ascend: bool) -> Iterator[Node]:
        node = self
        while node.parent:
            index = node.parent.index(node)
            while node.parent[index] is not node:
                index = node.parent.index(node, index + 1)
            for sibling in node.parent[index + 1:]:
                yield from sibling.findall(condition, True, descend, False, False)
            if not ascend:
                break
            node = node.parent

    def traverse(self, condition: type | Callable[[Node], bool] | None = None,
                 include_self: bool = True, descend: bool = True,
                 siblings: bool = False, ascend: bool = False) -> list[Node]:
        """Return `findall` as a list (obsolete)."""
        warnings.warn("nodes.Node.traverse() is obsoleted by Node.findall().",
                      DeprecationWarning, stacklevel=2)
        return list(self.findall(condition, include_self, descend, siblings, ascend))

    def next_node(self, condition: type | Callable[[Node], bool] | None = None,
                  include_self: bool = False, descend: bool = True,
                  siblings: bool = False, ascend: bool = False) -> Node | None:
        """First node of `findall` (``include_self`` defaults to False), or None."""
        return next(self.findall(condition, include_self, descend, siblings, ascend), None)

    def validate(self, recursive: bool = True) -> None:
        """Raise `ValidationError` if the node is invalid."""

    def validate_position(self) -> None:
        """Raise `ValidationError` if the node is at an invalid position."""


class Text(Node, str):
    """Terminal node containing (null-escaped) text only."""

    tagname = "#text"
    children = ()

    def __new__(cls, data: str, rawsource: None = None) -> Text:
        if isinstance(data, bytes):
            raise TypeError("expecting str data, not bytes")
        if rawsource is not None:
            warnings.warn('nodes.Text: initialization argument "rawsource" is ignored '
                          "and will be removed in Docutils 2.0.",
                          DeprecationWarning, stacklevel=2)
        return str.__new__(cls, data)

    def shortrepr(self, maxlen: int = 18) -> str:
        data = str(self)
        if len(data) > maxlen:
            data = data[:maxlen - 4] + " ..."
        return "<%s: %r>" % (self.tagname, data)

    def __repr__(self) -> str:
        return self.shortrepr(maxlen=68)

    def astext(self) -> str:
        return str(unescape(self))

    def _dom_node(self, domroot: Any) -> Any:
        return domroot.createTextNode(str(self))

    def copy(self) -> Text:
        return self.__class__(str(self))

    def deepcopy(self) -> Text:
        return self.copy()

    def pformat(self, indent: str = "    ", level: int = 0) -> str:
        try:
            if self.document.settings.detailed:
                lines = (indent * (level + 1) + repr(line) for line in self.splitlines(True))
                return "\n".join((indent * level + "<#text>", *lines)) + "\n"
        except AttributeError:
            pass
        lines = [indent * level + line for line in self.astext().splitlines()]
        return "\n".join(lines) + "\n" if lines else ""

    def rstrip(self, chars: str | None = None) -> Text:
        return self.__class__(str.rstrip(self, chars))

    def lstrip(self, chars: str | None = None) -> Text:
        return self.__class__(str.lstrip(self, chars))


def _value_text(value: Any) -> str:
    if isinstance(value, bool):
        return str(int(value))
    if isinstance(value, list):
        return " ".join(serial_escape("%s" % (item,)) for item in value)
    return str(value)


_BASIC_LIST_ATTRIBUTES = ("ids", "classes", "names", "dupnames")


class Element(Node):
    """Superclass of all elements: a list of children and a dict of attributes."""

    list_attributes: tuple[str, ...] = _BASIC_LIST_ATTRIBUTES
    valid_attributes: tuple[str, ...] = list_attributes + ("source",)
    common_attributes: tuple[str, ...] = valid_attributes
    known_attributes: tuple[str, ...] = common_attributes
    basic_attributes: tuple[str, ...] = list_attributes
    local_attributes: tuple[str, ...] = ("backrefs",)
    content_model: tuple = ()
    tagname: str | None = None
    child_text_separator = "\n\n"

    def __init__(self, rawsource: str = "", *children: Any, **attributes: Any) -> None:
        self.rawsource = rawsource
        if isinstance(rawsource, Element):
            raise TypeError('First argument "rawsource" must be a string.')
        self.children: list = []
        if children:
            self.extend(children)
        list_attributes = self.list_attributes
        if list_attributes is _BASIC_LIST_ATTRIBUTES:  # most elements: a literal is faster
            self.attributes: dict[str, Any] = {"ids": [], "classes": [], "names": [],
                                               "dupnames": []}
        else:
            self.attributes = {att: [] for att in list_attributes}
        for att, value in attributes.items():
            att = att.lower()
            self.attributes[att] = value[:] if att in list_attributes else value
        if self.tagname is None:
            self.tagname = self.__class__.__name__

    def _dom_node(self, domroot: Any) -> Any:
        element = domroot.createElement(self.tagname)
        for attribute, value in self.attlist():
            if isinstance(value, list):
                value = " ".join(serial_escape("%s" % (v,)) for v in value)
            element.setAttribute(attribute, "%s" % value)
        for child in self.children:
            element.appendChild(child._dom_node(domroot))
        return element

    def __repr__(self) -> str:
        data = ""
        for child in self.children:
            data += child.shortrepr()
            if len(data) > 60:
                data = data[:56] + " ..."
                break
        if self["names"]:
            return '<%s "%s": %s>' % (self.tagname, "; ".join(self["names"]), data)
        return "<%s: %s>" % (self.tagname, data)

    def shortrepr(self) -> str:
        if self["names"]:
            return '<%s "%s"...>' % (self.tagname, "; ".join(self["names"]))
        return "<%s...>" % self.tagname

    def __str__(self) -> str:
        if self.children:
            return "%s%s%s" % (self.starttag(), "".join(str(c) for c in self.children),
                               self.endtag())
        return self.emptytag()

    def starttag(self, quoteattr: Callable[[str], str] | None = None) -> str:
        quote = quoteattr or pseudo_quoteattr
        parts = [self.tagname]
        for name, value in self.attlist():
            if value is None:
                parts.append('%s="True"' % name)
            else:
                parts.append("%s=%s" % (name, quote(_value_text(value))))
        return "<%s>" % " ".join(parts)

    def endtag(self) -> str:
        return "</%s>" % self.tagname

    def emptytag(self) -> str:
        attributes = ('%s="%s"' % (n, v) for n, v in self.attlist())
        return "<%s/>" % " ".join((self.tagname, *attributes))

    def __len__(self) -> int:
        return len(self.children)

    def __contains__(self, key: Any) -> bool:
        if isinstance(key, str):
            return key in self.attributes
        return key in self.children

    def __getitem__(self, key: str | int | slice) -> Any:
        if isinstance(key, str):
            return self.attributes[key]
        if isinstance(key, int):
            return self.children[key]
        if isinstance(key, slice):
            assert key.step in (None, 1), "cannot handle slice with stride"
            return self.children[key.start:key.stop]
        raise TypeError("element index must be an integer, a slice, or an attribute name string")

    def __setitem__(self, key: str | int | slice, item: Any) -> None:
        if isinstance(key, str):
            self.attributes[str(key)] = item
        elif isinstance(key, int):
            self.setup_child(item)
            self.children[key] = item
        elif isinstance(key, slice):
            assert key.step in (None, 1), "cannot handle slice with stride"
            for node in item:
                self.setup_child(node)
            self.children[key.start:key.stop] = item
        else:
            raise TypeError(
                "element index must be an integer, a slice, or an attribute name string")

    def __delitem__(self, key: str | int | slice) -> None:
        if isinstance(key, str):
            del self.attributes[key]
        elif isinstance(key, int):
            del self.children[key]
        elif isinstance(key, slice):
            assert key.step in (None, 1), "cannot handle slice with stride"
            del self.children[key.start:key.stop]
        else:
            raise TypeError(
                "element index must be an integer, a simple slice, or an attribute name string")

    def __add__(self, other: list) -> list:
        return self.children + other

    def __radd__(self, other: list) -> list:
        return other + self.children

    def __iadd__(self, other: Any) -> Element:
        if isinstance(other, Node):
            self.append(other)
        elif other is not None:
            self.extend(other)
        return self

    def astext(self) -> str:
        return self.child_text_separator.join([child.astext() for child in self.children])

    def non_default_attributes(self) -> dict[str, Any]:
        return {key: value for key, value in self.attributes.items()
                if self.is_not_default(key)}

    def attlist(self) -> list[tuple[str, Any]]:
        return sorted(self.non_default_attributes().items())

    def get(self, key: str, failobj: Any = None) -> Any:
        return self.attributes.get(key, failobj)

    def hasattr(self, attr: str) -> bool:
        return attr in self.attributes

    has_key = hasattr

    def delattr(self, attr: str) -> None:
        if attr in self.attributes:
            del self.attributes[attr]

    def setdefault(self, key: str, failobj: Any = None) -> Any:
        return self.attributes.setdefault(key, failobj)

    def get_language_code(self, fallback: str = "") -> str:
        """Language tag from a ``language-*`` class of self or an ancestor."""
        for cls in self.get("classes", []):
            if cls.startswith("language-"):
                return cls.removeprefix("language-")
        try:
            return self.parent.get_language_code(fallback)
        except AttributeError:
            return fallback

    def append(self, item: Node) -> None:
        self.setup_child(item)
        self.children.append(item)

    def extend(self, item: Iterable[Node]) -> None:
        for node in item:
            self.append(node)

    def insert(self, index: int, item: Any) -> None:
        if isinstance(item, Node):
            self.setup_child(item)
            self.children.insert(index, item)
        elif item is not None:
            self[index:index] = item

    def pop(self, i: int = -1) -> Node:
        return self.children.pop(i)

    def remove(self, item: Node) -> None:
        self.children.remove(item)

    def index(self, item: Node, start: int = 0, stop: int = sys.maxsize) -> int:
        return self.children.index(item, start, stop)

    def previous_sibling(self) -> Node | None:
        """Return the preceding sibling or None."""
        try:
            i = self.parent.index(self)
        except AttributeError:
            return None
        return self.parent[i - 1] if i > 0 else None

    def section_hierarchy(self) -> list[Element]:
        """The <section> ancestors of self (and self), outermost first."""
        from docutils.nodes import section

        sections = []
        node: Node = self
        while node.parent is not None:
            if isinstance(node, section):
                sections.append(node)
            node = node.parent
        sections.reverse()
        return sections

    def is_not_default(self, key: str) -> bool:
        return not (self[key] == [] and key in self.list_attributes)

    def update_basic_atts(self, dict_: Mapping[str, Any] | Element) -> None:
        """Append the basic list attributes of `dict_` (a node or dict)."""
        if isinstance(dict_, Node):
            dict_ = dict_.attributes
        for att in self.basic_attributes:
            self.append_attr_list(att, dict_.get(att, []))

    def append_attr_list(self, attr: str, values: Iterable[Any]) -> None:
        for value in values:
            if value not in self[attr]:
                self[attr].append(value)

    def coerce_append_attr_list(self, attr: str, value: Any) -> None:
        if not isinstance(self.get(attr), list):
            self[attr] = [self[attr]]
        if not isinstance(value, list):
            value = [value]
        self.append_attr_list(attr, value)

    def replace_attr(self, attr: str, value: Any, force: bool = True) -> None:
        if force or self.get(attr) is None:
            self[attr] = value

    def copy_attr_convert(self, attr: str, value: Any, replace: bool = True) -> None:
        if self.get(attr) is not value:
            self.coerce_append_attr_list(attr, value)

    def copy_attr_coerce(self, attr: str, value: Any, replace: bool) -> None:
        if self.get(attr) is not value:
            if isinstance(self.get(attr), list) or isinstance(value, list):
                self.coerce_append_attr_list(attr, value)
            else:
                self.replace_attr(attr, value, replace)

    def copy_attr_concatenate(self, attr: str, value: Any, replace: bool) -> None:
        if self.get(attr) is not value:
            if isinstance(self.get(attr), list) and isinstance(value, list):
                self.append_attr_list(attr, value)
            else:
                self.replace_attr(attr, value, replace)

    def copy_attr_consistent(self, attr: str, value: Any, replace: bool) -> None:
        if self.get(attr) is not value:
            self.replace_attr(attr, value, replace)

    def update_all_atts(self, dict_: Mapping[str, Any] | Element,
                        update_fun: Callable = copy_attr_consistent,
                        replace: bool = True, and_source: bool = False) -> None:
        """Merge all attributes of `dict_` into self using `update_fun`."""
        if isinstance(dict_, Node):
            dict_ = dict_.attributes
        keep = self.is_not_list_attribute if and_source else self.is_not_known_attribute
        self.update_basic_atts(dict_)
        for att in filter(keep, dict_):
            update_fun(self, att, dict_[att], replace)

    def update_all_atts_consistantly(self, dict_: Mapping[str, Any] | Element,
                                     replace: bool = True, and_source: bool = False) -> None:
        self.update_all_atts(dict_, Element.copy_attr_consistent, replace, and_source)

    def update_all_atts_concatenating(self, dict_: Mapping[str, Any] | Element,
                                      replace: bool = True, and_source: bool = False) -> None:
        self.update_all_atts(dict_, Element.copy_attr_concatenate, replace, and_source)

    def update_all_atts_coercion(self, dict_: Mapping[str, Any] | Element,
                                 replace: bool = True, and_source: bool = False) -> None:
        self.update_all_atts(dict_, Element.copy_attr_coerce, replace, and_source)

    def update_all_atts_convert(self, dict_: Mapping[str, Any] | Element,
                                and_source: bool = False) -> None:
        self.update_all_atts(dict_, Element.copy_attr_convert, and_source=and_source)

    def clear(self) -> None:
        self.children = []

    def replace(self, old: Node, new: Any) -> None:
        """Replace child `old` by a node or a list of nodes."""
        index = self.index(old)
        if isinstance(new, Node):
            self.setup_child(new)
            self[index] = new
        elif new is not None:
            self[index:index + 1] = new

    def replace_self(self, new: Any) -> None:
        """Replace self by a node or a list of nodes (keeping basic attributes)."""
        update = new
        if not isinstance(new, Node):
            try:
                update = new[0]
            except IndexError:
                update = None
        if isinstance(update, Element):
            update.update_basic_atts(self)
        else:
            for att in self.basic_attributes:
                assert not self[att], 'Losing "%s" attribute: %s' % (att, self[att])
        self.parent.replace(self, new)

    def first_child_matching_class(self, childclass: type | tuple[type, ...], start: int = 0,
                                   end: int = sys.maxsize) -> int | None:
        """Index of the first child that is an instance of `childclass`."""
        for index in range(start, min(len(self), end)):
            if isinstance(self[index], childclass):
                return index
        return None

    def first_child_not_matching_class(self, childclass: type | tuple[type, ...],
                                       start: int = 0, end: int = sys.maxsize) -> int | None:
        """Index of the first child that is not an instance of `childclass`."""
        for index in range(start, min(len(self), end)):
            if not isinstance(self.children[index], childclass):
                return index
        return None

    def pformat(self, indent: str = "    ", level: int = 0) -> str:
        tagline = "%s%s\n" % (indent * level, self.starttag())
        return "".join((tagline, *(c.pformat(indent, level + 1) for c in self.children)))

    def copy(self) -> Element:
        obj = self.__class__(rawsource=self.rawsource, **self.attributes)
        obj._document = self._document
        obj.source = self.source
        obj.line = self.line
        return obj

    def deepcopy(self) -> Element:
        copy = self.copy()
        copy.extend([child.deepcopy() for child in self.children])
        return copy

    def note_referenced_by(self, name: str | None = None, id: str | None = None) -> None:
        """Note that this element is referenced by name `name` or id `id`."""
        self.referenced = True
        by_name = getattr(self, "expect_referenced_by_name", {}).get(name)
        by_id = getattr(self, "expect_referenced_by_id", {}).get(id)
        if by_name:
            by_name.referenced = True
        if by_id:
            by_id.referenced = True

    @classmethod
    def is_not_list_attribute(cls, attr: str) -> bool:
        return attr not in cls.list_attributes

    @classmethod
    def is_not_known_attribute(cls, attr: str) -> bool:
        return attr not in cls.common_attributes

    def validate_attributes(self) -> None:
        """Normalize attribute values; raise `ValidationError` for invalid ones."""
        messages = []
        for key, value in self.attributes.items():
            if key.startswith("internal:"):
                continue
            if key not in self.valid_attributes:
                valid = '", "'.join(self.valid_attributes)
                messages.append(f'Attribute "{key}" not one of "{valid}".')
                continue
            try:
                self.attributes[key] = ATTRIBUTE_VALIDATORS[key](value)
            except (ValueError, TypeError, KeyError) as error:
                messages.append(f'Attribute "{key}" has invalid value "{value}".\n  {error}')
        if messages:
            raise ValidationError(f"Element {self.starttag()} invalid:\n  "
                                  + "\n  ".join(messages), problematic_element=self)

    def validate_content(self, model: tuple | None = None,
                         elements: Iterable[Node] | None = None) -> list[Node]:
        """Check `elements` against `model`; return the children left over.

        Raise `ValidationError` when a required child is missing.
        """
        if model is None:
            model = self.content_model
        ichildren = iter(self.children if elements is None else elements)
        child = next(ichildren, None)
        for category, quantifier in model:
            if not isinstance(child, category):
                if quantifier in (".", "+"):
                    raise ValidationError(self._report_child(child, category),
                                          problematic_element=child)
                continue
            child.validate_position()
            if quantifier in (".", "?"):
                child = next(ichildren, None)
            else:
                child = _skip_matching(ichildren, category)
        return [] if child is None else [child, *ichildren]

    def _report_child(self, child: Node | None, category: Any) -> str:
        try:
            expected = category.__name__
        except AttributeError:
            expected = "> or <".join(c.__name__ for c in category)
        msg = f"Element {self.starttag()} invalid:\n"
        if child is None:
            return f"{msg}  Missing child of type <{expected}>."
        if isinstance(child, Text):
            return (f"{msg}  Expecting child of type <{expected}>, "
                    f'not text data "{child.astext()}".')
        return f"{msg}  Expecting child of type <{expected}>, not {child.starttag()}."

    def validate(self, recursive: bool = True) -> None:
        """Validate this element (and its descendants if `recursive`)."""
        self.validate_attributes()
        for child in self.validate_content():
            if isinstance(child, Text):
                raise ValidationError(f"Element {self.starttag()} invalid:\n"
                                      f'  Spurious text: "{child.astext()}".',
                                      problematic_element=self)
            raise ValidationError(f"Element {self.starttag()} invalid:\n"
                                  f"  Child element {child.starttag()} not allowed at this "
                                  "position.", problematic_element=child)
        if recursive:
            for child in self:
                child.validate(recursive=recursive)


def _skip_matching(ichildren: Iterator[Node], category: Any) -> Node | None:
    """Consume the children matching `category`; return the first other one."""
    for child in ichildren:
        if not isinstance(child, category):
            return child
        try:
            child.validate_position()
        except AttributeError:
            pass
    return None


# --- element categories ---------------------------------------------------------------


class Root:
    """Element at the root of a document tree."""


class Structural:
    """Structural elements."""


class SubStructural:
    """Structural subelements (children of `Structural` elements)."""


class Bibliographic:
    """Bibliographic elements (displayed document meta-data)."""


class Body:
    """Body elements."""


class Admonition(Body):
    """Admonitions (distinctive and self-contained notices)."""

    content_model = ((Body, "+"),)


class Sequential(Body):
    """List-like body elements."""


class General(Body):
    """Miscellaneous body elements."""


class Special(Body):
    """Special internal body elements."""


class Part:
    """Body subelements (always within specific parent elements)."""


class Decorative:
    """Decorative elements (`header` and `footer`)."""

    content_model = ((Body, "+"),)


class Inline:
    """Inline elements."""


class PreBibliographic:
    """Elements which may occur before Bibliographic Elements."""


class Invisible(Special, PreBibliographic):
    """Internal elements that don't appear in output."""


class Labeled:
    """Contains a `label` as its first element."""


class Resolvable:
    resolved: bool = False


class BackLinkable:
    """Mixin for elements that accept a "backrefs" attribute."""

    list_attributes = Element.list_attributes + ("backrefs",)
    valid_attributes = Element.valid_attributes + ("backrefs",)

    def add_backref(self: Any, refid: str) -> None:
        self["backrefs"].append(refid)


class Referential(Resolvable):
    """Elements holding a cross-reference (outgoing hyperlink)."""


class Targetable(Resolvable):
    """Cross-reference targets (incoming hyperlink)."""

    referenced: int = 0
    indirect_reference_name: str | None = None


class Titular:
    """Title, sub-title, or informal heading (rubric)."""


class TextElement(Element):
    """An element which directly contains text (and inline elements)."""

    content_model = (((Text, Inline), "*"),)
    child_text_separator = ""

    def __init__(self, rawsource: str = "", text: str = "", *children: Any,
                 **attributes: Any) -> None:
        if text:
            Element.__init__(self, rawsource, Text(text), *children, **attributes)
        else:
            Element.__init__(self, rawsource, *children, **attributes)


class FixedTextElement(TextElement):
    """An element which directly contains preformatted text."""

    valid_attributes = Element.valid_attributes + ("xml:space",)

    def __init__(self, rawsource: str = "", text: str = "", *children: Any,
                 **attributes: Any) -> None:
        super().__init__(rawsource, text, *children, **attributes)
        self.attributes["xml:space"] = "preserve"


class PureTextElement(TextElement):
    """An element which only contains text, no children."""

    content_model = ((Text, "?"),)


# --- helper functions ------------------------------------------------------------------


def unescape(text: str, restore_backslashes: bool = False,
             respect_whitespace: bool = False) -> str:
    """Remove null-escapes (or restore them to backslashes)."""
    if restore_backslashes:
        return text.replace("\x00", "\\")
    if "\x00" not in text:
        return str(text)  # a plain copy, like the joins below
    for sep in ("\x00 ", "\x00\n", "\x00"):
        text = "".join(text.split(sep))
    return text


_non_id_chars = re.compile("[^a-z0-9]+")
_non_id_at_ends = re.compile("^[-0-9]+|-+$")
_non_id_translate = {
    0x00F8: "o", 0x0111: "d", 0x0127: "h", 0x0131: "i", 0x0142: "l", 0x0167: "t",
    0x0180: "b", 0x0183: "b", 0x0188: "c", 0x018C: "d", 0x0192: "f", 0x0199: "k",
    0x019A: "l", 0x019E: "n", 0x01A5: "p", 0x01AB: "t", 0x01AD: "t", 0x01B4: "y",
    0x01B6: "z", 0x01E5: "g", 0x0225: "z", 0x0234: "l", 0x0235: "n", 0x0236: "t",
    0x0237: "j", 0x023C: "c", 0x023F: "s", 0x0240: "z", 0x0247: "e", 0x0249: "j",
    0x024B: "q", 0x024D: "r", 0x024F: "y",
}
_non_id_translate_digraphs = {
    0x00DF: "sz", 0x00E6: "ae", 0x0153: "oe", 0x0238: "db", 0x0239: "qp",
}


def make_id(string: str) -> str:
    """Convert `string` into an identifier matching ``[a-z](-?[a-z0-9]+)*``."""
    id = string.lower()
    id = id.translate(_non_id_translate_digraphs)
    id = id.translate(_non_id_translate)
    id = unicodedata.normalize("NFKD", id).encode("ascii", "ignore").decode("ascii")
    id = _non_id_chars.sub("-", " ".join(id.split()))
    return str(_non_id_at_ends.sub("", id))


def dupname(node: Element, name: str) -> None:
    node["dupnames"].append(name)
    node["names"].remove(name)
    node.referenced = True


def fully_normalize_name(name: str) -> str:
    """Return a case- and whitespace-normalized name."""
    return " ".join(name.lower().split())


def whitespace_normalize_name(name: str) -> str:
    """Return a whitespace-normalized name."""
    return " ".join(name.split())


def serial_escape(value: str) -> str:
    """Escape string values that are elements of a list, for serialization."""
    return value.replace("\\", r"\\").replace(" ", r"\ ")


def split_name_list(s: str) -> list[str]:
    """Split at non-escaped whitespace (inverse of `serial_escape`)."""
    s = s.replace("\\", "\x00").replace("\x00\x00", "\\").replace("\x00 ", "\x00\x00")
    return [name.replace("\x00\x00", " ").replace("\x00", "") for name in s.split(" ")]


def pseudo_quoteattr(value: str) -> str:
    """Quote attributes for pseudo-xml."""
    return '"%s"' % value


def parse_measure(measure: str, unit_pattern: str = "[a-zA-Zµ]*|%?") -> tuple[int | float, str]:
    """Parse a measure (number + unit)."""
    match = re.fullmatch(f"(-?[0-9.]+) *({unit_pattern})", measure)
    try:
        try:
            value: int | float = int(match.group(1))
        except ValueError:
            value = float(match.group(1))
        unit = match.group(2)
    except (AttributeError, ValueError):
        raise ValueError(f'"{measure}" is no valid measure.') from None
    return value, unit


def create_keyword_validator(*keywords: str) -> Callable[[str], str]:
    """Return a validator accepting only the given keywords."""
    def validate_keywords(value: str) -> str:
        if value not in keywords:
            allowed = '", "'.join(keywords)
            raise ValueError(f'"{value}" is not one of "{allowed}".')
        return value
    return validate_keywords


def validate_identifier(value: str) -> str:
    if value != make_id(value):
        raise ValueError(f'"{value}" is no valid id or class name.')
    return value


def validate_identifier_list(value: str | list[str]) -> list[str]:
    if isinstance(value, str):
        value = value.split()
    for token in value:
        validate_identifier(token)
    return value


def validate_measure(measure: str) -> str:
    value, unit = parse_measure(measure)
    return f"{value}{unit}"


def validate_colwidth(measure: str | int | float) -> int | float:
    if isinstance(measure, (int, float)):
        value = measure
    elif measure in ("*", ""):
        value = 1
    else:
        try:
            value, _unit = parse_measure(measure, unit_pattern="[*]?")
        except ValueError:
            value = -1
    if value <= 0:
        raise ValueError(f'"{measure}" is no proportional measure.')
    return value


def validate_NMTOKEN(value: str) -> str:  # noqa: N802 - docutils name
    if not re.fullmatch("[-._A-Za-z0-9]+", value):
        raise ValueError(f'"{value}" is no NMTOKEN.')
    return value


def validate_NMTOKENS(value: str | list[str]) -> list[str]:  # noqa: N802 - docutils name
    if isinstance(value, str):
        value = value.split()
    for token in value:
        validate_NMTOKEN(token)
    return value


def validate_refname_list(value: str | list[str]) -> list[str]:
    if isinstance(value, str):
        value = split_name_list(value)
    return [whitespace_normalize_name(name) for name in value]


def validate_yesorno(value: str | int | bool) -> bool:
    return False if value == "0" else bool(value)


ATTRIBUTE_VALIDATORS: dict[str, Callable[[Any], Any]] = {
    "alt": str, "align": str, "anonymous": validate_yesorno, "auto": str,
    "backrefs": validate_identifier_list, "bullet": str, "classes": validate_identifier_list,
    "char": str, "charoff": validate_NMTOKEN, "colname": validate_NMTOKEN, "colnum": int,
    "cols": int, "colsep": validate_yesorno, "colwidth": validate_colwidth, "content": str,
    "delimiter": str, "dir": create_keyword_validator("ltr", "rtl", "auto"),
    "dupnames": validate_refname_list,
    "enumtype": create_keyword_validator("arabic", "loweralpha", "lowerroman", "upperalpha",
                                         "upperroman"),
    "format": str,
    "frame": create_keyword_validator("top", "bottom", "topbot", "all", "sides", "none"),
    "height": validate_measure, "http-equiv": str, "ids": validate_identifier_list,
    "lang": str, "level": int, "line": int, "ltrim": validate_yesorno,
    "loading": create_keyword_validator("embed", "link", "lazy"), "media": str,
    "morecols": int, "morerows": int, "name": whitespace_normalize_name,
    "names": validate_refname_list, "namest": validate_NMTOKEN, "nameend": validate_NMTOKEN,
    "pgwide": validate_yesorno, "prefix": str, "refid": validate_identifier,
    "refname": whitespace_normalize_name, "refuri": str, "rowsep": validate_yesorno,
    "rtrim": validate_yesorno, "scale": int, "scheme": str, "source": str, "start": int,
    "stub": validate_yesorno, "suffix": str, "title": str, "type": validate_NMTOKEN,
    "uri": str, "valign": create_keyword_validator("top", "middle", "bottom"),
    "width": validate_measure, "xml:space": create_keyword_validator("default", "preserve"),
}
