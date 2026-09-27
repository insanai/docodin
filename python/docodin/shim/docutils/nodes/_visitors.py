"""Visitor base classes for document tree traversals."""

from __future__ import annotations

from typing import Any

node_class_names = """
    Text
    abbreviation acronym address admonition attention attribution author authors
    block_quote bullet_list
    caption caution citation citation_reference classifier colspec comment compound
        contact container copyright
    danger date decoration definition definition_list definition_list_item description
        docinfo doctest_block document
    emphasis entry enumerated_list error
    field field_body field_list field_name figure footer footnote footnote_reference
    generated
    header hint
    image important inline
    label legend line line_block list_item literal literal_block
    math math_block meta
    note
    option option_argument option_group option_list option_list_item option_string
        organization
    paragraph pending problematic
    raw reference revision row rubric
    section sidebar status strong subscript substitution_definition substitution_reference
        subtitle superscript system_message
    table target tbody term tgroup thead tip title title_reference topic transition
    version
    warning""".split()


class NodeVisitor:
    """Visitor dispatching to ``visit_<class>`` / ``depart_<class>`` methods.

    Unknown node types raise `NotImplementedError` unless listed in `optional`.
    """

    optional: tuple[str, ...] = ("meta",)

    def __init__(self, document: Any, /) -> None:
        self.document = document

    # The debug messages are only formatted when the reporter shows them
    # (``Reporter.debug`` does nothing otherwise).

    def dispatch_visit(self, node: Any) -> Any:
        node_name = node.__class__.__name__
        method = getattr(self, "visit_" + node_name, self.unknown_visit)
        reporter = self.document.reporter
        if getattr(reporter, "debug_flag", True):
            reporter.debug("docutils.nodes.NodeVisitor.dispatch_visit calling %s for %s"
                           % (method.__name__, node_name))
        return method(node)

    def dispatch_departure(self, node: Any) -> Any:
        node_name = node.__class__.__name__
        method = getattr(self, "depart_" + node_name, self.unknown_departure)
        reporter = self.document.reporter
        if getattr(reporter, "debug_flag", True):
            reporter.debug("docutils.nodes.NodeVisitor.dispatch_departure calling %s for %s"
                           % (method.__name__, node_name))
        return method(node)

    def unknown_visit(self, node: Any) -> None:
        if (self.document.settings.strict_visitor
                or node.__class__.__name__ not in self.optional):
            raise NotImplementedError("%s visiting unknown node type: %s"
                                      % (self.__class__, node.__class__.__name__))

    def unknown_departure(self, node: Any) -> None:
        if (self.document.settings.strict_visitor
                or node.__class__.__name__ not in self.optional):
            raise NotImplementedError("%s departing unknown node type: %s"
                                      % (self.__class__, node.__class__.__name__))


class SparseNodeVisitor(NodeVisitor):
    """Visitor whose methods do nothing by default (sparse traversals)."""


class GenericNodeVisitor(NodeVisitor):
    """Visitor calling `default_visit` / `default_departure` for every node."""

    def default_visit(self, node: Any) -> None:
        raise NotImplementedError

    def default_departure(self, node: Any) -> None:
        raise NotImplementedError


def _call_default_visit(self: GenericNodeVisitor, node: Any) -> None:
    self.default_visit(node)


def _call_default_departure(self: GenericNodeVisitor, node: Any) -> None:
    self.default_departure(node)


def _nop(self: SparseNodeVisitor, node: Any) -> None:
    pass


def _add_node_class_names(names: list[str]) -> None:
    for name in names:
        setattr(GenericNodeVisitor, "visit_" + name, _call_default_visit)
        setattr(GenericNodeVisitor, "depart_" + name, _call_default_departure)
        setattr(SparseNodeVisitor, "visit_" + name, _nop)
        setattr(SparseNodeVisitor, "depart_" + name, _nop)


_add_node_class_names(node_class_names)


class TreeCopyVisitor(GenericNodeVisitor):
    """Make a complete copy of a tree or branch, including attributes."""

    def __init__(self, document: Any) -> None:
        super().__init__(document)
        self.parent_stack: list[Any] = []
        self.parent: Any = []

    def get_tree_copy(self) -> Any:
        return self.parent[0]

    def default_visit(self, node: Any) -> None:
        newnode = node.copy()
        self.parent.append(newnode)
        self.parent_stack.append(self.parent)
        self.parent = newnode

    def default_departure(self, node: Any) -> None:
        self.parent = self.parent_stack.pop()
