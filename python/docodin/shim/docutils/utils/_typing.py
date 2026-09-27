"""Runtime stand-ins for typing helpers used in annotations."""

from __future__ import annotations

from typing import Any

__all__ = ("final", "overload")


def final[T](f: T) -> T:
    return f


def _overload_inner(*args: Any, **kwds: Any) -> Any:
    raise NotImplementedError


def overload[T](func: T) -> T:
    return _overload_inner  # type: ignore[return-value]
