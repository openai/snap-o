#!/usr/bin/env python3
"""Test manifest discovery on a connected device using a temporary non-debuggable APK."""

import argparse
import base64
import json
import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid
import zipfile
from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parent.parent


def run(*args):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError(f"Command failed: {args}\n{result.stdout}\n{result.stderr}")
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--freeze", action="store_true", help="also verify the target remains frozen during discovery")
    parser.add_argument("--icon", choices=["round", "adaptive", "legacy"], default="round")
    options = parser.parse_args()
    sdk = Path(os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") or Path.home() / "Library/Android/sdk")
    build = sdk / "build-tools/36.0.0"
    android = sdk / "platforms/android-36/android.jar"
    java = Path(os.environ["JAVA_HOME"]) / "bin" if "JAVA_HOME" in os.environ else Path(shutil.which("java")).parent
    adb = ["adb", "-s", options.serial]
    suffix = uuid.uuid4().hex[:12]
    package = "com.example.snapo.discoveryfixture.p" + suffix
    remote = "/data/local/tmp/snapo-discovery-test-" + suffix + ".jar"
    installed = False
    with tempfile.TemporaryDirectory(prefix="snapo-discovery-device-") as temporary:
        temporary = Path(temporary)
        resources = temporary / "res"
        for module in ["network", "tweaks-core"]:
            original = ROOT / "snapo-link-android" / module / "src/main/res"
            for kind in ["xml", "drawable", "values"]:
                (resources / kind).mkdir(parents=True, exist_ok=True)
                for source in (original / kind).glob("snapo_*inspector*.xml"):
                    shutil.copyfile(source, resources / kind / (module + "_" + source.name).replace("-", "_")) if kind == "values" else shutil.copyfile(source, resources / kind / source.name)
        (resources / "xml/snapo_tweaks_inspector.xml").write_text('''<inspector version="1" id="tweaks" name="Tweaks"
            protocolVersion="7" icon="@drawable/snapo_tweaks_inspector_icon"
            frontendAssets="snapo/inspectors/tweaks/frontend.zip" hostApiVersion="1" />''')
        assets = temporary / "assets"
        archive = assets / "snapo/inspectors/tweaks/frontend.zip"
        archive.parent.mkdir(parents=True)
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as frontend:
            frontend.writestr("index.html", '<script type="module" src="./assets/main.js"></script>')
            frontend.writestr("assets/main.js", 'document.body.dataset.fixture = "loaded";')
        Image.new("RGBA", (96, 96), "red").save(resources / "drawable/fixture_icon.png")
        round_icon = Image.new("RGBA", (96, 96))
        ImageDraw.Draw(round_icon).ellipse((0, 0, 95, 95), fill="#00ff00")
        round_icon.save(resources / "drawable/fixture_round.png")
        if options.icon == "adaptive":
            (resources / "drawable-v26").mkdir()
            (resources / "values/fixture_colors.xml").write_text('<resources><color name="fixture_background">#00ff00</color></resources>')
            (resources / "drawable-v26/fixture_icon.xml").write_text('''<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
  <background android:drawable="@color/fixture_background" />
  <foreground android:drawable="@drawable/fixture_foreground" />
</adaptive-icon>''')
            (resources / "drawable/fixture_foreground.xml").write_text('''<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp" android:viewportWidth="108" android:viewportHeight="108">
  <path android:fillColor="#0000ff" android:pathData="M45,45h18v18h-18z" />
</vector>''')
        round_attribute = 'android:roundIcon="@drawable/fixture_round"' if options.icon == "round" else ""
        manifest = temporary / "AndroidManifest.xml"
        manifest.write_text(f'''<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="{package}" android:versionCode="1" android:versionName="1">
  <uses-sdk android:minSdkVersion="24" android:targetSdkVersion="36" />
  <application android:label="Manifest fixture" android:icon="@drawable/fixture_icon" {round_attribute} android:debuggable="false" android:hasCode="false">
    <meta-data android:name="snapo.inspector.network" android:resource="@xml/snapo_network_inspector" />
    <meta-data android:name="snapo.inspector.tweaks" android:resource="@xml/snapo_tweaks_inspector" />
    <activity android:name="android.app.Activity" android:exported="true" />
  </application>
</manifest>''')
        compiled = temporary / "resources.zip"
        unsigned = temporary / "unsigned.apk"
        apk = temporary / "fixture.apk"
        key = temporary / "key.p12"
        run(build / "aapt2", "compile", "--dir", resources, "-o", compiled)
        run(build / "aapt2", "link", "--manifest", manifest, "-I", android, "-A", assets, "-o", unsigned, compiled)
        run(build / "zipalign", "-f", "4", unsigned, apk)
        run(java / "keytool", "-genkeypair", "-keystore", key, "-storepass", "android", "-alias", "fixture", "-keypass", "android", "-keyalg", "RSA", "-validity", "2", "-dname", "CN=Snap-O test")
        run(build / "apksigner", "sign", "--ks", key, "--ks-pass", "pass:android", apk)
        try:
            run(*adb, "install", apk)
            installed = True
            run(*adb, "push", ROOT / "scripts/snapo-discovery.jar", remote)
            run(*adb, "shell", "am", "start", "-W", "-n", package + "/android.app.Activity")
            pid = int(run(*adb, "shell", "pidof", package))
            debug = subprocess.run([*adb, "shell", "run-as", package, "id"], capture_output=True, text=True, timeout=5)
            assert debug.returncode != 0 and "not debuggable" in debug.stderr + debug.stdout
            run(*adb, "shell", "input", "keyevent", "KEYCODE_HOME")
            if options.freeze:
                print(run(*adb, "shell", "am", "freeze", "--sticky", str(pid)), flush=True)
            start = time.perf_counter()
            output = run(*adb, "exec-out", f"CLASSPATH={remote} app_process / com.openai.snapo.discovery.Main snapo_network_{pid} snapo_tweaks_{pid}")
            elapsed = round((time.perf_counter() - start) * 1000)
            records = [json.loads(line) for line in output.splitlines()]
            assert len(records) == 1, records
            info = records[0]
            assert info["pid"] == pid and info["app"]["packageName"] == package, info
            assert info["app"]["name"] == "Manifest fixture", info
            assert not info["app"]["errors"], info
            assert base64.b64decode(info["app"]["iconBase64"]).startswith(b"\x89PNG\r\n\x1a\n")
            icon = Image.open(io.BytesIO(base64.b64decode(info["app"]["iconBase64"]))).convert("RGBA")
            assert icon.size == (96, 96)
            if options.icon == "round":
                assert icon.getpixel((48, 48)) == (0, 255, 0, 255), "Did not prefer the round icon"
                assert icon.getpixel((0, 0))[3] == 0
            elif options.icon == "adaptive":
                assert icon.getpixel((48, 48)) == (0, 0, 255, 255), "Missing adaptive foreground"
                assert icon.getpixel((48, 8)) == (0, 255, 0, 255), "Missing adaptive background"
                assert icon.getpixel((0, 0))[3] == 0
                assert icon.getpixel((8, 8))[3] == 0, "Adaptive mask is not circular"
            else:
                assert icon.getpixel((48, 48)) == (255, 0, 0, 255)
                assert icon.getpixel((0, 0)) == (255, 0, 0, 255), "Legacy icon was cropped"
            descriptors = {entry["id"]: entry for entry in info["app"]["inspectors"]}
            assert set(descriptors) == {"network", "tweaks"}, descriptors
            for kind, protocol in [("network", 3), ("tweaks", 7)]:
                assert descriptors[kind]["protocolVersion"] == protocol, descriptors
                assert base64.b64decode(descriptors[kind]["iconBase64"]).startswith(b"\x89PNG\r\n\x1a\n")
            frontend = descriptors["tweaks"]["frontend"]
            assert frontend == {"assetPath": "snapo/inspectors/tweaks/frontend.zip", "hostApiVersion": 1}
            expected = dict(frontend, processIdentity=info["processIdentity"], androidUserId=info["androidUserId"],
                            packageName=package, revision=info["app"]["revision"], inspectorId="tweaks")
            encoded = base64.b64encode(json.dumps(expected).encode()).decode()
            # exec-out merges stderr into stdout; match the desktop's binary reader command.
            exported = subprocess.run([*adb, "exec-out", f"CLASSPATH={remote} app_process / com.openai.snapo.discovery.FrontendMain snapo_tweaks_{pid} {encoded} 2>/dev/null"],
                                      capture_output=True, timeout=30, check=True).stdout
            assert exported == archive.read_bytes(), "The reader changed the frontend ZIP"
            expected["revision"] = "stale"
            encoded = base64.b64encode(json.dumps(expected).encode()).decode()
            rejected = subprocess.run([*adb, "exec-out", f"CLASSPATH={remote} app_process / com.openai.snapo.discovery.FrontendMain snapo_tweaks_{pid} {encoded} 2>/dev/null"],
                                      capture_output=True, timeout=30)
            assert not rejected.stdout, f"Unexpected stale-package output: {rejected.stdout[:300]!r}"
            assert int(run(*adb, "shell", "pidof", package)) == pid
            if options.freeze:
                processes = run(*adb, "shell", "dumpsys", "activity", "processes", package)
                if "isFrozen=true" not in processes and "frozen=true" not in processes:
                    raise AssertionError("Fixture was not still frozen after discovery:\n" + processes)
            print(f"PASS: non-debuggable {'frozen' if options.freeze else 'background'} app, {options.icon} icon, descriptors and frontend ZIP, {elapsed} ms", flush=True)
        finally:
            if installed:
                run(*adb, "uninstall", package)
            run(*adb, "shell", "rm", "-f", remote)


if __name__ == "__main__":
    main()
