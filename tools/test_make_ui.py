"""Offline regression tests for the instrumented Make terminal interface."""

from __future__ import annotations

from contextlib import redirect_stdout
from dataclasses import replace
from datetime import datetime, timezone
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock

import make_ui


class DiagnosticsParsingTests(unittest.TestCase):
    """Report parsers must show failures and avoid misleading counters."""

    def test_ert_inventory_counts(self):
        log = ("24 test modules loaded\n"
               " RESULT  181/183 expected  |  1 unexpected  |  1 skipped\n")
        metrics = make_ui.extract_metrics(log)
        self.assertEqual(metrics["ert"], {"expected": 181, "total": 183,
                                          "unexpected": 1, "skipped": 1})
        self.assertEqual(metrics["ert_modules"], 24)
        self.assertIn("1 unexpected", make_ui.format_metrics(metrics))

    def test_isolated_ert_summary_tracks_hangs(self):
        """Timed-out tests must be recorded as failures, never skipped."""
        output = "RESULT  21/23 expected | 1 unexpected | 1 timed out | 0 skipped"
        metrics = make_ui.extract_metrics(output)
        self.assertEqual(metrics["ert"]["timed_out"], 1)
        self.assertIn("1 timed out", make_ui.format_metrics(metrics))

    def test_ert_standard_batch_output_counts(self):
        metrics = make_ui.extract_metrics("Ran 21 tests, 20 results as expected, 1 unexpected")
        self.assertEqual(metrics["ert"], {"total": 21, "expected": 20,
                                          "unexpected": 1})

    def test_doctor_counts(self):
        metrics = make_ui.extract_metrics(
            "Files: 120 (all project-owned *.el, recursively)\n"
            "Files: 111 passed / 9 failed | Checkdoc: 14 | package-lint: 3")
        self.assertEqual(metrics["doctor_files_discovered"], 120)
        self.assertEqual(metrics["doctor"]["failed_files"], 9)
        self.assertEqual(metrics["doctor"]["package_lint_issues"], 3)

    def test_offline_unittest_counts(self):
        result = make_ui.extract_metrics("Ran 12 tests in 0.123s\nOK")
        self.assertEqual(result["unittest"], {"tests": 12, "seconds": 0.123})

    def test_actionable_compilation_error_is_preserved(self):
        example = ("In toplevel form:\n"
                   "luau-semantic-highlight.el:134:38: Error: obsolete var\n"
                   "make: *** [Makefile:126: compile-strict] Error 1\n")
        excerpt = make_ui.failure_excerpt(example)
        self.assertTrue(any("luau-semantic-highlight.el:134:38" in x
                            for x in excerpt))
        self.assertTrue(any("make: ***" in x for x in excerpt))


    def test_status_colors_and_visible_width_remain_consistent(self):
        """Color escapes must never steal space from aligned CLI columns."""
        opts = make_ui.Options(Path.cwd(), ("make",), 5.0, False, True, False, 0)
        self.assertEqual(make_ui.status_marker("PASS", opts), "\033[32m✓\033[0m")
        self.assertEqual(make_ui.status_marker("FAIL", opts), "\033[31m✗\033[0m")
        self.assertEqual(make_ui.status_marker("RUN", opts), "\033[36m›\033[0m")
        self.assertEqual(make_ui.status_label("PASS", opts), "\033[32mPASS   \033[0m")
        self.assertEqual(make_ui.status_label("RUN", opts), "\033[36mRUN    \033[0m")
        self.assertEqual(make_ui.status_marker("TIMEOUT", opts), "\033[33m!\033[0m")

    def test_error_without_emacs_is_actionable(self):
        lines = make_ui.failure_excerpt(
            "/bin/sh: 1: emacs: not found\nmake[1]: *** [Makefile:45: __raw-test] Error 127")
        self.assertTrue(any("emacs: not found" in line for line in lines))

    def test_no_false_location_with_unsafe_name(self):
        self.assertEqual(make_ui.safe_name("../X / Y"), "X-Y")
        self.assertFalse(make_ui.paint("ok", "green", False).startswith("\x1b"))


class RunnerTests(unittest.TestCase):
    """Verify real subprocess behavior, logging and fail-closed semantics."""

    def setUp(self):
        # Isolate report discovery from a developer's configured archive path.
        environment = mock.patch.dict(os.environ, {"LUAU_REPORT_DIR": ".build/reports"})
        environment.start()
        self.addCleanup(environment.stop)
        self.temp = tempfile.TemporaryDirectory(prefix="luau-make-ui-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        script = self.root / "fake-make"
        script.write_text(
            "#!/usr/bin/env python3\n"
            "import sys, time\n"
            "target = sys.argv[-1]\n"
            "if target == '__raw-compile-strict':\n"
            "    print('luau-demo.el:17:8: Error: synthetic warning', flush=True)\n"
            "    sys.exit(2)\n"
            "if target == '__raw-benchmark-navigation':\n"
            "    time.sleep(0.85)\n"
            "print('Ran 3 tests in 0.001s', flush=True)\n"
            "print('OK', flush=True)\n"
        )
        script.chmod(script.stat().st_mode | stat.S_IXUSR)
        self.options = make_ui.Options(self.root, (str(script),),
                                       5.0, False, False, True, 0)

    def run_and_capture(self, targets, options=None):
        stream = io.StringIO()
        with redirect_stdout(stream):
            outcome = make_ui.run_suite("unit-suite", targets, options or self.options)
        reports = sorted(self.root.glob(".build/reports/*/report.json"))
        self.assertTrue(reports)
        content = json.loads(reports[-1].read_text())
        return outcome, content, stream.getvalue(), reports[-1]

    def test_multi_target_suite_continues_after_failure(self):
        outcome, report, screen, file = self.run_and_capture(
            ["test-tools", "compile-strict", "test"])
        self.assertEqual(outcome, 1)
        self.assertEqual(report["totals"], {"PASS": 2, "FAIL": 1,
                                            "TIMEOUT": 0, "NOT_RUN": 0})
        self.assertEqual([step["status"] for step in report["steps"]],
                         ["PASS", "FAIL", "PASS"])
        self.assertTrue((file.parent / "logs/03-test.log").is_file())
        self.assertTrue((file.parent / "report.txt").is_file())
        self.assertIn("luau-demo.el:17:8", screen)
        self.assertIn("2 passed, 1 failed", screen)
        self.assertEqual(report["steps"][0]["metrics"]["unittest"]["tests"], 3)

    def test_clean_exit_is_success(self):
        outcome, report, _, file = self.run_and_capture(["test-tools"])
        self.assertEqual(outcome, 0)
        self.assertEqual(report["status"], "PASS")
        self.assertIn("TARGET: test-tools", (file.parent / "logs/01-test-tools.log").read_text())

    def test_same_second_runs_get_distinct_reports(self):
        """Repeated suites in one second cannot collide on their report path."""
        with mock.patch.object(make_ui, "datetime") as clock:
            clock.now.return_value = datetime(2026, 11, 10, tzinfo=timezone.utc)
            self.run_and_capture(["test-tools"])
            self.run_and_capture(["test-tools"])
        reports = list(self.root.glob(".build/reports/*/report.json"))
        self.assertEqual(len(reports), 2)
        self.assertNotEqual(reports[0].parent, reports[1].parent)

    def test_failure_inbox_lists_file_locations_and_logs(self):
        """Saved errors remain inspectable even after later PASS runs."""
        self.run_and_capture(["compile-strict", "test-tools"])
        self.run_and_capture(["test-tools"])
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(make_ui.show_failures(self.root), 0)
        screen = output.getvalue()
        self.assertIn("compile-strict", screen)
        self.assertIn("luau-demo.el:17:8", screen)
        self.assertIn("make triage", screen)
        self.assertIn("logs/01-compile-strict.log", screen)

    def test_triage_reruns_only_failed_leaf_targets(self):
        """Triage must not repeat already-passing jobs or accept invented names."""
        self.run_and_capture(["test-tools", "compile-strict", "test"])
        output = io.StringIO()
        with redirect_stdout(output):
            exit_code = make_ui.rerun_failures(self.root, self.options)
        self.assertEqual(exit_code, 1)
        recent = json.loads(make_ui.report_files(self.root)[0].read_text())
        self.assertEqual(recent["name"], "triage")
        self.assertEqual(recent["targets"], ["compile-strict"])
        self.assertEqual(recent["steps"][0]["status"], "FAIL")

    def test_triage_rejects_unknown_or_untrusted_targets(self):
        """The JSON failure inbox cannot become an arbitrary command launcher."""
        report = {"steps": [
            {"target": "../../escape", "status": "FAIL"},
            {"target": "test-lsp", "status": "FAIL"},
            {"target": "test-lsp", "status": "FAIL"},
            {"target": "doctor", "status": "PASS"},
        ]}
        self.assertEqual(make_ui.failed_targets(report), ["test-lsp"])

    def test_missing_failure_inbox_is_not_a_failure(self):
        """A fresh checkout can inspect status before running the suite."""
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(make_ui.show_failures(self.root), 0)
            self.assertEqual(make_ui.rerun_failures(self.root, self.options), 0)
        self.assertIn("No unresolved failures", output.getvalue())

    def test_timeout_is_distinct_failure(self):
        opts = replace(self.options, timeout=0.3)
        outcome, report, _, _ = self.run_and_capture(["benchmark-navigation"], opts)
        self.assertEqual(outcome, 1)
        self.assertEqual(report["totals"]["TIMEOUT"], 1)
        self.assertEqual(report["steps"][0]["exit_code"], 124)

    def test_environment_controls(self):
        with mock.patch.dict(os.environ, {"NO_COLOR": "1", "LUAU_COLOR": "always",
                                              "LUAU_TIMEOUT": "0", "LUAU_VERBOSE": "1",
                                              "LUAU_HEARTBEAT": "0"}):
            opts = make_ui.options_from_environment(self.root, "make")
        self.assertFalse(opts.color)
        self.assertEqual(opts.timeout, 0)
        self.assertTrue(opts.verbose)

    def test_invalid_target_not_executed(self):
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            result = make_ui.run_suite("bad", ["../../../etc/passwd"], self.options)
        self.assertEqual(result, 2)
        self.assertEqual(list(self.root.glob(".build/reports/**/*")), [])

    def test_bundle_latest_has_full_logs_and_structured_report(self):
        self.run_and_capture(["test-tools"])
        with redirect_stdout(io.StringIO()):
            result = make_ui.bundle_latest(self.root)
        self.assertEqual(result, 0)
        archives = list((self.root / ".build").glob("luau-make-report-*.tar.gz"))
        self.assertEqual(len(archives), 1)
        import tarfile
        with tarfile.open(archives[0], "r:gz") as archive:
            self.assertIn("luau-make-report/report.json", archive.getnames())
            self.assertIn("luau-make-report/logs/01-test-tools.log", archive.getnames())

    def test_trend_handles_single_record(self):
        self.run_and_capture(["test-tools"])
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(make_ui.show_trend(self.root), 0)
        self.assertIn("n/a", output.getvalue())


    def test_failure_inbox_clears_after_newer_success(self):
        """A later passing leaf must supersede older failures in triage."""
        self.run_and_capture(["compile-strict"])
        self.assertEqual([s["target"] for _, s in make_ui.unresolved_failures(self.root)],
                         ["compile-strict"])
        self.run_and_capture(["test"])
        self.assertEqual([s["target"] for _, s in make_ui.unresolved_failures(self.root)],
                         ["compile-strict"])
        # Inject a later passing result with the same target, no command invoked.
        report = make_ui.run_suite  # preserve real history format
        _ = report
        success = {"name": "fixed", "status": "PASS", "steps": [
            {"target": "compile-strict", "status": "PASS", "duration_seconds": 0.4}]}
        directory = self.root / ".build/reports/zz-fixed"
        directory.mkdir(parents=True)
        (directory / "report.json").write_text(json.dumps(success))
        import time
        os.utime(directory / "report.json", None)
        self.assertFalse(make_ui.unresolved_failures(self.root))

    def test_unresolved_failure_inbox_ignores_corrupt_reports(self):
        """Corrupt report metadata cannot break inspection or trigger execution."""
        root = self.root / ".build/reports/corrupt"
        root.mkdir(parents=True)
        (root / "report.json").write_text("{not json")
        self.assertEqual(make_ui.unresolved_failures(self.root), [])

    def test_lsp_targets_are_registered(self):
        """The new regression suite and observational benchmark must be runnable."""
        self.assertIn("test-lsp", make_ui.TASKS)
        self.assertIn("benchmark-navigation", make_ui.BENCHMARKS)

    def test_report_exports_junit_xml_with_real_failure_status(self):
        """JUnit output retains error status and does not multiply ERT counts."""
        self.run_and_capture(["test", "compile-strict"])
        import xml.etree.ElementTree as ET
        latest = make_ui.report_files(self.root)[0].parent
        suite = ET.parse(latest / "junit.xml").getroot()
        self.assertEqual(suite.attrib["tests"], "2")
        self.assertEqual(suite.attrib["failures"], "1")
        cases = suite.findall("testcase")
        self.assertEqual(len(cases), 2)
        self.assertEqual(cases[1].attrib["name"], "compile-strict")
        self.assertIsNotNone(cases[1].find("failure"))

    def test_dashboard_marks_unknown_target_as_not_run(self):
        """A partial green test suite cannot imply full quality-gate success."""
        self.run_and_capture(["test"])
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(make_ui.show_dashboard(self.root), 0)
            self.assertEqual(make_ui.show_history(self.root), 0)
        self.assertIn("NOT RUN", out.getvalue())
        self.assertIn("RECENT RUN HISTORY", out.getvalue())

    def test_status_finds_last_report(self):
        self.run_and_capture(["test-tools"])
        stream = io.StringIO()
        with redirect_stdout(stream):
            result = make_ui.show_status(self.root)
        self.assertEqual(result, 0)
        self.assertIn("LAST RUN", stream.getvalue())


if __name__ == "__main__":
    unittest.main()
