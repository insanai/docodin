"""Differential fuzzing of the native smart quotes against the Python reference.

``docutils.utils.smartquotes.educate_tokens`` (from the docodin shim) runs
natively when the library is available; ``_educate_tokens`` is the pure-Python
implementation.  Random token sequences (text, literal and tag tokens made of
quotes, dashes, dots, backslashes, letters, digits, Unicode punctuation and
white space) are educated with random ``attr`` modes and languages, and with
customized quotes, by both; the results must be identical.

    uv run python tests/smartquotes_differential.py [--cases N] [--seed S]
"""

from __future__ import annotations

import argparse
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "python" / "docodin" / "shim"))
sys.path.insert(0, str(ROOT / "python"))

from docutils.utils import smartquotes  # noqa: E402

# Characters stable across the Unicode versions of the tables and the host.
ALPHABET = (
    "''''\"\"\"\"``’‘“”-----–—....  \\\\\\"
    "aeinstBDxX_09s12Ééßжß中٣５"
    "()[]{}!?;:,&#<>/@*«»„‚‹›"
    " \t\n\xa0\u2009\u200b\u200c\u3000\x00"
)
SNIPPETS = ("&#34;", "&#39;", "&#92;", "&#45;", "&quot;", "\\B", ". . .", "``", "''",
            "'90s", "---", "--", "...", "\"'a", "'\"a", "(' ", "-\" ", "\\\\'")
KINDS = ("plain", "plain", "plain", "text", "literal", "tag")
FIXED_ATTRS = ("1", "2", "3", "-1", "0", "qDe", "qBde", "qbiew", "", "q", "w")
EXTRA_LANGUAGES = ("", "xx", "EN", "en-GB", "De-CH", "FR", "en-uk-x-altquot", "enx")
CUSTOM_QUOTES = {"xx": "<>[]", "en": ("«\xa0", "\xa0»", "", "‘’"),
                 "de": ("'", '"', "`", "-")}


def random_text(rng: random.Random) -> str:
    parts = []
    for _ in range(rng.randrange(0, 14)):
        if rng.random() < 0.2:
            parts.append(rng.choice(SNIPPETS))
        else:
            parts.append(rng.choice(ALPHABET))
    return "".join(parts)


def random_tokens(rng: random.Random) -> list[tuple[str, str]]:
    return [(rng.choice(KINDS), random_text(rng)) for _ in range(rng.randrange(1, 6))]


def random_attr(rng: random.Random) -> str:
    if rng.random() < 0.5:
        return rng.choice(FIXED_ATTRS)
    return "".join(rng.sample("qbBdDiew12x-", rng.randrange(0, 6)))


def run(cases: int, seed: int) -> int:
    if smartquotes._native_library() is None:
        print("native smart quotes unavailable (build with scripts/build_odin.sh)")
        return 2
    rng = random.Random(seed)
    languages = sorted(smartquotes.smartchars.quotes) + list(EXTRA_LANGUAGES)
    failures = 0
    for case in range(cases):
        tokens = random_tokens(rng)
        attr = random_attr(rng)
        language = rng.choice(languages)
        custom = case % 10 == 0
        saved = dict(smartquotes.smartchars.quotes)
        if custom:
            smartquotes.smartchars.quotes.update(CUSTOM_QUOTES)
        try:
            native = list(smartquotes.educate_tokens(tokens, attr, language))
            python = list(smartquotes._educate_tokens(tokens, attr, language))
        finally:
            smartquotes.smartchars.quotes.clear()
            smartquotes.smartchars.quotes.update(saved)
        if native != python:
            failures += 1
            if failures <= 10:
                print(f"case {case}: attr={attr!r} language={language!r} custom={custom}")
                print(f"  tokens: {tokens!r}\n  native: {native!r}\n  python: {python!r}")
    print(f"{cases - failures}/{cases} identical (seed {seed})")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--cases", type=int, default=200_000)
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()
    return run(args.cases, args.seed)


if __name__ == "__main__":
    sys.exit(main())
