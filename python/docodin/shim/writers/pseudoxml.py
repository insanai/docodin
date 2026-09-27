"""Pseudo-XML writer."""

from __future__ import annotations

from docodin.shim.writers import Writer as BaseWriter


class Writer(BaseWriter):
    supported = ("pseudoxml", "xml")

    def translate(self) -> None:
        self.output = self.document.pformat()
        self.parts = {"whole": self.output, "body": self.output}
