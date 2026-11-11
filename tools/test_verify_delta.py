"""Offline tests for the cycle archive verifier (stdlib unittest)."""

from __future__ import annotations

import hashlib
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

from verify_delta import DeltaError, verify_archive


class DeltaVerifierTests(unittest.TestCase):
    """Check valid hashes, baseline classification and unsafe members."""

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.baseline = self.root / "baseline"
        self.baseline.mkdir()
        (self.baseline / "old.el").write_bytes(b"before")

    def make_archive(self, *, corrupt=False, traversal=False, duplicate=False,
                     symlink=False):
        """Create a small synthetic delta with optional contract violations."""
        archive = self.root / "cycle.tar.gz"
        added = b";;; new.el --- new\n"
        modified = b";;; old.el --- changed\n"
        contents = {
            "luau-mode/new.el": added,
            "luau-mode/old.el": modified,
        }
        manifest = "\n".join(
            f"{'MODIFIED' if name.endswith('old.el') else 'ADDED'}  "
            f"{hashlib.sha256(body).hexdigest()}  {name}"
            for name, body in contents.items()
        ) + "\n"
        if corrupt:
            contents["luau-mode/new.el"] = b"tampered"
        contents["luau-mode/docs/CYCLE-05-DELTA-MANIFEST.txt"] = manifest.encode()
        if traversal:
            contents["luau-mode/../escape.el"] = b"not allowed"
        with tarfile.open(archive, "w:gz") as bundle:
            for name, body in contents.items():
                def add_member() -> None:
                    member = tarfile.TarInfo(name)
                    member.size = len(body)
                    bundle.addfile(member, io.BytesIO(body))
                add_member()
                if duplicate and name.endswith("new.el"):
                    add_member()
            if symlink:
                link = tarfile.TarInfo("luau-mode/link.el")
                link.type = tarfile.SYMTYPE
                link.linkname = "../../outside"
                bundle.addfile(link)
        return archive

    def test_accepts_real_delta_and_baseline(self):
        """A manifest describing changed/new files passes every check."""
        self.assertEqual(
            {"added": 1, "modified": 1, "files": 3},
            verify_archive(self.make_archive(), self.baseline),
        )

    def test_rejects_changed_file_hash(self):
        """The verifier never silently trusts a manifest digest."""
        with self.assertRaisesRegex(DeltaError, "SHA-256 mismatch"):
            verify_archive(self.make_archive(corrupt=True))

    def test_rejects_path_traversal(self):
        """A path containing a parent reference is rejected before extraction."""
        with self.assertRaisesRegex(DeltaError, "Unsafe archive path"):
            verify_archive(self.make_archive(traversal=True))

    def test_rejects_duplicate_members(self):
        """Repeated tar headers may not mask earlier content."""
        with self.assertRaisesRegex(DeltaError, "Duplicate member"):
            verify_archive(self.make_archive(duplicate=True))

    def test_rejects_existing_added_file(self):
        """An ADDED file may not already exist in the prior cycle tree."""
        (self.baseline / "new.el").write_bytes(b";;; new.el --- new\n")
        with self.assertRaisesRegex(DeltaError, "already present"):
            verify_archive(self.make_archive(), self.baseline)

    def test_rejects_unchanged_modified_file(self):
        """A MODIFIED file must differ from the previous version."""
        (self.baseline / "old.el").write_bytes(b";;; old.el --- changed\n")
        with self.assertRaisesRegex(DeltaError, "Unchanged file"):
            verify_archive(self.make_archive(), self.baseline)

    def test_rejects_symlinks(self):
        """A TAR.GZ must contain only regular files and directories."""
        with self.assertRaisesRegex(DeltaError, "Unsupported member type"):
            verify_archive(self.make_archive(symlink=True))


if __name__ == "__main__":
    unittest.main()
