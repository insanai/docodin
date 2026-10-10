"""Tests of the native library interface."""

from __future__ import annotations

import os
import threading

import docutils.statemachine
import pytest
from docodin import _native


@pytest.fixture(scope="module")
def lib():
    return _native.native()


def test_abi_and_version(lib):
    assert lib.version
    assert lib._lib.docodin_abi_version() == _native.ABI_VERSION


@pytest.mark.parametrize("text", [
    "", "\n", "a\n\n", "  \n\t\n", "a\tb\n\tc  \n",
    "x\x0by\x0cz\r\nw\rv\x1cu\x85t s r",
    "　trailing \n",
])
@pytest.mark.parametrize("tab_width", [8, 4, 1])
def test_split_lines_matches_string2lines(lib, text, tab_width):
    expected = docutils.statemachine.string2lines(text, tab_width, convert_whitespace=True)
    assert lib.split_lines(text, tab_width) == expected


def test_parse_returns_items_and_line_count(lib):
    items, count, final, _ = lib.parse("Title\n=====\n\ntext\n")
    assert count == 4
    assert final == count + 1 or final == count
    kinds = [item[0] for item in items]
    assert kinds[0] == 2  # Section_Title event
    assert kinds[1] == 4  # Paragraph


def test_nul_bytes_are_not_truncated(lib):
    items, count, _, _ = lib.parse("a\x00b\n\nsecond\n")
    assert count == 3
    assert len(items) == 2


def test_raw_lines_mode(lib):
    # '\n'-joined StringList lines: whitespace-only lines are blank, no rstrip
    items, count, _, _ = lib.parse("para  \n  \nnext", line_count=3)
    assert count == 3
    assert len(items) == 2


def test_large_results_are_decoded_item_by_item(lib, monkeypatch):
    text = "Title\n=====\n\n" + "".join(f"para {i}\n\n- item\n\n" for i in range(50))
    expected = lib.parse(text)
    monkeypatch.setattr(_native, "LAZY_MIN_SIZE", 0)
    items, *rest = lib.parse_items(text)
    assert isinstance(items, _native.WireItems)
    assert len(items) == len(expected[0])
    assert items[-1] == expected[0][-1] and items[1] == expected[0][1]
    assert [items[0], *items] == [expected[0][0], *expected[0]]
    assert (list(items), *rest) == expected  # iteration drops the decoded items
    items.release()
    items.release()
    with pytest.raises(IndexError):
        items[0]
    with pytest.raises(IndexError):
        items[len(items)]


def test_parse_inline(lib):
    items = lib.parse_inline("*a* and ``b``", 1)
    assert items[0][0] == 48 and items[1] == " and " and items[2][0] == 50


def test_thread_safety(lib):
    text = open(__file__, encoding="utf-8").read().replace('"""', "") * 3
    expected = lib.parse(text)
    errors: list = []

    def work():
        try:
            for _ in range(20):
                if lib.parse(text) != expected:
                    errors.append("mismatch")
        except Exception as exc:  # noqa: BLE001
            errors.append(repr(exc))

    threads = [threading.Thread(target=work) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert not errors


def _peak_rss_mib() -> float:
    import resource
    import sys

    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return peak / (1 << 20) if sys.platform == "darwin" else peak / 1024


@pytest.mark.skipif(os.name == "nt", reason="uses the resource module")
def test_short_lived_threads_do_not_retain_arenas(lib):
    # Each thread's arena used to keep its block after the thread exited:
    # about 1 MiB per retired thread.
    text = "Paragraph with *emphasis* and ordinary words.\n\n" * 2000
    lib.parse(text)
    before = _peak_rss_mib()
    for _ in range(200):
        t = threading.Thread(target=lib.parse, args=(text,))
        t.start()
        t.join()
    assert _peak_rss_mib() - before < 64


@pytest.mark.parametrize("text", [
    "*a " * 5000,                                          # unclosed start-strings
    "-".join(["a"] * 5000) + "_",                           # long name chain
    "".join("|" + " " * (i + 1) + "x\n" for i in range(3000)),  # deep line block
    "".join("  " * i + "- item\n\n" for i in range(500)),    # deep lists
    "+" + "-+" * 200 + "\n" + ("|" + " |" * 200 + "\n+" + "-+" * 200 + "\n") * 50,
    "`" * 10000, "\\" * 10000, "::" * 5000, "[" * 5000 + "]_",
])
def test_pathological_inputs_complete(lib, text):
    lib.parse(text, line_length_limit=10**7)


def test_library_path_override(monkeypatch, tmp_path):
    monkeypatch.setenv("DOCODIN_LIB_PATH", str(tmp_path / "missing.so"))
    with pytest.raises(RuntimeError):
        _native._find_library()
    monkeypatch.delenv("DOCODIN_LIB_PATH")
    assert os.path.exists(_native._find_library())
