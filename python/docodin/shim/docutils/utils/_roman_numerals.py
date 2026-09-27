"""Conversion between integers and Roman numerals (1 to 4999)."""

from __future__ import annotations

import re
import sys
from typing import Any

__all__ = ("MAX", "MIN", "InvalidRomanNumeralError", "OutOfRangeError", "RomanNumeral")

MIN = 1
MAX = 4999

_ROMAN_NUMERAL_PREFIXES = [
    (value, sys.intern(upper), sys.intern(upper.lower()))
    for value, upper in ((1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"),
                         (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"),
                         (4, "IV"), (1, "I"))
]
_CANONICAL = re.compile("M{0,4}(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})")


class OutOfRangeError(TypeError):
    """Number out of range (must be between 1 and 4,999)."""


class InvalidRomanNumeralError(ValueError):
    """Not a valid Roman numeral."""

    def __init__(self, value: Any, *args: object) -> None:
        super().__init__(f"Invalid Roman numeral: {value}", *args)


class RomanNumeral:
    """A Roman numeral (immutable)."""

    __slots__ = ("_value",)

    def __init__(self, value: int, /) -> None:
        if not isinstance(value, int):
            raise TypeError("RomanNumeral: an integer is required, not "
                            f"{type(value).__qualname__!r}")
        if value < MIN or value > MAX:
            raise OutOfRangeError(
                f"Number out of range (must be between 1 and 4,999). Got {value}.")
        super().__setattr__("_value", value)

    def __int__(self) -> int:
        return self._value

    def __str__(self) -> str:
        return self.to_uppercase()

    def __repr__(self) -> str:
        return f"{self.__class__.__name__}({self._value!r})"

    def __eq__(self, other: object) -> bool:
        if isinstance(other, RomanNumeral):
            return self._value == other._value
        return NotImplemented

    def __lt__(self, other: object) -> bool:
        if isinstance(other, RomanNumeral):
            return self._value < other._value
        return NotImplemented

    def __hash__(self) -> int:
        return hash(self._value)

    def __setattr__(self, key: str, value: object) -> None:
        if key == "_value":
            raise AttributeError(f"Cannot set the {key!r} attribute.")
        super().__setattr__(key, value)

    def _digits(self, column: int) -> str:
        out = []
        n = self._value
        for entry in _ROMAN_NUMERAL_PREFIXES:
            while n >= entry[0]:
                n -= entry[0]
                out.append(entry[column])
        return "".join(out)

    def to_uppercase(self) -> str:
        return self._digits(1)

    def to_lowercase(self) -> str:
        return self._digits(2)

    @classmethod
    def from_string(cls, string: str, /) -> RomanNumeral:
        """Parse a canonical Roman numeral (all uppercase or all lowercase)."""
        if not string or not isinstance(string, str) or not string.isascii():
            raise InvalidRomanNumeralError(string)
        if not (string.isupper() or string.islower()):
            raise InvalidRomanNumeralError(string)
        chars = string.upper()
        if not _CANONICAL.fullmatch(chars):
            raise InvalidRomanNumeralError(string)
        result = 0
        index = 0
        for value, name, _lower in _ROMAN_NUMERAL_PREFIXES:
            while chars.startswith(name, index):
                result += value
                index += len(name)
        return cls(result)
