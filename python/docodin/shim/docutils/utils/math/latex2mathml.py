"""Convert LaTex maths code into presentational MathML.

This module is provisional:
the API is not settled and may change with any minor Docutils version.
"""

# Usage:
#
# >>> from latex2mathml import *

from __future__ import annotations

import re
import unicodedata
from collections.abc import Callable

from docutils.utils.math import MathError, mathalphabet2unichar, tex2unichar, toplevel_code
from docutils.utils.math.mathml_elements import (
    MathElement,
    MathRow,
    math,
    menclose,
    mfrac,
    mi,
    mn,
    mo,
    mover,
    mphantom,
    mroot,
    mrow,
    mspace,
    msqrt,
    msub,
    msubsup,
    msup,
    mtable,
    mtd,
    mtext,
    mtr,
    munder,
    munderover,
)

# Character data
# --------------

# LaTeX math macro to Unicode mappings.
# Character categories.

# identifiers -> <mi>

letters = {"hbar": "ℏ"}  # Compatibility mapping: \hbar resembles italic ħ
#                          "unicode-math" unifies \hbar and \hslash to ℏ.
letters.update(tex2unichar.mathalpha)

ordinary = tex2unichar.mathord  # Miscellaneous symbols

# special case: Capital Greek letters: (upright in TeX style)
greek_capitals = {
    "Phi": "Φ", "Xi": "Ξ", "Sigma": "Σ",
    "Psi": "Ψ", "Delta": "Δ", "Theta": "Θ",
    "Upsilon": "ϒ", "Pi": "Π", "Omega": "Ω",
    "Gamma": "Γ", "Lambda": "Λ"}

# functions -> <mi>
functions = {
    # functions with a space in the name
    "liminf": "lim inf",
    "limsup": "lim sup",
    "injlim": "inj lim",
    "projlim": "proj lim",
    # embellished function names (see handle_cmd() below)
    "varlimsup": "lim",
    "varliminf": "lim",
    "varprojlim": "lim",
    "varinjlim": "lim",
    # custom function name
    "operatorname": None,
}
functions.update((name, name) for name in
                 ("arccos", "arcsin", "arctan", "arg", "cos",
                  "cosh", "cot", "coth", "csc", "deg",
                  "det", "dim", "exp", "gcd", "hom",
                  "ker", "lg", "ln", "log", "Pr",
                  "sec", "sin", "sinh", "tan", "tanh"))
# Function with limits: 'lim', 'sup', 'inf', 'max', 'min':
# use <mo> to allow "movablelimits" attribute (see below).

# modulo operator/arithmetic
modulo_functions = {
    # cmdname: (binary, named, parentheses, padding)
    "bmod": (True, True, False, "0.278em"),  # a mod n
    "pmod": (False, True, True, "0.444em"),  # a  (mod n)
    "mod": (False, True, False, "0.667em"),  # a  mod n
    "pod": (False, False, True, "0.444em"),  # a  (n)
}


# "mathematical alphabets": map identifiers to the corresponding
# characters from the "Mathematical Alphanumeric Symbols" block
math_alphabets = {
    # 'cmdname':  'mathvariant value'        # package
    "mathbb": "double-struck",               # amssymb
    "mathbf": "bold",
    "mathbfit": "bold-italic",               # isomath
    "mathcal": "script",
    "mathfrak": "fraktur",                   # amssymb
    "mathit": "italic",
    "mathrm": "normal",
    "mathscr": "script",                     # mathrsfs et al
    "mathsf": "sans-serif",
    "mathbfsfit": "sans-serif-bold-italic",  # unicode-math
    "mathsfbfit": "sans-serif-bold-italic",  # isomath
    "mathsfit": "sans-serif-italic",         # isomath
    "mathtt": "monospace",
    # unsupported: bold-fraktur
    #              bold-script
    #              bold-sans-serif
}

# operator, fence, or separator -> <mo>

stretchables = {
    # extensible delimiters allowed in left/right cmds
    "backslash": "\\",
    "uparrow": "↑",      # ↑ UPWARDS ARROW
    "downarrow": "↓",    # ↓ DOWNWARDS ARROW
    "updownarrow": "↕",  # ↕ UP DOWN ARROW
    "Uparrow": "⇑",      # ⇑ UPWARDS DOUBLE ARROW
    "Downarrow": "⇓",    # ⇓ DOWNWARDS DOUBLE ARROW
    "Updownarrow": "⇕",  # ⇕ UP DOWN DOUBLE ARROW
    "lmoustache": "⎰",   # ⎰ … CURLY BRACKET SECTION
    "rmoustache": "⎱",   # ⎱ … LEFT CURLY BRACKET SECTION
    "arrowvert": "⏐",    # ⏐ VERTICAL LINE EXTENSION
    "bracevert": "⎪",    # ⎪ CURLY BRACKET EXTENSION
    "lvert": "|",             # left  |
    "lVert": "‖",        # left  ‖
    "rvert": "|",             # right |
    "rVert": "‖",        # right ‖
    "Arrowvert": "‖",    # ‖
}
stretchables.update(tex2unichar.mathfence)
stretchables.update(tex2unichar.mathopen)   # Braces
stretchables.update(tex2unichar.mathclose)  # Braces

# >>> print(' '.join(sorted(set(stretchables.values()))))
# [ \ ] { | } ‖ ↑ ↓ ↕ ⇑ ⇓ ⇕ ⌈ ⌉ ⌊ ⌋ ⌜ ⌝ ⌞ ⌟ ⎪ ⎰ ⎱ ⏐ ⟅ ⟆ ⟦ ⟧ ⟨ ⟩ ⟮ ⟯ ⦇ ⦈

operators = {
    # negated symbols without pre-composed Unicode character
    "nleqq": "≦̸",       # ≦̸
    "ngeqq": "≧̸",       # ≧̸
    "nleqslant": "⩽̸",   # ⩽̸
    "ngeqslant": "⩾̸",   # ⩾̸
    "ngtrless": "≹",    # txfonts
    "nlessgtr": "≸",    # txfonts
    "nsubseteqq": "⫅̸",  # ⫅̸
    "nsupseteqq": "⫆̸",  # ⫆̸
    # compatibility definitions:
    "centerdot": "⬝",  # BLACK VERY SMALL SQUARE | mathbin
    "varnothing": "⌀",  # ⌀ DIAMETER SIGN | empty set
    "varpropto": "∝",  # ∝ PROPORTIONAL TO | sans serif
    "triangle": "△",  # WHITE UP-POINTING TRIANGLE | mathord
    "triangledown": "▽",  # WHITE DOWN-POINTING TRIANGLE | mathord
    # alias commands:
    "dotsb": "⋯",  # ⋯ with binary operators/relations
    "dotsc": "…",  # … with commas
    "dotsi": "⋯",  # ⋯ with integrals
    "dotsm": "⋯",  # ⋯ multiplication dots
    "dotso": "…",  # … other dots
    # functions with movable limits (requires <mo>)
    "lim": "lim",
    "sup": "sup",
    "inf": "inf",
    "max": "max",
    "min": "min",
}
operators.update(tex2unichar.mathbin)    # Binary symbols
operators.update(tex2unichar.mathrel)    # Relation symbols, arrow symbols
operators.update(tex2unichar.mathpunct)  # Punctuation
operators.update(tex2unichar.mathop)     # Variable-sized symbols
operators.update(stretchables)


# special cases

thick_operators = {
    # style='font-weight: bold;'
    "thicksim": "∼",     # ∼
    "thickapprox": "≈",  # ≈
}

small_operators = {
    # mathsize='75%'
    "shortmid": "∣",        # ∣
    "shortparallel": "∥",   # ∥
    "nshortmid": "∤",       # ∤
    "nshortparallel": "∦",  # ∦
    "smallfrown": "⌢",      # ⌢ FROWN
    "smallsmile": "⌣",      # ⌣ SMILE
    "smallint": "∫",        # ∫ INTEGRAL
}

# Operators and functions with limits above/below in display formulas
# and in index position inline (movablelimits=True)
movablelimits = ("bigcap", "bigcup", "bigodot", "bigoplus", "bigotimes",
                 "bigsqcup", "biguplus", "bigvee", "bigwedge",
                 "coprod", "intop", "ointop", "prod", "sum",
                 "lim", "max", "min", "sup", "inf")
# Depending on settings, integrals may also be in this category.
# (e.g. if "amsmath" is loaded with option "intlimits", see
#  http://mirror.ctan.org/macros/latex/required/amsmath/amsldoc.pdf)

# horizontal space -> <mspace>

spaces = {"qquad": "2em",               # two \quad
          "quad": "1em",                # 18 mu
          "thickspace": "0.2778em",     # 5mu = 5/18em
          ";": "0.2778em",              # 5mu thickspace
          " ": "0.25em",                # inter word space
          "\n": "0.25em",               # inter word space
          "medspace": "0.2222em",       # 4mu = 2/9em
          ":": "0.2222em",              # 4mu medspace
          "thinspace": "0.1667em",      # 3mu = 1/6em
          ",": "0.1667em",              # 3mu thinspace
          "negthinspace": "-0.1667em",  # -3mu = -1/6em
          "!": "-0.1667em",             # negthinspace
          "negmedspace": "-0.2222em",   # -4mu = -2/9em
          "negthickspace": "-0.2778em",  # -5mu = -5/18em
          }

# accents: -> <mo stretchy="false"> in <mover>
accents = {
    # TeX:      spacing    combining
    "acute": "´",      # '́'
    "bar": "ˉ",        # '̄'
    "breve": "˘",      # '̆'
    "check": "ˇ",      # '̌'
    "dot": "˙",        # '̇'
    "ddot": "¨",       # '̈'
    "dddot": "˙˙˙",    # '⃛'  # or … ?
    "ddddot": "˙˙˙˙",  # '⃜'  # or ¨¨ ?
    "grave": "`",      # '̀'
    "hat": "ˆ",        # '̂'
    "mathring": "˚",   # '̊'
    "tilde": "~",      # '̃'  # tilde ~ or small tilde ˜?
    "vec": "→",        # '⃗'  # → too heavy, use scriptlevel="+1"
}

# limits etc. -> <mo> in <mover> or <munder>
over = {
    # TeX:                  (char,     offset-correction/em)
    "overbrace": ("⏞", -0.2),  # DejaVu Math -0.6
    "overleftarrow": ("←", -0.2),
    "overleftrightarrow": ("↔", -0.2),
    "overline": ("_", -0.2),  # ‒ does not stretch
    "overrightarrow": ("→", -0.2),
    "widehat": ("^", -0.5),
    "widetilde": ("~", -0.3),
}
under = {"underbrace": ("⏟", 0.1),  # DejaVu Math -0.7
         "underleftarrow": ("←", -0.2),
         "underleftrightarrow": ("↔", -0.2),
         "underline": ("_", -0.8),
         "underrightarrow": ("→", -0.2),
         }

# Character translations
# ----------------------
# characters with preferred alternative in mathematical use
# cf. https://www.w3.org/TR/MathML3/chapter7.html#chars.anomalous
anomalous_chars = {"-": "−",  # HYPHEN-MINUS -> MINUS SIGN
                   ":": "∶",  # COLON -> RATIO
                   "~": " ",  # NO-BREAK SPACE
                   }

# blackboard bold (Greek characters not working with "mathvariant" (Firefox 78)
mathbb = {"Γ": "ℾ",  # ℾ
          "Π": "ℿ",  # ℿ
          "Σ": "⅀",  # ⅀
          "γ": "ℽ",  # ℽ
          "π": "ℼ",  # ℼ
          }

# Matrix environments
matrices = {
    # name:    fences
    "matrix": ("", ""),
    "smallmatrix": ("", ""),  # smaller, see begin_environment()!
    "pmatrix": ("(", ")"),
    "bmatrix": ("[", "]"),
    "Bmatrix": ("{", "}"),
    "vmatrix": ("|", "|"),
    "Vmatrix": ("‖", "‖"),  # ‖
    "aligned": ("", ""),
    "cases": ("{", ""),
}

layout_styles = {
    "displaystyle": {"displaystyle": True, "scriptlevel": 0},
    "textstyle": {"displaystyle": False, "scriptlevel": 0},
    "scriptstyle": {"displaystyle": False, "scriptlevel": 1},
    "scriptscriptstyle": {"displaystyle": False, "scriptlevel": 2},
}
# See also https://www.w3.org/TR/MathML3/chapter3.html#presm.scriptlevel

fractions = {
    # name:   attributes
    "frac": {},
    "cfrac": {"displaystyle": True, "scriptlevel": 0,
              "class": "cfrac"},  # in LaTeX with padding
    "dfrac": layout_styles["displaystyle"],
    "tfrac": layout_styles["textstyle"],
    "binom": {"linethickness": 0},
    "dbinom": layout_styles["displaystyle"] | {"linethickness": 0},
    "tbinom": layout_styles["textstyle"] | {"linethickness": 0},
}

delimiter_sizes = ["", "1.2em", "1.623em", "2.047em", "2.470em"]
bigdelimiters = {"left": 0,
                 "right": 0,
                 "bigl": 1,
                 "bigr": 1,
                 "Bigl": 2,
                 "Bigr": 2,
                 "biggl": 3,
                 "biggr": 3,
                 "Biggl": 4,
                 "Biggr": 4,
                 }


# LaTeX to MathML translation
# ---------------------------

# auxiliary functions
# ~~~~~~~~~~~~~~~~~~~

def tex_cmdname(string: str) -> tuple[str, str]:
    """Return leading TeX command name and remainder of `string`.

    >>> tex_cmdname('mymacro2') # up to first non-letter
    ('mymacro', '2')
    >>> tex_cmdname('name 2') # strip trailing whitespace
    ('name', '2')
    >>> tex_cmdname('_2') # single non-letter character
    ('_', '2')

    """
    m = re.match(r"([a-zA-Z]+)[ \n]*(.*)", string, re.DOTALL)
    if m is None:
        m = re.match(r"(.?)(.*)", string, re.DOTALL)
    return m.group(1), m.group(2)


def tex_number(string: str) -> tuple[str, str]:
    """Return leading number literal and remainder of `string`.

    >>> tex_number('123.4')
    ('123.4', '')

    """
    m = re.match(r"([0-9.,]*[0-9]+)(.*)", string, re.DOTALL)
    if m is None:
        return "", string
    return m.group(1), m.group(2)


_TOKEN_PATTERN = re.compile(r"""((?P<cmd>\\[a-zA-Z]+)\s* # TeX command, skip whitespace
                                |(?P<chcmd>\\.)          # one-character TeX command
                                |(?P<ch>.?))             # first character (or empty)
                               (?P<remainder>.*$)        # remaining part of string
                            """, re.VERBOSE | re.DOTALL)


def tex_token(string: str) -> tuple[str, str]:
    """Return first simple TeX token and remainder of `string`.

    >>> tex_token('\\command{without argument}')
    ('\\command', '{without argument}')
    >>> tex_token('or first character')
    ('o', 'r first character')

    """
    m = _TOKEN_PATTERN.match(string)
    cmd, chcmd, ch, remainder = m.group("cmd", "chcmd", "ch", "remainder")
    return cmd or chcmd or ch, remainder


def tex_group(string: str) -> tuple[str, str]:
    """Return first TeX group or token and remainder of `string`.

    >>> tex_group('{first group} returned without brackets')
    ('first group', ' returned without brackets')

    """
    split_index = 0
    nest_level = 0   # level of {{nested} groups}
    escape = False   # the next character is escaped (\)

    if not string.startswith("{"):
        # special case: there is no group, return first token and remainder
        return string[:1], string[1:]
    for c in string:
        split_index += 1
        if escape:
            escape = False
        elif c == "\\":
            escape = True
        elif c == "{":
            nest_level += 1
        elif c == "}":
            nest_level -= 1
        if nest_level == 0:
            break
    else:
        raise MathError("Group without closing bracket!")
    return string[1:split_index - 1], string[split_index:]


def tex_token_or_group(string: str) -> tuple[str, str]:
    """Return first TeX group or token and remainder of `string`.

    >>> tex_token_or_group('\\command{without argument}')
    ('\\command', '{without argument}')
    >>> tex_token_or_group('first character')
    ('f', 'irst character')
    >>> tex_token_or_group(' also whitespace')
    (' ', 'also whitespace')
    >>> tex_token_or_group('{first group} keep rest')
    ('first group', ' keep rest')

    """
    arg, remainder = tex_token(string)
    if arg == "{":
        arg, remainder = tex_group(string.lstrip())
    return arg, remainder


_OPTARG_PATTERN = re.compile(r"""\s*                            # leading whitespace
                 \[(?P<optarg>(\\]|[^\[\]]|\\])*)\] # [group] without nested groups
                 (?P<remainder>.*$)
                 """, re.VERBOSE | re.DOTALL)


def tex_optarg(string: str) -> tuple[str, str]:
    """Return optional argument and remainder.

    >>> tex_optarg('[optional argument] returned without brackets')
    ('optional argument', ' returned without brackets')
    >>> tex_optarg('{empty string, if there is no optional arg}')
    ('', '{empty string, if there is no optional arg}')

    """
    m = _OPTARG_PATTERN.match(string)
    if m is None and not string.startswith("["):
        return "", string
    if m is None:
        raise MathError(f'Could not extract optional argument from "{string}"!')
    return m.group("optarg"), m.group("remainder")


# Parsing
# ~~~~~~~

def _open_group(node: MathElement) -> MathElement:
    """Handle "{": start a group."""
    if isinstance(node, MathRow) and node.nchildren == 1:
        # LaTeX takes one arg, MathML node accepts a group
        node.nchildren = None  # allow appending until closed by '}'
        return node
    # wrap group in an <mrow>
    new_node = mrow()
    node.append(new_node)
    return new_node


def _new_cell(node: MathElement) -> MathElement:
    """Handle "&": start a new table cell."""
    new_node = mtd()
    node.close().append(new_node)
    return new_node


def _anomalous_char(c: str, node: MathElement) -> MathElement | None:
    """Append character with a special meaning in LaTeX math mode."""
    # fix spacing before "unary" minus.
    attributes = {}
    if c == "-" and len(node):
        previous_node = node[-1]
        if (previous_node.text and previous_node.text in "([="
                or previous_node.get("class") == "mathopen"):
            attributes["form"] = "prefix"
    return node.append(mo(anomalous_chars[c], **attributes))


def _parse_symbol(c: str, node: MathElement) -> MathElement | None:
    """Append the element for a letter or symbol character `c` to `node`."""
    if c.isalpha():
        return node.append(mi(c))
    if c in anomalous_chars:
        return _anomalous_char(c, node)
    if c in "/()[]|":
        return node.append(mo(c, stretchy=False))
    if c in "+*=<>,.!?`';@":
        return node.append(mo(c))
    raise MathError(f'Unsupported character: "{c}"!')
    # TODO: append as <mi>?


_STRUCTURE_CHARS: dict[str, Callable[[MathElement], MathElement | None]] = {
    "_": lambda node: handle_script_or_limit(node, "_"),
    "^": lambda node: handle_script_or_limit(node, "^"),
    "{": lambda node: _open_group(node),
    "}": lambda node: node.close(),
    "&": lambda node: _new_cell(node),
}


def _parse_char(c: str, node: MathElement, string: str
                ) -> tuple[MathElement | None, str]:
    """Process character `c`. Return new current node and remainder of `string`."""
    if c == "\\":  # start of a LaTeX macro
        cmdname, string = tex_cmdname(string)
        return handle_cmd(cmdname, node, string)
    if c in _STRUCTURE_CHARS:
        return _STRUCTURE_CHARS[c](node), string
    if c.isdigit():
        number, string = tex_number(string)
        return node.append(mn(c + number)), string
    return _parse_symbol(c, node), string


def parse_latex_math(root: MathElement, source: str) -> MathElement:
    """Append MathML conversion of `string` to `node` and return it.

    >>> parse_latex_math(math(), r'\alpha')
    math(mi('α'))
    >>> parse_latex_math(mrow(), r'x_{n}')
    mrow(msub(mi('x'), mi('n')))

    """
    string = source  # not-yet handled part of source
    node = root  # the current "insertion point"

    # Loop over `string` while changing it.
    while len(string) > 0:
        # Take off first character:
        c, string = string[0], string[1:]
        if c in " \n":
            continue  # whitespace is ignored in LaTeX math mode
        node, string = _parse_char(c, node, string)
        if node is None:
            if not string:
                return root  # ignore unbalanced braces
            raise MathError(f'No insertion point for "{string}". '
                            f'Unbalanced braces in "{source[:-len(string)]}"?')
    if node.nchildren and len(node) < node.nchildren:
        raise MathError("Last node missing children. Source incomplete?")
    return root


# LaTeX commands
# ~~~~~~~~~~~~~~

type _Result = tuple[MathElement | None, str]


def _append_new(node: MathElement, new_node: MathElement, string: str) -> _Result:
    """Append `new_node` to `node` and make it the current node."""
    node.append(new_node)
    return new_node, string


def _cmd_letter(name: str, node: MathElement, string: str) -> _Result:
    new_node = mi(letters[name])
    if name in greek_capitals:
        # upright in "TeX style" but MathML sets them italic ("ISO style").
        # CSS styling does not change the font style in Firefox 78.
        # Use 'mathvariant="normal"'?
        new_node.set("class", "capital-greek")
    return node.append(new_node), string


def _cmd_ordinary(name: str, node: MathElement, string: str) -> _Result:
    # <mi mathvariant="normal"> well supported by Chromium but
    # Firefox 115.5.0 puts additional space around the symbol, e.g.
    # <mi mathvariant="normal">∂</mi><mi>t</mi> looks like ∂ t, not ∂t
    return node.append(mi(ordinary[name])), string


# embellished function names:
_FUNCTION_EMBELLISHMENTS = {
    "varliminf": lambda base: munder(base, mo("_")),                  # \underline\lim
    "varlimsup": lambda base: mover(base, mo("¯"), accent=False),     # \overline\lim
    "varprojlim": lambda base: munder(base, mo("←")),            # \underleftarrow\lim
    "varinjlim": lambda base: munder(base, mo("→")),             # \underrightarrow\lim
}


def _cmd_function(name: str, node: MathElement, string: str) -> _Result:
    # use <mi> followed by invisible function applicator character
    # (see https://www.w3.org/TR/MathML3/chapter3.html#presm.mi)
    if name == "operatorname":
        # custom function name, e.g. ``\operatorname{abs}(x)``
        # TODO: \operatorname* -> with limits
        arg, string = tex_token_or_group(string)
        new_node = mi(arg, mathvariant="normal")
    else:
        new_node = mi(functions[name])
    if name in _FUNCTION_EMBELLISHMENTS:
        new_node = _FUNCTION_EMBELLISHMENTS[name](new_node)
    node = node.append(new_node)
    # add ApplyFunction when appropriate (not \sin^2(x), say)
    # cf. https://www.w3.org/TR/MathML3/chapter3.html#presm.mi
    if string and string[0] not in ("^", "_"):
        node = node.append(mo("⁡"))  # &ApplyFunction;
    return node, string


def _cmd_modulo(name: str, node: MathElement, string: str) -> _Result:
    binary, named, parentheses, padding = modulo_functions[name]
    if binary:
        return node.append(mo("mod", lspace=padding, rspace=padding)), string
    # left padding
    if node.in_block():
        padding = "1em"
    node = node.append(mspace(width=padding))
    if parentheses:
        node = node.append(mo("(", stretchy=False))
    if named:
        node = node.append(mi("mod"))
        node = node.append(mspace(width="0.333em"))
    arg, string = tex_token_or_group(string)
    node = parse_latex_math(node, arg)
    if parentheses:
        node = node.append(mo(")", stretchy=False))
    return node, string


def _cmd_boldsymbol(name: str, node: MathElement, string: str) -> _Result:
    return _append_new(node, mrow(CLASS="boldsymbol"), string)


def _cmd_colon(name: str, node: MathElement, string: str) -> _Result:
    # trailing punctuation, not binary relation
    return node.append(mo(":", form="postfix", lspace="0", rspace="0.28em")), string


def _cmd_idotsint(name: str, node: MathElement, string: str) -> _Result:
    # AMS shortcut for ∫︀···∫︀
    return parse_latex_math(node, r"\int\dotsi\int"), string


def _cmd_thick_operator(name: str, node: MathElement, string: str) -> _Result:
    return node.append(mo(thick_operators[name], style="font-weight: bold")), string


def _cmd_small_operator(name: str, node: MathElement, string: str) -> _Result:
    return node.append(mo(small_operators[name], mathsize="75%")), string


def _cmd_operator(name: str, node: MathElement, string: str) -> _Result:
    attributes = {}
    if name in movablelimits and string and string[0] in " _^":
        attributes["movablelimits"] = True
    elif name in ("lvert", "lVert"):
        attributes["class"] = "mathopen"
    return node.append(mo(operators[name], **attributes)), string


def _cmd_bigdelimiter(name: str, node: MathElement, string: str) -> _Result:
    delimiter_attributes = {}
    size = delimiter_sizes[bigdelimiters[name]]
    delimiter, string = tex_token_or_group(string)
    if delimiter not in "()[]/|.":
        try:
            delimiter = stretchables[delimiter.lstrip("\\")]
        except KeyError:
            raise MathError(f'Unsupported "\\{name}" delimiter "{delimiter}"!') from None
    if size:
        delimiter_attributes["maxsize"] = size
        delimiter_attributes["minsize"] = size
        delimiter_attributes["symmetric"] = True
    if name == "left" or name.endswith("l"):
        row = mrow()
        node.append(row)
        node = row
    if delimiter != ".":  # '.' stands for "empty delimiter"
        node.append(mo(delimiter, **delimiter_attributes))
    if name == "right" or name.endswith("r"):
        node = node.close()
    return node, string


def _cmd_not(name: str, node: MathElement, string: str) -> _Result:
    # negation: LaTeX just overlays next symbol with "/".
    arg, string = tex_token(string)
    if arg == "{":
        return node, "{\\not " + string
    if arg.startswith("\\"):  # LaTeX macro
        try:
            arg = operators[arg[1:]]
        except KeyError:
            raise MathError(rf'"\not" cannot negate: "{arg}"!') from None
    arg = unicodedata.normalize("NFC", arg + "̸")
    return node.append(mo(arg)), string


def _cmd_text(name: str, node: MathElement, string: str) -> _Result:
    # arbitrary text (usually comments)  ->  <mtext>
    arg, string = tex_token_or_group(string)
    parts = arg.split("$")  # extract inline math
    for i, part in enumerate(parts):
        if i % 2 == 0:  # i is even
            # LaTeX keeps whitespace in, e.g., ``\text{ foo }``,
            # <mtext> displays only internal whitespace.
            # → replace marginal whitespace with NBSP
            node = node.append(mtext(re.sub("(^[ \n]|[ \n]$)", " ", part)))
        else:
            parse_latex_math(node, part)
    return node, string


def _cmd_space(name: str, node: MathElement, string: str) -> _Result:
    return node.append(mspace(width="%s" % spaces[name])), string


def _cmd_hspace(name: str, node: MathElement, string: str) -> _Result:
    arg, string = tex_group(string)
    if arg.endswith("mu"):
        # unit "mu" (1mu=1/18em) not supported by MathML
        arg = "%sem" % (float(arg[:-2]) / 18)
    return node.append(mspace(width="%s" % arg)), string


def _cmd_phantom(name: str, node: MathElement, string: str) -> _Result:
    return _append_new(node, mphantom(), string)


def _cmd_boxed(name: str, node: MathElement, string: str) -> _Result:
    # CSS padding is broken in Firefox 115.6.0esr
    # therefore we still need the deprecated <menclose> element
    return _append_new(node, menclose(notation="box", CLASS="boxed"), string)


def _cmd_sqrt(name: str, node: MathElement, string: str) -> _Result:
    radix, string = tex_optarg(string)
    if radix:
        indexnode = mrow()
        new_node = mroot(indexnode, switch=True)
        parse_latex_math(indexnode, radix)
        indexnode.close()
    else:
        new_node = msqrt()
    return _append_new(node, new_node, string)


def _cmd_fraction(name: str, node: MathElement, string: str) -> _Result:
    attributes = fractions[name]
    if name == "cfrac":
        optarg, string = tex_optarg(string)
        optargs = {"l": "left", "r": "right"}
        if optarg in optargs:
            attributes = attributes.copy()
            attributes["numalign"] = optargs[optarg]  # "numalign" is deprecated
            attributes["class"] += " numalign-" + optargs[optarg]
    new_node = frac = mfrac(**attributes)
    if name.endswith("binom"):
        new_node = mrow(mo("("), new_node, mo(")"), CLASS="binom")
        new_node.nchildren = 3
    node.append(new_node)
    return frac, string


def _cmd_newline(name: str, node: MathElement, string: str) -> _Result:
    # end of a row
    entry = mtd()
    node.close().close().append(mtr(entry))
    return entry, string


def _cmd_accent(name: str, node: MathElement, string: str) -> _Result:
    accent_node = mo(accents[name], stretchy=False)
    # mi() would be simpler, but semantically wrong
    # --- https://w3c.github.io/mathml-core/#operator-fence-separator-or-accent-mo
    if name == "vec":
        accent_node.set("scriptlevel", "+1")  # scale down arrow
    return _append_new(node, mover(accent_node, accent=True, switch=True), string)


def _cmd_over(name: str, node: MathElement, string: str) -> _Result:
    # set "accent" to False (otherwise dots on i and j are dropped)
    # but to True on accent node get "textstyle" (full size) symbols on top
    new_node = mover(mo(over[name][0], accent=True), switch=True, accent=False)
    return _append_new(node, new_node, string)


def _cmd_overset(name: str, node: MathElement, string: str) -> _Result:
    return _append_new(node, mover(switch=True), string)


def _cmd_under(name: str, node: MathElement, string: str) -> _Result:
    return _append_new(node, munder(mo(under[name][0]), switch=True), string)


def _cmd_underset(name: str, node: MathElement, string: str) -> _Result:
    return _append_new(node, munder(switch=True), string)


def _cmd_xarrow(name: str, node: MathElement, string: str) -> _Result:
    subscript, string = tex_optarg(string)
    base = mo(operators["long" + name[1:]])
    if subscript:
        new_node = munderover(base)
        sub_node = parse_latex_math(mrow(), subscript)
        if len(sub_node) == 1:
            sub_node = sub_node[0]
        new_node.append(sub_node)
    else:
        new_node = mover(base)
    return _append_new(node, new_node, string)


def _cmd_layout_style(name: str, node: MathElement, string: str) -> _Result:
    # 'displaystyle', 'textstyle', ...
    if len(node) > 0:
        raise MathError(rf'Declaration "\{name}" must be first command in a group!')
    for k, v in layout_styles[name].items():
        node.set(k, v)
    return node, string


def _cmd_limits(name: str, node: MathElement, string: str) -> _Result:
    arg, remainder = tex_token(string)
    if arg in "_^":  # else ignore
        string = remainder
        node = handle_script_or_limit(node, arg, limits=name)
    return node, string


def _cmd_begin(name: str, node: MathElement, string: str) -> _Result:
    return begin_environment(node, string)


def _cmd_end(name: str, node: MathElement, string: str) -> _Result:
    return end_environment(node, string)


def handle_math_alphabet(name: str, node: MathElement, string: str) -> _Result:
    attributes = {}
    if name == "mathscr":
        attributes["class"] = "mathscr"
    arg, string = tex_token_or_group(string)
    # Shortcut for text arg like \mathrm{out} with more than one letter:
    if name == "mathrm" and arg.isalpha() and len(arg) > 1:
        node = node.append(mi(arg))  # <mi> defaults to "normal" font
        return node, string
    # Parse into an <mrow>
    container = mrow(**attributes)
    node.append(container)
    parse_latex_math(container, arg)
    key = name.replace("mathscr", "mathcal").replace("mathbfsfit", "mathsfbfit")
    a2ch = getattr(mathalphabet2unichar, key, {})
    for subnode in container.iter():
        if isinstance(subnode, mn):
            # a number may consist of more than one digit
            subnode.text = "".join(a2ch.get(ch, ch) for ch in subnode.text)
        elif isinstance(subnode, mi):
            # don't convert multi-letter identifiers (functions)
            subnode.text = a2ch.get(subnode.text, subnode.text)
            if name == "mathrm" and subnode.text.isalpha():
                subnode.set("mathvariant", "normal")
    return container.close(), string


# Command handlers in order of precedence: (selector, handler)
_CMD_HANDLERS: list[tuple[Callable[[str], bool],
                          Callable[[str, MathElement, str], _Result]]] = [
    # Token elements: identifier  ->  <mi>
    (lambda name: name in letters, _cmd_letter),
    (lambda name: name in ordinary, _cmd_ordinary),
    (lambda name: name in functions, _cmd_function),
    (lambda name: name in modulo_functions, _cmd_modulo),
    # font changes or mathematical alphanumeric characters
    (lambda name: name in ("boldsymbol", "pmb"), _cmd_boldsymbol),  # \pmb is "poor mans bold"
    (lambda name: name in math_alphabets, handle_math_alphabet),
    # operator, fence, or separator  ->  <mo>
    (lambda name: name == "colon", _cmd_colon),
    (lambda name: name == "idotsint", _cmd_idotsint),
    (lambda name: name in thick_operators, _cmd_thick_operator),
    (lambda name: name in small_operators, _cmd_small_operator),
    (lambda name: name in operators, _cmd_operator),
    (lambda name: name in bigdelimiters, _cmd_bigdelimiter),
    (lambda name: name == "not", _cmd_not),
    # arbitrary text (usually comments)  ->  <mtext>
    (lambda name: name in ("text", "mbox", "textrm"), _cmd_text),
    # horizontal space -> <mspace>
    (lambda name: name in spaces, _cmd_space),
    (lambda name: name in ("hspace", "mspace"), _cmd_hspace),
    (lambda name: name == "phantom", _cmd_phantom),
    (lambda name: name == "boxed", _cmd_boxed),
    # Complex elements (Layout schemata)
    (lambda name: name == "sqrt", _cmd_sqrt),
    (lambda name: name in fractions, _cmd_fraction),
    (lambda name: name == "\\", _cmd_newline),
    (lambda name: name in accents, _cmd_accent),
    (lambda name: name in over, _cmd_over),
    (lambda name: name == "overset", _cmd_overset),
    (lambda name: name in under, _cmd_under),
    (lambda name: name == "underset", _cmd_underset),
    (lambda name: name in ("xleftarrow", "xrightarrow"), _cmd_xarrow),
    (lambda name: name in layout_styles, _cmd_layout_style),
    (lambda name: name.endswith("limits"), _cmd_limits),
    # Environments
    (lambda name: name == "begin", _cmd_begin),
    (lambda name: name == "end", _cmd_end),
]


def handle_cmd(name: str, node: MathElement, string: str) -> _Result:
    """Process LaTeX command `name` followed by `string`.

    Append result to `node`.
    If needed, parse `string` for command argument.
    Return new current node and remainder of `string`:

    >>> handle_cmd('hbar', math(), r' \frac')
    (math(mi('ℏ')), ' \\frac')
    >>> handle_cmd('hspace', math(), r'{1ex} (x)')
    (math(mspace(width='1ex')), ' (x)')

    """
    for selector, handler in _CMD_HANDLERS:
        if selector(name):
            return handler(name, node, string)
    raise MathError(rf'Unknown LaTeX command "\{name}".')


def _with_limits(child: MathElement, limits: str) -> bool:
    return (limits in ("limits", "movablelimits")
            or limits == "" and child.get("movablelimits", None))


def handle_script_or_limit(node: MathElement, c: str, limits: str = "") -> MathElement:
    """Append script or limit element to `node`."""
    child = node.pop()
    if limits == "limits":
        child.set("movablelimits", "false")
    elif (limits == "movablelimits"
          or getattr(child, "text", "") in movablelimits):
        child.set("movablelimits", "true")

    if c == "_":
        if isinstance(child, mover):
            new_node = munderover(*child, switch=True)
        elif isinstance(child, msup):
            new_node = msubsup(*child, switch=True)
        elif _with_limits(child, limits):
            new_node = munder(child)
        else:
            new_node = msub(child)
    elif c == "^":
        if isinstance(child, munder):
            new_node = munderover(*child)
        elif isinstance(child, msub):
            new_node = msubsup(*child)
        elif _with_limits(child, limits):
            new_node = mover(child)
        else:
            new_node = msup(child)
    node.append(new_node)
    return new_node


def begin_environment(node: MathElement, string: str) -> _Result:
    name, string = tex_group(string)
    if name not in matrices:
        raise MathError(f'Environment "{name}" not supported!')
    left_delimiter = matrices[name][0]
    attributes = {}
    if left_delimiter:
        wrapper = mrow(mo(left_delimiter))
        if name == "cases":
            wrapper = mrow(mo(left_delimiter, rspace="0.17em"))
            attributes["columnalign"] = "left"
            attributes["class"] = "cases"
        node.append(wrapper)
        node = wrapper
    elif name == "smallmatrix":
        attributes["rowspacing"] = "0.02em"
        attributes["columnspacing"] = "0.333em"
        attributes["scriptlevel"] = "1"
    elif name == "aligned":
        attributes["class"] = "ams-align"
    # TODO: array, aligned & alignedat take an optional [t], [b], or [c].
    entry = mtd()
    node.append(mtable(mtr(entry), **attributes))
    return entry, string


def end_environment(node: MathElement, string: str) -> _Result:
    name, string = tex_group(string)
    if name not in matrices:
        raise MathError(f'Environment "{name}" not supported!')
    node = node.close().close().close()  # close: mtd, mdr, mtable
    right_delimiter = matrices[name][1]
    if right_delimiter:
        node = node.append(mo(right_delimiter))
        node = node.close()
    elif name == "cases":
        node = node.close()
    return node, string


def tex_equation_columns(rows: list[str]) -> int:
    """Return the number of "equation_columns" in `code_lines`.

    cf. "alignat" in http://mirror.ctan.org/macros/latex/required/amsmath/amsldoc.pdf
    """
    tabs = max(row.count("&") - row.count(r"\&") for row in rows)
    if tabs == 0:
        return 0
    return int(tabs / 2 + 1)


def align_attributes(rows: list[str]) -> dict[str, object]:
    """Return dictionary with attributes to style an <mtable> as align environment.

    Not used with HTML. Replaced by CSS rule for "mtable.ams-align" in
    "minimal.css" as "columnalign" is disregarded by Chromium and webkit.
    """
    atts = {"class": "ams-align",
            "displaystyle": True}
    # get maximal number of non-escaped "next column" markup characters:
    tabs = max(row.count("&") - row.count(r"\&") for row in rows)
    if tabs:
        aligns = ["right", "left"] * tabs
        spacing = ["0", "2em"] * tabs
        atts["columnalign"] = " ".join(aligns[:tabs + 1])
        atts["columnspacing"] = " ".join(spacing[:tabs])
    return atts


def tex2mathml(tex_math: str, as_block: bool = False) -> str:
    """Return string with MathML code corresponding to `tex_math`.

    Set `as_block` to ``True`` for displayed formulas.
    """
    # Set up tree
    math_tree = math(xmlns="http://www.w3.org/1998/Math/MathML")
    node = math_tree
    if as_block:
        math_tree.set("display", "block")
        rows = toplevel_code(tex_math).split(r"\\")
        if len(rows) > 1:
            # emulate "align*" environment with a math table
            node = mtd()
            math_tree.append(mtable(mtr(node), CLASS="ams-align", displaystyle=True))
    parse_latex_math(node, tex_math)
    math_tree.indent_xml()
    return math_tree.toxml()
