#!/usr/bin/env python3
"""Verify one strict incremental Luau Mode TAR.GZ archive.

This tool validates archive safety, the manifest's content hashes, and
(optional) ADDED/MODIFIED classifications against a previous-cycle tree.
It does not run Emacs, ERT, Checkdoc or package-lint.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path, PurePosixPath
import re
import sys
import tarfile

ROOT = "luau-mode"
MANIFEST = re.compile(r"^luau-mode/docs/CYCLE-\d+-DELTA-MANIFEST\.txt$")
ENTRY = re.compile(r"^(ADDED|MODIFIED)\s+([0-9a-f]{64})\s+(luau-mode/.+)$")
FORBIDDEN = {".git", ".packages", "__pycache__"}


class DeltaError(ValueError):
    """A supplied archive violates the strict Luau delta contract."""


def _validate_path(name: str) -> None:
    """Reject traversal and non-Luau paths before extracting anything."""
    path = PurePosixPath(name)
    if (path.is_absolute() or not path.parts or path.parts[0] != ROOT
            or ".." in path.parts or any(x in FORBIDDEN for x in path.parts)
            or "\\" in name):
        raise DeltaError(f"Unsafe archive path: {name!r}")
    if path.suffix in {".elc", ".pyc"}:
        raise DeltaError(f"Compiled/cache file in source delta: {name}")


def verify_archive(archive: Path, baseline: Path | None = None) -> dict[str, int]:
    """Validate ARCHIVE against its manifest and optional BASELINE tree.

    Return a dictionary of added, modified and total file counts.  Raise
    `DeltaError' for any mismatch, unsafe path or missing required entry.
    """
    with tarfile.open(archive, "r:gz") as bundle:
        paths: set[str] = set()
        files: dict[str, bytes] = {}
        for member in bundle.getmembers():
            _validate_path(member.name)
            name = member.name.rstrip("/")
            if name in paths:
                raise DeltaError(f"Duplicate member: {name}")
            paths.add(name)
            if member.isdir():
                continue
            if not member.isfile():
                raise DeltaError(f"Unsupported member type: {name}")
            stream = bundle.extractfile(member)
            if stream is None:
                raise DeltaError(f"Cannot read member: {name}")
            files[name] = stream.read()

    manifests = [name for name in files if MANIFEST.fullmatch(name)]
    if len(manifests) != 1:
        raise DeltaError(f"Expected one cycle manifest, found {len(manifests)}")
    manifest_name = manifests[0]
    descriptions: dict[str, tuple[str, str]] = {}
    for line in files[manifest_name].decode("utf-8").splitlines():
        if match := ENTRY.fullmatch(line):
            status, digest, name = match.groups()
            if name in descriptions:
                raise DeltaError(f"Duplicate manifest entry: {name}")
            descriptions[name] = status, digest

    if not descriptions:
        raise DeltaError("Manifest contains no file hashes")
    if set(files) - {manifest_name} != set(descriptions):
        raise DeltaError("Archive files differ from the manifest inventory")

    counts = {"added": 0, "modified": 0, "files": len(files)}
    for name, (status, digest) in descriptions.items():
        body = files[name]
        if hashlib.sha256(body).hexdigest() != digest:
            raise DeltaError(f"SHA-256 mismatch: {name}")
        if baseline is not None:
            prior = baseline.joinpath(*PurePosixPath(name).parts[1:])
            present = prior.is_file()
            if status == "ADDED" and present:
                raise DeltaError(f"Claimed ADDED but already present: {name}")
            if status == "MODIFIED" and not present:
                raise DeltaError(f"Claimed MODIFIED but missing: {name}")
            if present and prior.read_bytes() == body:
                raise DeltaError(f"Unchanged file included: {name}")
        counts[status.lower()] += 1
    return counts


def main() -> int:
    """Parse command-line options and print a concise verification report."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="Cycle TAR.GZ to verify")
    parser.add_argument("--baseline", type=Path,
                        help="Cumulative luau-mode/ directory before this cycle")
    args = parser.parse_args()
    try:
        counts = verify_archive(args.archive, args.baseline)
    except (DeltaError, OSError, tarfile.TarError, UnicodeError) as error:
        print(f"DELTA FAIL  {error}", file=sys.stderr)
        return 1
    print("DELTA PASS  " + str(args.archive))
    print(f"  Added: {counts['added']}  Modified: {counts['modified']}  "
          f"Total: {counts['files']} (including manifest)")
    if args.baseline:
        print("  Baseline changed-file verification: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
