"""LaTeX encoding maps: LaTeX representations for active and Unicode characters."""

from __future__ import annotations

__docformat__ = "reStructuredText"


class CharMaps:
    """LaTeX representations for active and Unicode characters."""

    # characters that need escaping even in `alltt` environments:
    alltt = {
        ord("\\"): "\\textbackslash{}",
        ord("{"): "\\{",
        ord("}"): "\\}",
    }
    # characters that normally need escaping:
    special = {
        ord("#"): "\\#",
        ord("$"): "\\$",
        ord("%"): "\\%",
        ord("&"): "\\&",
        ord("~"): "\\textasciitilde{}",
        ord("_"): "\\_",
        ord("^"): "\\textasciicircum{}",
        # straight double quotes are "active" in many languages
        ord('"'): "\\textquotedbl{}",
        # Square brackets are ordinary chars and cannot be escaped with '\',
        # so we put them in a group "{[}". (Alternative: ensure that all
        # macros with optional arguments are terminated with {} and text
        # inside any optional argument is put in a group ``[{text}]``).
        # Commands with optional args inside an optional arg must be put in a
        # group, e.g. ``\item[{\hyperref[label]{text}}]``.
        ord("["): "{[}",
        ord("]"): "{]}",
        # the soft hyphen is unknown in 8-bit text
        # and not properly handled by XeTeX
        0x00AD: "\\-",  # SOFT HYPHEN
    }
    # Unicode chars that are not recognized by LaTeX's utf8 encoding
    unsupported_unicode = {
        # TODO: ensure white space also at the beginning of a line?
        # 0x00A0: "\\leavevmode\\nobreak\\vadjust{}~"
        0x2000: "\\enskip",                        # EN QUAD
        0x2001: "\\quad",                          # EM QUAD
        0x2002: "\\enskip",                        # EN SPACE
        0x2003: "\\quad",                          # EM SPACE
        0x2008: "\\,",                             # PUNCTUATION SPACE
        0x200b: "\\hspace{0pt}",                   # ZERO WIDTH SPACE
        0x202F: "\\,",                             # NARROW NO-BREAK SPACE
        # 0x02d8: "\\\u{ }",                       # BREVE
        0x2011: "\\hbox{-}",                       # NON-BREAKING HYPHEN
        0x212b: "\\AA",                            # ANGSTROM SIGN
        0x21d4: "\\ensuremath{\\Leftrightarrow}",  # LEFT RIGHT DOUBLE ARROW
        0x2260: "\\ensuremath{\\neq}",             # NOT EQUAL TO
        0x2261: "\\ensuremath{\\equiv}",           # IDENTICAL TO
        0x2264: "\\ensuremath{\\le}",              # LESS-THAN OR EQUAL TO
        0x2265: "\\ensuremath{\\ge}",              # GREATER-THAN OR EQUAL TO
        # Docutils footnote symbols:
        0x2660: "\\ensuremath{\\spadesuit}",
        0x2663: "\\ensuremath{\\clubsuit}",
        0xfb00: "ff",                              # LATIN SMALL LIGATURE FF
        0xfb01: "fi",                              # LATIN SMALL LIGATURE FI
        0xfb02: "fl",                              # LATIN SMALL LIGATURE FL
        0xfb03: "ffi",                             # LATIN SMALL LIGATURE FFI
        0xfb04: "ffl",                             # LATIN SMALL LIGATURE FFL
    }
    # Unicode chars that are recognized by LaTeX's utf8 encoding
    utf8_supported_unicode = {
        0x00A0: "~",                   # NO-BREAK SPACE
        0x00AB: "\\guillemotleft{}",   # LEFT-POINTING DOUBLE ANGLE QUOTATION
        0x00bb: "\\guillemotright{}",  # RIGHT-POINTING DOUBLE ANGLE QUOTATION
        0x200C: "\\textcompwordmark{}",  # ZERO WIDTH NON-JOINER
        0x2013: "\\textendash{}",
        0x2014: "\\textemdash{}",
        0x2018: "\\textquoteleft{}",
        0x2019: "\\textquoteright{}",
        0x201A: "\\quotesinglbase{}",    # SINGLE LOW-9 QUOTATION MARK
        0x201C: "\\textquotedblleft{}",
        0x201D: "\\textquotedblright{}",
        0x201E: "\\quotedblbase{}",      # DOUBLE LOW-9 QUOTATION MARK
        0x2030: "\\textperthousand{}",   # PER MILLE SIGN
        0x2031: "\\textpertenthousand{}",  # PER TEN THOUSAND SIGN
        0x2039: "\\guilsinglleft{}",
        0x203A: "\\guilsinglright{}",
        0x2423: "\\textvisiblespace{}",  # OPEN BOX
        0x2020: "\\dag{}",
        0x2021: "\\ddag{}",
        0x2026: "\\dots{}",
        0x2122: "\\texttrademark{}",
    }
    # recognized with "utf8", if textcomp is loaded
    textcomp = {
        # Latin-1 Supplement
        0x00a2: "\\textcent{}",              # ¢ CENT SIGN
        0x00a4: "\\textcurrency{}",          # ¤ CURRENCY SYMBOL
        0x00a5: "\\textyen{}",               # ¥ YEN SIGN
        0x00a6: "\\textbrokenbar{}",         # ¦ BROKEN BAR
        0x00a7: "\\textsection{}",           # § SECTION SIGN
        0x00a8: "\\textasciidieresis{}",     # ¨ DIAERESIS
        0x00a9: "\\textcopyright{}",         # © COPYRIGHT SIGN
        0x00aa: "\\textordfeminine{}",       # ª FEMININE ORDINAL INDICATOR
        0x00ac: "\\textlnot{}",              # ¬ NOT SIGN
        0x00ae: "\\textregistered{}",        # ® REGISTERED SIGN
        0x00af: "\\textasciimacron{}",       # ¯ MACRON
        0x00b0: "\\textdegree{}",            # ° DEGREE SIGN
        0x00b1: "\\textpm{}",                # ± PLUS-MINUS SIGN
        0x00b2: "\\texttwosuperior{}",       # ² SUPERSCRIPT TWO
        0x00b3: "\\textthreesuperior{}",     # ³ SUPERSCRIPT THREE
        0x00b4: "\\textasciiacute{}",        # ´ ACUTE ACCENT
        0x00b5: "\\textmu{}",                # µ MICRO SIGN
        0x00b6: "\\textparagraph{}",         # ¶ PILCROW SIGN # != \textpilcrow
        0x00b9: "\\textonesuperior{}",       # ¹ SUPERSCRIPT ONE
        0x00ba: "\\textordmasculine{}",      # º MASCULINE ORDINAL INDICATOR
        0x00bc: "\\textonequarter{}",        # 1/4 FRACTION
        0x00bd: "\\textonehalf{}",           # 1/2 FRACTION
        0x00be: "\\textthreequarters{}",     # 3/4 FRACTION
        0x00d7: "\\texttimes{}",             # × MULTIPLICATION SIGN
        0x00f7: "\\textdiv{}",               # ÷ DIVISION SIGN
        # others
        0x0192: "\\textflorin{}",            # LATIN SMALL LETTER F WITH HOOK
        0x02b9: "\\textasciiacute{}",        # MODIFIER LETTER PRIME
        0x02ba: "\\textacutedbl{}",          # MODIFIER LETTER DOUBLE PRIME
        0x2016: "\\textbardbl{}",            # DOUBLE VERTICAL LINE
        0x2022: "\\textbullet{}",            # BULLET
        0x2032: "\\textasciiacute{}",        # PRIME
        0x2033: "\\textacutedbl{}",          # DOUBLE PRIME
        0x2035: "\\textasciigrave{}",        # REVERSED PRIME
        0x2036: "\\textgravedbl{}",          # REVERSED DOUBLE PRIME
        0x203b: "\\textreferencemark{}",     # REFERENCE MARK
        0x203d: "\\textinterrobang{}",       # INTERROBANG
        0x2044: "\\textfractionsolidus{}",   # FRACTION SLASH
        0x2045: "\\textlquill{}",            # LEFT SQUARE BRACKET WITH QUILL
        0x2046: "\\textrquill{}",            # RIGHT SQUARE BRACKET WITH QUILL
        0x2052: "\\textdiscount{}",          # COMMERCIAL MINUS SIGN
        0x20a1: "\\textcolonmonetary{}",     # COLON SIGN
        0x20a3: "\\textfrenchfranc{}",       # FRENCH FRANC SIGN
        0x20a4: "\\textlira{}",              # LIRA SIGN
        0x20a6: "\\textnaira{}",             # NAIRA SIGN
        0x20a9: "\\textwon{}",               # WON SIGN
        0x20ab: "\\textdong{}",              # DONG SIGN
        0x20ac: "\\texteuro{}",              # EURO SIGN
        0x20b1: "\\textpeso{}",              # PESO SIGN
        0x20b2: "\\textguarani{}",           # GUARANI SIGN
        0x2103: "\\textcelsius{}",           # DEGREE CELSIUS
        0x2116: "\\textnumero{}",            # NUMERO SIGN
        0x2117: "\\textcircledP{}",          # SOUND RECORDING COPYRIGHT
        0x211e: "\\textrecipe{}",            # PRESCRIPTION TAKE
        0x2120: "\\textservicemark{}",       # SERVICE MARK
        0x2122: "\\texttrademark{}",         # TRADE MARK SIGN
        0x2126: "\\textohm{}",               # OHM SIGN
        0x2127: "\\textmho{}",               # INVERTED OHM SIGN
        0x212e: "\\textestimated{}",         # ESTIMATED SYMBOL
        0x2190: "\\textleftarrow{}",         # LEFTWARDS ARROW
        0x2191: "\\textuparrow{}",           # UPWARDS ARROW
        0x2192: "\\textrightarrow{}",        # RIGHTWARDS ARROW
        0x2193: "\\textdownarrow{}",         # DOWNWARDS ARROW
        0x2212: "\\textminus{}",             # MINUS SIGN
        0x2217: "\\textasteriskcentered{}",  # ASTERISK OPERATOR
        0x221a: "\\textsurd{}",              # SQUARE ROOT
        0x2422: "\\textblank{}",             # BLANK SYMBOL
        0x25e6: "\\textopenbullet{}",        # WHITE BULLET
        0x25ef: "\\textbigcircle{}",         # LARGE CIRCLE
        0x266a: "\\textmusicalnote{}",       # EIGHTH NOTE
        0x26ad: "\\textmarried{}",           # MARRIAGE SYMBOL
        0x26ae: "\\textdivorced{}",          # DIVORCE SYMBOL
        0x27e8: "\\textlangle{}",            # MATHEMATICAL LEFT ANGLE BRACKET
        0x27e9: "\\textrangle{}",            # MATHEMATICAL RIGHT ANGLE BRACKET
    }
    # Unicode chars that require a feature/package to render
    pifont = {
        0x2665: "\\ding{170}",               # black heartsuit
        0x2666: "\\ding{169}",               # black diamondsuit
        0x2713: "\\ding{51}",                # check mark
        0x2717: "\\ding{55}",                # check mark
    }
    # TODO: greek alphabet ... ?
    # see also LaTeX codec
    # http://aspn.activestate.com/ASPN/Cookbook/Python/Recipe/252124
    # and unimap.py from TeXML
