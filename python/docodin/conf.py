"""Sphinx conf.py discovery and metadata extraction module.

Allows DocOdin to detect and leverage project configuration from Sphinx conf.py
files across both the standalone native compiler and Python runtime shims.
"""

from __future__ import annotations

import ast
from pathlib import Path
from typing import Any


def find_conf_py(start_path: str | Path | None = None) -> Path | None:
    """Locate the nearest Sphinx conf.py file by searching upwards from start_path.

    Args:
        start_path: Starting file or directory path. Defaults to current working directory.

    Returns:
        The Path to conf.py if found, or None if no conf.py exists in directory ancestry.
    """
    if start_path is None:
        current = Path.cwd().resolve()
    else:
        current = Path(start_path).resolve()
        if current.is_file():
            current = current.parent

    for candidate_dir in [current, *current.parents]:
        conf_file = candidate_dir / "conf.py"
        if conf_file.is_file():
            return conf_file
    return None


def load_conf_py(conf_path: str | Path) -> dict[str, Any]:
    """Load configuration variables from a Sphinx conf.py file.

    Attempts standard execution via runpy or exec, and falls back to static AST
    parsing if execution fails due to missing optional Sphinx extension dependencies.

    Args:
        conf_path: Absolute or relative path to conf.py.

    Returns:
        Dictionary of configuration variables defined in conf.py.

    Raises:
        FileNotFoundError: If the specified conf.py path does not exist.
    """
    path = Path(conf_path).resolve()
    if not path.is_file():
        raise FileNotFoundError(f"Sphinx configuration file not found at: {path}")

    # First attempt: safe execution in an isolated namespace
    namespace: dict[str, Any] = {"__file__": str(path)}
    try:
        code = path.read_text(encoding="utf-8")
        exec(compile(code, str(path), "exec"), namespace)
        return {
            k: v
            for k, v in namespace.items()
            if not k.startswith("__") and not callable(v) and not hasattr(v, "__file__")
        }
    except Exception:
        # Fallback: Static AST evaluation to extract literal assignments safely
        return _parse_conf_ast(path)


def _parse_conf_ast(path: Path) -> dict[str, Any]:
    """Statically parse conf.py using the Python AST to extract literal variables.

    Args:
        path: Path to the conf.py file.

    Returns:
        Dictionary of literal variable assignments.
    """
    results: dict[str, Any] = {}
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except Exception:
        return results

    for node in tree.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    try:
                        val = ast.literal_eval(node.value)
                        results[target.id] = val
                    except (ValueError, SyntaxError):
                        pass
    return results


def get_metadata(start_path: str | Path | None = None) -> dict[str, Any]:
    """Retrieve core project metadata (title, author, version) from nearest conf.py.

    Args:
        start_path: Starting path for conf.py discovery.

    Returns:
        Dictionary with extracted metadata keys: 'title', 'project', 'author',
        'version', 'release', 'copyright', and 'conf_path'. If conf.py is not
        found, returns empty strings with 'conf_path' set to None.
    """
    conf_file = find_conf_py(start_path)
    if not conf_file:
        return {
            "title": "",
            "project": "",
            "author": "",
            "version": "",
            "release": "",
            "copyright": "",
            "conf_path": None,
        }

    config = load_conf_py(conf_file)
    project = str(config.get("project", ""))
    html_title = str(config.get("html_title", ""))
    title = html_title or project

    return {
        "title": title,
        "project": project,
        "author": str(config.get("author", "")),
        "version": str(config.get("version", "")),
        "release": str(config.get("release", "")),
        "copyright": str(config.get("copyright", "")),
        "conf_path": str(conf_file),
    }
