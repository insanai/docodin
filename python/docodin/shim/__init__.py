"""DocOdin Drop-in Compatibility Shim for docutils.

This module provides a pure drop-in replacement for the ``docutils`` package
when upstream docutils is not installed in the environment. It allows Sphinx,
Sphinx extensions, and third-party tools to import ``docutils``, ``docutils.nodes``,
``docutils.core``, etc. and work seamlessly with the DocOdin engine.
"""

from __future__ import annotations

import sys
from types import ModuleType
from typing import Any

__version__ = "0.22.4"
__version_info__ = (0, 22, 4, "final", 0, True)


class ApplicationError(Exception):
    pass


class DataError(ApplicationError):
    pass


_SHIM_MODULES = [
    "docutils",
    "docutils.nodes",
    "docutils.core",
    "docutils.statemachine",
    "docutils.utils",
    "docutils.utils.smartquotes",
    "docutils.frontend",
    "docutils.transforms",
    "docutils.transforms.parts",
    "docutils.transforms.universal",
    "docutils.transforms.references",
    "docutils.languages",
    "docutils.languages.en",
    "docutils.parsers",
    "docutils.parsers.rst",
    "docutils.parsers.rst.directives",
    "docutils.parsers.rst.directives.body",
    "docutils.parsers.rst.roles",
    "docutils.parsers.rst.states",
    "docutils.parsers.rst.languages",
    "docutils.parsers.rst.languages.en",
    "docutils.writers",
    "docutils.writers.html5_polyglot",
    "docutils.writers.latex2e",
    "docutils.writers.pseudoxml",
]

_SAVED_MODULES: dict[str, Any] = {}


def install_shim(force: bool = False) -> None:
    """Install the DocOdin docutils compatibility shim into sys.modules.

    If upstream docutils is already loaded or installed and force is False,
    this does nothing. If force is True or docutils is not installed, it
    registers all docutils submodules backed by DocOdin.

    Args:
        force: If True, replace an already loaded docutils module in sys.modules.
            Defaults to False.
    """
    global _SAVED_MODULES

    if not force and "docutils" in sys.modules and not getattr(sys.modules["docutils"], "_is_docodin_shim", False):
        return

    from docodin.shim import (
        core as shim_core,
        frontend as shim_frontend,
        languages as shim_languages,
        nodes as shim_nodes,
        parsers as shim_parsers,
        smartquotes as shim_smartquotes,
        statemachine as shim_statemachine,
        transforms as shim_transforms,
        utils as shim_utils,
        writers as shim_writers,
    )
    from docodin.shim.languages import en as shim_languages_en
    from docodin.shim.parsers import rst as shim_rst
    from docodin.shim.parsers.rst import (
        directives as shim_directives,
        languages as shim_rst_languages,
        roles as shim_roles,
        states as shim_states,
    )
    from docodin.shim.parsers.rst.directives import body as shim_directives_body
    from docodin.shim.parsers.rst.languages import en as shim_rst_languages_en
    from docodin.shim.transforms import (
        parts as shim_transforms_parts,
        references as shim_transforms_references,
        universal as shim_transforms_universal,
    )
    from docodin.shim.writers import (
        html5_polyglot as shim_html5,
        latex2e as shim_latex,
        pseudoxml as shim_pseudoxml,
    )

    # Base docutils module
    mod = ModuleType("docutils")
    mod.__version__ = __version__
    mod.__version_info__ = __version_info__
    mod.ApplicationError = ApplicationError
    mod.DataError = DataError
    mod._is_docodin_shim = True
    mod.nodes = shim_nodes
    mod.core = shim_core
    mod.statemachine = shim_statemachine
    mod.utils = shim_utils
    mod.frontend = shim_frontend
    mod.transforms = shim_transforms
    mod.languages = shim_languages
    mod.parsers = shim_parsers
    mod.writers = shim_writers
    mod.__path__ = []

    # Parsers
    parsers_mod = ModuleType("docutils.parsers")
    parsers_mod.Parser = shim_parsers.Parser
    parsers_mod.get_parser_class = shim_parsers.get_parser_class
    parsers_mod.rst = shim_rst
    parsers_mod.__path__ = []

    # Writers
    writers_mod = ModuleType("docutils.writers")
    writers_mod.Writer = shim_writers.Writer
    writers_mod.get_writer_class = shim_writers.get_writer_class
    writers_mod.html5_polyglot = shim_html5
    writers_mod.latex2e = shim_latex
    writers_mod.pseudoxml = shim_pseudoxml
    writers_mod.__path__ = []

    mapping = {
        "docutils": mod,
        "docutils.nodes": shim_nodes,
        "docutils.core": shim_core,
        "docutils.statemachine": shim_statemachine,
        "docutils.utils": shim_utils,
        "docutils.utils.smartquotes": shim_smartquotes,
        "docutils.frontend": shim_frontend,
        "docutils.transforms": shim_transforms,
        "docutils.transforms.parts": shim_transforms_parts,
        "docutils.transforms.universal": shim_transforms_universal,
        "docutils.transforms.references": shim_transforms_references,
        "docutils.languages": shim_languages,
        "docutils.languages.en": shim_languages_en,
        "docutils.parsers": parsers_mod,
        "docutils.parsers.rst": shim_rst,
        "docutils.parsers.rst.directives": shim_directives,
        "docutils.parsers.rst.directives.body": shim_directives_body,
        "docutils.parsers.rst.roles": shim_roles,
        "docutils.parsers.rst.states": shim_states,
        "docutils.parsers.rst.languages": shim_rst_languages,
        "docutils.parsers.rst.languages.en": shim_rst_languages_en,
        "docutils.writers": writers_mod,
        "docutils.writers.html5_polyglot": shim_html5,
        "docutils.writers.latex2e": shim_latex,
        "docutils.writers.pseudoxml": shim_pseudoxml,
    }

    for name, m in mapping.items():
        if name in sys.modules and not getattr(sys.modules[name], "_is_docodin_shim", False):
            _SAVED_MODULES.setdefault(name, sys.modules[name])
        sys.modules[name] = m


def uninstall_shim() -> None:
    """Remove docutils shim modules from sys.modules and restore originals."""
    global _SAVED_MODULES
    for mod_name in _SHIM_MODULES:
        if mod_name in _SAVED_MODULES:
            sys.modules[mod_name] = _SAVED_MODULES.pop(mod_name)
        elif mod_name in sys.modules and getattr(sys.modules[mod_name], "_is_docodin_shim", False):
            del sys.modules[mod_name]
