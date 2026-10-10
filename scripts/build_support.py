"""Verified downloads shared by the build tool installers."""

from __future__ import annotations

import hashlib
import json
import urllib.request
from pathlib import Path

MANIFEST = Path(__file__).with_name("toolchains.json")


def toolchains() -> dict:
    return json.loads(MANIFEST.read_text(encoding="utf-8"))


def download_verified(asset: dict[str, str], target: Path) -> None:
    request = urllib.request.Request(asset["url"], headers={"User-Agent": "docodin-build"})
    digest = hashlib.sha256()
    with urllib.request.urlopen(request, timeout=120) as response, target.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            digest.update(chunk)
            output.write(chunk)
    if digest.hexdigest() != asset["sha256"]:
        target.unlink()
        raise RuntimeError(f"Checksum mismatch for {asset['url']}")
