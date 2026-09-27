"""Docutils roles drop-in implementation for docodin."""

from __future__ import annotations

from typing import Any, Callable

from docodin.shim import nodes

_roles: dict[str, Any] = {}
_role_registry: dict[str, Any] = {}
DEFAULT_INTERPRETED_ROLE = "title-reference"


def register_local_role(name: str, role_fn: Any) -> None:
    _roles[name.lower()] = role_fn


def register_canonical_role(name: str, role_fn: Any) -> None:
    _role_registry[name.lower()] = role_fn
    register_local_role(name, role_fn)


def register_generic_role(canonical_name: str, node_class: type[nodes.Node]) -> None:
    def generic_role(name: str, rawtext: str, text: str, lineno: int, inliner: Any, options: dict[str, Any] = {}, content: list[str] = []) -> tuple[list[nodes.Node], list[nodes.system_message]]:
        node = node_class(rawtext, text, **options)
        return [node], []

    register_canonical_role(canonical_name, generic_role)


def set_classes(options: dict[str, Any]) -> None:
    if "class" in options:
        classes = options.setdefault("classes", [])
        classes.extend(options.pop("class"))


def role(role_name: str, language_module: Any, lineno: int, reporter: Any) -> tuple[Any, list[Any]]:
    normname = role_name.lower()
    messages: list[Any] = []
    if normname in _roles:
        return _roles[normname], messages

    canonicalname = None
    if normname:
        if hasattr(language_module, "roles") and normname in language_module.roles:
            canonicalname = language_module.roles[normname]
        else:
            from docodin.shim.parsers.rst.languages import en as en_rst

            if hasattr(en_rst, "roles") and normname in en_rst.roles:
                canonicalname = en_rst.roles[normname]
            else:
                canonicalname = normname
    else:
        canonicalname = DEFAULT_INTERPRETED_ROLE

    if canonicalname in _roles:
        return _roles[canonicalname], messages
    if canonicalname in _role_registry:
        role_fn = _role_registry[canonicalname]
        register_local_role(normname, role_fn)
        return role_fn, messages

    return None, messages


class CustomRole:
    def __init__(self, role_name: str, base_role: Any, options: dict[str, Any] = {}, content: list[str] = []) -> None:
        self.name = role_name
        self.base_role = base_role
        self.options = options
        self.content = content

    def __call__(self, role_name: str, rawtext: str, text: str, lineno: int, inliner: Any, options: dict[str, Any] = {}, content: list[str] = []) -> Any:
        opts = dict(self.options)
        opts.update(options)
        cnt = list(self.content) + content
        return self.base_role(role_name, rawtext, text, lineno, inliner, options=opts, content=cnt)


class GenericRole:
    def __init__(self, role_name: str, node_class: type[nodes.Node]) -> None:
        self.name = role_name
        self.node_class = node_class

    def __call__(self, role_name: str, rawtext: str, text: str, lineno: int, inliner: Any, options: dict[str, Any] = {}, content: list[str] = []) -> tuple[list[nodes.Node], list[nodes.system_message]]:
        node = self.node_class(rawtext, text, **options)
        return [node], []
