"""Fast construction of docutils nodes for the tree builder.

``Element.__init__`` + ``extend()``/``setup_child()`` dominate tree building.
For a *fresh, unattached* node ``setup_child`` only sets ``child.parent``
(``document`` is None), so the helpers below build nodes that are
indistinguishable from constructor-built ones (same attributes, rawsource,
tagname, parent links).  Nodes are attached to the live tree with docutils'
own ``append`` so ``document``/``source``/``line`` propagation is unchanged.
"""

from __future__ import annotations

from typing import Any

from docutils import nodes

Text = nodes.Text

_object_new = object.__new__
_BASE_ATTS = ("ids", "classes", "names", "dupnames")
_BACKLINK_ATTS = _BASE_ATTS + ("backrefs",)
_str_new = str.__new__
_list_atts_cache: dict[type, tuple[str, ...]] = {}


def _text(data: str) -> nodes.Text:
    """``nodes.Text(data)`` (without the bytes/rawsource argument checks)."""
    return _str_new(Text, data)


def _element(cls: type, rawsource: str, children: list) -> Any:
    """``cls(rawsource, *children)`` for classes using ``Element.__init__``."""
    node = _object_new(cls)
    node.rawsource = rawsource
    node.children = children
    for child in children:
        child.parent = node
    atts = _list_atts_cache.get(cls)
    if atts is None:
        atts = _list_atts_cache[cls] = tuple(cls.list_attributes)
    if atts == _BASE_ATTS:
        node.attributes = {"ids": [], "classes": [], "names": [], "dupnames": []}
    elif atts == _BACKLINK_ATTS:
        node.attributes = {"ids": [], "classes": [], "names": [], "dupnames": [], "backrefs": []}
    else:
        node.attributes = {att: [] for att in atts}
    if cls.tagname is None:
        node.tagname = cls.__name__
    return node


def _text_element(cls: type, rawsource: str, text: str) -> Any:
    """``cls(rawsource, text)`` for ``TextElement`` subclasses."""
    return _element(cls, rawsource, [_str_new(Text, text)] if text else [])


def _fixed_text_element(cls: type, rawsource: str, text: str) -> Any:
    """``cls(rawsource, text)`` for ``FixedTextElement`` subclasses."""
    node = _element(cls, rawsource, [_str_new(Text, text)] if text else [])
    node.attributes["xml:space"] = "preserve"
    return node


def _append(parent: nodes.Element, child: nodes.Node) -> None:
    """``parent.append(child)`` (``Node.setup_child`` semantics, inlined)."""
    doc = parent._document
    if doc is not None:
        child.parent = parent
        child._document = doc
        if child.source is None:
            child.source = doc.current_source
        if child.line is None:
            child.line = doc.current_line
        parent.children.append(child)
    elif parent.parent is None:  # detached subtree under construction
        child.parent = parent
        parent.children.append(child)
    else:
        parent.append(child)


def _extend(parent: nodes.Element, children: list) -> None:
    for child in children:
        _append(parent, child)
