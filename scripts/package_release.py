"""Assemble the qualified wheels, source, native archives and checksums."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import shutil
import tarfile
import tomllib
import zipfile
from email.parser import BytesParser
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROGRAMS = ("docodin", "docodin-check", "docodin-lsp")
PLATFORMS = ("linux-x86_64", "macos-arm64")


def documentation_pdfs() -> list[str]:
    names = ["docodin-book.pdf", "docodin-dod.pdf"]
    names.extend(f"dod-{source.stem}.pdf" for source in
                 sorted((ROOT / "docs" / "dod").glob("[0-9][0-9][0-9][0-9]-*.rst"))
                 if not source.name.startswith("0000-"))
    return names


def check_documentation(directory: Path) -> None:
    for name in documentation_pdfs():
        with (directory / name).open("rb") as pdf:
            if pdf.read(5) != b"%PDF-":
                raise ValueError(f"Invalid documentation PDF: {name}")


def project_version(tag: str | None = None) -> str:
    version = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))["project"]["version"]
    if tag is not None and tag != f"v{version}":
        raise ValueError(f"Tag {tag!r} does not match project version v{version}")
    return version


def check_wheel(path: Path, version: str, platform: str) -> None:
    with zipfile.ZipFile(path) as wheel:
        names = wheel.namelist()
        metadata = [name for name in names if name.endswith(".dist-info/METADATA")]
        if len(metadata) != 1:
            raise ValueError(f"Invalid wheel metadata: {path}")
        fields = BytesParser().parsebytes(wheel.read(metadata[0]))
        if fields["Name"] != "docodin" or fields["Version"] != version:
            raise ValueError(f"Wheel identity mismatch: {path}")
        suffix = "_x86_64.whl" if platform == "linux-x86_64" else "_arm64.whl"
        family = "manylinux_" if platform == "linux-x86_64" else "macosx_"
        if f"-py3-none-{family}" not in path.name or not path.name.endswith(suffix):
            raise ValueError(f"Wrong wheel platform: {path}")
        for program in PROGRAMS:
            if not any(name.endswith(f".data/scripts/{program}") for name in names):
                raise ValueError(f"Wheel is missing {program}: {path}")


def check_source(path: Path, version: str) -> None:
    with tarfile.open(path) as source:
        metadata = source.extractfile(f"docodin-{version}/PKG-INFO")
        if metadata is None:
            raise ValueError("Source distribution is missing metadata")
        fields = BytesParser().parsebytes(metadata.read())
        if fields["Name"] != "docodin" or fields["Version"] != version:
            raise ValueError("Source distribution identity mismatch")


def native_archive(wheel_path: Path, output: Path, version: str, platform: str) -> None:
    prefix = f"docodin-{version}-{platform}"
    instructions = (
        f"docodin {version} ({platform})\n\n"
        "Run ./docodin --help, ./docodin-check --help or ./docodin-lsp --help.\n"
        "Supported native documents need no Python. PDF generation needs TeX.\n"
        "Python-dependent features need the docodin Python package; install the matching wheel.\n"
        "Authors: Vikrant Rathore; algorithm assistance: Ronak Rathore; logo design: Kanak Rathore.\n"
        "Source: https://github.com/insanai/docodin\n"
    )
    with zipfile.ZipFile(wheel_path) as wheel, tarfile.open(output / f"{prefix}.tar.gz", "w:gz") as archive:
        for name in wheel.namelist():
            basename = Path(name).name
            if ".data/scripts/" in name and basename in PROGRAMS:
                add_file(archive, f"{prefix}/{basename}", wheel.read(name), 0o755)
            elif ".dist-info/licenses/" in name:
                relative = name.split(".dist-info/licenses/", 1)[1]
                add_file(archive, f"{prefix}/{relative}", wheel.read(name))
        add_file(archive, f"{prefix}/README.txt", instructions.encode())


def add_file(archive: tarfile.TarFile, name: str, data: bytes, mode: int = 0o644) -> None:
    entry = tarfile.TarInfo(name)
    entry.size = len(data)
    entry.mode = mode
    entry.mtime = 0
    archive.addfile(entry, io.BytesIO(data))


def assemble(inputs: Path, output: Path, revision: str, tag: str | None) -> None:
    version = project_version(tag)
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("A full Git commit hash is required")
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError("Use an empty release output directory")
    for platform in PLATFORMS:
        wheels = list((inputs / platform).rglob("*.whl"))
        if len(wheels) != 1:
            raise ValueError(f"Expected one qualified wheel for {platform}")
        wheel = wheels[0]
        check_wheel(wheel, version, platform)
        shutil.copy2(wheel, output / wheel.name)
        native_archive(wheel, output, version, platform)
    sources = list((inputs / "linux-x86_64").rglob(f"docodin-{version}.tar.gz"))
    if len(sources) != 1:
        raise ValueError("Expected one qualified Linux source distribution")
    check_source(sources[0], version)
    shutil.copy2(sources[0], output / sources[0].name)
    pdfs = inputs / "linux-x86_64" / "docs" / "pdf"
    check_documentation(pdfs)
    for name in documentation_pdfs():
        pdf = pdfs / name
        shutil.copy2(pdf, output / pdf.name)
    manifest = {"version": version, "revision": revision, "files": {}}
    for path in sorted(output.iterdir()):
        manifest["files"][path.name] = {
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "size": path.stat().st_size,
        }
    (output / "RELEASE.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    checksums = [f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
                 for path in sorted(output.iterdir())]
    (output / "SHA256SUMS").write_text("".join(checksums), encoding="utf-8")


def verify(directory: Path, tag: str, revision: str | None = None) -> None:
    version = project_version(tag)
    manifest = json.loads((directory / "RELEASE.json").read_text(encoding="utf-8"))
    if manifest["version"] != version:
        raise ValueError("Release manifest version does not match its tag")
    if revision is not None and manifest["revision"] != revision:
        raise ValueError("Release artifacts do not match the tag's commit")
    entries = {}
    for line in (directory / "SHA256SUMS").read_text(encoding="utf-8").splitlines():
        digest, name = line.split("  ", 1)
        if Path(name).name != name or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("Invalid checksum entry")
        if hashlib.sha256((directory / name).read_bytes()).hexdigest() != digest:
            raise ValueError(f"Checksum mismatch: {name}")
        if name in entries:
            raise ValueError(f"Duplicate checksum entry: {name}")
        entries[name] = digest
    expected = set(manifest["files"]) | {"RELEASE.json"}
    if set(entries) != expected or {path.name for path in directory.iterdir()} != expected | {"SHA256SUMS"}:
        raise ValueError("Release files do not match the checksum manifest")
    for name, record in manifest["files"].items():
        if record["sha256"] != entries[name] or record["size"] != (directory / name).stat().st_size:
            raise ValueError(f"Manifest mismatch: {name}")
    check_source(directory / f"docodin-{version}.tar.gz", version)
    check_documentation(directory)
    for platform in PLATFORMS:
        wheels = [path for path in directory.glob("*.whl") if
                  path.name.endswith("_x86_64.whl" if platform == "linux-x86_64" else "_arm64.whl")]
        if len(wheels) != 1:
            raise ValueError(f"Missing wheel for {platform}")
        check_wheel(wheels[0], version, platform)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    parser.add_argument("--revision")
    parser.add_argument("--tag")
    parser.add_argument("--verify", type=Path)
    parser.add_argument("--print-version", action="store_true")
    args = parser.parse_args()
    if args.print_version:
        print(project_version(args.tag))
    elif args.verify:
        if not args.tag:
            parser.error("--verify requires --tag")
        verify(args.verify, args.tag, args.revision)
    elif args.inputs and args.revision:
        assemble(args.inputs, args.output, args.revision, args.tag)
    else:
        parser.error("supply --inputs and --revision, --verify and --tag, or --print-version")


if __name__ == "__main__":
    main()
