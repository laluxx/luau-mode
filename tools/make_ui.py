#!/usr/bin/env python3
"""Human-readable, testable, machine-readable Make instrumentation for Luau.

Public Make recipes call this stdlib-only command.  The underlying recipes are
private __raw-* targets; one report owns every step in a multi-target suite.
Output is ANSI-colored in terminals or when LUAU_COLOR=always is configured.
M-x luau-make-check integrates ANSI decoding in Emacs compilation buffers.

The runner returns nonzero on any failing or timed-out step.  No test failures
are converted to successful output, and no network access is performed here.
"""

from __future__ import annotations

import argparse
import hashlib
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
import statistics
import tarfile
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import threading
import time
from typing import Any
import xml.etree.ElementTree as ET

try:
    import resource  # Unix and macOS, optional on other systems.
except ImportError:  # pragma: no cover - unavailable on Windows.
    resource = None


TASKS = (
    "dependencies", "test-install", "test", "test-core", "test-lsp", "test-font-lock", "test-interface", "test-tools", "test-static", "package-audit",
    "verify-delta", "compile", "compile-strict", "doctor", "checkdoc",
    "package-lint", "lint", "bootstrap", "clean", "clean-bytecode",
    "benchmark-font-lock", "benchmark-navigation",
)
BENCHMARKS = tuple(t for t in TASKS if t.startswith("benchmark-"))
REPORT_DIR = Path(".build/reports")
ELISP_PATTERN = re.compile(r"(?:^|\n)\s*RESULT\s+(\d+)/(\d+) expected\s*\|\s*(\d+) unexpected\s*\|\s*(\d+) skipped")
ERT_ISOLATED_PATTERN = re.compile(r"RESULT\s+(\d+)/(\d+) expected\s*\|\s*(\d+) unexpected\s*\|\s*(\d+) timed out\s*\|\s*(\d+) skipped")
ERT_PATTERN = re.compile(r"Ran\s+(\d+)\s+tests?,\s+(\d+)\s+results? as expected,\s+(\d+)\s+unexpected", re.I)
DOCTOR_PATTERN = re.compile(r"Files:\s*(\d+) passed\s*/\s*(\d+) failed\s*\|\s*Checkdoc:\s*(\d+)\s*\|\s*package-lint:\s*(\d+)")
UNITTEST_PATTERN = re.compile(r"Ran (\d+) tests? in ([\d.]+)s", re.I)
LOCATION_PATTERN = re.compile(r"(?:^|\s)([\w./+~-]+\.el):(\d+)(?::(\d+))?:")
BACKTRACE_PATTERN = re.compile(
    r"(?:Error:|error:|FAILED|\*\*\*|Traceback|make(?:\[\d+\])?: \*\*\*|"
    r"not found|No such file|Debugger entered|void-function|void-variable|"
    r"Cannot execute|File error:|package-lint unavailable)", re.I)
ANSI = {"green": "\033[32m", "red": "\033[31m", "yellow": "\033[33m",
        "cyan": "\033[36m", "magenta": "\033[35m", "blue": "\033[34m",
        "dim": "\033[2m", "bold": "\033[1m", "end": "\033[0m"}


@dataclass(frozen=True)
class Options:
    root: Path
    make_cmd: tuple[str, ...]
    timeout: float
    verbose: bool
    color: bool
    ascii_only: bool
    heartbeat: float


def utc_now() -> str:
    """Return an ISO8601 UTC timestamp."""
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def safe_name(value: str) -> str:
    """Produce a portable filename component, with no traversal."""
    return re.sub(r"[^A-Za-z0-9_.-]+", "-", value).strip(".-") or "run"


def paint(value: str, style: str, enabled: bool) -> str:
    """Colorize VALUE only when explicitly enabled."""
    return f"{ANSI[style]}{value}{ANSI['end']}" if enabled else value


def glyph(kind: str, opts: Options) -> str:
    """Supply an ASCII fallback for limited compilation terminals."""
    ascii_glyphs = {"PASS": "+", "FAIL": "x", "TIMEOUT": "!", "RUN": ">"}
    unicode_glyphs = {"PASS": "✓", "FAIL": "✗", "TIMEOUT": "!", "RUN": "›"}
    return (ascii_glyphs if opts.ascii_only else unicode_glyphs).get(kind, "-")


def status_style(status: str) -> str:
    """Return consistent semantic roles for CLI status rendering."""
    return {"PASS": "green", "FAIL": "red", "TIMEOUT": "yellow",
            "RUN": "cyan"}.get(status, "dim")


def status_marker(status: str, opts: Options) -> str:
    """Color an aligned one-cell icon according to its semantic status."""
    return paint(glyph(status, opts), status_style(status), opts.color)


def status_label(status: str, opts: Options, width: int = 7) -> str:
    """Pad labels before inserting ANSI codes, preserving visual alignment."""
    return paint(f"{status:<{width}}", status_style(status), opts.color)


def divider(opts: Options, width: int = 78) -> str:
    """Return a visually consistent neutral separator."""
    return paint(("-" if opts.ascii_only else "─") * width, "dim", opts.color)


def synopsis(target: str) -> str:
    """Describe a target without duplicating its Make implementation."""
    descriptions = {
        "dependencies": "ensure isolated package-lint is installed (network on first run)",
        "test": "entire recursively discovered ERT suite",
        "test-install": "isolated package.el tar installation and autoload smoke test",
        "test-core": "editing, font-lock and Rojo regressions",
        "test-lsp": "optional lsp-mode / Eglot registration tests",
        "test-font-lock": "autoload, faces, custom syntax fontification regressions",
        "test-interface": "Imenu, Eldoc, matching keywords and live Roblox docs",
        "package-audit": "MELPA metadata, face inheritance and autoload source audit",
        "test-tools": "offline Python tooling tests",
        "test-static": "static source checks (not native Emacs checks)",
        "compile": "byte compile all package sources",
        "compile-strict": "byte compile with warnings as errors",
        "doctor": "recursive Checkdoc + package-lint, fail closed",
        "checkdoc": "recursive Checkdoc only",
        "package-lint": "recursive package-lint only",
        "lint": "alias for full recursive doctor",
        "bootstrap": "install package-lint into local .packages directory",
        "verify-delta": "verify strict incremental TAR.GZ manifest",
        "clean": "delete generated bytecode and dependency cache",
        "clean-bytecode": "remove generated Emacs bytecode",
        "benchmark-font-lock": "fontification benchmark, no performance claims",
        "benchmark-navigation": "navigation benchmark, no performance claims",
    }
    return descriptions.get(target, target)


def machine_info(root: Path) -> dict[str, Any]:
    """Record reproducibility details without capturing private environment."""
    info: dict[str, Any] = {
        "platform": sys.platform,
        "python": sys.version.split()[0],
        "cwd": str(root),
        "cpu_count": os.cpu_count(),
        "git_commit": None,
        "emacs": None,
        "source_files": 0,
        "test_files": 0,
        "benchmark_files": 0,
        "package_version": None,
        "development_cycle": None,
    }
    # Report the actual checked-out source, not a remembered cycle label.
    source = root / "luau-mode.el"
    if source.is_file():
        match = re.search(r"^;; Version: ([0-9]+(?:\.[0-9]+)+)\s*$",
                          source.read_text(encoding="utf-8"), re.M)
        if match:
            info["package_version"] = match.group(1)
    cycle_numbers = [int(match.group(1))
                     for path in (root / "docs").glob("CYCLE-*.org")
                     if (match := re.fullmatch(r"CYCLE-([0-9]+)\.org", path.name))]
    if cycle_numbers:
        info["development_cycle"] = max(cycle_numbers)
    for path in root.glob("**/*.el"):
        if set(path.relative_to(root).parts) & {".git", ".packages", ".build"}:
            continue
        if path.relative_to(root).parts[0] == "test":
            info["test_files"] += path.name.endswith("-test.el")
        elif path.relative_to(root).parts[0] == "bench":
            info["benchmark_files"] += 1
        else:
            info["source_files"] += 1
    for command, key in (([os.getenv("EMACS", "emacs"), "--version"], "emacs"),
                         (["git", "rev-parse", "--short", "HEAD"], "git_commit")):
        try:
            probe = subprocess.run(command, cwd=root, capture_output=True, text=True,
                                   check=False, timeout=3)
            if probe.returncode == 0:
                info[key] = probe.stdout.splitlines()[0].strip()
        except (FileNotFoundError, OSError, subprocess.TimeoutExpired, IndexError):
            pass
    return info


def extract_metrics(output: str) -> dict[str, Any]:
    """Extract stable counts, leaving version-specific output in raw logs."""
    metrics: dict[str, Any] = {}
    if match := ERT_ISOLATED_PATTERN.search(output):
        expected, total, unexpected, timed_out, skipped = map(int, match.groups())
        metrics["ert"] = {"expected": expected, "total": total,
                          "unexpected": unexpected, "timed_out": timed_out,
                          "skipped": skipped}
    elif match := ELISP_PATTERN.search(output):
        expected, total, unexpected, skipped = map(int, match.groups())
        metrics["ert"] = {"expected": expected, "total": total,
                          "unexpected": unexpected, "skipped": skipped}
    elif match := ERT_PATTERN.search(output):
        total, expected, unexpected = map(int, match.groups())
        metrics["ert"] = {"expected": expected, "total": total,
                          "unexpected": unexpected}
    if match := DOCTOR_PATTERN.search(output):
        passed, failed, checkdoc, package_lint = map(int, match.groups())
        metrics["doctor"] = {"passed_files": passed, "failed_files": failed,
                             "checkdoc_issues": checkdoc, "package_lint_issues": package_lint}
    if match := UNITTEST_PATTERN.search(output):
        metrics["unittest"] = {"tests": int(match.group(1)),
                               "seconds": float(match.group(2))}
    if match := re.search(r"(\d+) test modules loaded", output):
        metrics["ert_modules"] = int(match.group(1))
    if match := re.search(r"Files:\s+(\d+)\s+\(all project-owned", output):
        metrics["doctor_files_discovered"] = int(match.group(1))
    return metrics


def failure_excerpt(output: str, limit: int = 9) -> list[str]:
    """Select actionable error lines with context, without hiding full logs."""
    lines = output.splitlines()
    candidates: list[str] = []
    for index, line in enumerate(lines):
        clean = line.strip()
        if not clean:
            continue
        if LOCATION_PATTERN.search(line) or BACKTRACE_PATTERN.search(line):
            if not clean.startswith(("[DIAGNOSTIC RESULT]", "[TEST]")):
                candidates.append(clean[:260])
                if "FAILED" in clean and index + 1 < len(lines):
                    nxt = lines[index + 1].strip()
                    if nxt and len(candidates) < limit:
                        candidates.append(nxt[:260])
    # Include the tail if we couldn't find a recognizable error message.
    if not candidates:
        candidates = [line.strip()[:260] for line in lines[-limit:] if line.strip()]
    # Preserve the first useful error and final make failure, deduplicating noise.
    unique = list(dict.fromkeys(candidates))
    if len(unique) > limit:
        unique = unique[:limit - 2] + ["... (see full log) ..."] + unique[-1:]
    return unique


def format_metrics(metrics: dict[str, Any]) -> str:
    """Compact counters appended to status rows."""
    if "ert" in metrics:
        ert = metrics["ert"]
        return (f"ERT {ert['expected']}/{ert['total']}"
                + (f" / {ert['unexpected']} unexpected" if ert['unexpected'] else "")
                + (f" / {ert['timed_out']} timed out" if ert.get("timed_out") else "")
                + (f" / {ert['skipped']} skipped" if ert.get('skipped') else ""))
    if "doctor" in metrics:
        d = metrics["doctor"]
        return (f"{d['passed_files']}/{d['passed_files'] + d['failed_files']} files"
                f" / {d['checkdoc_issues']} checkdoc / {d['package_lint_issues']} lint")
    if "unittest" in metrics:
        return f"{metrics['unittest']['tests']} tests"
    return ""


def make_command(target: str, opts: Options) -> list[str]:
    """Build a safe private-target invocation without shell evaluation."""
    if target not in TASKS:
        raise ValueError(f"Unknown Make target: {target}")
    return [*opts.make_cmd, "--no-print-directory", "--silent", f"__raw-{target}"]


def terminate_process_tree(process: subprocess.Popen[bytes]) -> None:
    """Stop a timed-out process and its children, including runaway Emacs."""
    try:
        if sys.platform == "win32":
            process.terminate()
        else:
            os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            if sys.platform == "win32":
                process.kill()
            else:
                os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def child_cpu() -> tuple[float, float] | None:
    """Return accumulated waited-child CPU usage, when the OS supports it."""
    if resource is None:
        return None
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    return usage.ru_utime, usage.ru_stime


def log_diagnostics(output: str) -> dict[str, int]:
    """Count recognizable warnings and errors, without equating them to failures."""
    return {
        "warning_lines": len(re.findall(r"(?im)^.*\bwarning(?:[: (]|$).*$", output)),
        "error_lines": len(re.findall(r"(?im)^.*(?:\berror[: (]|\bfailed\b).*$", output)),
        "log_bytes": len(output.encode("utf-8", errors="replace")),
    }


def run_step(target: str, index: int, count: int, log_dir: Path,
             opts: Options) -> dict[str, Any]:
    """Run one target, timestamp and capture full combined output, even on fail."""
    if target not in TASKS:
        raise ValueError(f"Refusing unrecognized target: {target}")
    label = f"[{index:02d}/{count:02d}] {target:<28}"
    print(f"  {status_marker('RUN', opts)} {paint(label, 'bold', opts.color)} "
          f"{status_label('RUN', opts)} "
          f"{paint(synopsis(target), 'dim', opts.color)}", flush=True)
    command = make_command(target, opts)
    start = time.monotonic()
    began = utc_now()
    cpu_before = child_cpu()
    log_path = log_dir / f"{index:02d}-{target}.log"
    timeout = False
    timeout_budget = (min(opts.timeout, 20) if opts.timeout and target.startswith("benchmark-")
                      else opts.timeout)
    returncode = 127
    thread_error: list[str] = []
    with log_path.open("w", encoding="utf-8") as log:
        log.write(f"TARGET: {target}\nSTARTED_UTC: {began}\n"
                  f"COMMAND: {shlex.join(command)}\n{'=' * 72}\n")
        log.flush()
        try:
            process = subprocess.Popen(command, cwd=opts.root, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, start_new_session=True,
                                       bufsize=0)
            def collect() -> None:
                """Drain child stdout concurrently so it cannot deadlock."""
                try:
                    assert process.stdout is not None
                    for raw in iter(process.stdout.readline, b""):
                        decoded = raw.decode("utf-8", errors="replace")
                        log.write(decoded)
                        log.flush()
                        if opts.verbose:
                            # Indenting would hide Emacs compilation file:line markers.
                            print(decoded, end="", flush=True)
                except (OSError, UnicodeError) as exc:
                    thread_error.append(str(exc))
                finally:
                    if process.stdout:
                        process.stdout.close()
            reader = threading.Thread(target=collect, daemon=True)
            reader.start()
            last_heartbeat = start
            while process.poll() is None:
                elapsed = time.monotonic() - start
                if timeout_budget and elapsed >= timeout_budget:
                    timeout = True
                    terminate_process_tree(process)
                    break
                if opts.heartbeat and elapsed - (last_heartbeat - start) >= opts.heartbeat:
                    print(f"      {paint('◌' if not opts.ascii_only else '~', 'cyan', opts.color)} "
                          f"{paint('RUNNING', 'cyan', opts.color)}  {target} "
                          f"{elapsed:.0f}s  {paint('log:', 'dim', opts.color)} {log_path}",
                          flush=True)
                    last_heartbeat = time.monotonic()
                try:
                    process.wait(timeout=(1.0 if not timeout_budget else
                                          max(0.05, min(1.0, timeout_budget - elapsed))))
                except subprocess.TimeoutExpired:
                    continue
            returncode = process.wait()
            reader.join(timeout=5)
            if thread_error:
                log.write("\n[CAPTURE ERROR] " + "; ".join(thread_error) + "\n")
                if returncode == 0:
                    returncode = 125
        except OSError as exc:
            log.write(f"\n[START ERROR] {exc}\n")
        duration = round(time.monotonic() - start, 3)
        status = "TIMEOUT" if timeout else "PASS" if returncode == 0 else "FAIL"
        log.write(f"\nRESULT: {status} / exit={124 if timeout else returncode} / {duration}s\n")
    output = log_path.read_text(encoding="utf-8", errors="replace")
    metrics = extract_metrics(output)
    diagnostics = log_diagnostics(output)
    cpu_after = child_cpu()
    cpu_usage = (None if cpu_before is None or cpu_after is None else {
        "user_seconds": round(max(0.0, cpu_after[0] - cpu_before[0]), 3),
        "system_seconds": round(max(0.0, cpu_after[1] - cpu_before[1]), 3),
    })
    errors = failure_excerpt(output) if status != "PASS" else []
    extra = format_metrics(metrics)
    if diagnostics["warning_lines"]:
        extra += ("  ·  " if extra else "") + f"{diagnostics['warning_lines']} warning" + ("s" if diagnostics["warning_lines"] != 1 else "")
    print(f"  {status_marker(status, opts)} {paint(label, 'bold', opts.color)} "
          f"{status_label(status, opts)} {duration:7.2f}s"
          + ("  " + paint("│", "dim", opts.color) + f"  {extra}" if extra else ""),
          flush=True)
    if errors:
        for line in errors:
            print(f"      {paint(line, 'red', opts.color)}")
        print(f"      {paint('LOG', 'dim', opts.color)}  {log_path}")
    return {"target": target, "description": synopsis(target), "status": status,
            "exit_code": 124 if timeout else returncode, "duration_seconds": duration,
            "started_utc": began, "finished_utc": utc_now(),
            "log": str(log_path.relative_to(log_dir.parent)),
            "metrics": metrics, "diagnostics": diagnostics,
            "child_cpu": cpu_usage, "errors": errors}


def write_report(directory: Path, report: dict[str, Any]) -> None:
    """Persist complete JSON data and a compact plain-text overview."""
    (directory / "report.json").write_text(
        json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8")
    lines = [f"LUAU MODE / {report['name']}",
             f"Date: {report['started_utc']}",
             f"Runtime: {report['duration_seconds']:.3f}s",
             f"Status: {report['status']}",
             f"Total: {report['totals']}", ""]
    for entry in report["steps"]:
        lines.append(f"{entry['status']:<8} {entry['target']:<28} "
                     f"{entry['duration_seconds']:>9.3f}s  "
                     f"{format_metrics(entry['metrics'])}")
        for error in entry["errors"]:
            lines.append("    " + error)
        lines.append("    " + entry["log"])
    (directory / "report.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    write_junit(directory / "junit.xml", report)


def write_junit(path: Path, report: dict[str, Any]) -> None:
    """Export a valid JUnit-style result, preserving failures and skip counts.

    One Make leaf target is one test case; nested ERT assertions are retained
    as metrics and full plain-text logs, not counted as individual JUnit cases.
    The exporter never promotes a failing step to success or invents ERT counts.
    """
    steps = report["steps"]
    suite = ET.Element("testsuite", {
        "name": f"luau-mode.{report['name']}",
        "tests": str(len(steps)),
        "failures": str(sum(s["status"] == "FAIL" for s in steps)),
        "errors": str(sum(s["status"] == "TIMEOUT" for s in steps)),
        "skipped": "0",
        "time": str(report["duration_seconds"]),
    })
    for step in steps:
        case = ET.SubElement(suite, "testcase", {
            "name": step["target"],
            "classname": "luau-mode.make",
            "time": str(step["duration_seconds"]),
        })
        if step["status"] != "PASS":
            status_tag = "error" if step["status"] == "TIMEOUT" else "failure"
            detail = ET.SubElement(case, status_tag, {
                "message": f"{step['status']}: {step['target']}",
                "type": "timeout" if status_tag == "error" else "make-failure",
            })
            detail.text = "\n".join(step["errors"]) or "See archived raw log"
        ET.SubElement(case, "system-out").text = (
            f"log: {step['log']}\nmetrics: "
            + json.dumps(step["metrics"], ensure_ascii=False, sort_keys=True))
    path.write_bytes(ET.tostring(suite, encoding="utf-8", xml_declaration=True))


def run_suite(name: str, targets: list[str], opts: Options) -> int:
    """Run TARGETS sequentially, never skipping later steps after failures."""
    unknown = [name for name in targets if name not in TASKS]
    if unknown:
        print(f"Invalid targets: {', '.join(unknown)}", file=sys.stderr)
        return 2
    if not targets:
        print("A suite must have at least one target", file=sys.stderr)
        return 2
    report_root = opts.root / Path(os.environ.get("LUAU_REPORT_DIR", str(REPORT_DIR)))
    # Distinct run IDs avoid overwriting reports from multiple invocations.
    session_id = (f"{datetime.now(timezone.utc):%Y%m%d-%H%M%S}-"
                  f"{time.time_ns():019d}-{safe_name(name)}")
    directory = report_root / session_id
    suffix = 0
    while True:
        logs = directory / "logs"
        try:
            logs.mkdir(parents=True, exist_ok=False)
            break
        except FileExistsError:
            suffix += 1
            directory = report_root / f"{session_id}-{suffix}"
    machine = machine_info(opts.root)
    print("\n" + divider(opts))
    print("  " + paint("◆  LUAU MODE", "bold", opts.color)
          + "  " + paint("/", "dim", opts.color) + "  "
          + paint(name.upper(), "cyan", opts.color))
    print(f"  {len(targets)} checks  " + paint("│", "dim", opts.color)
          + f"  {machine.get('emacs') or 'Emacs not detected'}  "
          + paint("│", "dim", opts.color) + f"  Python {machine['python']}")
    print(f"  {machine['source_files']} sources  " + paint("│", "dim", opts.color)
          + f"  {machine['test_files']} test modules  "
          + paint("│", "dim", opts.color) + f"  {machine['benchmark_files']} benchmarks")
    if machine["package_version"]:
        revision = f"  Package {machine['package_version']}"
        if machine["development_cycle"] is not None:
            revision += f"  " + paint("│", "dim", opts.color) + f"  Cycle {machine['development_cycle']:02d}"
        print(revision)
    print(divider(opts))
    started = utc_now()
    begin = time.monotonic()
    entries = []
    try:
        for index, target in enumerate(targets, 1):
            entries.append(run_step(target, index, len(targets), logs, opts))
    except KeyboardInterrupt:
        print("\nInterrupted; partial report will be saved", file=sys.stderr)
    runtime = round(time.monotonic() - begin, 3)
    totals = {name: sum(entry["status"] == name for entry in entries)
              for name in ("PASS", "FAIL", "TIMEOUT")}
    totals["NOT_RUN"] = len(targets) - len(entries)
    success = totals["FAIL"] == totals["TIMEOUT"] == totals["NOT_RUN"] == 0
    report = {"schema_version": 1, "name": name, "started_utc": started,
              "finished_utc": utc_now(), "duration_seconds": runtime,
              "machine": machine, "status": "PASS" if success else "FAIL",
              "targets": targets, "steps": entries, "totals": totals,
              "options": {"timeout_seconds": opts.timeout, "verbose": opts.verbose,
                          "heartbeat_seconds": opts.heartbeat}}
    write_report(directory, report)
    label = "PASS" if success else "FAIL"
    print(divider(opts))
    if len(entries) >= 3:
        print("  " + paint("SLOWEST TARGETS", "bold", opts.color)
              + paint("  ·  wall-clock duration", "dim", opts.color))
        longest = max((entry["duration_seconds"] for entry in entries), default=0)
        for entry in sorted(entries, key=lambda item: item["duration_seconds"],
                            reverse=True)[:5]:
            width = (max(1, round(18 * entry["duration_seconds"] / longest))
                     if longest else 1)
            bar = ("#" if opts.ascii_only else "━") * width
            print(f"    {entry['target']:<27} {entry['duration_seconds']:>7.2f}s  "
                  + paint(bar, "red" if entry["status"] != "PASS" else "cyan", opts.color))
        if totals["FAIL"] or totals["TIMEOUT"]:
            print("  " + paint("FAILED TARGETS", "red", opts.color) + "  " + ", ".join(
                entry["target"] for entry in entries if entry["status"] != "PASS"))
        print(divider(opts))
    print(f"  {status_marker(label, opts)} " + status_label(label, opts, 7) + " "
          + paint(f"{totals['PASS']} passed", "green", opts.color) + ", "
          + paint(f"{totals['FAIL']} failed", "red" if totals['FAIL'] else "dim", opts.color)
          + ", " + paint(f"{totals['TIMEOUT']} timed out",
                          "yellow" if totals['TIMEOUT'] else "dim", opts.color)
          + f"  {totals['NOT_RUN']} not run  "
          + paint("│", "dim", opts.color) + f"  {runtime:.2f}s")
    print(f"  {paint('Report ', 'dim', opts.color)} {directory / 'report.json'}")
    print(f"  {paint('Summary', 'dim', opts.color)} {directory / 'report.txt'}")
    print(f"  {paint('Logs   ', 'dim', opts.color)} {logs}")
    print(divider(opts) + "\n", flush=True)
    return 0 if success else 1


def report_files(root: Path) -> list[Path]:
    """Return newest first report paths, including historical individual runs."""
    directory = root / Path(os.environ.get("LUAU_REPORT_DIR", str(REPORT_DIR)))
    if not directory.exists():
        return []
    # Run IDs embed a nanosecond creation sequence.  Ordering by directory
    # name avoids filesystem timestamp granularity and same-second triage
    # races, including on networked or copied directories.
    return sorted(directory.glob("*/report.json"),
                  key=lambda path: path.parent.name, reverse=True)


def latest_failed_report(root: Path) -> tuple[Path, dict[str, Any]] | None:
    """Find the most recent saved report containing failed leaf targets.

    Inspection commands and passing runs do not erase failure history.
    Corrupt historical reports are ignored, not executed or trusted.
    """
    for path in report_files(root):
        try:
            report = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(report, dict) and any(
                step.get("status") in ("FAIL", "TIMEOUT")
                for step in report.get("steps", []) if isinstance(step, dict)):
            return path, report
    return None


def failed_targets(report: dict[str, Any]) -> list[str]:
    """Return ordered unique known failing leaf targets, never arbitrary commands."""
    failed: list[str] = []
    for step in report.get("steps", []):
        name = step.get("target")
        if (step.get("status") in ("FAIL", "TIMEOUT")
                and isinstance(name, str) and name in TASKS
                and name not in failed):
            failed.append(name)
    return failed


def unresolved_failures(root: Path) -> list[tuple[Path, dict[str, Any]]]:
    """Find failures not superseded by later PASS results of the same target.

    History may contain both individual runs and complete suites.  Only the
    newest observed result per *known* target is authoritative.  A later
    successful quickcheck must not leave an old compiler failure actionable.
    """
    outcomes: dict[str, tuple[Path, dict[str, Any]]] = {}
    for path in report_files(root):
        try:
            report = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(report, dict) or not isinstance(report.get("steps"), list):
            continue
        # A suite may repeat a target: the last attempt is the final outcome.
        for step in reversed(report["steps"]):
            if not isinstance(step, dict):
                continue
            target = step.get("target")
            status = step.get("status")
            if (isinstance(target, str) and target in TASKS
                    and target not in outcomes
                    and status in ("PASS", "FAIL", "TIMEOUT")):
                outcomes[target] = (path, step)
    return [(path, step) for path, step in outcomes.values()
            if step["status"] in ("FAIL", "TIMEOUT")]


def show_failures(root: Path) -> int:
    """Show only unresolved failures, not stale historical problems."""
    problems = unresolved_failures(root)
    if not problems:
        print("No unresolved failures recorded for any previously tested target.")
        print("Untested targets are not counted as passed; run `make check`.")
        return 0
    print("\n  LUAU MODE / UNRESOLVED FAILURE INBOX")
    print(f"  {len(problems)} targets still failing in their latest recorded run")
    print("  " + "=" * 70)
    for path, step in problems:
        print(f"\n  [x] {step['target']} ({step['status']}, "
              f"exit={step.get('exit_code', '?')}, "
              f"{step.get('duration_seconds', 0):.2f}s)")
        for finding in step.get("errors", [])[:12]:
            print(f"      {finding}")
        print(f"      LOG: {path.parent / step['log']}")
    print("\n  Rerun unresolved failures: make triage\n")
    return 0


def rerun_failures(root: Path, opts: Options) -> int:
    """Rerun each unresolved failing leaf exactly once."""
    problems = unresolved_failures(root)
    if not problems:
        print("No unresolved failures to rerun; use `make check` for full coverage.")
        return 0
    targets = [step["target"] for _, step in problems]
    print(f"Re-running {len(targets)} unresolved targets: {', '.join(targets)}")
    return run_suite("triage", targets, opts)


def show_dashboard(root: Path) -> int:
    """Give a concise cross-run summary without treating untested gates as PASS."""
    reports = report_files(root)
    print("\n  LUAU MODE / QUALITY DASHBOARD")
    print("  " + "=" * 70)
    if not reports:
        print("  No recorded runs. Start with `make quickcheck` or `make check`.\n")
        return 0
    seen: dict[str, tuple[str, float]] = {}
    for path in reports:
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(record, dict):
            continue
        for step in reversed(record.get("steps", [])):
            if not isinstance(step, dict):
                continue
            target, status = step.get("target"), step.get("status")
            if (target in TASKS and target not in seen
                    and status in ("PASS", "FAIL", "TIMEOUT")):
                seen[target] = (status, float(step.get("duration_seconds", 0)))
    green = sum(status == "PASS" for status, _ in seen.values())
    red = sum(status != "PASS" for status, _ in seen.values())
    print(f"  Known targets: {green} passed | {red} failing | "
          f"{len(TASKS) - len(seen)} never tested")
    print("  Target                   Latest      Runtime")
    print("  " + "-" * 70)
    for target in ("compile-strict", "test", "test-lsp", "doctor",
                   "test-tools", "test-static"):
        status, duration = seen.get(target, ("NOT RUN", None))
        runtime = "--" if duration is None else f"{duration:.2f}s"
        print(f"  {target:<27}{status:<12}{runtime:>8}")
    if red:
        print("  Unresolved failures: " + ", ".join(
            target for target, (status, _) in seen.items() if status != "PASS"))
    print(f"  Latest report: {reports[0]}")
    print("  Timings are descriptive only; green rows do not imply full-suite PASS.\n")
    return 0


def show_history(root: Path, limit: int = 12) -> int:
    """Print recent run statuses with stable dates and duration."""
    print("\n  LUAU MODE / RECENT RUN HISTORY")
    print("  " + "=" * 70)
    count = 0
    for path in report_files(root):
        try:
            report = json.loads(path.read_text(encoding="utf-8"))
            name, state = report["name"], report["status"]
            started = report["started_utc"]
            duration = float(report["duration_seconds"])
        except (OSError, ValueError, KeyError, TypeError):
            continue
        print(f"  {started:<25} {state:<8} {duration:>7.2f}s  {name}")
        count += 1
        if count >= limit:
            break
    if not count:
        print("  No runs available.")
    print()
    return 0


def show_trend(root: Path) -> int:
    """Describe historical timing changes without unstable performance gating."""
    reports = report_files(root)
    if not reports:
        print("No timing history. Run `make check` or `make benchmark` first.")
        return 0
    recent = [json.loads(path.read_text(encoding="utf-8")) for path in reports[:100]]
    latest = recent[0]
    identity = (latest.get("machine", {}).get("platform"),
                latest.get("machine", {}).get("emacs"))
    all_steps: dict[str, list[float]] = {}
    for report in recent:
        machine = report.get("machine", {})
        if (machine.get("platform"), machine.get("emacs")) != identity:
            continue
        for step in report.get("steps", []):
            if step.get("status") == "PASS":
                samples = all_steps.setdefault(step["target"], [])
                if len(samples) < 6:
                    samples.append(float(step["duration_seconds"]))
    print("\n  LUAU MODE / RECENT DURATION TREND (informational only)")
    print(f"  Matched platform={identity[0]}  Emacs={identity[1] or 'not detected'}")
    print("  Latest | prior median | change; up to 5 previous successful samples")
    print("  " + "-" * 71)
    for target, samples in sorted(all_steps.items()):
        latest_value = samples[0]
        baseline = statistics.median(samples[1:]) if len(samples) > 1 else None
        change = ((latest_value / baseline - 1) * 100
                  if baseline is not None and baseline > 0 else None)
        print(f"  {target:<27} {latest_value:>8.2f}s  "
              f"{f'{baseline:.2f}s' if baseline is not None else 'n/a':>10}  "
              f"{f'{change:+.1f}%' if change is not None else 'n/a':>8}")
    print("  Times are not normalized for machine load; no pass/fail is inferred.\n")
    return 0


def bundle_latest(root: Path) -> int:
    """Produce one compressed report to upload, with all logs and JSON."""
    reports = report_files(root)
    if not reports:
        print("No diagnostics to bundle. Run `make diagnostics` first.", file=sys.stderr)
        return 2
    latest = reports[0].parent
    output_dir = root / ".build"
    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / f"luau-make-report-{latest.name}.tar.gz"
    # Source hashes allow precise cycle-to-cycle comparisons without uploading
    # potentially private project directories or additional source files.
    source = [path for path in sorted(root.rglob("*"))
              if path.is_file() and not set(path.relative_to(root).parts)
              & {".git", ".build", ".packages", "__pycache__"}]
    manifest = "".join(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  "
                       f"{path.relative_to(root)}\n" for path in source)
    with tarfile.open(output, "w:gz") as archive:
        import io
        payload = manifest.encode("utf-8")
        info = tarfile.TarInfo("luau-make-report/source-sha256.txt")
        info.size = len(payload)
        archive.addfile(info, io.BytesIO(payload))
        for file in sorted(latest.rglob("*")):
            if file.is_file() and not file.is_symlink():
                archive.add(file, arcname=f"luau-make-report/{file.relative_to(latest)}",
                            recursive=False)
    color_setting = os.environ.get("LUAU_COLOR", "auto").lower()
    colored = ("NO_COLOR" not in os.environ
               and (color_setting == "always"
                    or (color_setting == "auto" and sys.stdout.isatty()
                        and os.environ.get("TERM", "dumb") != "dumb")))
    print("\n" + paint("─" * 78, "dim", colored))
    print("  " + paint("◆  LUAU MODE", "bold", colored) + "  "
          + paint("/", "dim", colored) + "  "
          + paint("REPORT BUNDLE", "cyan", colored))
    print("  " + paint("✓", "green", colored) + " "
          + paint("ARCHIVED", "green", colored) + "  " + str(output))
    print("  " + paint("UPLOAD", "bold", colored)
          + " this TAR.GZ to continue the next implementation cycle.")
    print(paint("─" * 78, "dim", colored) + "\n")
    return 0


def show_help() -> None:
    """Show public, coherent targets and their environment controls."""
    groups = [
        ("QUALITY", [
            ("make check", "Every non-destructive gate, with automatic diagnostic TAR.GZ"),
            ("make quickcheck", "Fast compile, tests, lint, and tools"),
            ("make doctor", "Recursive Checkdoc and package-lint"),
            ("make test", "Every Luau ERT test, recursively discovered"),
            ("make test-core / make test-lsp / make test-font-lock / make test-interface", "Focused ERT suites"),
            ("make test-tools / make test-static", "Offline checks"),
            ("make triage", "Rerun unresolved failing targets"),
            ("make failures", "Detailed failures with log paths"),
            ("make diagnostics", "Exhaustive suite with benchmarks"),
            ("make diagnostics-bundle", "Compatibility alias to make check"),
        ]),
        ("BUILD / MAINTENANCE", [
            ("make compile-strict", "Byte compilation, warnings as errors"),
            ("make compile", "Byte compilation"),
            ("make checkdoc", "Recursive Checkdoc"),
            ("make package-lint", "Recursive package-lint"),
            ("make bootstrap", "Install local package-lint (uses network)"),
            ("make benchmark", "Run available observational benchmarks"),
            ("make verify-delta DELTA=...", "Verify incremental release TAR.GZ"),
            ("make clean", "Remove generated bytecode and package cache"),
        ]),
        ("REPORTING", [
            ("make status", "Most recent report"),
            ("make dashboard", "Latest state per target"),
            ("make history / make trend", "Historical quality and runtime"),
            ("make bundle", "Archive latest logs, JSON, and JUnit"),
        ]),
    ]
    print("\n  LUAU MODE   /   MAKE TARGETS\n  " + "=" * 69)
    for title, rows in groups:
        print(f"\n  {title}")
        for command, description in rows:
            print(f"    {command:<43} {description}")
    print("\n  OUTPUT CONTROLS")
    print("    LUAU_VERBOSE=1        Stream raw command output as it runs")
    print("    LUAU_TIMEOUT=75       Per-target timeout in seconds (0 disables)")
    print("    LUAU_ERT_TIMEOUT=8    Per-test timeout in seconds (no false skips)")
    print("    LUAU_HEARTBEAT=10     Ongoing heartbeat interval in seconds")
    print("    LUAU_COLOR=always    Force ANSI colors; NO_COLOR disables colors")
    print("    LUAU_ASCII=1         Plain-ASCII status glyphs")
    print("    LUAU_REPORT_DIR=...  Override generated report directory")
    print("    Full, unabridged logs and JSON are retained under .build/reports/\n")


def show_status(root: Path) -> int:
    """Show the newest saved report, without creating an empty one."""
    recent = report_files(root)
    if not recent:
        print("No Make reports found. Run `make check` or `make diagnostics` first.")
        return 0
    report = json.loads(recent[0].read_text(encoding="utf-8"))
    print(f"\n  LUAU MODE / LAST RUN: {report['name']} ({report['status']})")
    print(f"  Started : {report['started_utc']}")
    print(f"  Duration: {report['duration_seconds']:.2f}s")
    print(f"  Results : {report['totals']}")
    for step in report["steps"]:
        print(f"    {step['status']:<8} {step['target']:<27} "
              f"{step['duration_seconds']:>7.2f}s  {format_metrics(step['metrics'])}")
    print(f"  Report  : {recent[0]}\n")
    return 0


def options_from_environment(root: Path, make: str) -> Options:
    """Use explicit opt-in verbosity, automatic terminal color safety."""
    try:
        timeout = float(os.environ.get("LUAU_TIMEOUT", "75"))
        heartbeat = float(os.environ.get("LUAU_HEARTBEAT", "10"))
    except ValueError as exc:
        raise ValueError("LUAU_TIMEOUT and LUAU_HEARTBEAT must be numeric") from exc
    if timeout < 0 or heartbeat < 0:
        raise ValueError("LUAU_TIMEOUT and LUAU_HEARTBEAT must be nonnegative")
    color_setting = os.environ.get("LUAU_COLOR", "auto").lower()
    if color_setting not in ("always", "never", "auto"):
        raise ValueError("LUAU_COLOR must be always, never or auto")
    color = ("NO_COLOR" not in os.environ and
             (color_setting == "always" or
              (color_setting == "auto" and sys.stdout.isatty() and
               os.environ.get("TERM", "dumb") != "dumb")))
    # Empty string in LUAU_VERBOSE is treated as disabled, as is 0.
    verbose = os.environ.get("LUAU_VERBOSE", "").strip().lower() not in ("", "0", "false", "no")
    make_cmd = tuple(shlex.split(make))
    if not make_cmd:
        raise ValueError("An executable Make command is required")
    return Options(root, make_cmd, timeout, verbose, color,
                   os.environ.get("LUAU_ASCII", "") == "1", heartbeat)


def main(argv: list[str] | None = None) -> int:
    """Parse the public runner API and return a reliable Make exit status."""
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run", help="Run one checked Make target")
    run.add_argument("target", choices=TASKS)
    run.add_argument("--make", default="make", help="Make executable / command")
    suite = sub.add_parser("suite", help="Run an independently logged target suite")
    suite.add_argument("name", help="Report group name")
    suite.add_argument("targets", nargs="+", choices=TASKS)
    suite.add_argument("--make", default="make", help="Make executable / command")
    sub.add_parser("help", help="Show Make target inventory")
    sub.add_parser("status", help="Show last saved report")
    sub.add_parser("dashboard", help="Cross-run quality gates and unresolved failures")
    sub.add_parser("history", help="Last twelve timed reports")
    sub.add_parser("trend", help="Show historical timing comparisons")
    sub.add_parser("bundle", help="Package latest machine report and logs")
    sub.add_parser("failures", help="Inspect latest failed leaf targets")
    triage = sub.add_parser("triage", help="Rerun latest failed leaf targets")
    triage.add_argument("--make", default="make", help="Make executable / command")
    args = parser.parse_args(argv)
    if args.command == "help":
        show_help()
        return 0
    if args.command == "status":
        return show_status(Path.cwd())
    if args.command == "dashboard":
        return show_dashboard(Path.cwd())
    if args.command == "history":
        return show_history(Path.cwd())
    if args.command == "trend":
        return show_trend(Path.cwd())
    if args.command == "bundle":
        return bundle_latest(Path.cwd())
    if args.command == "failures":
        return show_failures(Path.cwd())
    try:
        opts = options_from_environment(Path.cwd(), args.make)
    except ValueError as exc:
        parser.error(str(exc))
    if args.command == "triage":
        return rerun_failures(Path.cwd(), opts)
    return run_suite(args.target if args.command == "run" else args.name,
                     [args.target] if args.command == "run" else args.targets, opts)


if __name__ == "__main__":
    raise SystemExit(main())
