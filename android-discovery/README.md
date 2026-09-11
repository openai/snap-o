# Android resource reader

Snap-O reads inspector descriptors and icons from installed APK resources. The reader runs as the ADB shell in its own process. It does not start the inspected app or connect to its inspector sockets. Non-debuggable and frozen apps are supported.

Each socket uses `snapo_<id>_<pid>`. The reader resolves the PID's package and Android user, then reads the `snapo.inspector.<id>` manifest entry. See the [discovery contract](../contracts/discovery/README.md).

Each metadata read uploads the reader into a private temporary directory under `/data/local/tmp`. It runs from that directory, then removes the reader and directory on exit. Concurrent desktop and CLI reads cannot replace each other's helper. Metadata caching avoids uploads during ordinary socket polling.

The desktop caches successful reads until a new or replaced socket requires a refresh. Failed reads retry after 30 seconds. A refresh includes every visible inspector in the affected process.

Pass up to 64 socket names to `com.openai.snapo.discovery.Main` through `app_process`. The reader returns one JSON line per process. It reads up to four processes concurrently and shares each package's resources within the invocation. Each line contains either package and inspector metadata or an error for that PID. Icons are 96-pixel PNGs encoded as base64.

App icons prefer the manifest's `android:roundIcon`. Adaptive app icons use a circular mask; legacy icons keep their original shape. Inspector descriptor icons are unchanged. Round-icon selection reads Android's optional `ApplicationInfo.roundIconRes` field and falls back to the normal package icon if that field or resource cannot be read.

## Frontend asset reader

`com.openai.snapo.discovery.FrontendMain` is a separate entry point in the same JAR. It accepts one inspector socket name and a base64-encoded JSON object identifying the expected process, package revision, and frontend descriptor. It reads the ZIP named by the descriptor through Android's asset API and returns the unchanged ZIP bytes on standard output. Diagnostics go to standard error.

The tool verifies the selection before reading and checks process identity and package revision again afterward. It rejects compressed archives larger than 16 MiB. The desktop validates ZIP entries and expanded size before loading the frontend. Discovery does not fetch ZIPs, and the Android inspector HTTP server does not serve frontend assets.

## Build

Install JDK 17, Android SDK platform 36, and build-tools 36.0.0. Set `JAVA_HOME` and `ANDROID_HOME` as needed, then run:

```sh
python3 android-discovery/build.py
python3 android-discovery/build.py --check
```

The reproducible output is `scripts/snapo-discovery.jar`. It is checked in so desktop and CLI users do not need Java or an Android SDK. Keep this file beside the standalone CLI when distributing it. The macOS app bundles it under `Contents/Resources`, outside the directory for signed executables. The reader adds no dependencies to inspected Android apps.

## Device test

The pixel checks require Pillow (`python3 -m pip install Pillow`).

```sh
python3 android-discovery/test-device.py --serial DEVICE --freeze --icon round
python3 android-discovery/test-device.py --serial DEVICE --freeze --icon adaptive
python3 android-discovery/test-device.py --serial DEVICE --freeze --icon legacy
```

The test installs a temporary non-debuggable APK containing both library descriptors. It verifies metadata, icon selection, and rendered pixels while the app is frozen, then removes the fixture and reader. `--freeze` requires an Android version supporting `am freeze`; omit it to test normal background execution. Adaptive-icon checks require API 26 or newer. Only the temporary fixture is frozen.

Framework startup and user-context creation use reflected Android framework methods because `app_process` is a shell entry point, not an installed Android component. Package and resource reads use `PackageManager`. Test supported Android versions when changing this boundary. Errors must leave discovery rows visible and must not fall back to starting the app.
