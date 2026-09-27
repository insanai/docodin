"""Universal transforms."""

from __future__ import annotations

from docodin.shim.transforms import Transform


class Decorations(Transform):
    default_priority = 820


class Messages(Transform):
    default_priority = 860


class FilterMessages(Transform):
    default_priority = 870


class StripComments(Transform):
    default_priority = 890


class StripClassesAndElements(Transform):
    default_priority = 900


class SmartQuotes(Transform):
    default_priority = 850
