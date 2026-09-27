"""Docutils document tree element class library (``docutils.nodes``).

The implementation is split into private modules; every public class and
function is re-exported here with ``__module__ == "docutils.nodes"``, so
reprs, pickles and ``isinstance`` checks behave as with docutils.
"""

from __future__ import annotations

from ._base import *  # noqa: F403
from ._base import (  # noqa: F401 - part of the docutils.nodes namespace
    ATTRIBUTE_VALIDATORS,
    _non_id_at_ends,
    _non_id_chars,
    _non_id_translate,
    _non_id_translate_digraphs,
)
from ._document import document  # noqa: F401 - part of the docutils.nodes namespace
from ._elements import *  # noqa: F403
from ._visitors import (  # noqa: F401 - part of the docutils.nodes namespace
    GenericNodeVisitor,
    NodeVisitor,
    SparseNodeVisitor,
    TreeCopyVisitor,
    _add_node_class_names,
    node_class_names,
)

__docformat__ = "reStructuredText"


def _adopt_public_names() -> None:
    namespace = globals()
    for name, value in list(namespace.items()):
        if name.startswith("__"):
            continue
        module = getattr(value, "__module__", "")
        if isinstance(module, str) and module.startswith(__name__ + "."):
            try:
                value.__module__ = __name__
            except (AttributeError, TypeError):
                pass


_adopt_public_names()
