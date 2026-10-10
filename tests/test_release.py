"""Release consistency: one version everywhere, and the license files the artifacts ship."""

from __future__ import annotations

import re
import subprocess
import tomllib
from pathlib import Path

import docodin
import pytest
from docodin import _native

ROOT = Path(__file__).resolve().parent.parent
PROGRAMS = ["docodin", "docodin-check", "docodin-lsp"]


def project() -> dict:
    return tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))["project"]


def test_versions_agree():
    version = project()["version"]
    odin = (ROOT / "odin" / "version" / "version.odin").read_text(encoding="utf-8")
    assert re.search(r'VERSION :: "([^"]+)"', odin).group(1) == version
    assert docodin.__version__ == version
    assert _native.native().version == version
    for conf in ("book", "dod"):
        text = (ROOT / "docs" / conf / "conf.py").read_text(encoding="utf-8")
        assert f'release = "{version}"' in text, conf


@pytest.mark.parametrize("program", PROGRAMS)
def test_programs_report_the_version(program):
    binary = ROOT / "bin" / program
    if not binary.is_file():
        pytest.skip(f"bin/{program} not built")
    out = subprocess.run([str(binary), "--version"], capture_output=True, text=True,
                         check=True).stdout
    assert out.startswith(f"{program} {project()['version']}")


def test_license_files_exist():
    for name in project()["license-files"]:
        assert list(ROOT.glob(name)), name
