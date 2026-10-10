"""Wrong versions, modified artifacts and incomplete releases must not publish."""

from __future__ import annotations

import importlib.util
import io
import tarfile
import zipfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("release_tools", ROOT / "scripts" / "package_release.py")
assert spec and spec.loader
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def candidates(root: Path) -> tuple[Path, str]:
    version = release.project_version()
    for platform, tag in (("linux-x86_64", "manylinux_2_34_x86_64"),
                           ("macos-arm64", "macosx_11_0_arm64")):
        directory = root / platform
        directory.mkdir(parents=True)
        with zipfile.ZipFile(directory / f"docodin-{version}-py3-none-{tag}.whl", "w") as wheel:
            wheel.writestr(f"docodin-{version}.dist-info/METADATA",
                           f"Metadata-Version: 2.4\nName: docodin\nVersion: {version}\n")
            for name in release.PROGRAMS:
                wheel.writestr(f"docodin-{version}.data/scripts/{name}", b"native fixture")
            wheel.writestr(f"docodin-{version}.dist-info/licenses/LICENSE", "MIT fixture")
    with tarfile.open(root / "linux-x86_64" / f"docodin-{version}.tar.gz", "w:gz") as source:
        data = f"Name: docodin\nVersion: {version}\n".encode()
        info = tarfile.TarInfo(f"docodin-{version}/PKG-INFO")
        info.size = len(data)
        source.addfile(info, io.BytesIO(data))
    pdfs = root / "linux-x86_64" / "docs" / "pdf"
    pdfs.mkdir(parents=True)
    for name in release.documentation_pdfs():
        (pdfs / name).write_bytes(b"%PDF-1.7\nPDF fixture")
    return root, version


def test_assembled_release_preserves_native_modes_and_identity(tmp_path: Path) -> None:
    inputs, version = candidates(tmp_path / "input")
    out = tmp_path / "release"
    revision = "a" * 40
    release.assemble(inputs, out, revision, f"v{version}")
    release.verify(out, f"v{version}", revision)
    assert len(list(out.iterdir())) == 7
    assert not list(out.glob("*.pdf"))
    with tarfile.open(out / f"docodin-{version}-linux-x86_64.tar.gz") as archive:
        for name in release.PROGRAMS:
            assert archive.getmember(f"docodin-{version}-linux-x86_64/{name}").mode == 0o755


@pytest.mark.parametrize("damage", ["bytes", "missing-checksum", "wrong-commit"])
def test_publish_rejects_modified_or_unqualified_artifacts(tmp_path: Path, damage: str) -> None:
    inputs, version = candidates(tmp_path / "input")
    out = tmp_path / "release"
    release.assemble(inputs, out, "a" * 40, f"v{version}")
    revision = "a" * 40
    if damage == "bytes":
        next(out.glob("*.whl")).write_bytes(b"tampered")
    elif damage == "missing-checksum":
        checksums = out / "SHA256SUMS"
        checksums.write_text("\n".join(checksums.read_text().splitlines()[1:]) + "\n")
    else:
        revision = "b" * 40
    with pytest.raises(ValueError):
        release.verify(out, f"v{version}", revision)


def test_release_rejects_missing_platform_and_wrong_tag(tmp_path: Path) -> None:
    inputs, version = candidates(tmp_path / "input")
    next((inputs / "macos-arm64").glob("*.whl")).unlink()
    with pytest.raises(ValueError, match="macos-arm64"):
        release.assemble(inputs, tmp_path / "out", "a" * 40, f"v{version}")
    with pytest.raises(ValueError, match="does not match"):
        release.project_version("v0.0.0")


def test_release_requires_every_individual_dod_pdf(tmp_path: Path) -> None:
    inputs, version = candidates(tmp_path / "input")
    next((inputs / "linux-x86_64" / "docs" / "pdf").glob("dod-*.pdf")).unlink()
    with pytest.raises(FileNotFoundError):
        release.assemble(inputs, tmp_path / "out", "a" * 40, f"v{version}")


def test_verification_reads_version_from_the_tagged_source(tmp_path: Path) -> None:
    inputs, version = candidates(tmp_path / "input")
    out = tmp_path / "release"
    release.assemble(inputs, out, "a" * 40, f"v{version}")
    tagged = tmp_path / "tagged-source"
    tagged.mkdir()
    (tagged / "pyproject.toml").write_text(f'[project]\nversion = "{version}"\n')
    release.verify(out, f"v{version}", "a" * 40, tagged)
    (tagged / "pyproject.toml").write_text('[project]\nversion = "0.0.0"\n')
    with pytest.raises(ValueError, match="does not match"):
        release.verify(out, f"v{version}", "a" * 40, tagged)
