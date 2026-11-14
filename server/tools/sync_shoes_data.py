"""Copy/verify Shoes recordings and replay fixtures without deleting data."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path

from sync_shoes_source import SOURCE_ROOT, SYSTEM_ROOT, TARGET_ROOT


ARCHIVE_ROOT = SYSTEM_ROOT / "data" / "shoes_archive"
REFERENCE_DATA = SYSTEM_ROOT / "integrations" / "shoes_reference" / "data"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sync(check: bool = False, source: Path = SOURCE_ROOT) -> dict[str, str]:
    if not source.is_dir():
        raise FileNotFoundError(source)
    manifest: dict[str, str] = {}
    for folder in ("data", "diagnostics", "log"):
        for path in sorted((source / folder).rglob("*")):
            if not path.is_file():
                continue
            relative = path.relative_to(source)
            digest = sha256(path)
            manifest[relative.as_posix()] = digest
            destinations = [ARCHIVE_ROOT / relative]
            if folder == "data":
                destinations.append(REFERENCE_DATA / path.relative_to(source / "data"))
            for destination in destinations:
                if check:
                    if not destination.is_file() or sha256(destination) != digest:
                        raise AssertionError(f"Shoes data drift: {relative}")
                else:
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(path, destination)
    manifest_path = ARCHIVE_ROOT / "ARCHIVE_MANIFEST.json"
    if check:
        if not manifest_path.is_file() or json.loads(manifest_path.read_text("utf-8")) != manifest:
            raise AssertionError("Shoes data manifest is stale")
        for path in source.rglob("*"):
            if not path.is_file() or ".git" in path.relative_to(source).parts:
                continue
            relative = path.relative_to(source)
            if not any(
                target.is_file() and sha256(target) == sha256(path)
                for target in (TARGET_ROOT / relative, ARCHIVE_ROOT / relative)
            ):
                raise AssertionError(f"Shoes file is not mirrored: {relative}")
    else:
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--source", type=Path, default=SOURCE_ROOT)
    options = parser.parse_args()
    files = sync(check=options.check, source=options.source)
    print(f"Verified {len(files)} Shoes data files" if options.check else f"Copied {len(files)} Shoes data files")
