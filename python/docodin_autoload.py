"""Interpreter start-up hook of docodin (imported by ``docodin.pth``).

A top-level module, so that importing it does not import the docodin package.

* With ``DOCODIN_DOCUTILS=1`` in the environment, every Python process serves
  ``docutils`` from docodin, so unchanged tools (``sphinx-build``,
  ``rst2html``, test runners) use it.
* Otherwise docodin stays a fallback: ``import docutils`` finds docodin's
  implementation only when no docutils is installed.  The fallback finder
  imports nothing until it is asked for ``docutils``.
"""

import os
import sys


class _LazyFallback:
    """Last entry of ``sys.meta_path``: defers to docodin's docutils finder."""

    @staticmethod
    def find_spec(fullname, path=None, target=None):
        if fullname != "docutils" and not fullname.startswith("docutils."):
            return None
        from docodin.shim import _FINDER

        return _FINDER.find_spec(fullname, path, target)


if os.environ.get("DOCODIN_DOCUTILS") == "1":
    from docodin.shim import install_shim

    install_shim(force=True)
else:
    sys.meta_path.append(_LazyFallback())
