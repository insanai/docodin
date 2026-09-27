"""docutils implemented by docodin.

The ``docutils`` package under this directory is a drop-in implementation of
the docutils 0.22 API whose reStructuredText parser is docodin's native
engine.  It is imported under the name ``docutils``: an import hook maps
``docutils`` and ``docutils.*`` to the files here, so classes keep their
docutils module paths (pickled Sphinx environments stay compatible) and each
module is loaded exactly once.

* :func:`enable` registers the hook as a fallback, used only when the real
  docutils is not installed (``import docodin`` does this).
* :func:`install_shim` puts it in front of every other finder, replacing an
  installed docutils (used by tests and ``docodin-sphinx-build --shim``).
"""

from __future__ import annotations

import importlib.abc
import importlib.util
import sys
from importlib.machinery import ModuleSpec
from pathlib import Path
from types import ModuleType

__all__ = ["enable", "install_shim", "is_active", "uninstall_shim"]

ROOT = Path(__file__).with_name("docutils")
_PACKAGE = "docutils"


class _DocutilsFinder(importlib.abc.MetaPathFinder):
    """Resolve ``docutils`` and its submodules to the files under :data:`ROOT`."""

    def find_spec(self, fullname: str, path: object = None, target: ModuleType | None = None,
                  ) -> ModuleSpec | None:
        if fullname != _PACKAGE and not fullname.startswith(_PACKAGE + "."):
            return None
        base = ROOT.joinpath(*fullname.split(".")[1:])
        init = base / "__init__.py"
        if init.is_file():
            return importlib.util.spec_from_file_location(
                fullname, init, submodule_search_locations=[str(base)])
        module = base.with_suffix(".py")
        if module.is_file():
            return importlib.util.spec_from_file_location(fullname, module)
        return None


_FINDER = _DocutilsFinder()


def _loaded_docutils() -> list[str]:
    return [name for name in sys.modules
            if name == _PACKAGE or name.startswith(_PACKAGE + ".")]


def _unregister() -> None:
    while _FINDER in sys.meta_path:
        sys.meta_path.remove(_FINDER)


def enable() -> None:
    """Make ``import docutils`` fall back to docodin when docutils is absent."""
    if _FINDER not in sys.meta_path:
        sys.meta_path.append(_FINDER)


def is_active() -> bool:
    """Whether the loaded ``docutils`` is docodin's implementation."""
    module = sys.modules.get(_PACKAGE)
    return bool(module is not None and getattr(module, "__docodin_shim__", False))


def install_shim(force: bool = False) -> None:
    """Serve ``docutils`` from docodin.

    Without ``force`` this only enables the fallback.  With ``force`` the hook
    takes precedence over an installed docutils; already imported docutils
    modules are dropped (objects created from them keep their old classes).
    """
    if not force:
        enable()
        return
    _unregister()
    sys.meta_path.insert(0, _FINDER)
    if not is_active():
        for name in _loaded_docutils():
            del sys.modules[name]


def uninstall_shim() -> None:
    """Remove the hook and drop docodin's ``docutils`` modules."""
    _unregister()
    if is_active():
        for name in _loaded_docutils():
            del sys.modules[name]
