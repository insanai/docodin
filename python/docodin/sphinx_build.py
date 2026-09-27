"""``docodin-sphinx-build``: ``sphinx-build`` with docutils served by docodin.

Takes exactly the arguments of ``sphinx-build``.

A Sphinx build keeps a large, long-lived environment in memory, and Python's
full garbage collections rescan it again and again (a sixth of the build
time of CPython's documentation).  Unless ``DOCODIN_GC=default`` is set, the
build therefore runs with a tuned collector:

* the collection thresholds are raised moderately, and
* after the extensions are loaded and after all documents are read, the
  live objects are collected once and then frozen (`gc.freeze`): later
  collections skip them.

The output is unchanged.  On CPython's documentation the build is about 18 %
faster and its peak memory about 17 % higher (garbage collected later during
reading); ``DOCODIN_GC=default`` keeps Python's default collector for
memory-constrained builds.
"""

from __future__ import annotations

import gc
import os
import sys
from typing import Any

GC_THRESHOLDS = (50_000, 20, 100)


def _collect_and_freeze(*_args: Any) -> None:
    gc.collect()
    gc.freeze()


def tune_garbage_collection() -> None:
    """Raise the collector's thresholds and freeze the long-lived objects of
    every Sphinx application created afterwards."""
    import sphinx.application

    gc.set_threshold(*GC_THRESHOLDS)
    sphinx_init = sphinx.application.Sphinx.__init__

    def init(self: Any, *args: Any, **kwargs: Any) -> None:
        sphinx_init(self, *args, **kwargs)
        self.connect("builder-inited", _collect_and_freeze)
        self.connect("env-updated", _collect_and_freeze)

    sphinx.application.Sphinx.__init__ = init


def main(argv: list[str] | None = None) -> int:
    from docodin.shim import install_shim

    install_shim(force=True)  # before Sphinx imports docutils
    if os.environ.get("DOCODIN_GC", "tuned") != "default":
        tune_garbage_collection()
    from sphinx.cmd.build import main as sphinx_main

    return sphinx_main(sys.argv[1:] if argv is None else argv)


if __name__ == "__main__":
    sys.exit(main())
