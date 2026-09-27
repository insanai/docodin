"""References transforms."""

from __future__ import annotations

from docodin.shim.transforms import Transform


class Substitutions(Transform):
    default_priority = 220


class PropagateTargets(Transform):
    default_priority = 260


class AnonymousHyperlinks(Transform):
    default_priority = 440


class IndirectHyperlinks(Transform):
    default_priority = 460


class ExternalTargets(Transform):
    default_priority = 640


class InternalTargets(Transform):
    default_priority = 660


class Footnotes(Transform):
    default_priority = 620


class DanglingReferences(Transform):
    default_priority = 850
