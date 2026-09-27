"""Math conversion utilities (LaTeX math to MathML, HTML and plain text)."""

from __future__ import annotations

__docformat__ = "reStructuredText"


class MathError(ValueError):
    """Exception for math syntax and math conversion errors."""

    def __init__(self, msg: str, details: list | None = None) -> None:
        super().__init__(msg)
        self.details = [] if details is None else details


def toplevel_code(code: str) -> str:
    """Return string (LaTeX math) `code` with environments stripped out."""
    chunks = code.split(r"\begin{")
    return r"\begin{".join(chunk.split(r"\end{")[-1] for chunk in chunks)


def pick_math_environment(code: str, numbered: bool = False) -> str:
    """Return the right math environment to display `code`."""
    env = "align" if toplevel_code(code).find(r"\\") >= 0 else "equation"
    return env if numbered else env + "*"


def wrap_math_code(code: str, as_block: bool) -> str:
    """Wrap `code` in a math environment (block) or inline math delimiters."""
    if as_block:
        env = pick_math_environment(code)
        return "\\begin{%s}\n%s\n\\end{%s}" % (env, code, env)
    return "$%s$" % code
