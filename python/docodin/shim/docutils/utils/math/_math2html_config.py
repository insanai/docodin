"""Configuration tables of `math2html` (converted from the eLyXer config file)."""

from __future__ import annotations

from docutils.utils.math import tex2unichar

__docformat__ = "reStructuredText"


class ContainerConfig:
    """Configuration class from elyxer.config file"""

    extracttext = {
        "allowed": ["FormulaConstant"],
        "extracted": [
            "AlphaCommand",
            "Bracket",
            "BracketCommand",
            "CombiningFunction",
            "EmptyCommand",
            "FontFunction",
            "Formula",
            "FormulaNumber",
            "FormulaSymbol",
            "OneParamFunction",
            "OversetFunction",
            "RawText",
            "SpacedCommand",
            "SymbolFunction",
            "TextFunction",
            "UndersetFunction",
        ],
    }


class EscapeConfig:
    """Configuration class from elyxer.config file"""

    chars = {
        "\n": "",
        "'": "’",
        "`": "‘",
    }

    entities = {
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
    }


class FormulaConfig:
    """Configuration class from elyxer.config file"""

    alphacommands = {
        "\\AmS": '<span class="textsc">AmS</span>',
        "\\AA": "Å",
        "\\AE": "Æ",
        "\\DH": "Ð",
        "\\L": "Ł",
        "\\O": "Ø",
        "\\OE": "Œ",
        "\\TH": "Þ",
        "\\aa": "å",
        "\\ae": "æ",
        "\\dh": "ð",
        "\\i": "ı",
        "\\j": "ȷ",
        "\\l": "ł",
        "\\o": "ø",
        "\\oe": "œ",
        "\\ss": "ß",
        "\\th": "þ",
        "\\hbar": "ħ",  # cf. \hslash: ℏ in tex2unichar
    }
    for key, value in tex2unichar.mathalpha.items():
        alphacommands["\\" + key] = value

    array = {
        "begin": r"\begin",
        "cellseparator": "&",
        "end": r"\end",
        "rowseparator": r"\\",
    }

    bigbrackets = {
        "(": ["⎛", "⎜", "⎝"],
        ")": ["⎞", "⎟", "⎠"],
        "[": ["⎡", "⎢", "⎣"],
        "]": ["⎤", "⎥", "⎦"],
        "{": ["⎧", "⎪", "⎨", "⎩"],
        "}": ["⎫", "⎪", "⎬", "⎭"],
        # TODO: 2-row brackets with ⎰⎱ (\lmoustache \rmoustache)
        "|": ["|"],  # 007C VERTICAL LINE
        # '|': ['⎮'],  # 23AE INTEGRAL EXTENSION
        # '|': ['⎪'],  # 23AA CURLY BRACKET EXTENSION
        "‖": ["‖"],  # 2016 DOUBLE VERTICAL LINE
        # '∥': ['∥'],  # 2225 PARALLEL TO
    }

    bracketcommands = {
        "\\left": 'span class="stretchy"',
        "\\left.": '<span class="leftdot"></span>',
        "\\middle": 'span class="stretchy"',
        "\\right": 'span class="stretchy"',
        "\\right.": '<span class="rightdot"></span>',
    }

    combiningfunctions = {
        "\\'": "\u0301",  # x́
        '\\"': "\u0308",  # ẍ
        "\\^": "\u0302",  # x̂
        "\\`": "\u0300",  # x̀
        "\\~": "\u0303",  # x̃
        "\\c": "\u0327",  # x̧
        "\\r": "\u030a",  # x̊
        "\\s": "\u0329",  # x̩
        "\\textcircled": "\u20dd",  # x⃝
        "\\textsubring": "\u0325",  # x̥
        "\\v": "\u030c",  # x̌
    }
    for key, value in tex2unichar.mathaccent.items():
        combiningfunctions["\\" + key] = value

    commands = {
        "\\\\": "<br/>",
        "\\\n": " ",  # escaped whitespace
        "\\\t": " ",  # escaped whitespace
        "\\centerdot": "\u2b1d",  # BLACK VERY SMALL SQUARE, mathbin
        "\\colon": ": ",
        "\\copyright": "©",
        "\\dotminus": "∸",
        "\\dots": "…",
        "\\dotsb": "⋯",
        "\\dotsc": "…",
        "\\dotsi": "⋯",
        "\\dotsm": "⋯",
        "\\dotso": "…",
        "\\euro": "€",
        "\\guillemotleft": "«",
        "\\guillemotright": "»",
        "\\lVert": "‖",
        "\\Arrowvert": "‖",
        "\\lvert": "|",
        "\\newline": "<br/>",
        "\\nobreakspace": " ",
        "\\nolimits": "",
        "\\nonumber": "",
        "\\qquad": "  ",
        "\\rVert": "‖",
        "\\rvert": "|",
        "\\textasciicircum": "^",
        "\\textasciitilde": "~",
        "\\textbackslash": "\\",
        "\\textcopyright": "©",
        "\\textdegree": "°",
        "\\textellipsis": "…",
        "\\textemdash": "—",
        "\\textendash": "—",
        "\\texteuro": "€",
        "\\textgreater": ">",
        "\\textless": "<",
        "\\textordfeminine": "ª",
        "\\textordmasculine": "º",
        "\\textquotedblleft": "“",
        "\\textquotedblright": "”",
        "\\textquoteright": "’",
        "\\textregistered": "®",
        "\\textrightarrow": "→",
        "\\textsection": "§",
        "\\texttrademark": "™",
        "\\texttwosuperior": "²",
        "\\textvisiblespace": " ",
        "\\thickspace": '<span class="thickspace"> </span>',  # 5/13 em
        "\\;": '<span class="thickspace"> </span>',  # 5/13 em
        "\\triangle": "\u25b3",  # WHITE UP-POINTING TRIANGLE, mathord
        "\\triangledown": "\u25bd",  # WHITE DOWN-POINTING TRIANGLE, mathord
        "\\varnothing": "\u2300",  # ⌀ DIAMETER SIGN
        # functions
        "\\Pr": "Pr",
        "\\arccos": "arccos",
        "\\arcsin": "arcsin",
        "\\arctan": "arctan",
        "\\arg": "arg",
        "\\cos": "cos",
        "\\cosh": "cosh",
        "\\cot": "cot",
        "\\coth": "coth",
        "\\csc": "csc",
        "\\deg": "deg",
        "\\det": "det",
        "\\dim": "dim",
        "\\exp": "exp",
        "\\gcd": "gcd",
        "\\hom": "hom",
        "\\injlim": "inj lim",
        "\\ker": "ker",
        "\\lg": "lg",
        "\\liminf": "lim inf",
        "\\limsup": "lim sup",
        "\\ln": "ln",
        "\\log": "log",
        "\\projlim": "proj lim",
        "\\sec": "sec",
        "\\sin": "sin",
        "\\sinh": "sinh",
        "\\tan": "tan",
        "\\tanh": "tanh",
    }
    cmddict = {}
    cmddict.update(tex2unichar.mathbin)  # TODO: spacing around binary operators
    cmddict.update(tex2unichar.mathopen)
    cmddict.update(tex2unichar.mathclose)
    cmddict.update(tex2unichar.mathfence)
    cmddict.update(tex2unichar.mathord)
    cmddict.update(tex2unichar.mathpunct)
    cmddict.update(tex2unichar.space)
    commands.update(("\\" + key, value) for key, value in cmddict.items())

    oversetfunctions = {
        # math accents (cf. combiningfunctions)
        # '\\acute':    '´',
        "\\bar": "‒",  # FIGURE DASH
        # '\\breve':    '˘',
        # '\\check':    'ˇ',
        "\\dddot": '<span class="smallsymbol">⋯</span>',
        # '\\ddot':     '··', # ¨ too high
        # '\\dot':      '·',
        # '\\grave':    '`',
        # '\\hat':      '^',
        # '\\mathring': '˚',
        # '\\tilde':    '~',
        "\\vec": '<span class="smallsymbol">→</span>',
        # embellishments
        "\\overleftarrow": "⟵",
        "\\overleftrightarrow": "⟷",
        "\\overrightarrow": "⟶",
        "\\widehat": "^",
        "\\widetilde": "～",
    }

    undersetfunctions = {
        "\\underleftarrow": "⟵",
        "\\underleftrightarrow": "⟷",
        "\\underrightarrow": "⟶",
    }

    endings = {
        "bracket": "}",
        "complex": "\\]",
        "endafter": "}",
        "endbefore": "\\end{",
        "squarebracket": "]",
    }

    environments = {
        "align": ["r", "l"],
        "eqnarray": ["r", "c", "l"],
        "gathered": ["l", "l"],
        "smallmatrix": ["c", "c"],
    }

    fontfunctions = {
        "\\boldsymbol": "b",
        "\\mathbb": 'span class="blackboard"',
        "\\mathbb{A}": "𝔸",
        "\\mathbb{B}": "𝔹",
        "\\mathbb{C}": "ℂ",
        "\\mathbb{D}": "𝔻",
        "\\mathbb{E}": "𝔼",
        "\\mathbb{F}": "𝔽",
        "\\mathbb{G}": "𝔾",
        "\\mathbb{H}": "ℍ",
        "\\mathbb{J}": "𝕁",
        "\\mathbb{K}": "𝕂",
        "\\mathbb{L}": "𝕃",
        "\\mathbb{N}": "ℕ",
        "\\mathbb{O}": "𝕆",
        "\\mathbb{P}": "ℙ",
        "\\mathbb{Q}": "ℚ",
        "\\mathbb{R}": "ℝ",
        "\\mathbb{S}": "𝕊",
        "\\mathbb{T}": "𝕋",
        "\\mathbb{W}": "𝕎",
        "\\mathbb{Z}": "ℤ",
        "\\mathbf": "b",
        "\\mathcal": 'span class="scriptfont"',
        "\\mathcal{B}": "ℬ",
        "\\mathcal{E}": "ℰ",
        "\\mathcal{F}": "ℱ",
        "\\mathcal{H}": "ℋ",
        "\\mathcal{I}": "ℐ",
        "\\mathcal{L}": "ℒ",
        "\\mathcal{M}": "ℳ",
        "\\mathcal{R}": "ℛ",
        "\\mathfrak": 'span class="fraktur"',
        "\\mathfrak{C}": "ℭ",
        "\\mathfrak{F}": "𝔉",
        "\\mathfrak{H}": "ℌ",
        "\\mathfrak{I}": "ℑ",
        "\\mathfrak{R}": "ℜ",
        "\\mathfrak{Z}": "ℨ",
        "\\mathit": "i",
        "\\mathring{A}": "Å",
        "\\mathring{U}": "Ů",
        "\\mathring{a}": "å",
        "\\mathring{u}": "ů",
        "\\mathring{w}": "ẘ",
        "\\mathring{y}": "ẙ",
        "\\mathrm": 'span class="mathrm"',
        "\\mathscr": 'span class="mathscr"',
        "\\mathscr{B}": "ℬ",
        "\\mathscr{E}": "ℰ",
        "\\mathscr{F}": "ℱ",
        "\\mathscr{H}": "ℋ",
        "\\mathscr{I}": "ℐ",
        "\\mathscr{L}": "ℒ",
        "\\mathscr{M}": "ℳ",
        "\\mathscr{R}": "ℛ",
        "\\mathsf": 'span class="mathsf"',
        "\\mathtt": 'span class="mathtt"',
        "\\operatorname": 'span class="mathrm"',
    }

    hybridfunctions = {
        "\\addcontentsline": ["{$p!}{$q!}{$r!}", "f0{}", "ignored"],
        "\\addtocontents": ["{$p!}{$q!}", "f0{}", "ignored"],
        "\\backmatter": ["", "f0{}", "ignored"],
        "\\binom": [
            "{$1}{$2}",
            "f2{(}f0{f1{$1}f1{$2}}f2{)}",
            'span class="binom"',
            'span class="binomstack"',
            'span class="bigdelimiter size2"',
        ],
        "\\boxed": ["{$1}", "f0{$1}", 'span class="boxed"'],
        "\\cfrac": [
            "[$p!]{$1}{$2}",
            "f0{f3{(}f1{$1}f3{)/(}f2{$2}f3{)}}",
            'span class="fullfraction"',
            'span class="numerator align-$p"',
            'span class="denominator"',
            'span class="ignored"',
        ],
        "\\color": ["{$p!}{$1}", "f0{$1}", 'span style="color: $p;"'],
        "\\colorbox": ["{$p!}{$1}", "f0{$1}", 'span class="colorbox" style="background: $p;"'],
        "\\dbinom": [
            "{$1}{$2}",
            "(f0{f1{f2{$1}}f1{f2{ }}f1{f2{$2}}})",
            'span class="binomial"',
            'span class="binomrow"',
            'span class="binomcell"',
        ],
        "\\dfrac": [
            "{$1}{$2}",
            "f0{f3{(}f1{$1}f3{)/(}f2{$2}f3{)}}",
            'span class="fullfraction"',
            'span class="numerator"',
            'span class="denominator"',
            'span class="ignored"',
        ],
        "\\displaystyle": ["{$1}", "f0{$1}", 'span class="displaystyle"'],
        "\\fancyfoot": ["[$p!]{$q!}", "f0{}", "ignored"],
        "\\fancyhead": ["[$p!]{$q!}", "f0{}", "ignored"],
        "\\fbox": ["{$1}", "f0{$1}", 'span class="fbox"'],
        "\\fboxrule": ["{$p!}", "f0{}", "ignored"],
        "\\fboxsep": ["{$p!}", "f0{}", "ignored"],
        "\\fcolorbox": [
            "{$p!}{$q!}{$1}",
            "f0{$1}",
            'span class="boxed" style="border-color: $p; background: $q;"',
        ],
        "\\frac": [
            "{$1}{$2}",
            "f0{f3{(}f1{$1}f3{)/(}f2{$2}f3{)}}",
            'span class="fraction"',
            'span class="numerator"',
            'span class="denominator"',
            'span class="ignored"',
        ],
        "\\framebox": ["[$p!][$q!]{$1}", "f0{$1}",
                        'span class="framebox align-$q" style="width: $p;"'],
        "\\frontmatter": ["", "f0{}", "ignored"],
        "\\href": ["[$o]{$u!}{$t!}", "f0{$t}", 'a href="$u"'],
        "\\hspace": ["{$p!}", "f0{ }", 'span class="hspace" style="width: $p;"'],
        "\\leftroot": ["{$p!}", "f0{ }", 'span class="leftroot" style="width: $p;px"'],
        # TODO: convert 1 mu to 1/18 em
        # '\\mspace': ['{$p!}', 'f0{ }', 'span class="hspace" style="width: $p;"'],
        "\\nicefrac": [
            "{$1}{$2}",
            "f0{f1{$1}⁄f2{$2}}",
            'span class="fraction"',
            'sup class="numerator"',
            'sub class="denominator"',
            'span class="ignored"',
        ],
        "\\parbox": ["[$p!]{$w!}{$1}", "f0{1}", 'div class="Boxed" style="width: $w;"'],
        "\\raisebox": ["{$p!}{$1}", "f0{$1.font}",
                        'span class="raisebox" style="vertical-align: $p;"'],
        "\\renewenvironment": ["{$1!}{$2!}{$3!}", ""],
        "\\rule": ["[$v!]{$w!}{$h!}", "f0/", 'hr class="line" style="width: $w; height: $h;"'],
        "\\scriptscriptstyle": ["{$1}", "f0{$1}", 'span class="scriptscriptstyle"'],
        "\\scriptstyle": ["{$1}", "f0{$1}", 'span class="scriptstyle"'],
        # TODO: increase √-size with argument (\frac in display mode, ...)
        "\\sqrt": [
            "[$0]{$1}",
            "f0{f1{$0}f2{√}f4{(}f3{$1}f4{)}}",
            'span class="sqrt"',
            'sup class="root"',
            'span class="radical"',
            'span class="root"',
            'span class="ignored"',
        ],
        "\\stackrel": [
            "{$1}{$2}",
            "f0{f1{$1}f2{$2}}",
            'span class="stackrel"',
            'span class="upstackrel"',
            'span class="downstackrel"',
        ],
        "\\tbinom": [
            "{$1}{$2}",
            "(f0{f1{f2{$1}}f1{f2{ }}f1{f2{$2}}})",
            'span class="binomial"',
            'span class="binomrow"',
            'span class="binomcell"',
        ],
        "\\tfrac": [
            "{$1}{$2}",
            "f0{f3{(}f1{$1}f3{)/(}f2{$2}f3{)}}",
            'span class="textfraction"',
            'span class="numerator"',
            'span class="denominator"',
            'span class="ignored"',
        ],
        "\\textcolor": ["{$p!}{$1}", "f0{$1}", 'span style="color: $p;"'],
        "\\textstyle": ["{$1}", "f0{$1}", 'span class="textstyle"'],
        "\\thispagestyle": ["{$p!}", "f0{}", "ignored"],
        "\\unit": ["[$0]{$1}", "$0f0{$1.font}", 'span class="unit"'],
        "\\unitfrac": [
            "[$0]{$1}{$2}",
            "$0f0{f1{$1.font}⁄f2{$2.font}}",
            'span class="fraction"',
            'sup class="unit"',
            'sub class="unit"',
        ],
        "\\uproot": ["{$p!}", "f0{ }", 'span class="uproot" style="width: $p;px"'],
        "\\url": ["{$u!}", "f0{$u}", 'a href="$u"'],
        "\\vspace": ["{$p!}", "f0{ }", 'span class="vspace" style="height: $p;"'],
    }

    hybridsizes = {
        "\\binom": "$1+$2",
        "\\cfrac": "$1+$2",
        "\\dbinom": "$1+$2+1",
        "\\dfrac": "$1+$2",
        "\\frac": "$1+$2",
        "\\tbinom": "$1+$2+1",
    }

    labelfunctions = {
        "\\label": 'a name="#"',
    }

    limitcommands = {
        "\\biginterleave": "⫼",
        "\\inf": "inf",
        "\\lim": "lim",
        "\\max": "max",
        "\\min": "min",
        "\\sup": "sup",
        "\\ointop": '<span class="bigoperator integral">∮</span>',
        "\\bigcap": '<span class="bigoperator">⋂</span>',
        "\\bigcup": '<span class="bigoperator">⋃</span>',
        "\\bigodot": '<span class="bigoperator">⨀</span>',
        "\\bigoplus": '<span class="bigoperator">⨁</span>',
        "\\bigotimes": '<span class="bigoperator">⨂</span>',
        "\\bigsqcap": '<span class="bigoperator">⨅</span>',
        "\\bigsqcup": '<span class="bigoperator">⨆</span>',
        "\\biguplus": '<span class="bigoperator">⨄</span>',
        "\\bigvee": '<span class="bigoperator">⋁</span>',
        "\\bigwedge": '<span class="bigoperator">⋀</span>',
        "\\coprod": '<span class="bigoperator">∐</span>',
        "\\intop": '<span class="bigoperator integral">∫</span>',
        "\\prod": '<span class="bigoperator">∏</span>',
        "\\sum": '<span class="bigoperator">∑</span>',
        "\\varprod": '<span class="bigoperator">⨉</span>',
        "\\zcmp": "⨟",
        "\\zhide": "⧹",
        "\\zpipe": "⨠",
        "\\zproject": "⨡",
        # integrals have limits in index position with LaTeX default settings
        # TODO: move to commands?
        "\\int": '<span class="bigoperator integral">∫</span>',
        "\\iint": '<span class="bigoperator integral">∬</span>',
        "\\iiint": '<span class="bigoperator integral">∭</span>',
        "\\iiiint": '<span class="bigoperator integral">⨌</span>',
        "\\fint": '<span class="bigoperator integral">⨏</span>',
        "\\idotsint": '<span class="bigoperator integral">∫⋯∫</span>',
        "\\oint": '<span class="bigoperator integral">∮</span>',
        "\\oiint": '<span class="bigoperator integral">∯</span>',
        "\\oiiint": '<span class="bigoperator integral">∰</span>',
        "\\ointclockwise": '<span class="bigoperator integral">∲</span>',
        "\\ointctrclockwise": '<span class="bigoperator integral">∳</span>',
        "\\smallint": '<span class="smallsymbol integral">∫</span>',
        "\\sqint": '<span class="bigoperator integral">⨖</span>',
        "\\varointclockwise": '<span class="bigoperator integral">∲</span>',
    }

    modified = {
        "\n": "",
        " ": "",
        "$": "",
        "&": "\t",
        "'": "’",
        "+": "\u2009+\u2009",
        ",": ",\u2009",
        "-": "\u2009−\u2009",
        "/": "\u2009⁄\u2009",
        ":": " : ",
        "<": "\u2009&lt;\u2009",
        "=": "\u2009=\u2009",
        ">": "\u2009&gt;\u2009",
        "@": "",
        "~": "\u00a0",
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
        # '\\bar': 'span class="bar"',
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
        "\\nleqq": "\u2266\u0338",  # ≦̸
        "\\ngeqq": "\u2267\u0338",  # ≧̸
        "\\nleqslant": "\u2a7d\u0338",  # ⩽̸
        "\\ngeqslant": "\u2a7e\u0338",  # ⩾̸
        "\\nsubseteqq": "\u2ac5\u0338",  # ⫅̸
        "\\nsupseteqq": "\u2ac6\u0338",  # ⫆̸
        "\\nsqsubset": "\u2276\u228f",  # ⊏̸
        # modified glyphs
        "\\shortmid": '<span class="smallsymbol">∣</span>',
        "\\shortparallel": '<span class="smallsymbol">∥</span>',
        "\\nshortmid": '<span class="smallsymbol">∤</span>',
        "\\nshortparallel": '<span class="smallsymbol">∦</span>',
        "\\smallfrown": '<span class="smallsymbol">⌢</span>',
        "\\smallsmile": '<span class="smallsymbol">⌣</span>',
        "\\thickapprox": '<span class="boldsymbol">≈</span>',
        "\\thicksim": '<span class="boldsymbol">∼</span>',
        "\\varpropto": '<span class="mathsf">\u221d</span>',  # ∝ PROPORTIONAL TO
    }
    for key, value in tex2unichar.mathrel.items():
        spacedcommands["\\" + key] = value
    starts = {
        "beginafter": "}",
        "beginbefore": "\\begin{",
        "bracket": "{",
        "command": "\\",
        "comment": "%",
        "complex": "\\[",
        "simple": "$",
        "squarebracket": "[",
        "unnumbered": "*",
    }

    symbolfunctions = {
        "^": "sup",
        "_": "sub",
    }

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

    unmodified = {
        "characters": [".", "*", "€", "(", ")", "[", "]", "·", "!", ";", "|", "§", '"', "?"],
    }
