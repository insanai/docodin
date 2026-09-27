"""Sphinx extension: parse reStructuredText sources with docodin.

Add ``"docodin.sphinx"`` to ``extensions`` in ``conf.py``.
"""

from __future__ import annotations

from typing import Any

import docutils.statemachine
from docutils.statemachine import StringList
from sphinx.parsers import RSTParser

from docodin.builder import parse_string, parse_string_list
from docodin.parser import _supported


class OdinSphinxRSTParser(RSTParser):
    """Sphinx's ``RSTParser`` accelerated with the native DocOdin engine."""

    def _has_decoration(self) -> bool:
        """Check whether the Sphinx configuration defines rst_prolog or rst_epilog.

        Returns:
            True if rst_prolog or rst_epilog is configured, False otherwise.
        """
        config = getattr(self, "_config", None) or getattr(self, "config", None)
        if config is None:
            return False
        return bool(getattr(config, "rst_prolog", None) or getattr(config, "rst_epilog", None))

    def parse(self, inputstring: str | StringList, document: Any) -> None:
        """Parse source reStructuredText string or StringList into a Sphinx document tree.

        Args:
            inputstring: Source markup text or pre-split StringList.
            document: Target docutils document tree.
        """
        if not _supported(self.state_classes, self.inliner):
            return super().parse(inputstring, document)
        self.setup_parse(inputstring, document)  # type: ignore[arg-type]
        if isinstance(inputstring, str) and not self._has_decoration():
            # No rst_prolog/rst_epilog: parse the string directly.
            parse_string(inputstring, document, self.inliner)
        else:
            if isinstance(inputstring, str):
                lines = docutils.statemachine.string2lines(
                    inputstring, tab_width=document.settings.tab_width, convert_whitespace=True)
                inputlines = StringList(lines, document.current_source)
            else:
                inputlines = inputstring
            self.decorate(inputlines)
            parse_string_list(inputlines, document, self.inliner)
        self.finish_parse()
        return None


def _tune_garbage_collection(app: Any) -> None:
    if app.config.docodin_gc_tuning:
        import gc

        from docodin.sphinx_build import GC_THRESHOLDS, _collect_and_freeze

        gc.set_threshold(*GC_THRESHOLDS)
        _collect_and_freeze()
        app.connect("env-updated", _collect_and_freeze)


def setup(app: Any) -> dict[str, Any]:
    """Register docodin as the accelerated reStructuredText parser in Sphinx.

    Args:
        app: The Sphinx application instance.

    Returns:
        Extension metadata dictionary including version and parallel safety flags.
    """
    app.add_source_parser(OdinSphinxRSTParser, override=True)
    # the opt-in collector tuning of docodin-sphinx-build (see docodin.sphinx_build)
    app.add_config_value("docodin_gc_tuning", False, "")
    app.connect("builder-inited", _tune_garbage_collection)
    from docodin import __version__

    return {
        "version": __version__,
        "parallel_read_safe": True,
        "parallel_write_safe": True,
    }
