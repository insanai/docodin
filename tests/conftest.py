"""Shared helpers for the docodin test suite."""

from __future__ import annotations

import docodin
import docutils.frontend
import docutils.parsers.rst
import docutils.utils
import pytest


def parse_pformat(parser, text: str, **settings_overrides) -> str:
    """Parse ``text`` with ``parser`` into a fresh document and return pseudo-XML."""
    settings = docutils.frontend.get_default_settings(docutils.parsers.rst.Parser)
    settings.warning_stream = ""
    settings.report_level = 5
    settings.halt_level = 5
    for key, value in settings_overrides.items():
        setattr(settings, key, value)
    document = docutils.utils.new_document("test data", settings)
    parser.parse(text, document)
    return document.pformat()


@pytest.fixture
def assert_parity():
    """Assert that docodin and docutils produce the same document tree."""

    def check(text: str, **settings_overrides) -> str:
        expected = parse_pformat(docutils.parsers.rst.Parser(), text, **settings_overrides)
        got = parse_pformat(docodin.Parser(), text, **settings_overrides)
        assert got == expected
        return got

    return check


@pytest.fixture(autouse=True)
def _restore_docutils():
    """Tests that patch docutils must not leak the patch into other tests."""
    patched = docodin.is_patched()
    yield
    if docodin.is_patched() and not patched:
        docodin.unpatch_docutils()
