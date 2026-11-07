#!/usr/bin/env python3
"""Keep CI output short and collect evidence before the step timeout."""

import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def capture(directory, name, command):
    with (directory / name).open("w") as output:
        try:
            subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=5, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            output.write(str(error) + "\n")


def diagnose(directory):
    capture(directory, "processes.txt", ["ps", "-axo", "pid,ppid,state,%cpu,%mem,etime,comm"])
    capture(directory, "memory.txt", ["vm_stat"])
    capture(directory, "disk.txt", ["df", "-h"])
    for name in ("xcodebuild", "xctest", "Snap-O", "testmanagerd"):
        try:
            result = subprocess.run(["pgrep", "-x", name], capture_output=True, text=True, timeout=5, check=False)
            for pid in result.stdout.split()[:1]:
                capture(directory, f"sample-{name}-{pid}.txt", ["sample", pid, "1", "1"])
        except (OSError, subprocess.TimeoutExpired) as error:
            print(f"Could not find {name}: {error}", flush=True)
    print(f"Process samples saved in {directory}", flush=True)
    print((directory / "processes.txt").read_text(), flush=True)


def run(name, command):
    directory = Path(os.environ["RUNNER_TEMP"]) / "mac-diagnostics" / name
    directory.mkdir(parents=True, exist_ok=True)
    log_path = directory / "output.log"
    started = time.monotonic()
    sampled = False
    print(f"Starting {name}; full output: {log_path}", flush=True)
    with log_path.open("w") as output:
        process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            while True:
                try:
                    code = process.wait(timeout=15)
                    break
                except subprocess.TimeoutExpired:
                    elapsed = time.monotonic() - started
                    print(f"{name}: still running after {elapsed:.0f}s (pid {process.pid})", flush=True)
                    if "test-without-building" in command:
                        print("\n".join(log_path.read_text(errors="replace").splitlines()[-12:]), flush=True)
                        if elapsed >= 45 and not sampled:
                            sampled = True
                            diagnose(directory)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
    print("\n".join(log_path.read_text(errors="replace").splitlines()[-30:]), flush=True)
    print(f"{name}: exit {code} after {time.monotonic() - started:.1f}s", flush=True)
    return code if code >= 0 else 128 - code


def cancelled(signum, _frame):
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, cancelled)
    signal.signal(signal.SIGINT, cancelled)
    sys.exit(run(sys.argv[1], sys.argv[2:]))
