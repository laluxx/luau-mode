"""Regression tests for the isolated ERT supervisor, including timeouts."""

from __future__ import annotations

from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock

import ert_runner


class IsolatedErtRunnerTests(unittest.TestCase):
    """Ensure discovery, failures and hangs cannot produce false PASS reports."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="luau-ert-supervisor-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        fake = self.root / "emacs-mock"
        fake.write_text(
            "#!/usr/bin/env python3\n"
            "import os, sys, time\n"
            "if os.getenv('LUAU_ERT_LIST'):\n"
            "  print('LUAU_ERT_TEST:luau-test-good')\n"
            "  print('LUAU_ERT_TEST:luau-test-bad')\n"
            "  sys.exit(int(os.getenv('FAKE_LIST_EXIT','0')))\n"
            "test=os.getenv('LUAU_ERT_SINGLE')\n"
            "if test=='luau-test-bad':\n"
            "  if os.getenv('FAKE_BAD')=='sleep': time.sleep(4)\n"
            "  if os.getenv('FAKE_BAD')=='fail': print('FAILED: case',flush=True);sys.exit(1)\n"
            "print('Ran 1 tests, 1 results as expected, 0 unexpected')\n"
        )
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        self.patch_root = mock.patch.object(ert_runner, "ROOT", self.root)
        self.patch_root.start()
        self.addCleanup(self.patch_root.stop)
        self.patch_env = mock.patch.dict(os.environ, {
            "EMACS": str(fake), "LUAU_ERT_TIMEOUT": "1.7", "FAKE_BAD": "ok",
        })
        self.patch_env.start()
        self.addCleanup(self.patch_env.stop)

    def invoke(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            result = ert_runner.main()
        return result, buf.getvalue()

    def test_all_green(self):
        result, log = self.invoke()
        self.assertEqual(result, 0)
        self.assertIn('RESULT  2/2 expected | 0 unexpected | 0 timed out', log)

    def test_one_test_fails_without_skipping_others(self):
        with mock.patch.dict(os.environ, {"FAKE_BAD": "fail"}):
            result, log = self.invoke()
        self.assertEqual(result, 1)
        self.assertIn('FAIL    luau-test-bad', log)
        self.assertIn('RESULT  1/2 expected | 1 unexpected', log)

    def test_hang_is_terminated_and_named(self):
        with mock.patch.dict(os.environ, {"FAKE_BAD": "sleep"}):
            result, log = self.invoke()
        self.assertEqual(result, 1)
        self.assertIn('TIMEOUT luau-test-bad', log)
        self.assertIn('1 timed out', log)

    def test_discovery_failure_is_not_green(self):
        with mock.patch.dict(os.environ, {"FAKE_LIST_EXIT": "1"}):
            result, log = self.invoke()
        self.assertEqual(result, 2)
        self.assertIn('discovery returned a nonzero status', log)


if __name__ == '__main__':
    unittest.main()
