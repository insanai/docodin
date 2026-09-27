"""Transforms: tree-to-tree changes applied after parsing.

A `Transformer` collects the transforms required by the components and
the pending elements of a document and applies them in priority order.
"""

from __future__ import annotations

import warnings
from typing import Any

from docutils import ApplicationError, TransformSpec, languages

__docformat__ = "reStructuredText"


class TransformError(ApplicationError):
    pass


class Transform:
    """Base class of Docutils transforms."""

    default_priority: int | None = None

    def __init__(self, document: Any, startnode: Any = None) -> None:
        self.document = document
        self.startnode = startnode
        self.language = languages.get_language(document.settings.language_code,
                                               document.reporter)

    def apply(self, **kwargs: Any) -> None:
        raise NotImplementedError("subclass must override this method")


class Transformer(TransformSpec):
    """Store and apply transforms in priority order."""

    def __init__(self, document: Any) -> None:
        self.transforms: list[tuple[str, type[Transform], Any, dict[str, Any]]] = []
        self.unknown_reference_resolvers: list[Any] = []
        self.document = document
        self.applied: list[tuple[str, type[Transform], Any, dict[str, Any]]] = []
        self.sorted = False
        self.components: dict[str, Any] = {}
        self.serialno = 0

    def add_transform(self, transform_class: type[Transform], priority: int | None = None,
                      **kwargs: Any) -> None:
        """Store a single transform (with keyword arguments for `apply`)."""
        if priority is None:
            priority = transform_class.default_priority
        self.transforms.append((self.get_priority_string(priority), transform_class, None,
                                kwargs))
        self.sorted = False

    def add_transforms(self, transform_list: list[type[Transform]]) -> None:
        """Store multiple transforms with their default priorities."""
        for transform_class in transform_list:
            self.transforms.append((self.get_priority_string(transform_class.default_priority),
                                    transform_class, None, {}))
        self.sorted = False

    def add_pending(self, pending: Any, priority: int | None = None) -> None:
        """Store a transform attached to a `pending` element."""
        transform_class = pending.transform
        if priority is None:
            priority = transform_class.default_priority
        self.transforms.append((self.get_priority_string(priority), transform_class, pending,
                                {}))
        self.sorted = False

    def get_priority_string(self, priority: int) -> str:
        """Unique sortable key: priority plus a serial number (stable order)."""
        self.serialno += 1
        return "%03d-%03d" % (priority, self.serialno)

    def populate_from_components(self, components: Any) -> None:
        """Store the transforms and reference resolvers of each component."""
        resolvers: list[Any] = []
        for component in components:
            if not isinstance(component, TransformSpec):
                continue
            self.add_transforms(component.get_transforms())
            self.components[component.component_type] = component
            resolvers.extend(component.unknown_reference_resolvers)
        self.sorted = False
        resolvers.sort(key=lambda resolver: resolver.priority)
        self.unknown_reference_resolvers += resolvers
        if self.unknown_reference_resolvers:
            warnings.warn("The `unknown_reference_resolvers` hook chain will be removed in "
                          "Docutils 1.0.\nUse a transform to resolve references.",
                          DeprecationWarning, stacklevel=2)

    def apply_transforms(self) -> None:
        """Apply all stored transforms, lowest priority value first."""
        self.document.reporter.attach_observer(self.document.note_transform_message)
        while self.transforms:
            if not self.sorted:
                self.transforms.sort(reverse=True)
                self.sorted = True
            priority, transform_class, pending, kwargs = self.transforms.pop()
            transform = transform_class(self.document, startnode=pending)
            transform.apply(**kwargs)
            self.applied.append((priority, transform_class, pending, kwargs))
        self.document.reporter.detach_observer(self.document.note_transform_message)
