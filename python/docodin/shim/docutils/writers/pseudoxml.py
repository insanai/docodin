"""Simple internal document tree Writer, writes indented pseudo-XML."""

from __future__ import annotations

from docutils import frontend, writers

__docformat__ = "reStructuredText"


class Writer(writers.Writer):
    supported = ("pseudoxml", "pprint", "pformat")
    """Formats this writer supports."""

    settings_spec = (
        '"Docutils pseudo-XML" Writer Options',
        None,
        (("Pretty-print <#text> nodes.",
          ["--detailed"],
          {"action": "store_true", "validator": frontend.validate_boolean}),
         ),
    )

    config_section = "pseudoxml writer"
    config_section_dependencies = ("writers",)

    output = None
    """Final translated form of `document`."""

    def translate(self) -> None:
        self.output = self.document.pformat()

    def supports(self, format: str) -> bool:  # noqa: A002 - docutils API name
        """This writer supports all format-specific elements."""
        return True
