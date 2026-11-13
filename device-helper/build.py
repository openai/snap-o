#!/usr/bin/env python3
"""Build the Android device helper bundled with Snap-O."""

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify the checked-in helper matches its sources")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    sdk = Path(os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") or Path.home() / "Library/Android/sdk")
    android = sdk / "platforms/android-36/android.jar"
    d8 = sdk / "build-tools/36.0.0/d8"
    java = Path(os.environ["JAVA_HOME"]) / "bin/javac" if "JAVA_HOME" in os.environ else shutil.which("javac")
    if not android.is_file() or not d8.is_file() or not java:
        parser.error("Install Android SDK platform 36, build-tools 36.0.0, and JDK 17.")
    with tempfile.TemporaryDirectory(prefix="snapo-device-build-") as temporary:
        temporary = Path(temporary)
        classes = temporary / "classes"
        classes.mkdir()
        dex = temporary / "dex"
        dex.mkdir()
        sources = sorted((root / "src").rglob("*.java"))
        fingerprint = hashlib.sha256(Path(__file__).read_bytes())
        for source in sources:
            fingerprint.update(source.relative_to(root).as_posix().encode() + b"\0" + source.read_bytes())
        build_id = fingerprint.hexdigest()[:16]
        build_source = temporary / "Build.java"
        build_source.write_text(f'package com.openai.snapo; final class Build {{ static final String ID = "{build_id}"; }}\n')
        sources.append(build_source)
        subprocess.run([str(java), "--release", "8", "-g:none", "-classpath", str(android), "-d", str(classes), *map(str, sources)], check=True)
        subprocess.run([str(d8), "--release", "--min-api", "24", "--lib", str(android), "--output", str(dex), *map(str, sorted(classes.rglob("*.class")))], check=True)
        output = temporary / "snapo-device-helper.jar"
        with zipfile.ZipFile(output, "w") as archive:
            entry = zipfile.ZipInfo("classes.dex", (1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_STORED
            entry.external_attr = 0o644 << 16
            archive.writestr(entry, (dex / "classes.dex").read_bytes())
            archive.comment = ("SNHB" + build_id).encode("ascii")
        destination = root / "snapo-device-helper.jar"
        if args.check:
            if not destination.is_file() or destination.read_bytes() != output.read_bytes():
                parser.error("Helper is out of date; run device-helper/build.py.")
            print("Android device helper matches its sources.")
        else:
            shutil.copyfile(output, destination)
            print(f"Built {destination.name}: {destination.stat().st_size} bytes")


if __name__ == "__main__":
    main()
