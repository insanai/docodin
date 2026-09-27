"""Language specifics for LaTeX (the `babel` package)."""

from __future__ import annotations

from typing import Any

from docutils import utils

__docformat__ = "reStructuredText"


class Babel:
    """Language specifics for LaTeX."""

    # TeX (babel) language names:
    # ! not all of these are supported by Docutils!
    #
    # based on LyX' languages file with adaptions to `BCP 47`_
    # (https://www.rfc-editor.org/rfc/bcp/bcp47.txt) and
    # http://www.tug.org/TUGboat/Articles/tb29-3/tb93miklavec.pdf
    # * the key without subtags is the default
    # * case is ignored
    # cf. https://docutils.sourceforge.io/docs/howto/i18n.html
    #     https://www.w3.org/International/articles/language-tags/
    # and http://www.iana.org/assignments/language-subtag-registry
    language_codes = {
        # code          TeX/Babel-name    comment
        "af":           "afrikaans",
        "ar":           "arabic",
        # "be":           "belarusian",
        "bg":           "bulgarian",
        "br":           "breton",
        "ca":           "catalan",
        # "cop":          "coptic",
        "cs":           "czech",
        "cy":           "welsh",
        "da":           "danish",
        "de":           "ngerman",        # new spelling (de_1996)
        "de-1901":      "german",         # old spelling
        "de-AT":        "naustrian",
        "de-AT-1901":   "austrian",
        "dsb":          "lowersorbian",
        "el":           "greek",          # monotonic (el-monoton)
        "el-polyton":   "polutonikogreek",
        "en":           "english",        # TeX' default language
        "en-AU":        "australian",
        "en-CA":        "canadian",
        "en-GB":        "british",
        "en-NZ":        "newzealand",
        "en-US":        "american",
        "eo":           "esperanto",
        "es":           "spanish",
        "et":           "estonian",
        "eu":           "basque",
        # "fa":           "farsi",
        "fi":           "finnish",
        "fr":           "french",
        "fr-CA":        "canadien",
        "ga":           "irish",          # Irish Gaelic
        # "grc":                          # Ancient Greek
        "grc-ibycus":   "ibycus",         # Ibycus encoding
        "gl":           "galician",
        "he":           "hebrew",
        "hr":           "croatian",
        "hsb":          "uppersorbian",
        "hu":           "magyar",
        "ia":           "interlingua",
        "id":           "bahasai",        # Bahasa (Indonesian)
        "is":           "icelandic",
        "it":           "italian",
        "ja":           "japanese",
        "kk":           "kazakh",
        "la":           "latin",
        "lt":           "lithuanian",
        "lv":           "latvian",
        "mn":           "mongolian",      # Mongolian, Cyrillic (mn-cyrl)
        "ms":           "bahasam",        # Bahasa (Malay)
        "nb":           "norsk",          # Norwegian Bokmal
        "nl":           "dutch",
        "nn":           "nynorsk",        # Norwegian Nynorsk
        "no":           "norsk",          # Norwegian (Bokmal)
        "pl":           "polish",
        "pt":           "portuges",
        "pt-BR":        "brazil",
        "ro":           "romanian",
        "ru":           "russian",
        "se":           "samin",          # North Sami
        "sh-Cyrl":      "serbianc",       # Serbo-Croatian, Cyrillic
        "sh-Latn":      "serbian",        # Serbo-Croatian, Latin (cf. 'hr')
        "sk":           "slovak",
        "sl":           "slovene",
        "sq":           "albanian",
        "sr":           "serbianc",       # Serbian, Cyrillic (contributed)
        "sr-Latn":      "serbian",        # Serbian, Latin script
        "sv":           "swedish",
        # "th":           "thai",
        "tr":           "turkish",
        "uk":           "ukrainian",
        "vi":           "vietnam",
        # zh-Latn:      Chinese Pinyin
        }
    # normalize (downcase) keys
    language_codes = {k.lower(): v for k, v in language_codes.items()}

    warn_msg = 'Language "%s" not supported by LaTeX (babel)'

    # "Active characters" are shortcuts that start a LaTeX macro and may need
    # escaping for literals use. Characters that prevent literal use (e.g.
    # starting accent macros like "a -> ä) will be deactivated if one of the
    # defining languages is used in the document.
    # Special cases:
    #  ~ (tilde) -- used in estonian, basque, galician, and old versions of
    #    spanish -- cannot be deactivated as it denotes a no-break space macro,
    #  " (straight quote) -- used in albanian, austrian, basque
    #    brazil, bulgarian, catalan, czech, danish, dutch, estonian,
    #    finnish, galician, german, icelandic, italian, latin, naustrian,
    #    ngerman, norsk, nynorsk, polish, portuges, russian, serbian, slovak,
    #    slovene, spanish, swedish, ukrainian, and uppersorbian --
    #    is escaped as ``\textquotedbl``.
    active_chars = {
        # TeX/Babel-name:  active characters to deactivate
        # "breton":        ":;!?"  # ensure whitespace
        # "esperanto":     "^",
        # "estonian":      "~\"`",
        # "french":        ":;!?"  # ensure whitespace
        "galician":        ".<>",  # also '~"'
        # "magyar":        "`",  # for special hyphenation cases
        "spanish":         ".<>",  # old versions also "~"
        # "turkish":       ":!="  # ensure whitespace
        }

    def __init__(self, language_code: str, reporter: Any = None) -> None:
        self.reporter = reporter
        self.language = self.language_name(language_code)
        self.otherlanguages = {}

    def __call__(self) -> str:
        """Return the babel call with correct options and settings"""
        languages = sorted(self.otherlanguages.keys())
        if languages:
            languages.append(f'main={self.language or "english"}')
        else:
            languages.append(self.language or "english")
        self.setup = [r"\usepackage[%s]{babel}" % ",".join(languages)]
        # Deactivate "active characters"
        shorthands = []
        for c in "".join(self.active_chars.get(lng, "") for lng in languages):
            if c not in shorthands:
                shorthands.append(c)
        if shorthands:
            self.setup.append(r"\AtBeginDocument{\shorthandoff{%s}}" % "".join(shorthands))
        self._deactivate_tilde(languages)
        if languages[-1] == "main=english" and "french" in self.otherlanguages:
            self.setup += ["% Prevent side-effects if French hyphenation "
                           "patterns are not loaded:",
                           r"\frenchbsetup{StandardLayout}",
                           r"\AtBeginDocument{\selectlanguage{%s}"
                           r"\noextrasfrench}" % self.language]
        return "\n".join(self.setup)

    def _deactivate_tilde(self, languages: list[str]) -> None:
        # Including '~' in shorthandoff prevents its use as no-break space
        if "galician" in languages:
            self.setup.append(r"\deactivatetilden % restore ~ in Galician")
        for lng in ("estonian", "basque"):
            if lng in languages:
                self.setup.extend([r"\makeatletter",
                                   r"  \addto\extras%s{\bbl@deactivate{~}}" % lng,
                                   r"\makeatother"])

    def language_name(self, language_code: str) -> str:
        """Return TeX language name for `language_code`"""
        for tag in utils.normalize_language_tag(language_code):
            try:
                return self.language_codes[tag]
            except KeyError:
                pass
        if self.reporter is not None:
            self.reporter.warning(self.warn_msg % language_code)
        return ""

    def get_language(self) -> str:
        # Obsolete, kept for backwards compatibility with Sphinx
        return self.language
