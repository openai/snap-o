---
name: snap-o-network-inspector
description: Fetch and inspect Android network captures for a selected device/socket using the Snap-O CLI. Use when you need raw CDP request/response data, headers, bodies, status, or websocket events.
---

# Snap-O Network Inspector

Use this skill to pull raw network evidence from Snap-O.

## CLI Path

Use the Python CLI bundled in this skill's `scripts` directory:

```bash
SNAPO_BIN=/path/to/snap-o-network-inspector/scripts/snapo
```

Resolve the path relative to the directory containing this `SKILL.md`. The script requires Python 3 and Android Platform Tools; no Python packages, compiler toolchain, or macOS application are required.

The script resolves `adb` from `PATH`, `ANDROID_SDK_ROOT`, or `ANDROID_HOME`. Use `--adb <path>` or `SNAPO_ADB` to select a specific ADB executable or wrapper.

## Current Command Surface

- `snapo network list`: lists available Snap-O Network Inspector servers.
- `snapo network requests`: emits CDP network events for a server.
- `snapo network show`: shows full details for a request id, including headers and bodies.

Useful global selectors:

- `-s`, `--serial`: use a specific device serial.
- `-d`: use the single connected USB device.
- `-e`: use the single connected emulator.
- `--adb`: use a specific ADB executable or wrapper.
- `--adb-host`, `--adb-port`: connect directly to an explicit remote ADB server; otherwise the configured ADB command selects its endpoint.

## Core Flow

1. List available servers.

```bash
"$SNAPO_BIN" network list --json
```

For a remote ADB endpoint, append `--adb-host <host> --adb-port <port>` to `list`, `requests`, or `show`; the script uses the ADB server directly. Otherwise, its localhost forward is removed automatically when the command exits.

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
