#!/usr/bin/env python3
"""Build a deterministic, locally installable multi-file Emacs package.

This is an install-smoke fixture, not a claim that MELPA has built the package.
Only the explicit distribution allowlist is shipped.  No network is used.
"""

from __future__ import annotations

import argparse
import io
from pathlib import Path
import re
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "luau-mode"
MODULES = ("luau-mode.el", "luau-lsp.el", "luau-roblox.el", "luau-make.el", "luau-interface.el")
DATA = ("README.md", "COPYING")
HEADER_VERSION = re.compile(r"^;; Version: (\d+(?:\.\d+)+)$", re.M)
HEADER_REQUIRES = re.compile(r'^;; Package-Requires: (\(\(emacs "\d+(?:\.\d+)+"\)\))$', re.M)


class ReleaseError(ValueError):
    """Source metadata cannot produce an installable package."""


def metadata(root: Path) -> tuple[str, str]:
    """Extract and validate package version and dependency metadata."""
    source = (root / "luau-mode.el").read_text(encoding="utf-8")
    version = HEADER_VERSION.search(source)
    requires = HEADER_REQUIRES.search(source)
    if not version or not requires:
        raise ReleaseError("Missing or invalid Version/Package-Requires header")
    for item in (*MODULES, *DATA):
        path = root / item
        if not path.is_file() or path.is_symlink():
            raise ReleaseError(f"Required distribution file missing or unsafe: {item}")
    return version.group(1), requires.group(1)


def archive_path(root: Path) -> Path:
    """Return the canonical local-install archive location."""
    version, _ = metadata(root)
    return root / ".build" / "release" / f"{PACKAGE}-{version}.tar"


def _member(bundle: tarfile.TarFile, name: str, content: bytes) -> None:
    """Append CONTENT with normalized metadata to BUNDLE."""
    info = tarfile.TarInfo(name)
    info.size = len(content)
    info.mtime = 0
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    info.mode = 0o644
    bundle.addfile(info, io.BytesIO(content))


def build(root: Path, output: Path | None = None) -> Path:
    """Write a deterministic Emacs package tar without test/build artifacts."""
    version, requires = metadata(root)
    output = output or archive_path(root)
    output.parent.mkdir(parents=True, exist_ok=True)
    prefix = f"{PACKAGE}-{version}"
    manifest = (
        f';;; {PACKAGE}-pkg.el --- Package descriptor -*- lexical-binding: t; no-byte-compile: t; -*-\n'
        f'(define-package "{PACKAGE}" "{version}" '
        f'"Standalone major mode for Luau and Rojo" \'{requires})\n'
    ).encode("utf-8")
    with tarfile.open(output, mode="w", format=tarfile.USTAR_FORMAT) as bundle:
        directory = tarfile.TarInfo(prefix + "/")
        directory.type = tarfile.DIRTYPE
        directory.mtime = 0
        directory.uid = directory.gid = 0
        directory.mode = 0o755
        bundle.addfile(directory)
        for item in sorted((*MODULES, *DATA)):
            _member(bundle, f"{prefix}/{item}", (root / item).read_bytes())
        _member(bundle, f"{prefix}/{PACKAGE}-pkg.el", manifest)
    return output


def main() -> int:
    """Build the archive and print its path for the Make smoke check."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--print-path", action="store_true")
    args = parser.parse_args()
    try:
        output = build(args.root, args.output)
    except (OSError, ReleaseError) as error:
        print(f"RELEASE FAIL  {error}", file=sys.stderr)
        return 1
    if args.print_path:
        print(output.resolve())
    else:
        print(f"RELEASE PASS  {output.resolve()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
