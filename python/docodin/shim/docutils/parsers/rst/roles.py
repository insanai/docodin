"""Interpreted text roles: registry and the standard roles.

A role function has the signature
``role_fn(name, rawtext, text, lineno, inliner, options=None, content=None)``
and returns ``(nodes, system_messages)``.
"""

from __future__ import annotations

import warnings
from collections.abc import Callable
from typing import Any

from docutils import nodes
from docutils.parsers.rst import directives
from docutils.parsers.rst.languages import en as _fallback_language_module
from docutils.utils.code_analyzer import Lexer, LexerError

__docformat__ = "reStructuredText"

DEFAULT_INTERPRETED_ROLE = "title-reference"

_role_registry: dict[str, Callable[..., Any]] = {}
"""Mapping of canonical role names to role functions."""

_roles: dict[str, Callable[..., Any]] = {}
"""Mapping of local or language-dependent interpreted text role names to role functions."""


def role(role_name: str, language_module: Any, lineno: int,
         reporter: Any) -> tuple[Callable[..., Any] | None, list[nodes.system_message]]:
    """Locate and return a role function from its language-dependent name.

    Return ``(None, messages)`` if the role is not registered.
    """
    normname = role_name.lower()
    messages: list[nodes.system_message] = []
    if normname in _roles:
        return _roles[normname], messages
    canonicalname, msg_text = _canonical_name(role_name, normname, language_module)
    if msg_text:
        messages.append(reporter.info("\n".join(msg_text), line=lineno))
    if canonicalname in _role_registry:
        role_fn = _role_registry[canonicalname]
        register_local_role(normname, role_fn)
        return role_fn, messages
    return None, messages


def _canonical_name(role_name: str, normname: str,
                    language_module: Any) -> tuple[str, list[str]]:
    msg_text: list[str] = []
    canonicalname = None
    if not role_name:
        return DEFAULT_INTERPRETED_ROLE, msg_text
    try:
        canonicalname = language_module.roles[normname]
    except AttributeError as error:
        msg_text.append("Problem retrieving role entry from language module %r: %s."
                        % (language_module, error))
    except KeyError:
        msg_text.append('No role entry for "%s" in module "%s".'
                        % (role_name, language_module.__name__))
    if not canonicalname:
        try:
            canonicalname = _fallback_language_module.roles[normname]
            msg_text.append('Using English fallback for role "%s".' % role_name)
        except KeyError:
            msg_text.append('Trying "%s" as canonical role name.' % role_name)
            canonicalname = normname
    return canonicalname, msg_text


def register_canonical_role(name: str, role_fn: Callable[..., Any]) -> None:
    """Register an interpreted text role by its canonical name."""
    set_implicit_options(role_fn)
    _role_registry[name.lower()] = role_fn


def register_local_role(name: str, role_fn: Callable[..., Any]) -> None:
    """Register an interpreted text role by its local or language-dependent name."""
    set_implicit_options(role_fn)
    _roles[name.lower()] = role_fn


def set_implicit_options(role_fn: Any) -> None:
    """Add customization options to role functions, unless explicitly set or disabled."""
    if not hasattr(role_fn, "options") or role_fn.options is None:
        role_fn.options = {"class": directives.class_option}
    elif "class" not in role_fn.options:
        role_fn.options["class"] = directives.class_option


def register_generic_role(canonical_name: str, node_class: type) -> None:
    """For roles which simply wrap a given `node_class` around the text."""
    register_canonical_role(canonical_name, GenericRole(canonical_name, node_class))


class GenericRole:
    """Generic interpreted text role: wrap the text in a `node_class` element."""

    def __init__(self, role_name: str, node_class: type) -> None:
        self.name = role_name
        self.node_class = node_class

    def __call__(self, role: str, rawtext: str, text: str, lineno: int, inliner: Any,
                 options: dict[str, Any] | None = None, content: Any = None) -> tuple:
        options = normalize_options(options)
        return [self.node_class(rawtext, text, **options)], []


class CustomRole:
    """Wrapper for custom interpreted text roles (the "role" directive)."""

    def __init__(self, role_name: str, base_role: Any, options: dict[str, Any] | None = None,
                 content: Any = None) -> None:
        self.name = role_name
        self.base_role = base_role
        self.options = getattr(base_role, "options", None)
        self.content = getattr(base_role, "content", None)
        self.supplied_options = options
        self.supplied_content = content

    def __call__(self, role: str, rawtext: str, text: str, lineno: int, inliner: Any,
                 options: dict[str, Any] | None = None, content: Any = None) -> tuple:
        opts = normalize_options(self.supplied_options)
        try:
            opts.update(options)
        except TypeError:  # options may be None
            pass
        supplied_content = self.supplied_content or []
        content = content or []
        delimiter = ["\n"] if supplied_content and content else []
        return self.base_role(role, rawtext, text, lineno, inliner, options=opts,
                              content=supplied_content + delimiter + content)


def generic_custom_role(role: str, rawtext: str, text: str, lineno: int, inliner: Any,
                        options: dict[str, Any] | None = None, content: Any = None) -> tuple:
    """Base for custom roles if no other base role is specified."""
    options = normalize_options(options)
    return [nodes.inline(rawtext, text, **options)], []


generic_custom_role.options = {"class": directives.class_option}

for _name, _node_class in (("abbreviation", nodes.abbreviation), ("acronym", nodes.acronym),
                           ("emphasis", nodes.emphasis), ("literal", nodes.literal),
                           ("strong", nodes.strong), ("subscript", nodes.subscript),
                           ("superscript", nodes.superscript),
                           ("title-reference", nodes.title_reference)):
    register_generic_role(_name, _node_class)


def _problem(inliner: Any, rawtext: str, msg: nodes.system_message) -> tuple:
    return [inliner.problematic(rawtext, rawtext, msg)], [msg]


def pep_reference_role(role: str, rawtext: str, text: str, lineno: int, inliner: Any,
                       options: dict[str, Any] | None = None, content: Any = None) -> tuple:
    options = normalize_options(options)
    try:
        pepnum = int(nodes.unescape(text))
        if pepnum < 0 or pepnum > 9999:
            raise ValueError
    except ValueError:
        msg = inliner.reporter.error(
            'PEP number must be a number from 0 to 9999; "%s" is invalid.' % text, line=lineno)
        return _problem(inliner, rawtext, msg)
    settings = inliner.document.settings
    ref = settings.pep_base_url + settings.pep_file_url_template % pepnum
    return [nodes.reference(rawtext, "PEP " + text, refuri=ref, **options)], []


register_canonical_role("pep-reference", pep_reference_role)


def rfc_reference_role(role: str, rawtext: str, text: str, lineno: int, inliner: Any,
                       options: dict[str, Any] | None = None, content: Any = None) -> tuple:
    options = normalize_options(options)
    if "#" in text:
        rfcnum, section = nodes.unescape(text).split("#", 1)
    else:
        rfcnum, section = nodes.unescape(text), None
    try:
        number = int(rfcnum)
        if number < 1:
            raise ValueError
    except ValueError:
        msg = inliner.reporter.error('RFC number must be a number greater than or equal to 1; '
                                     '"%s" is invalid.' % text, line=lineno)
        return _problem(inliner, rawtext, msg)
    ref = inliner.document.settings.rfc_base_url + inliner.rfc_url % number
    if section is not None:
        ref += "#" + section
    return [nodes.reference(rawtext, "RFC " + str(number), refuri=ref, **options)], []


register_canonical_role("rfc-reference", rfc_reference_role)


def raw_role(role: str, rawtext: str, text: str, lineno: int, inliner: Any,
             options: dict[str, Any] | None = None, content: Any = None) -> tuple:
    options = normalize_options(options)
    if not inliner.document.settings.raw_enabled:
        msg = inliner.reporter.warning("raw (and derived) roles disabled")
        return _problem(inliner, rawtext, msg)
    if "format" not in options:
        msg = inliner.reporter.error(
            'No format (Writer name) is associated with this role: "%s".\n'
            'The "raw" role cannot be used directly.\nInstead, use the "role" directive to '
            "create a new role with an associated format." % role, line=lineno)
        return _problem(inliner, rawtext, msg)
    node = nodes.raw(rawtext, nodes.unescape(text, True), **options)
    node.source, node.line = inliner.reporter.get_source_and_line(lineno)
    return [node], []


raw_role.options = {"format": directives.unchanged}
register_canonical_role("raw", raw_role)


def code_role(role: str, rawtext: str, text: str, lineno: int, inliner: Any,
              options: dict[str, Any] | None = None, content: Any = None) -> tuple:
    options = normalize_options(options)
    language = options.get("language", "")
    classes = ["code"]
    if "classes" in options:
        classes.extend(options["classes"])
    if language and language not in classes:
        classes.append(language)
    try:
        tokens = Lexer(nodes.unescape(text, True), language,
                       inliner.document.settings.syntax_highlight)
    except LexerError as error:
        msg = inliner.reporter.warning(error)
        return _problem(inliner, rawtext, msg)
    node = nodes.literal(rawtext, "", classes=classes)
    for token_classes, value in tokens:
        if token_classes:
            node += nodes.inline(value, value, classes=token_classes)
        else:  # insert as Text to decrease the verbosity of the output
            node += nodes.Text(value)
    return [node], []


code_role.options = {"language": directives.unchanged}
register_canonical_role("code", code_role)


def math_role(role: str, rawtext: str, text: str, lineno: int, inliner: Any,
              options: dict[str, Any] | None = None, content: Any = None) -> tuple:
    options = normalize_options(options)
    return [nodes.math(rawtext, nodes.unescape(text, True), **options)], []


register_canonical_role("math", math_role)


def unimplemented_role(role: str, rawtext: str, text: str, lineno: int, inliner: Any,
                       options: dict[str, Any] | None = None, content: Any = None) -> tuple:
    msg = inliner.reporter.error('Interpreted text role "%s" not implemented.' % role,
                                 line=lineno)
    return _problem(inliner, rawtext, msg)


for _name in ("index", "named-reference", "anonymous-reference", "uri-reference",
              "footnote-reference", "citation-reference", "substitution-reference", "target",
              "restructuredtext-unimplemented-role"):
    register_canonical_role(_name, unimplemented_role)


def set_classes(options: dict[str, Any] | None) -> None:
    """Deprecated: rename "class" to "classes" in `options` (in place)."""
    warnings.warn("The auxiliary function roles.set_classes() is obsoleted by "
                  "roles.normalize_options() and will be removed in Docutils 2.0",
                  PendingDeprecationWarning, stacklevel=2)
    if options and "class" in options:
        assert "classes" not in options
        options["classes"] = options.pop("class")


def normalized_role_options(options: dict[str, Any] | None) -> dict[str, Any]:
    warnings.warn("The auxiliary function roles.normalized_role_options() is obsoleted by "
                  "roles.normalize_options() and will be removed in Docutils 2.0",
                  PendingDeprecationWarning, stacklevel=2)
    return normalize_options(options)


def normalize_options(options: dict[str, Any] | None) -> dict[str, Any]:
    """Return a copy of `options` with "class" renamed to "classes"."""
    if options is None:
        return {}
    n_options = options.copy()
    if "class" in n_options:
        assert "classes" not in n_options
        n_options["classes"] = n_options.pop("class")
    return n_options
