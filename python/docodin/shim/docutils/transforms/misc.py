"""Miscellaneous transforms."""

from __future__ import annotations

from docutils import nodes
from docutils.transforms import Transform

__docformat__ = "reStructuredText"


class CallBack(Transform):
    """Call ``pending.details["callback"](pending)`` and remove the pending node."""

    default_priority = 990

    def apply(self) -> None:
        pending = self.startnode
        pending.details["callback"](pending)
        pending.parent.remove(pending)


class ClassAttribute(Transform):
    """Add the "class" directive's classes to the next suitable element."""

    default_priority = 210

    def apply(self) -> None:
        pending = self.startnode
        for element in pending.findall(include_self=False, descend=False, siblings=True,
                                       ascend=True):
            if isinstance(element, (nodes.Invisible, nodes.system_message)):
                continue
            element["classes"] += pending.details["class"]
            pending.parent.remove(pending)
            return
        error = self.document.reporter.error(
            'No suitable element following "%s" directive' % pending.details["directive"],
            nodes.literal_block(pending.rawsource, pending.rawsource), line=pending.line)
        pending.replace_self(error)


class Transitions(Transform):
    """Check transition placement; move trailing transitions up the tree."""

    default_priority = 830

    def apply(self) -> None:
        for node in self.document.findall(nodes.transition):
            self.visit_transition(node)

    def visit_transition(self, node: nodes.transition) -> None:
        index = self._check_placement(node)
        if not isinstance(node.parent, (nodes.document, nodes.section)):
            return
        assert index < len(node.parent)
        if index != len(node.parent) - 1:
            return
        sibling: nodes.Element = node
        while index == len(sibling.parent) - 1:
            sibling = sibling.parent
            if sibling.parent is None:  # at the document level
                warning = self.document.reporter.warning(
                    "Document may not end with a transition.", base_node=node)
                node.parent.append(warning)
                return
            index = sibling.parent.index(sibling)
        node.parent.remove(node)
        sibling.parent.insert(index + 1, node)

    def _check_placement(self, node: nodes.transition) -> int:
        """Warn about a misplaced transition; return its (new) index."""
        index = node.parent.index(node)
        previous_sibling = node.previous_sibling()
        msg = ""
        if not isinstance(node.parent, (nodes.document, nodes.section)):
            msg = "Transition must be child of <document> or <section>."
        elif index == 0 or isinstance(previous_sibling, (nodes.title, nodes.subtitle,
                                                         nodes.meta, nodes.decoration)):
            msg = "Document or section may not begin with a transition."
        elif isinstance(previous_sibling, nodes.transition):
            msg = ("At least one body element must separate transitions; "
                   "adjacent transitions are not allowed.")
        if not msg:
            return index
        warning = self.document.reporter.warning(msg, base_node=node)
        # insert the warning after the transition if the parent allows it
        node.parent[index] = nodes.paragraph()
        try:
            node.parent.validate(recursive=False)
        except nodes.ValidationError:
            node.parent[index] = node
        else:
            node.parent[index] = node
            node.parent.insert(index + 1, warning)
            index += 1
        return index
