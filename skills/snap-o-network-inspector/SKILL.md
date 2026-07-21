---
name: snap-o-network-inspector
description: Fetch and inspect Android network captures for a selected device/socket using the Snap-O CLI. Use when you need raw CDP request/response data, headers, bodies, status, or websocket events.
---

# Snap-O Network Inspector

Use this skill to pull raw network evidence from Snap-O.

## CLI Path

Use the bundled macOS script:

```bash
SNAPO_BIN=/Applications/Snap-O.app/Contents/MacOS/snapo
```

If Snap-O is not installed at that path, recommend installing it from:
https://openai.github.io/snap-o/

On Linux, use the installed script:

```bash
SNAPO_BIN="$(command -v snapo)"
```

If it is not installed, use this repository's `scripts/snapo` directly or install it on `PATH`. It requires Python 3 and Android Platform Tools; no Python packages or compiler toolchain are required.

The script resolves `adb` from `PATH`, `ANDROID_SDK_ROOT`, or `ANDROID_HOME`. Use `--adb <path>` or `SNAPO_ADB` to select a configured ADB/Namespace shim explicitly.

## Current Command Surface

- `snapo network list`: lists available Snap-O Network Inspector servers.
- `snapo network requests`: emits CDP network events for a server.
- `snapo network show`: shows full details for a request id, including headers and bodies.

Useful global selectors:

- `-s`, `--serial`: use a specific device serial.
- `-d`: use the single connected USB device.
- `-e`: use the single connected emulator.
- `--adb`: use a specific ADB executable or Namespace shim.
- `--adb-host`, `--adb-port`: connect directly to an explicit remote or tunneled ADB server; otherwise the configured ADB/shim selects its endpoint.

## Core Flow

1. List available servers.

```bash
"$SNAPO_BIN" network list --json
```

For a remote ADB endpoint, append `--adb-host <host> --adb-port <port>` to `list`, `requests`, or `show`; the script uses the ADB smart socket directly. With a configured Namespace shim, omit those flags so its Snap-O forward is opened on an explicit localhost port and removed automatically on exit.

Use `--no-app-info` to skip package and app metadata lookup.

2. Pick a target serial and socket. If multiple devices or sockets are available, select them explicitly.

3. Pull captured events.

```bash
"$SNAPO_BIN" network requests -s <serial> -n <socket_name> --filter '<url-filter>' --no-stream --json
```

`--filter` uses the same case-insensitive URL syntax as the Network Inspector search bar. Separate terms must all match, a term prefixed with `-` is excluded, and quotes or backslashes can escape whitespace.

`network requests` replaces request `Authorization` and `Cookie` values and response `Set-Cookie` values with `[REDACTED]`.

4. Inspect one request deeply when full request or response details are required.

```bash
"$SNAPO_BIN" network show -s <serial> -n <socket_name> -r <request_id> --json
```

This output can contain URL query values and request or response bodies.

5. Re-check command help if output differs.

```bash
"$SNAPO_BIN" --help
"$SNAPO_BIN" network --help
"$SNAPO_BIN" network list --help
"$SNAPO_BIN" network requests --help
"$SNAPO_BIN" network show --help
```

## Output Notes

- `--json` emits NDJSON, so process it line by line.
- `network requests` emits Chrome DevTools Protocol-style records with top-level `method` and `params` fields.
- Use `--no-stream` for a one-shot buffered snapshot.
- The Android transport admits clients with `HelloSnapO`, returns `SnapO.appInfo`, and gates delivery with `SnapO.startStream` and `SnapO.stopStream`.
