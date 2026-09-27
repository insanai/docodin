"""Docutils transforms drop-in implementation for docodin."""

from __future__ import annotations

from typing import Any


class Transform:
    """Base class for document tree transformations."""

    default_priority = 500

    def __init__(self, document: Any, startnode: Any = None) -> None:
        self.document = document
        self.startnode = startnode

    def apply(self, **kwargs: Any) -> None:
        pass


class Transformer:
    """Manages transforms for a document."""

    def __init__(self, document: Any) -> None:
        self.document = document
        self.applied: list[Any] = []
        self.transforms: list[tuple[int, type[Transform], Any, dict[str, Any]]] = []
        self.unknown_reference_resolvers: list[Any] = []

    def add_transform(self, transform_class: type[Transform], priority: int | None = None, **kwargs: Any) -> None:
        if priority is None:
            priority = transform_class.default_priority
        self.transforms.append((priority, transform_class, None, kwargs))

    def add_transforms(self, transform_classes: list[type[Transform]]) -> None:
        for tc in transform_classes:
            self.add_transform(tc)

    def apply_transforms(self) -> None:
        self.transforms.sort(key=lambda t: t[0])
        while self.transforms:
            priority, transform_class, startnode, kwargs = self.transforms.pop(0)
            transform = transform_class(self.document, startnode=startnode)
            transform.apply(**kwargs)
            self.applied.append((priority, transform_class, startnode, kwargs))
