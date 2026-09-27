"""``docodin-sphinx-build``: ``sphinx-build`` with docutils served by docodin.

Takes exactly the arguments of ``sphinx-build``.
"""

from __future__ import annotations

import sys


def main(argv: list[str] | None = None) -> int:
    from docodin.shim import install_shim

    install_shim(force=True)  # before Sphinx imports docutils
    from sphinx.cmd.build import main as sphinx_main

    return sphinx_main(sys.argv[1:] if argv is None else argv)


if __name__ == "__main__":
    sys.exit(main())
