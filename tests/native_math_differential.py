"""Differential test of the native math converters (``odin/math``) against docutils.

Every snippet is converted by ``latex2mathml.tex2mathml`` (inline and block), by
``math2html.math2html`` (inline, display and ``simplemath``) with the messages written
to standard error, by ``str.translate(unichar2tex.uni2tex_table)`` and by
``pick_math_environment``; exceptions count by type and message. The native side is
the ``odin/math/difftest`` executable, built by this script.

The snippets are hand-picked edge cases, a grammar-driven fuzzer, random sequences of
the commands in the tables, and optionally a JSON list from ``--snippets``::

    uv run --no-project --python 3.14 --with docutils==0.22.4 python \
        tests/native_math_differential.py [--reference docutils|shim]
        [--fuzz N] [--seed S] [--snippets FILE] [--show N]

The reference is the installed docutils (default) or the docodin shim.  Run it
with the CPython version the native tables are generated from (3.14): Unicode
data and the texts of Python exceptions (which docutils lets through) differ
between versions.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import random
import subprocess
import sys
import tempfile
from collections import Counter
from collections.abc import Callable
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHIM = ROOT / "python" / "docodin" / "shim"
BINARY = ROOT / "build" / "math-difftest"

HAND = [
    # fractions, roots and other templates
    r"\frac{\frac{a}{b}}{\frac{c}{\frac{d}{e}}}", r"\dfrac{1}{\tfrac{2}{3}}",
    r"\cfrac[r]{1}{1+\cfrac{1}{x}}", r"\cfrac[l]{a}{b}", r"\cfrac[x]{a}{b}", r"\frac{1}",
    r"\frac", r"\binom{1}", r"\sqrt", r"\sqrt[3]", r"\sqrt[3]{}", r"\sqrt[\]]{x}",
    r"\sqrt[a\]b]{x}", r"\sqrt[a\]b[c]{x}", r"\sqrt [2] x", r"\nicefrac{1}{2}",
    r"\unitfrac[m]{a}{b}", r"\unit[3]{kg}", r"\unit{m}", r"\raisebox{2pt}{x}",
    r"\raisebox{2pt}", r"\stackrel{a}{=}", r"\boxed{x}", r"\framebox[2cm][c]{z}",
    r"\parbox[t]{3cm}{w}", r"\rule{1cm}{2pt}", r"\href{http://a}{b}", r"\url{http://x}",
    r"\renewenvironment{a}{b}{c}", r"\addcontentsline{a}{b}{c}", r"\leftroot{2}",
    # literal parameters
    r"\color{re{d}x}{y}", r"\color{$1}{x}", r"\fcolorbox{$q}{red}{x}", r"\color{red}",
    r"\color", r"\color}", r"\color red{x}", r"\hspace", r"\hspace{", r"\hspace{3mu}",
    r"\hspace{-1.5mu}", r"\hspace{1_0mu}", r"\hspace{1__0mu}", r"\hspace{ 2 mu}",
    r"\hspace{infmu}", r"\hspace{-nanmu}", r"\hspace{1e400mu}", r"\hspace{1e-400mu}",
    r"\hspace{٣mu}", r"\hspace{xmu}", r"\hspace{mu}", r"\hspace{.5mu}", r"\hspace{5.mu}",
    r"\hspace{1e5mu}", r"\hspace{123456789012345678mu}", r"\mspace{0.0001mu}",
    # environments
    r"\begin{matrix}a&b\\c&d\end{matrix}", r"\begin{pmatrix}1\\2\end{pmatrix}",
    r"\begin{array}{lcr}a&b&c\\d&e&f\end{array}", r"\begin{array}[t]{cc}1&2\end{array}",
    r"\begin{array}{}a\end{array}", r"\begin{array}", r"\begin{array}(", r"\begin{array}{c",
    r"\begin{cases}x&y\\z\end{cases}", r"\begin{cases}\end{cases}",
    r"\begin{align}a&=b\\c&=d\end{align}", r"\begin{eqnarray}a&b&c\end{eqnarray}",
    r"\begin{smallmatrix}1&2\end{smallmatrix}", r"\begin{aligned}a&=b\end{aligned}",
    r"\begin{Vmatrix}a\end{Vmatrix}", r"\begin{bogus*}q\end{bogus*}", r"\begin",
    r"\begin(", r"\begin{matrix}\begin{matrix}1\end{matrix}\end{matrix}",
    r"\begin{matrix}a\end{pmatrix}", r"\end{matrix}", r"a\\b", r"a\\b\\c&d",
    # commands
    r"\foo", r"\Upfoo\Upbar", r"\Upsilon", r"\upalpha", r"\Upxyz\Upq", r"\Upß\Up",
    r"\Upŉx\Up", r"\up", r"\Up", r"\sum\limits_a^b", r"\int\nolimits_0^1", r"\lim\limits",
    r"\max\movablelimits^2", r"\foolimits_x", "\\", "x\\", "{\\", "{\\}", "\\{\\}",
    r"\operatorname{sgn}x", r"\operatorname*{argmax}", r"\varlimsup_n", r"\bmod",
    r"a\pmod{n}", r"\mod", r"\pod{x}", r"\colon", r"\idotsint", r"\not=", r"\not{=}",
    r"\not\in", r"\not\foo", r"\not", r"\not{}", r"\displaystyle x", r"x\displaystyle",
    r"{\scriptstyle x}", r"\xleftarrow[a]{b}", r"\xrightarrow{x}", r"\overset{a}{b}",
    # unbalanced
    "{", "}", "{{", "}}", "{x", "x}", "{x}}", "a}b}c", "[", "]", r"\left(", r"\right)",
    r"\left(\left[x\right)", r"\middle|", r"\left\{\begin{matrix}a\\b\\c\end{matrix}\right.",
    r"\left(\begin{array}{c}1\\2\\3\\4\end{array}\right)", r"\left\langle x\right\rangle",
    r"\big(", r"\Bigg|", r"\bigl(x\bigr)", r"\big", r"\big{x}", r"\big{()}", r"\big\langle",
    # fonts and accents
    r"\mathbb{R}", r"\mathbb{RR}", r"\mathcal{L}", r"\mathscr{E}", r"\mathrm{d}x",
    r"\mathrm{sin}", r"\mathrm{ab1}", r"\mathbf{12.5}", r"\mathbfsfit{x}", r"\mathsfbfit{x}",
    r"\mathbb{\Gamma}", r"\text{a $b$ c}", "\\text{ a \n}", "\\text{\n}", "\\text{x \n}",
    r"\hat{x}", r"\hat{}", r"\hat", r"\vec{v}", r"\bar", r"\ddot{\frac{a}{b}}", r"\'e",
    r"\"u", r"\c{c}", r"\v{s}", r"\hat{+}", r"\hat{\le}", r"\acute{\,}", r"\'{é}", r"\~{ñ}",
    r"\v{\text{ǆ}}", r"\c{\u}", "\\'\u0301", r"\r{ᄀ}", r"\s{가}",
    # spaces, comments, characters
    "a b", "a\tb", "a\u2003b", "x%comment\ny", "x%comment", "{%x}", "\ufeffx", "", " ",
    "\n", "x^2_3", "x^", "^", "x^^2", r"\sum_{i=0}^{n}", r"\int_a^b", r"\lim_{x\to0}",
    r"1+2-3=4<5>6", r"f'(x)", "a,b;c:d", "3.14", "1,000.5", "@&$", "→", "#", "§", "²",
    "x²", "٣", "\x00", "\x7f", "\u200b", "a-b", "(-a", "[=-", r"\lvert-x", "\U0001d400",
]

CMDS = [r"\alpha", r"\beta", r"\Gamma", r"\sum", r"\int", r"\lim", r"\infty", r"\le", r"\to",
        r"\cdot", r"\partial", r"\nabla", r"\sin", r"\log", r"\pm", r"\times", r"\in", r"\ldots",
        r"\foo", r"\bar", r"\quad", r"\,", r"\;", r"\\", r"\{", r"\}", r"\|", r"\langle"]
ONE = [r"\sqrt", r"\hat", r"\vec", r"\bar", r"\mathbb", r"\mathcal", r"\mathrm", r"\mathbf",
       r"\boldsymbol", r"\text", r"\mbox", r"\textbf", r"\overline", r"\underline",
       r"\overbrace", r"\phantom", r"\not", r"\tilde", r"\widehat", r"\boxed", r"\big",
       r"\displaystyle", r"\operatorname", r"\ddot", r"\mathring", r"\hspace", r"\c"]
TWO = [r"\frac", r"\dfrac", r"\tfrac", r"\cfrac", r"\binom", r"\dbinom", r"\tbinom",
       r"\stackrel", r"\nicefrac", r"\unitfrac", r"\color", r"\textcolor", r"\overset"]
ENVS = ["matrix", "pmatrix", "bmatrix", "cases", "array", "align", "align*", "eqnarray",
        "gathered", "smallmatrix", "equation", "equation*", "split", "bogus", "aligned"]
DELIMS = ["(", ")", "[", "]", r"\{", r"\}", "|", r"\|", ".", r"\langle", r"\rfloor", "/", "x"]
ATOMS = ["x", "y", "Z", "1", "42", "3.5", "+", "-", "=", "<", ">", ",", ";", ":", "'", "!",
         "?", "*", "/", "|", ".", " ", "~", "@", "&", "$", "§", "α", "→", "#", '"', "`",
         "%c\n", "\t", "é", "e\u0301", "²", "\u2009", "ß"]


class Fuzzer:
    """Random TeX from a small grammar (groups, templates, environments, scripts)."""

    def __init__(self, seed: int, commands: list[str]) -> None:
        self.rng = random.Random(seed)
        self.commands = commands

    def expr(self, depth: int) -> str:
        return "".join(self.item(depth) for _ in range(self.rng.randint(1, 4)))

    def group(self, depth: int) -> str:
        roll = self.rng.random()
        if roll < 0.08:
            return "{" + self.expr(depth - 1)  # unbalanced on purpose
        if roll < 0.12:
            return self.rng.choice(ATOMS)
        return "{" + self.expr(depth - 1) + "}"

    def item(self, depth: int) -> str:
        if depth <= 0:
            return self.rng.choice(ATOMS + CMDS)
        makers = [self.one, self.two, self.env, self.delimited, self.scripts, self.limits,
                  self.bigdelim, self.root, self.table_command]
        if self.rng.random() < 0.7:
            return self.rng.choice(makers)(depth)
        return self.rng.choice(ATOMS + CMDS)

    def one(self, depth: int) -> str:
        return self.rng.choice(ONE) + self.group(depth)

    def two(self, depth: int) -> str:
        optional = "[" + self.expr(depth - 1) + "]" if self.rng.random() < 0.3 else ""
        second = self.group(depth) if self.rng.random() < 0.9 else ""
        return self.rng.choice(TWO) + optional + self.group(depth) + second

    def delimited(self, depth: int) -> str:
        right = r"\right" + self.rng.choice(DELIMS) if self.rng.random() < 0.85 else ""
        return r"\left" + self.rng.choice(DELIMS) + self.expr(depth - 1) + right

    def scripts(self, depth: int) -> str:
        second = self.rng.choice("^_") + self.group(depth) if self.rng.random() < 0.5 else ""
        return self.rng.choice("^_") + self.group(depth) + second

    def limits(self, depth: int) -> str:
        operator = self.rng.choice([r"\sum", r"\int", r"\lim", r"\prod", r"\max", r"\bigcup"])
        return operator + "_" + self.group(depth) + "^" + self.group(depth)

    def bigdelim(self, depth: int) -> str:
        size = self.rng.choice([r"\big", r"\Big", r"\bigg", r"\Bigg", r"\bigl", r"\Bigr"])
        return size + self.rng.choice(DELIMS)

    def root(self, depth: int) -> str:
        return r"\sqrt[" + self.expr(depth - 1) + "]" + self.group(depth)

    def table_command(self, depth: int) -> str:
        suffix = self.rng.choice(["", " ", "{x}", "{x}{y}", "x", "[a]{b}", "*"])
        return self.rng.choice(self.commands) + suffix

    def env(self, depth: int) -> str:
        name = self.rng.choice(ENVS)
        head = r"\begin{" + name + "}"
        if name == "array":
            head += self.rng.choice(["{c}", "{lr}", "{lcr}", "[t]{cl}", "{}", ""])
        rows = ["&".join(self.expr(depth - 1) for _ in range(self.rng.randint(1, 3)))
                for _ in range(self.rng.randint(1, 3))]
        end = name if self.rng.random() < 0.85 else self.rng.choice(ENVS)
        tail = r"\end{" + end + "}" if self.rng.random() < 0.9 else ""
        return head + r"\\".join(rows) + tail


def table_commands() -> list[str]:
    """The command names of the converters' tables."""
    from docutils.utils.math import latex2mathml, math2html

    config = math2html.FormulaConfig
    names = {"\\" + name for name in latex2mathml.letters | latex2mathml.operators
             | latex2mathml.functions | latex2mathml.accents | latex2mathml.over
             | latex2mathml.math_alphabets | latex2mathml.spaces | latex2mathml.fractions
             | latex2mathml.bigdelimiters | latex2mathml.layout_styles}
    for table in (config.commands, config.hybridfunctions, config.onefunctions,
                  config.limitcommands, config.textfunctions, config.fontfunctions,
                  config.combiningfunctions, config.oversetfunctions, config.bracketcommands):
        names.update(name for name in table if "{" not in name)
    return sorted(names)


def corpus(fuzz: int, seed: int, extra: Path | None) -> list[str]:
    commands = table_commands()
    fuzzer = Fuzzer(seed, commands)
    snippets = list(HAND)
    snippets += [fuzzer.expr(fuzzer.rng.randint(1, 3)) for _ in range(fuzz)]
    snippets += ["".join(fuzzer.item(0) if fuzzer.rng.random() < 0.5 else
                         fuzzer.table_command(0) for _ in range(fuzzer.rng.randint(1, 8)))
                 for _ in range(fuzz // 2)]
    if extra is not None:
        snippets += json.loads(extra.read_text(encoding="utf-8"))
    return list(dict.fromkeys(snippets))


def outcome(convert: Callable[[], str]) -> dict[str, str]:
    """The result of `convert` with the messages written to standard error."""
    stream = io.StringIO()
    result = {"value": "", "exc": "", "msg": "", "trace": ""}
    with contextlib.redirect_stderr(stream), contextlib.redirect_stdout(stream):
        try:
            result["value"] = convert()
        except Exception as error:  # the exception is the result
            result["exc"], result["msg"] = type(error).__name__, str(error)
    result["trace"] = stream.getvalue()
    return result


def reference(snippet: str) -> dict[str, object]:
    from docutils.utils.math import latex2mathml, math2html, pick_math_environment, unichar2tex

    def html(display: bool, simple: bool = False) -> dict[str, str]:
        math2html.DocumentParameters.displaymode = display
        math2html.Options.simplemath = simple
        try:
            return outcome(lambda: math2html.math2html(snippet))
        finally:
            math2html.Options.simplemath = False

    return {
        "mml0": outcome(lambda: latex2mathml.tex2mathml(snippet, False)),
        "mml1": outcome(lambda: latex2mathml.tex2mathml(snippet, True)),
        "h0": html(False), "h1": html(True), "hsimple": html(False, True),
        "uni": snippet.translate(unichar2tex.uni2tex_table),
        "env": pick_math_environment(snippet),
    }


def native(snippets: list[str]) -> list[dict[str, object]]:
    subprocess.run(["odin", "build", str(ROOT / "odin" / "math" / "difftest"), "-o:speed",
                    "-vet", "-strict-style", f"-out:{BINARY}"], check=True)
    with tempfile.NamedTemporaryFile("w", suffix=".json", encoding="utf-8") as file:
        json.dump(snippets, file)
        file.flush()
        output = subprocess.run([str(BINARY), file.name], check=True, capture_output=True)
    return json.loads(output.stdout)


def use_reference(name: str) -> None:
    """Import docutils from the shim (for ``--reference shim``) in this process."""
    if name == "shim" and str(SHIM) not in sys.path:
        sys.path.insert(0, str(SHIM))


def references(snippets: list[str], name: str, jobs: int) -> list[dict[str, object]]:
    if jobs <= 1:
        return [reference(snippet) for snippet in snippets]
    with ProcessPoolExecutor(jobs, initializer=use_reference, initargs=(name,)) as pool:
        return list(pool.map(reference, snippets, chunksize=100))


def compare(snippets: list[str], name: str, jobs: int, show: int) -> int:
    results = native(snippets)
    mismatches: Counter[str] = Counter()
    expectations = references(snippets, name, jobs)
    for snippet, got, expected in zip(snippets, results, expectations, strict=True):
        for key, value in expected.items():
            if got[key] == value:
                continue
            mismatches[key] += 1
            if sum(mismatches.values()) <= show:
                print(f"--- {key} {snippet!r}\n expected: {value!r}\n native:   {got[key]!r}")
    print(f"{len(snippets)} snippets; mismatches: {dict(mismatches) or 0}")
    return 1 if mismatches else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--reference", choices=("docutils", "shim"), default="docutils")
    parser.add_argument("--fuzz", type=int, default=6000, help="number of fuzzed snippets")
    parser.add_argument("--seed", type=int, default=20260927)
    parser.add_argument("--snippets", type=Path, help="a JSON list of more snippets")
    parser.add_argument("--show", type=int, default=10, help="mismatches to show")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 1,
                        help="processes running the reference")
    args = parser.parse_args()
    use_reference(args.reference)
    import docutils

    print(f"reference: {Path(docutils.__file__).parent}")
    snippets = corpus(args.fuzz, args.seed, args.snippets)
    return compare(snippets, args.reference, args.jobs, args.show)


if __name__ == "__main__":
    sys.exit(main())
