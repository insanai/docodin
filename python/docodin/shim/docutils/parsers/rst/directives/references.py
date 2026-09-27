"""Directives for references and targets."""

from __future__ import annotations

from docutils import nodes
from docutils.parsers.rst import Directive, directives
from docutils.transforms import references

__docformat__ = "reStructuredText"


class TargetNotes(Directive):
    """Target footnote generation."""

    option_spec = {"class": directives.class_option}

    def run(self) -> list[nodes.Node]:
        pending = nodes.pending(references.TargetNotes)
        self.add_name(pending)
        pending.details.update(self.options)
        self.state_machine.document.note_pending(pending)
        return [pending]
