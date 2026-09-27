"""Standalone file Reader for the reStructuredText markup syntax."""

from __future__ import annotations

from docutils import frontend, readers
from docutils.transforms import frontmatter, misc, references

__docformat__ = "reStructuredText"


class Reader(readers.Reader):
    supported = ("standalone",)
    document = None
    settings_spec = (
        "Standalone Reader Options", None, (
            ("Disable the promotion of a lone top-level section title to document title (and "
             "subsequent section title to document subtitle promotion; enabled by default).",
             ["--no-doc-title"],
             {"dest": "doctitle_xform", "action": "store_false", "default": True,
              "validator": frontend.validate_boolean}),
            ("Disable the bibliographic field list transform (enabled by default).",
             ["--no-doc-info"],
             {"dest": "docinfo_xform", "action": "store_false", "default": True,
              "validator": frontend.validate_boolean}),
            ("Activate the promotion of lone subsection titles to section subtitles "
             "(disabled by default).", ["--section-subtitles"],
             {"dest": "sectsubtitle_xform", "action": "store_true", "default": False,
              "validator": frontend.validate_boolean}),
            ("Deactivate the promotion of lone subsection titles.", ["--no-section-subtitles"],
             {"dest": "sectsubtitle_xform", "action": "store_false"}),
        ))
    config_section = "standalone reader"
    config_section_dependencies = ("readers",)

    def get_transforms(self) -> list[type]:
        return [*super().get_transforms(),
                references.Substitutions, references.PropagateTargets, frontmatter.DocTitle,
                frontmatter.SectionSubTitle, frontmatter.DocInfo, references.AnonymousHyperlinks,
                references.IndirectHyperlinks, references.Footnotes, references.ExternalTargets,
                references.InternalTargets, references.DanglingReferences, misc.Transitions]
