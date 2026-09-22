#!/usr/bin/env python3
"""Exercise clipboard sync on an unlocked device and restore its original clipboard."""

import argparse
import base64
from pathlib import Path
import re
import select
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import uuid


def read_exact(connection, count):
    result = bytearray()
    while len(result) < count:
        chunk = connection.recv(count - len(result))
        if not chunk:
            raise RuntimeError("Clipboard helper disconnected")
        result.extend(chunk)
    return bytes(result)


def read_text(connection):
    length, = struct.unpack(">I", read_exact(connection, 4))
    assert length <= 1024 * 1024, "Oversized clipboard frame"
    return read_exact(connection, length).decode("utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    adb = shutil.which("adb") or str(Path.home() / "Library/Android/sdk/platform-tools/adb")
    device = [adb, "-s", args.serial]
    directories = []

    def start(jar, main_class):
        directory = "/data/local/tmp/snapo-clipboard-test-" + uuid.uuid4().hex
        directories.append(directory)
        encoded = base64.b64encode(jar.read_bytes()).decode("ascii")
        command = f"""mkdir -m 700 '{directory}' || exit 1
trap 'rm -f "{directory}/helper.jar"; rmdir "{directory}" 2>/dev/null' EXIT
printf '%s' '{encoded}' | base64 -d > '{directory}/helper.jar'
chmod 444 '{directory}/helper.jar'
CLASSPATH='{directory}/helper.jar' app_process / {main_class} '{directory}' 2>/dev/null"""
        connection = socket.create_connection(("127.0.0.1", 5037), timeout=8)
        try:
            for request in ["host:transport:" + args.serial, "exec:" + command]:
                data = request.encode("utf-8")
                connection.sendall(f"{len(data):04X}".encode("ascii") + data)
                assert read_exact(connection, 4) == b"OKAY", "ADB rejected helper startup"
            return connection
        except BaseException:
            connection.close()
            raise

    def helper():
        connection = start(root / "snapo-device-helper.jar", "com.openai.snapo.clipboard.Main")
        try:
            assert read_exact(connection, 4) == struct.pack(">I", 1)
            read_text(connection)
            return connection
        except BaseException:
            connection.close()
            raise

    policy = subprocess.run([*device, "shell", "dumpsys window policy"], capture_output=True, text=True, check=True, timeout=8)
    assert re.search(r"^\s*showing=false\s*$", policy.stdout, re.MULTILINE), "Unlock the device before testing"
    with tempfile.TemporaryDirectory(prefix="snapo-clipboard-tests-") as temporary:
        fixture_jar = Path(temporary) / "fixture.jar"
        subprocess.run(["python3", str(root / "build.py"), "--device-test-jar", str(fixture_jar)], check=True)
        with start(fixture_jar, "com.openai.snapo.clipboard.DeviceFixture") as fixture:
            assert read_exact(fixture, 6) == b"ready\n", "Unlock the device before testing"
            try:
                with helper() as connection:
                    text = "Snap-O host 🌍\n日本語\0".encode("utf-8")
                    connection.sendall(struct.pack(">I", len(text)) + text)
                    fixture.sendall(b"verify-host\n")
                    assert read_exact(fixture, 3) == b"ok\n"
                    assert not select.select([connection], [], [], 0.5)[0], "Host write echoed back"
                    fixture.sendall(b"copy-device\n")
                    assert read_exact(fixture, 3) == b"ok\n"
                    assert read_text(connection) == "Snap-O device 🧪\nمرحبا"
            finally:
                fixture.sendall(b"restore\n")
                assert read_exact(fixture, 9) == b"restored\n", "Clipboard restoration failed"
    for directory in directories:
        deadline = time.monotonic() + 5
        while subprocess.run([*device, "shell", f"test ! -e '{directory}'"], timeout=8).returncode:
            if time.monotonic() >= deadline:
                raise AssertionError("Helper did not remove its temporary directory after disconnect")
            time.sleep(0.1)
    print("Device clipboard passed: both directions, Unicode, no echoes, overlay suppression, disconnect, and cleanup.")


if __name__ == "__main__":
    main()
