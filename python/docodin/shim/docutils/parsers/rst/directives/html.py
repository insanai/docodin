"""Deprecated module: the "meta" directive lives in `directives.misc`."""

from __future__ import annotations

import warnings

from docutils.parsers.rst.directives.misc import Meta, MetaBody  # noqa: F401

__docformat__ = "reStructuredText"

warnings.warn("The `docutils.parsers.rst.directive.html` module will be removed in Docutils 2.0. "
              'Since Docutils 0.18, the "Meta" node is defined in '
              "`docutils.parsers.rst.directives.misc`.", DeprecationWarning, stacklevel=2)
