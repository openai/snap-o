#!/usr/bin/env python3
"""Run device helper logic tests without Android or a device."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parent
    javac = Path(os.environ["JAVA_HOME"]) / "bin/javac" if "JAVA_HOME" in os.environ else shutil.which("javac")
    java = Path(os.environ["JAVA_HOME"]) / "bin/java" if "JAVA_HOME" in os.environ else shutil.which("java")
    if not javac or not java:
        raise SystemExit("Install JDK 17.")
    with tempfile.TemporaryDirectory(prefix="snapo-device-tests-") as temporary:
        subprocess.run([
            str(javac), "--release", "8", "-d", temporary,
            str(root / "src/com/openai/snapo/video/FrameWindow.java"),
            str(root / "tests/FrameWindowTest.java"),
        ], check=True)
        subprocess.run([str(java), "-cp", temporary, "com.openai.snapo.video.FrameWindowTest"], check=True)


if __name__ == "__main__":
    main()
