"""Python Enhancement Proposal (PEP) Reader."""

from __future__ import annotations

from typing import Any

from docutils.parsers import rst
from docutils.readers import standalone
from docutils.transforms import frontmatter, peps

__docformat__ = "reStructuredText"


class Reader(standalone.Reader):
    supported = ("pep",)
    settings_spec = ("PEP Reader Option Defaults",
                     "The --pep-references and --rfc-references options (for the "
                     "reStructuredText parser) are on by default.", ())
    config_section = "pep reader"
    config_section_dependencies = ("readers", "standalone reader")
    settings_default_overrides = {"pep_references": True, "rfc_references": True}
    inliner_class = rst.states.Inliner

    def get_transforms(self) -> list[type]:
        transforms = super().get_transforms()
        transforms.remove(frontmatter.DocTitle)
        transforms.remove(frontmatter.SectionSubTitle)
        transforms.remove(frontmatter.DocInfo)
        transforms.extend([peps.Headers, peps.Contents, peps.TargetNotes])
        return transforms

    def __init__(self, parser: Any = None, parser_name: str | None = None) -> None:
        if parser is None or isinstance(parser, str):
            parser = rst.Parser(rfc2822=True, inliner=self.inliner_class())
        super().__init__(parser)
