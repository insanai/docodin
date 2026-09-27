"""When the reStructuredText parser runs the Python state machine.

docodin's native engine implements the stock grammar of `states`.  It cannot
see what an extension changes in Python, so a parse falls back to the pure
Python state machine when

* the state classes are not the stock ones (custom ``state_classes``, a
  subclass of a state, another initial state, a custom ``Inliner`` class);
* an extension replaced or wrapped a method or changed a pattern of a stock
  state class or of ``Inliner`` since the module was loaded (`Snapshot`), except the
  transitions the native builder replays (``Body.doctest``, ``Text.indent``);
* ``DOCODIN_NATIVE=0`` is set in the environment (Python everywhere).
"""

from __future__ import annotations

import os
import re
from types import SimpleNamespace
from typing import Any

# Transitions whose replacements the native builder runs on the constructs it
# built (see `docodin._machine.replay_transition`): sphinx-autodoc-typehints
# replaces ``Body.doctest`` and wraps ``Text.indent``.
REPLAYED = frozenset({("Body", "doctest"), ("Text", "indent")})

# Class attributes that change at run time without changing the grammar.
_VOLATILE = frozenset({"nested_sm_cache", "__doc__", "__weakref__", "__dict__"})
# ``StateWS`` adds its whitespace patterns to the class-level ``patterns``.
_WS_PATTERNS = {"blank": " *$", "indent": " +"}


def python_forced() -> bool:
    """``DOCODIN_NATIVE=0``: parse everything with the Python state machine."""
    return os.environ.get("DOCODIN_NATIVE") == "0"


def _fingerprint(value: Any) -> Any:
    """A comparable summary of a class attribute (patterns compile lazily)."""
    if isinstance(value, re.Pattern):
        return ("re", value.pattern)
    if isinstance(value, str):
        return ("re", value)
    if isinstance(value, dict):
        items = [(key, _fingerprint(item)) for key, item in value.items()
                 if _WS_PATTERNS.get(key) != getattr(item, "pattern", item)]
        return ("dict", tuple(sorted(items, key=lambda pair: repr(pair[0]))))
    if isinstance(value, (list, tuple)) or type(value).__name__ == "dict_keys":
        return ("seq", tuple(_fingerprint(item) for item in value))
    if isinstance(value, SimpleNamespace):
        return ("ns", _fingerprint(vars(value)))
    return value


class Snapshot:
    """The attributes of the stock state classes as the module defined them."""

    def __init__(self, classes: list[type]) -> None:
        self.originals: dict[type, dict[str, Any]] = {
            cls: {name: value for name, value in vars(cls).items() if name not in _VOLATILE}
            for cls in classes}
        self.fingerprints = {
            cls: {name: _fingerprint(value) for name, value in attributes.items()}
            for cls, attributes in self.originals.items()}

    def original(self, cls: type, name: str) -> Any:
        """The stock attribute `name` of `cls` (inherited ones included)."""
        for klass in cls.__mro__:
            attributes = self.originals.get(klass)
            if attributes is not None and name in attributes:
                return attributes[name]
        return getattr(cls, name)

    def changes(self) -> set[tuple[str, str]]:
        """(class name, attribute) of every attribute changed since the snapshot."""
        changed = set()
        for cls, fingerprints in self.fingerprints.items():
            current = {name: value for name, value in vars(cls).items()
                       if name not in _VOLATILE}
            for name in fingerprints.keys() | current.keys():
                if name not in current or name not in fingerprints:
                    changed.add((cls.__name__, name))
                    continue
                value = current[name]
                if value is self.originals[cls][name]:
                    if not isinstance(value, (dict, list, SimpleNamespace)):
                        continue
                if _fingerprint(value) != fingerprints[name]:
                    changed.add((cls.__name__, name))
        return changed

    def grammar_changed(self) -> bool:
        """Whether extensions changed the stock states beyond the replayed transitions."""
        return not self.changes() <= REPLAYED
