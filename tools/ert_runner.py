#!/usr/bin/env python3
"""Run each ERT test in a separate, bounded Emacs process.

A runaway font-lock matcher cannot hold the whole check suite hostage.
The test name and complete diagnostic trace are always written to stdout.
No test failures are downgraded to skips.
"""

from __future__ import annotations

import os
import signal
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
NAME = re.compile(r"^LUAU_ERT_TEST:([A-Za-z0-9_-]+)$", re.M)


def command() -> list[str]:
    """Return the configured Emacs command with a clean batch environment."""
    executable = shlex.split(os.environ.get("EMACS", "emacs"))
    if not executable:
        raise ValueError("EMACS is empty")
    return [*executable, "-Q", "--batch", "-L", str(ROOT),
            "-L", str(ROOT / "test"), "-L", str(ROOT / "tests"),
            "--eval", "(setq load-prefer-newer t)",
            "-l", str(ROOT / "test/batch-ert.el")]


def run_bounded(args: list[str], env: dict[str, str], timeout: float) -> subprocess.CompletedProcess[str]:
    """Run Emacs with bounded execution and terminate its entire process tree.

    Tests can start Rojo and helper processes.  Killing Emacs alone is not
    sufficient when children keep the captured output pipe open.
    """
    process = subprocess.Popen(args, cwd=ROOT, env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, errors="replace",
                               start_new_session=(os.name != "nt"))
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        if os.name != "nt":
            os.killpg(process.pid, signal.SIGKILL)
        else:
            process.kill()
        output, _ = process.communicate()
        raise subprocess.TimeoutExpired(args, timeout, output=output) from exc
    return subprocess.CompletedProcess(args, process.returncode, stdout=output)


def main() -> int:
    """Discover, execute, and summarize every selected test separately."""
    timeout = float(os.environ.get("LUAU_ERT_TIMEOUT", "8"))
    if timeout <= 0:
        raise ValueError("LUAU_ERT_TIMEOUT must be positive")
    env = dict(os.environ)
    env["LUAU_ERT_LIST"] = "1"
    env.pop("LUAU_ERT_SINGLE", None)
    try:
        listed = run_bounded(command(), env, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"ERROR: ERT discovery failed: {exc}", flush=True)
        return 2
    if listed.returncode != 0:
        print(listed.stdout, flush=True)
        print("ERROR: ERT discovery returned a nonzero status", flush=True)
        return 2
    names = NAME.findall(listed.stdout)
    if not names or len(names) != len(set(names)):
        print(listed.stdout, flush=True)
        print("ERROR: no tests, or duplicate ERT test identifiers", flush=True)
        return 2
    print(f"LUAU ISOLATED ERT / {len(names)} tests / {timeout:g}s per test", flush=True)
    passed = failed = timed_out = 0
    start = time.monotonic()
    for index, name in enumerate(names, 1):
        env.pop("LUAU_ERT_LIST", None)
        env["LUAU_ERT_SINGLE"] = name
        print(f"  › [{index:02d}/{len(names):02d}] {name}", flush=True)
        try:
            result = run_bounded(command(), env, timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            timed_out += 1
            output = exc.stdout or b""
            if isinstance(output, bytes):
                output = output.decode("utf-8", errors="replace")
            print(f"  TIMEOUT {name} after {timeout:g}s", flush=True)
            print(output[-5000:], flush=True)
            continue
        if result.returncode == 0:
            passed += 1
            print(f"  PASS    {name}", flush=True)
        else:
            failed += 1
            print(f"  FAIL    {name} (exit {result.returncode})", flush=True)
            print(result.stdout[-16000:], flush=True)
    total = len(names)
    print(f"RESULT  {passed}/{total} expected | {failed} unexpected | "
          f"{timed_out} timed out | 0 skipped", flush=True)
    print(f"Runtime: {time.monotonic() - start:.2f}s", flush=True)
    return 0 if passed == total else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(2)
