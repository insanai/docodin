"""Translation tables of `math2html` (from eLyXer's configuration file).

The tables map LaTeX command names (with the leading backslash) to their HTML
translation. What kind of HTML a command yields depends on the table it is found in:

* plain replacement text (`FormulaConfig.commands`, `alphacommands`, `limitcommands`,
  `spacedcommands`),
* a tag that wraps the single argument (`onefunctions`, `fontfunctions`, `textfunctions`),
* a combining character added to the argument (`combiningfunctions`),
* a symbol set over or under the argument (`oversetfunctions`, `undersetfunctions`),
* read and write templates for commands with several arguments (`hybridfunctions`).

The tables are public and may be extended at run time.
"""

from __future__ import annotations

from docutils.utils.math import tex2unichar

__docformat__ = "reStructuredText"


def _commands(table: dict[str, str]) -> dict[str, str]:
    """Return `table` with a backslash prepended to every key."""
    return {"\\" + name: value for name, value in table.items()}


def _bigoperators(css_class: str, **symbols: str) -> dict[str, str]:
    """Return a table of big-operator commands rendered in a styled span."""
    return {"\\" + name: f'<span class="{css_class}">{symbol}</span>'
            for name, symbol in symbols.items()}


class ContainerConfig:
    """Which containers hold (or lead to) the plain text of a formula."""

    extracttext = {
        "allowed": ["FormulaConstant"],
        "extracted": [
            "AlphaCommand", "Bracket", "BracketCommand", "CombiningFunction", "EmptyCommand",
            "FontFunction", "Formula", "FormulaNumber", "FormulaSymbol", "OneParamFunction",
            "OversetFunction", "RawText", "SpacedCommand", "SymbolFunction", "TextFunction",
            "UndersetFunction",
        ],
    }


class EscapeConfig:
    """Character replacements for text and HTML-special characters."""

    chars = {"\n": "", "'": "’", "`": "‘"}
    entities = {"&": "&amp;", "<": "&lt;", ">": "&gt;"}


class FormulaConfig:
    """The command and symbol tables driving the TeX to HTML translation."""

    alphacommands = {
        "\\AmS": '<span class="textsc">AmS</span>',
        "\\AA": "Å", "\\AE": "Æ", "\\DH": "Ð", "\\L": "Ł", "\\O": "Ø", "\\OE": "Œ",
        "\\TH": "Þ", "\\aa": "å", "\\ae": "æ", "\\dh": "ð", "\\i": "ı", "\\j": "ȷ",
        "\\l": "ł", "\\o": "ø", "\\oe": "œ", "\\ss": "ß", "\\th": "þ",
        "\\hbar": "ħ",  # cf. \hslash: ℏ in tex2unichar
    } | _commands(tex2unichar.mathalpha)

    array = {"begin": r"\begin", "cellseparator": "&", "end": r"\end", "rowseparator": r"\\"}

    # pieces of brackets spanning several rows: top, (extension, middle,) bottom
    bigbrackets = {
        "(": ["⎛", "⎜", "⎝"], ")": ["⎞", "⎟", "⎠"],
        "[": ["⎡", "⎢", "⎣"], "]": ["⎤", "⎥", "⎦"],
        "{": ["⎧", "⎪", "⎨", "⎩"], "}": ["⎫", "⎪", "⎬", "⎭"],
        "|": ["|"],  # 007C VERTICAL LINE
        "‖": ["‖"],  # 2016 DOUBLE VERTICAL LINE
    }

    bracketcommands = {
        "\\left": 'span class="stretchy"',
        "\\left.": '<span class="leftdot"></span>',
        "\\middle": 'span class="stretchy"',
        "\\right": 'span class="stretchy"',
        "\\right.": '<span class="rightdot"></span>',
    }

    combiningfunctions = {
        "\\'": "́", '\\"': "̈", "\\^": "̂", "\\`": "̀", "\\~": "̃",
        "\\c": "̧", "\\r": "̊", "\\s": "̩", "\\v": "̌",
        "\\textcircled": "⃝", "\\textsubring": "̥",
    } | _commands(tex2unichar.mathaccent)

    cmddict = (tex2unichar.mathbin | tex2unichar.mathopen | tex2unichar.mathclose
               | tex2unichar.mathfence | tex2unichar.mathord | tex2unichar.mathpunct
               | tex2unichar.space)

    commands = {
        "\\\\": "<br/>",
        "\\\n": " ", "\\\t": " ",  # escaped whitespace
        "\\centerdot": "⬝",  # BLACK VERY SMALL SQUARE, mathbin
        "\\colon": ": ", "\\copyright": "©", "\\dotminus": "∸",
        "\\dots": "…", "\\dotsb": "⋯", "\\dotsc": "…", "\\dotsi": "⋯", "\\dotsm": "⋯",
        "\\dotso": "…", "\\euro": "€", "\\guillemotleft": "«", "\\guillemotright": "»",
        "\\lVert": "‖", "\\Arrowvert": "‖", "\\lvert": "|", "\\newline": "<br/>",
        "\\nobreakspace": "\u00a0", "\\nolimits": "", "\\nonumber": "", "\\qquad": "\u2001\u2001",
        "\\rVert": "‖", "\\rvert": "|",
        "\\textasciicircum": "^", "\\textasciitilde": "~", "\\textbackslash": "\\",
        "\\textcopyright": "©", "\\textdegree": "°", "\\textellipsis": "…",
        "\\textemdash": "—", "\\textendash": "—", "\\texteuro": "€", "\\textgreater": ">",
        "\\textless": "<", "\\textordfeminine": "ª", "\\textordmasculine": "º",
        "\\textquotedblleft": "“", "\\textquotedblright": "”", "\\textquoteright": "’",
        "\\textregistered": "®", "\\textrightarrow": "→", "\\textsection": "§",
        "\\texttrademark": "™", "\\texttwosuperior": "²", "\\textvisiblespace": " ",
        "\\thickspace": '<span class="thickspace"> </span>',  # 5/13 em
        "\\;": '<span class="thickspace"> </span>',  # 5/13 em
        "\\triangle": "△",  # WHITE UP-POINTING TRIANGLE, mathord
        "\\triangledown": "▽",  # WHITE DOWN-POINTING TRIANGLE, mathord
        "\\varnothing": "⌀",  # ⌀ DIAMETER SIGN
        # functions
        "\\Pr": "Pr", "\\arccos": "arccos", "\\arcsin": "arcsin", "\\arctan": "arctan",
        "\\arg": "arg", "\\cos": "cos", "\\cosh": "cosh", "\\cot": "cot", "\\coth": "coth",
        "\\csc": "csc", "\\deg": "deg", "\\det": "det", "\\dim": "dim", "\\exp": "exp",
        "\\gcd": "gcd", "\\hom": "hom", "\\injlim": "inj\u202flim", "\\ker": "ker", "\\lg": "lg",
        "\\liminf": "lim\u202finf", "\\limsup": "lim\u202fsup", "\\ln": "ln", "\\log": "log",
        "\\projlim": "proj\u202flim", "\\sec": "sec", "\\sin": "sin", "\\sinh": "sinh",
        "\\tan": "tan", "\\tanh": "tanh",
    } | _commands(cmddict)

    oversetfunctions = {
        # math accents (cf. combiningfunctions)
        "\\bar": "‒",  # FIGURE DASH
        "\\dddot": '<span class="smallsymbol">⋯</span>',
        "\\vec": '<span class="smallsymbol">→</span>',
        # embellishments
        "\\overleftarrow": "⟵", "\\overleftrightarrow": "⟷", "\\overrightarrow": "⟶",
        "\\widehat": "^", "\\widetilde": "～",
    }

    undersetfunctions = {
        "\\underleftarrow": "⟵", "\\underleftrightarrow": "⟷", "\\underrightarrow": "⟶",
    }

    endings = {
        "bracket": "}", "complex": "\\]", "endafter": "}", "endbefore": "\\end{",
        "squarebracket": "]",
    }

    # column alignments of the multi-row environments without an argument
    environments = {
        "align": ["r", "l"], "eqnarray": ["r", "c", "l"], "gathered": ["l", "l"],
        "smallmatrix": ["c", "c"],
    }

    fontfunctions = {
        "\\boldsymbol": "b", "\\mathbf": "b", "\\mathit": "i",
        "\\mathbb": 'span class="blackboard"',
        "\\mathcal": 'span class="scriptfont"',
        "\\mathfrak": 'span class="fraktur"',
        "\\mathrm": 'span class="mathrm"',
        "\\mathscr": 'span class="mathscr"',
        "\\mathsf": 'span class="mathsf"',
        "\\mathtt": 'span class="mathtt"',
        "\\operatorname": 'span class="mathrm"',
        # letters with a pre-composed Unicode character
        "\\mathbb{A}": "𝔸", "\\mathbb{B}": "𝔹", "\\mathbb{C}": "ℂ", "\\mathbb{D}": "𝔻",
        "\\mathbb{E}": "𝔼", "\\mathbb{F}": "𝔽", "\\mathbb{G}": "𝔾", "\\mathbb{H}": "ℍ",
        "\\mathbb{J}": "𝕁", "\\mathbb{K}": "𝕂", "\\mathbb{L}": "𝕃", "\\mathbb{N}": "ℕ",
        "\\mathbb{O}": "𝕆", "\\mathbb{P}": "ℙ", "\\mathbb{Q}": "ℚ", "\\mathbb{R}": "ℝ",
        "\\mathbb{S}": "𝕊", "\\mathbb{T}": "𝕋", "\\mathbb{W}": "𝕎", "\\mathbb{Z}": "ℤ",
        "\\mathcal{B}": "ℬ", "\\mathcal{E}": "ℰ", "\\mathcal{F}": "ℱ", "\\mathcal{H}": "ℋ",
        "\\mathcal{I}": "ℐ", "\\mathcal{L}": "ℒ", "\\mathcal{M}": "ℳ", "\\mathcal{R}": "ℛ",
        "\\mathfrak{C}": "ℭ", "\\mathfrak{F}": "𝔉", "\\mathfrak{H}": "ℌ", "\\mathfrak{I}": "ℑ",
        "\\mathfrak{R}": "ℜ", "\\mathfrak{Z}": "ℨ",
        "\\mathring{A}": "Å", "\\mathring{U}": "Ů", "\\mathring{a}": "å", "\\mathring{u}": "ů",
        "\\mathring{w}": "ẘ", "\\mathring{y}": "ẙ",
        "\\mathscr{B}": "ℬ", "\\mathscr{E}": "ℰ", "\\mathscr{F}": "ℱ", "\\mathscr{H}": "ℋ",
        "\\mathscr{I}": "ℐ", "\\mathscr{L}": "ℒ", "\\mathscr{M}": "ℳ", "\\mathscr{R}": "ℛ",
    }

    # [read template, write template, tag of f0, tag of f1, ...]; see `HybridFunction`
    _fraction = ["{$1}{$2}", "f0{f3{(}f1{$1}f3{)/(}f2{$2}f3{)}}"]
    _fraction_parts = ['span class="numerator"', 'span class="denominator"',
                       'span class="ignored"']
    _smallbinom = ["{$1}{$2}", "(f0{f1{f2{$1}}f1{f2{\u2005}}f1{f2{$2}}})", 'span class="binomial"',
                   'span class="binomrow"', 'span class="binomcell"']
    hybridfunctions = {
        "\\addcontentsline": ["{$p!}{$q!}{$r!}", "f0{}", "ignored"],
        "\\addtocontents": ["{$p!}{$q!}", "f0{}", "ignored"],
        "\\backmatter": ["", "f0{}", "ignored"],
        "\\binom": ["{$1}{$2}", "f2{(}f0{f1{$1}f1{$2}}f2{)}", 'span class="binom"',
                    'span class="binomstack"', 'span class="bigdelimiter size2"'],
        "\\boxed": ["{$1}", "f0{$1}", 'span class="boxed"'],
        "\\cfrac": ["[$p!]{$1}{$2}", _fraction[1], 'span class="fullfraction"',
                    'span class="numerator align-$p"', *_fraction_parts[1:]],
        "\\color": ["{$p!}{$1}", "f0{$1}", 'span style="color: $p;"'],
        "\\colorbox": ["{$p!}{$1}", "f0{$1}", 'span class="colorbox" style="background: $p;"'],
        "\\dbinom": list(_smallbinom),
        "\\dfrac": [*_fraction, 'span class="fullfraction"', *_fraction_parts],
        "\\displaystyle": ["{$1}", "f0{$1}", 'span class="displaystyle"'],
        "\\fancyfoot": ["[$p!]{$q!}", "f0{}", "ignored"],
        "\\fancyhead": ["[$p!]{$q!}", "f0{}", "ignored"],
        "\\fbox": ["{$1}", "f0{$1}", 'span class="fbox"'],
        "\\fboxrule": ["{$p!}", "f0{}", "ignored"],
        "\\fboxsep": ["{$p!}", "f0{}", "ignored"],
        "\\fcolorbox": ["{$p!}{$q!}{$1}", "f0{$1}",
                        'span class="boxed" style="border-color: $p; background: $q;"'],
        "\\frac": [*_fraction, 'span class="fraction"', *_fraction_parts],
        "\\framebox": ["[$p!][$q!]{$1}", "f0{$1}",
                       'span class="framebox align-$q" style="width: $p;"'],
        "\\frontmatter": ["", "f0{}", "ignored"],
        "\\href": ["[$o]{$u!}{$t!}", "f0{$t}", 'a href="$u"'],
        "\\hspace": ["{$p!}", "f0{ }", 'span class="hspace" style="width: $p;"'],
        "\\leftroot": ["{$p!}", "f0{ }", 'span class="leftroot" style="width: $p;px"'],
        "\\nicefrac": ["{$1}{$2}", "f0{f1{$1}⁄f2{$2}}", 'span class="fraction"',
                       'sup class="numerator"', 'sub class="denominator"', 'span class="ignored"'],
        "\\parbox": ["[$p!]{$w!}{$1}", "f0{1}", 'div class="Boxed" style="width: $w;"'],
        "\\raisebox": ["{$p!}{$1}", "f0{$1.font}",
                       'span class="raisebox" style="vertical-align: $p;"'],
        "\\renewenvironment": ["{$1!}{$2!}{$3!}", ""],
        "\\rule": ["[$v!]{$w!}{$h!}", "f0/", 'hr class="line" style="width: $w; height: $h;"'],
        "\\scriptscriptstyle": ["{$1}", "f0{$1}", 'span class="scriptscriptstyle"'],
        "\\scriptstyle": ["{$1}", "f0{$1}", 'span class="scriptstyle"'],
        "\\sqrt": ["[$0]{$1}", "f0{f1{$0}f2{√}f4{(}f3{$1}f4{)}}", 'span class="sqrt"',
                   'sup class="root"', 'span class="radical"', 'span class="root"',
                   'span class="ignored"'],
        "\\stackrel": ["{$1}{$2}", "f0{f1{$1}f2{$2}}", 'span class="stackrel"',
                       'span class="upstackrel"', 'span class="downstackrel"'],
        "\\tbinom": list(_smallbinom),
        "\\tfrac": [*_fraction, 'span class="textfraction"', *_fraction_parts],
        "\\textcolor": ["{$p!}{$1}", "f0{$1}", 'span style="color: $p;"'],
        "\\textstyle": ["{$1}", "f0{$1}", 'span class="textstyle"'],
        "\\thispagestyle": ["{$p!}", "f0{}", "ignored"],
        "\\unit": ["[$0]{$1}", "$0f0{$1.font}", 'span class="unit"'],
        "\\unitfrac": ["[$0]{$1}{$2}", "$0f0{f1{$1.font}⁄f2{$2.font}}",
                       'span class="fraction"', 'sup class="unit"', 'sub class="unit"'],
        "\\uproot": ["{$p!}", "f0{ }", 'span class="uproot" style="width: $p;px"'],
        "\\url": ["{$u!}", "f0{$u}", 'a href="$u"'],
        "\\vspace": ["{$p!}", "f0{ }", 'span class="vspace" style="height: $p;"'],
    }
    del _fraction, _fraction_parts, _smallbinom

    # sizes (in rows) of hybrid functions stacking their arguments
    hybridsizes = {
        "\\binom": "$1+$2", "\\cfrac": "$1+$2", "\\dbinom": "$1+$2+1", "\\dfrac": "$1+$2",
        "\\frac": "$1+$2", "\\tbinom": "$1+$2+1",
    }

    labelfunctions = {"\\label": 'a name="#"'}

    limitcommands = {
        "\\biginterleave": "⫼", "\\inf": "inf", "\\lim": "lim", "\\max": "max",
        "\\min": "min", "\\sup": "sup",
        "\\zcmp": "⨟", "\\zhide": "⧹", "\\zpipe": "⨠", "\\zproject": "⨡",
    } | _bigoperators(
        "bigoperator", bigcap="⋂", bigcup="⋃", bigodot="⨀", bigoplus="⨁", bigotimes="⨂",
        bigsqcap="⨅", bigsqcup="⨆", biguplus="⨄", bigvee="⋁", bigwedge="⋀", coprod="∐",
        prod="∏", sum="∑", varprod="⨉",
    ) | _bigoperators(
        # integrals have limits in index position with LaTeX default settings
        "bigoperator integral", int="∫", intop="∫", iint="∬", iiint="∭", iiiint="⨌",
        fint="⨏", idotsint="∫⋯∫", oint="∮", ointop="∮", oiint="∯", oiiint="∰",
        ointclockwise="∲", ointctrclockwise="∳", sqint="⨖", varointclockwise="∲",
    ) | _bigoperators("smallsymbol integral", smallint="∫")

    # symbols translated with spacing (binary operators, relations)
    modified = {
        "\n": "", " ": "", "$": "", "&": "\t", "'": "’", "+": " + ",
        ",": ", ", "-": " − ", "/": " ⁄ ", ":": " : ",
        "<": " &lt; ", "=": " = ", ">": " &gt; ", "@": "",
        "~": " ",
    }

    onefunctions = {
        "\\big": 'span class="bigdelimiter size1"',
        "\\bigl": 'span class="bigdelimiter size1"',
        "\\bigr": 'span class="bigdelimiter size1"',
        "\\Big": 'span class="bigdelimiter size2"',
        "\\Bigl": 'span class="bigdelimiter size2"',
        "\\Bigr": 'span class="bigdelimiter size2"',
        "\\bigg": 'span class="bigdelimiter size3"',
        "\\biggl": 'span class="bigdelimiter size3"',
        "\\biggr": 'span class="bigdelimiter size3"',
        "\\Bigg": 'span class="bigdelimiter size4"',
        "\\Biggl": 'span class="bigdelimiter size4"',
        "\\Biggr": 'span class="bigdelimiter size4"',
        "\\begin{array}": 'span class="arraydef"',
        "\\centering": 'span class="align-center"',
        "\\ensuremath": 'span class="ensuremath"',
        "\\hphantom": 'span class="phantom"',
        "\\noindent": 'span class="noindent"',
        "\\overbrace": 'span class="overbrace"',
        "\\overline": 'span class="overline"',
        "\\phantom": 'span class="phantom"',
        "\\underbrace": 'span class="underbrace"',
        "\\underline": "",
        "\\vphantom": 'span class="phantom"',
    }

    # relations (put additional space before and after the symbol)
    spacedcommands = {
        # negated symbols without pre-composed Unicode character
        "\\nleqq": "≦̸",  # ≦̸
        "\\ngeqq": "≧̸",  # ≧̸
        "\\nleqslant": "⩽̸",  # ⩽̸
        "\\ngeqslant": "⩾̸",  # ⩾̸
        "\\nsubseteqq": "⫅̸",  # ⫅̸
        "\\nsupseteqq": "⫆̸",  # ⫆̸
        "\\nsqsubset": "≶⊏",  # ⊏̸
        # modified glyphs
        "\\shortmid": '<span class="smallsymbol">∣</span>',
        "\\shortparallel": '<span class="smallsymbol">∥</span>',
        "\\nshortmid": '<span class="smallsymbol">∤</span>',
        "\\nshortparallel": '<span class="smallsymbol">∦</span>',
        "\\smallfrown": '<span class="smallsymbol">⌢</span>',
        "\\smallsmile": '<span class="smallsymbol">⌣</span>',
        "\\thickapprox": '<span class="boldsymbol">≈</span>',
        "\\thicksim": '<span class="boldsymbol">∼</span>',
        "\\varpropto": '<span class="mathsf">∝</span>',  # ∝ PROPORTIONAL TO
    } | _commands(tex2unichar.mathrel)

    starts = {
        "beginafter": "}", "beginbefore": "\\begin{", "bracket": "{", "command": "\\",
        "comment": "%", "complex": "\\[", "simple": "$", "squarebracket": "[",
        "unnumbered": "*",
    }

    symbolfunctions = {"^": "sup", "_": "sub"}

    textfunctions = {
        "\\mbox": 'span class="mbox"',
        "\\text": 'span class="text"',
        "\\textbf": 'span class="textbf"',
        "\\textit": 'span class="textit"',
        "\\textnormal": 'span class="textnormal"',
        "\\textrm": 'span class="textrm"',
        "\\textsc": 'span class="textsc"',
        "\\textsf": 'span class="textsf"',
        "\\textsl": 'span class="textsl"',
        "\\texttt": 'span class="texttt"',
        "\\textup": 'span class="normal"',
    }

    # symbols passed through unchanged
    unmodified = {
        "characters": [".", "*", "€", "(", ")", "[", "]", "·", "!", ";", "|", "§", '"', "?"],
    }
