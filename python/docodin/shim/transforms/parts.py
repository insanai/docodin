"""Parts transforms."""

from __future__ import annotations

from docodin.shim.transforms import Transform


class Contents(Transform):
    default_priority = 720


class Header(Transform):
    default_priority = 810


class Footer(Transform):
    default_priority = 820
