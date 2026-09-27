"""Python implementation of the reStructuredText inline markup parser.

docodin parses inline markup natively (see ``docodin.builder.OdinInliner``);
this implementation serves the Python state machine of `states`, inliners that
extensions customize (subclasses or extra ``implicit_dispatch`` patterns) and
direct users of `Inliner`.
"""

from __future__ import annotations

import re
from collections.abc import Callable
from types import SimpleNamespace as Struct
from typing import Any

from docutils import ApplicationError, nodes, utils
from docutils.nodes import fully_normalize_name as normalize_name
from docutils.nodes import unescape, whitespace_normalize_name
from docutils.utils import escape2null, punctuation_chars, split_escaped_whitespace, urischemes


class MarkupMismatch(Exception):
    pass


def build_regexp(definition: tuple, compile_patterns: bool = True) -> Any:
    """Build, compile and return a regular expression based on `definition`.

    `definition` is a 4-tuple (group name, prefix, suffix, parts); parts may
    be strings or nested definitions.
    """
    name, prefix, suffix, parts = definition
    part_strings = [build_regexp(part, None) if isinstance(part, tuple) else part
                    for part in parts]
    regexp = "%s(?P<%s>%s)%s" % (prefix, name, "|".join(part_strings), suffix)
    return re.compile(regexp) if compile_patterns else regexp


_URI_PATTERN = r"""
    %(start_string_prefix)s
    (?P<whole>
      (?P<absolute>           # absolute URI
        (?P<scheme>             # scheme (http, ftp, mailto)
          [a-zA-Z][a-zA-Z0-9.+-]*
        )
        :
        (
          (                       # either:
            (//?)?                  # hierarchical URI
            %(uric)s*               # URI characters
            %(uri_end)s             # final URI char
          )
          (                       # optional query
            \?%(uric)s*
            %(uri_end)s
          )?
          (                       # optional fragment
            \#%(uric)s*
            %(uri_end)s
          )?
        )
      )
    |                       # *OR*
      (?P<email>              # email address
        %(email_pattern)s
      )
    )
    %(end_string_suffix)s
    """

_PEP_PATTERN = r"""
    %(start_string_prefix)s
    (
      (pep-(?P<pepnum1>\d+)(.txt)?) # reference to source file
    |
      (PEP\s+(?P<pepnum2>\d+))      # reference by name
    )
    %(end_string_suffix)s"""

_RFC_PATTERN = r"""
    %(start_string_prefix)s
    (RFC(-|\s+)?(?P<rfcnum>\d+))
    %(end_string_suffix)s"""

_INTERPRETED_END = r"""
    %(non_unescaped_whitespace_escape_before)s
    (
      `
      (?P<suffix>
        (?P<role>:%(simplename)s:)?
        (?P<refend>__?)?
      )
    )
    %(end_string_suffix)s
    """

_EMBEDDED_LINK = r"""
    (
      (?:[ \n]+|^)            # spaces or beginning of line/string
      <                       # open bracket
      %(non_whitespace_after)s
      (([^<>]|\x00[<>])+)     # anything but unescaped angle brackets
      %(non_whitespace_escape_before)s
      >                       # close bracket
    )
    $                         # end of string
    """


class Inliner:
    """Parse inline markup; call the `parse()` method."""

    non_whitespace_before = r"(?<!\s)"
    non_whitespace_escape_before = r"(?<![\s\x00])"
    non_unescaped_whitespace_escape_before = r"(?<!(?<!\x00)[\s\x00])"
    non_whitespace_after = r"(?!\s)"
    simplename = r"(?:(?!_)\w)+(?:[-._+:](?:(?!_)\w)+)*"
    uric = r"""[-_.!~*'()[\];/:@&=+$,%a-zA-Z0-9\x00]"""
    uri_end_delim = r"""[>]"""
    urilast = r"""[_~*/=+a-zA-Z0-9]"""
    uri_end = r"""(?:%(urilast)s|%(uric)s(?=%(uri_end_delim)s))""" % locals()
    emailc = r"""[-_!~*'{|}/#?^`&=+$%a-zA-Z0-9\x00]"""
    email_pattern = r"""
          %(emailc)s+(?:\.%(emailc)s+)*   # name
          (?<!\x00)@                      # at
          %(emailc)s+(?:\.%(emailc)s*)*   # host
          %(uri_end)s                     # final URI char
          """
    rfc_url = "rfc%d.html"

    def __init__(self) -> None:
        self.implicit_dispatch: list[tuple[re.Pattern[str], Callable[..., list]]] = []

    def init_customizations(self, settings: Any) -> None:
        """Compile the patterns (depending on `settings`) and implicit dispatch."""
        if getattr(settings, "character_level_inline_markup", False):
            start_string_prefix = "(^|(?<!\x00))"
            end_string_suffix = ""
        else:
            start_string_prefix = r"(^|(?<=\s|[%s%s]))" % (punctuation_chars.openers,
                                                           punctuation_chars.delimiters)
            end_string_suffix = r"($|(?=\s|[\x00%s%s%s]))" % (
                punctuation_chars.closing_delimiters, punctuation_chars.delimiters,
                punctuation_chars.closers)
        args = {"start_string_prefix": start_string_prefix,
                "end_string_suffix": end_string_suffix}
        args.update(vars(self.__class__))
        for cls in type(self).__mro__:
            for key, value in vars(cls).items():
                args.setdefault(key, value)
        self.start_string_prefix = start_string_prefix
        self.end_string_suffix = end_string_suffix
        self.parts = self._initial_parts(start_string_prefix, end_string_suffix)
        self.patterns = self._compile_patterns(args)
        self.implicit_dispatch.append((self.patterns.uri, self.standalone_uri))
        if settings.pep_references:
            self.implicit_dispatch.append((self.patterns.pep, self.pep_reference))
        if settings.rfc_references:
            self.implicit_dispatch.append((self.patterns.rfc, self.rfc_reference))

    def _initial_parts(self, start_string_prefix: str, end_string_suffix: str) -> tuple:
        return ("initial_inline", start_string_prefix, "", [
            ("start", "", self.non_whitespace_after,
             [r"\*\*", r"\*(?!\*)", r"``", r"_`", r"\|(?!\|)"]),
            ("whole", "", end_string_suffix, [
                r"(?P<refname>%s)(?P<refend>__?)" % self.simplename,
                ("footnotelabel", r"\[", r"(?P<fnend>\]_)",
                 [r"[0-9]+", r"\#(%s)?" % self.simplename, r"\*",
                  r"(?P<citationlabel>%s)" % self.simplename])]),
            ("backquote", r"(?P<role>(:%s:)?)" % self.simplename, self.non_whitespace_after,
             ["`(?!`)"]),
        ])

    def _compile_patterns(self, args: dict[str, Any]) -> Struct:
        suffix = args["end_string_suffix"]
        uri_args = {**args, "email_pattern": self.email_pattern % args}
        return Struct(
            initial=build_regexp(self.parts),
            emphasis=re.compile(self.non_whitespace_escape_before + r"(\*)" + suffix),
            strong=re.compile(self.non_whitespace_escape_before + r"(\*\*)" + suffix),
            interpreted_or_phrase_ref=re.compile(_INTERPRETED_END % args, re.VERBOSE),
            embedded_link=re.compile(_EMBEDDED_LINK % args, re.VERBOSE),
            literal=re.compile(self.non_whitespace_before + "(``)" + suffix),
            target=re.compile(self.non_whitespace_escape_before + r"(`)" + suffix),
            substitution_ref=re.compile(self.non_whitespace_escape_before + r"(\|_{0,2})"
                                        + suffix),
            email=re.compile(self.email_pattern % args + "$", re.VERBOSE),
            uri=re.compile(_URI_PATTERN % uri_args, re.VERBOSE),
            pep=re.compile(_PEP_PATTERN % args, re.VERBOSE),
            rfc=re.compile(_RFC_PATTERN % args, re.VERBOSE),
        )

    def parse(self, text: str, lineno: int, memo: Any,
              parent: nodes.Element) -> tuple[list[nodes.Node], list[nodes.system_message]]:
        """Return (nodes, system messages) for the inline markup of `text`."""
        self.document = memo.document
        self.language = memo.language
        self.reporter = self.document.reporter
        self.parent = parent
        remaining = escape2null(text)
        processed: list[nodes.Node] = []
        unprocessed: list[str] = []
        messages: list[nodes.system_message] = []
        while remaining:
            match = self.patterns.initial.search(remaining)
            if not match:
                break
            groups = match.groupdict()
            method = self.dispatch[groups["start"] or groups["backquote"] or groups["refend"]
                                   or groups["fnend"]]
            before, inlines, remaining, sysmessages = method(self, match, lineno)
            unprocessed.append(before)
            messages += sysmessages
            if inlines:
                processed += self.implicit_inline("".join(unprocessed), lineno)
                processed += inlines
                unprocessed = []
        remaining = "".join(unprocessed) + remaining
        if remaining:
            processed += self.implicit_inline(remaining, lineno)
        return processed, messages

    def quoted_start(self, match: re.Match[str]) -> bool:
        """Whether the start-string is quoted (enclosed in matching punctuation)."""
        string = match.string
        start = match.start()
        if start == 0:
            return False
        prestart = string[start - 1]
        try:
            poststart = string[match.end()]
        except IndexError:
            return True
        return punctuation_chars.match_chars(prestart, poststart)

    def inline_obj(self, match: re.Match[str], lineno: int, end_pattern: re.Pattern[str],
                   nodeclass: type, restore_backslashes: bool = False) -> tuple:
        """Parse an inline object delimited by start- and end-string."""
        string = match.string
        matchstart = match.start("start")
        matchend = match.end("start")
        if self.quoted_start(match):
            return string[:matchend], [], string[matchend:], [], ""
        endmatch = end_pattern.search(string[matchend:])
        if endmatch and endmatch.start(1):
            text = endmatch.string[:endmatch.start(1)]
            if restore_backslashes:
                text = unescape(text, True)
            textend = matchend + endmatch.end(1)
            rawsource = unescape(string[matchstart:textend], True)
            node = nodeclass(rawsource, text)
            return string[:matchstart], [node], string[textend:], [], endmatch.group(1)
        msg = self.reporter.warning("Inline %s start-string without end-string."
                                    % nodeclass.__name__, line=lineno)
        text = unescape(string[matchstart:matchend], True)
        prb = self.problematic(text, text, msg)
        return string[:matchstart], [prb], string[matchend:], [msg], ""

    def problematic(self, text: str, rawsource: str,
                    message: nodes.system_message) -> nodes.problematic:
        msgid = self.document.set_id(message, self.parent)
        problematic = nodes.problematic(rawsource, text, refid=msgid)
        message.add_backref(self.document.set_id(problematic))
        return problematic

    def emphasis(self, match: re.Match[str], lineno: int) -> tuple:
        return self.inline_obj(match, lineno, self.patterns.emphasis, nodes.emphasis)[:4]

    def strong(self, match: re.Match[str], lineno: int) -> tuple:
        return self.inline_obj(match, lineno, self.patterns.strong, nodes.strong)[:4]

    def interpreted_or_phrase_ref(self, match: re.Match[str], lineno: int) -> tuple:
        end_pattern = self.patterns.interpreted_or_phrase_ref
        string = match.string
        matchstart = match.start("backquote")
        matchend = match.end("backquote")
        rolestart = match.start("role")
        role = match.group("role")
        position = ""
        if role:
            role = role[1:-1]
            position = "prefix"
        elif self.quoted_start(match):
            return string[:matchend], [], string[matchend:], []
        endmatch = end_pattern.search(string[matchend:])
        if not (endmatch and endmatch.start(1)):
            msg = self.reporter.warning("Inline interpreted text or phrase reference "
                                        "start-string without end-string.", line=lineno)
            text = unescape(string[matchstart:matchend], True)
            return string[:matchstart], [self.problematic(text, text, msg)], \
                string[matchend:], [msg]
        textend = matchend + endmatch.end()
        if endmatch.group("role"):
            if role:
                return self._role_error(
                    string, rolestart, textend, lineno,
                    "Multiple roles in interpreted text (both prefix and suffix present; "
                    "only one allowed).")
            role = endmatch.group("suffix")[1:-1]
            position = "suffix"
        escaped = endmatch.string[:endmatch.start(1)]
        rawsource = unescape(string[matchstart:textend], True)
        if rawsource[-1:] == "_":
            if role:
                return self._role_error(
                    string, rolestart, textend, lineno,
                    "Mismatch: both interpreted text role %s and reference suffix." % position)
            return self.phrase_ref(string[:matchstart], string[textend:], rawsource, escaped)
        rawsource = unescape(string[rolestart:textend], True)
        nodelist, messages = self.interpreted(rawsource, escaped, role, lineno)
        return string[:rolestart], nodelist, string[textend:], messages

    def _role_error(self, string: str, rolestart: int, textend: int, lineno: int,
                    message: str) -> tuple:
        msg = self.reporter.warning(message, line=lineno)
        text = unescape(string[rolestart:textend], True)
        return string[:rolestart], [self.problematic(text, text, msg)], string[textend:], [msg]

    def phrase_ref(self, before: str, after: str, rawsource: str, escaped: str,
                   text: str | None = None) -> tuple:
        """Reference (with optional embedded URI or alias) for a phrase."""
        match = self.patterns.embedded_link.search(escaped)
        target, aliastype, alias = None, "", ""
        if match:
            text, unescaped, rawtext, target, aliastype, alias = self._embedded(match, escaped)
        else:
            text = escaped
            unescaped = unescape(text)
            rawtext = unescape(escaped, True)
        refname = normalize_name(unescaped)
        reference = nodes.reference(rawsource, text, name=whitespace_normalize_name(unescaped))
        reference[0].rawsource = rawtext
        node_list: list[nodes.Node] = [reference]
        if rawsource[-2:] == "__":
            if target and aliastype == "name":
                reference["refname"] = alias
                self.document.note_refname(reference)
            elif target and aliastype == "uri":
                reference["refuri"] = alias
            else:
                reference["anonymous"] = True
        elif target:
            self._link_embedded(reference, target, refname, aliastype, alias)
            node_list.append(target)
        else:
            reference["refname"] = refname
            self.document.note_refname(reference)
        return before, node_list, after, []

    def _embedded(self, match: re.Match[str], escaped: str) -> tuple:
        """(text, unescaped, rawtext, target, alias type, alias) of an embedded link."""
        text = escaped[:match.start(0)]
        unescaped = unescape(text)
        rawtext = unescape(text, True)
        aliastext = match.group(2)
        rawaliastext = unescape(aliastext, True)
        underscore_escaped = rawaliastext.endswith(r"\_")
        if aliastext.endswith("_") and not (underscore_escaped
                                            or self.patterns.uri.match(aliastext)):
            aliastype = "name"
            alias = normalize_name(unescape(aliastext[:-1]))
            target = nodes.target(match.group(1), refname=alias)
            target.indirect_reference_name = whitespace_normalize_name(unescape(aliastext[:-1]))
        else:
            aliastype = "uri"
            alias_parts = split_escaped_whitespace(match.group(2))
            alias = " ".join("".join(part.split()) for part in alias_parts)
            alias = self.adjust_uri(unescape(alias))
            if alias.endswith(r"\_"):
                alias = alias[:-2] + "_"
            target = nodes.target(match.group(1), refuri=alias)
            target.referenced = 1
        if not aliastext:
            raise ApplicationError("problem with embedded link: %r" % aliastext)
        if not text:
            text = alias
            unescaped = unescape(text)
            rawtext = rawaliastext
        return text, unescaped, rawtext, target, aliastype, alias

    def _link_embedded(self, reference: nodes.reference, target: nodes.target, refname: str,
                       aliastype: str, alias: str) -> None:
        target["names"].append(refname)
        if aliastype == "name":
            reference["refname"] = alias
            self.document.note_indirect_target(target)
            self.document.note_refname(reference)
        else:
            reference["refuri"] = alias
        self.document.note_implicit_target(target, self.parent)

    def adjust_uri(self, uri: str) -> str:
        return "mailto:" + uri if self.patterns.email.match(uri) else uri

    def interpreted(self, rawsource: str, text: str, role: str, lineno: int) -> tuple:
        from docutils.parsers.rst import roles

        role_fn, messages = roles.role(role, self.language, lineno, self.reporter)
        if role_fn:
            nodelist, messages2 = role_fn(role, rawsource, text, lineno, self)
            return nodelist, messages + messages2
        msg = self.reporter.error('Unknown interpreted text role "%s".' % role, line=lineno)
        return [self.problematic(rawsource, rawsource, msg)], [*messages, msg]

    def literal(self, match: re.Match[str], lineno: int) -> tuple:
        return self.inline_obj(match, lineno, self.patterns.literal, nodes.literal,
                               restore_backslashes=True)[:4]

    def inline_internal_target(self, match: re.Match[str], lineno: int) -> tuple:
        before, inlines, remaining, sysmessages, _end = self.inline_obj(
            match, lineno, self.patterns.target, nodes.target)
        if inlines and isinstance(inlines[0], nodes.target):
            assert len(inlines) == 1
            target = inlines[0]
            target["names"].append(normalize_name(target.astext()))
            self.document.note_explicit_target(target, self.parent)
        return before, inlines, remaining, sysmessages

    def substitution_reference(self, match: re.Match[str], lineno: int) -> tuple:
        before, inlines, remaining, sysmessages, endstring = self.inline_obj(
            match, lineno, self.patterns.substitution_ref, nodes.substitution_reference)
        if len(inlines) == 1 and isinstance(inlines[0], nodes.substitution_reference):
            subref_node = inlines[0]
            subref_text = subref_node.astext()
            self.document.note_substitution_ref(subref_node, subref_text)
            if endstring[-1:] == "_":
                reference_node = nodes.reference("|%s%s" % (subref_text, endstring), "")
                if endstring[-2:] == "__":
                    reference_node["anonymous"] = True
                else:
                    reference_node["refname"] = normalize_name(subref_text)
                    self.document.note_refname(reference_node)
                reference_node += subref_node
                inlines = [reference_node]
        return before, inlines, remaining, sysmessages

    def footnote_reference(self, match: re.Match[str], lineno: int) -> tuple:
        """Handle footnote and citation references (``[label]_``)."""
        label = match.group("footnotelabel")
        refname = normalize_name(label)
        before = match.string[:match.start("whole")]
        remaining = match.string[match.end("whole"):]
        if match.group("citationlabel"):
            refnode = nodes.citation_reference("[%s]_" % label, refname=refname)
            refnode += nodes.Text(label)
            self.document.note_citation_ref(refnode)
            return before, [refnode], remaining, []
        refnode = nodes.footnote_reference("[%s]_" % label)
        if refname[0] == "#":
            refname = refname[1:]
            refnode["auto"] = 1
            self.document.note_autofootnote_ref(refnode)
        elif refname == "*":
            refname = ""
            refnode["auto"] = "*"
            self.document.note_symbol_footnote_ref(refnode)
        else:
            refnode += nodes.Text(label)
        if refname:
            refnode["refname"] = refname
            self.document.note_footnote_ref(refnode)
        if utils.get_trim_footnote_ref_space(self.document.settings):
            before = before.rstrip()
        return before, [refnode], remaining, []

    def reference(self, match: re.Match[str], lineno: int, anonymous: bool = False) -> tuple:
        referencename = match.group("refname")
        refname = normalize_name(referencename)
        referencenode = nodes.reference(referencename + match.group("refend"), referencename,
                                        name=whitespace_normalize_name(referencename))
        referencenode[0].rawsource = referencename
        if anonymous:
            referencenode["anonymous"] = True
        else:
            referencenode["refname"] = refname
            self.document.note_refname(referencenode)
        string = match.string
        return (string[:match.start("whole")], [referencenode], string[match.end("whole"):], [])

    def anonymous_reference(self, match: re.Match[str], lineno: int) -> tuple:
        return self.reference(match, lineno, anonymous=True)

    def standalone_uri(self, match: re.Match[str], lineno: int) -> list[nodes.Node]:
        scheme = match.group("scheme")
        if scheme and scheme.lower() not in urischemes.schemes:
            raise MarkupMismatch
        addscheme = "mailto:" if match.group("email") else ""
        text = match.group("whole")
        refuri = addscheme + unescape(text)
        return [nodes.reference(unescape(text, True), text, refuri=refuri)]

    def pep_reference(self, match: re.Match[str], lineno: int) -> list[nodes.Node]:
        text = match.group(0)
        if text.startswith("pep-"):
            pepnum = int(unescape(match.group("pepnum1")))
        elif text.startswith("PEP"):
            pepnum = int(unescape(match.group("pepnum2")))
        else:
            raise MarkupMismatch
        settings = self.document.settings
        ref = settings.pep_base_url + settings.pep_file_url_template % pepnum
        return [nodes.reference(unescape(text, True), text, refuri=ref)]

    def rfc_reference(self, match: re.Match[str], lineno: int) -> list[nodes.Node]:
        text = match.group(0)
        if not text.startswith("RFC"):
            raise MarkupMismatch
        rfcnum = int(unescape(match.group("rfcnum")))
        ref = self.document.settings.rfc_base_url + self.rfc_url % rfcnum
        return [nodes.reference(unescape(text, True), text, refuri=ref)]

    def implicit_inline(self, text: str, lineno: int) -> list[nodes.Node]:
        """Check `text` for implicit inline markup (standalone URIs etc.)."""
        if not text:
            return []
        for pattern, method in self.implicit_dispatch:
            match = pattern.search(text)
            if match:
                try:
                    return (self.implicit_inline(text[:match.start()], lineno)
                            + method(match, lineno)
                            + self.implicit_inline(text[match.end():], lineno))
                except MarkupMismatch:
                    pass
        return [nodes.Text(text)]

    dispatch = {
        "*": emphasis,
        "**": strong,
        "`": interpreted_or_phrase_ref,
        "``": literal,
        "_`": inline_internal_target,
        "]_": footnote_reference,
        "|": substitution_reference,
        "_": reference,
        "__": anonymous_reference,
    }
