---
layout: guide
title: "Command-line inspection \xB7 Snap-O"
description: Install the Snap-O CLI on macOS or Linux, inspect Android network requests,
  and use live Tweaks.
styles:
- guide.css
- network-inspector.css
languages:
- bash
breadcrumbs:
- label: Snap-O
  href: index.html
---

# Command-line inspection

The `snapo` Python client inspects network traffic and reads or changes Tweaks on macOS and Linux.
It requires Python 3, Android Platform Tools, and an Android app with the matching Snap-O integration.
The macOS app does not need to be running.

## Install

### macOS

The app bundles the client at `/Applications/Snap-O.app/Contents/MacOS/snapo`.
Use that full path in place of `snapo` below, or add `/Applications/Snap-O.app/Contents/MacOS` to your `PATH`.

### Linux and standalone macOS

Download the standalone script and its Android reader from the `main` branch:

```bash
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/openai/snap-o/main/cli/snapo -o ~/.local/bin/snapo
curl -fsSL https://raw.githubusercontent.com/openai/snap-o/main/plugin-reader/snapo-discovery.jar -o ~/.local/bin/snapo-discovery.jar
chmod +x ~/.local/bin/snapo
```

Add `~/.local/bin` to your `PATH` if it is not already there:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Add the same line to your shell configuration to keep it across sessions.

Python API overrides are included in the same standalone script. No checkout or extra Python package is required.

## ADB configuration

The script supports `snapo network list`, `requests`, and `show`, as well as `snapo tweaks apps`, `list`, `get`, `set`, `action`, `reset`, and `watch`. It resolves `adb` from `PATH`, `ANDROID_SDK_ROOT`, or `ANDROID_HOME`; use `--adb <path>` or `SNAPO_ADB` to select a specific ADB executable or wrapper. By default, server selection is left to the configured ADB command, which normally connects to `127.0.0.1:5037`. Pass `--adb-host <host> --adb-port <port>` to use an explicit remote ADB server.

Verify that ADB can see your Android device, then inspect its available Snap-O servers:

```bash
adb devices -l
snapo network list --json
snapo tweaks apps --json
```

With the default ADB configuration, the CLI opens a localhost forward for the selected `snapo_network_<pid>` or `snapo_tweaks_<pid>` socket and removes it when the command exits. Wrappers selecting a remote ADB server must tunnel that forward back to localhost; otherwise, specify `--adb-host` and `--adb-port`. With an explicit ADB endpoint, the CLI connects through the ADB server directly and does not create a forward. Treat captured bodies, URL query values, and editable tweaks as sensitive.

For slow remote wrappers, `--adb-timeout 90` increases the per-command ADB deadline from its 30-second default. Values must be greater than zero and at most 90 seconds. This deadline is separate from the Python handler's `--timeout`. Repeated shutdown signals leave forward cleanup running until it finishes or reaches the ADB deadline.

## Inspect an app

```bash
snapo network list --json
snapo network requests -s <serial> -n <socket> --no-stream --json
snapo network show -s <serial> -n <socket> -r <request-id> --json
snapo network intercept ./prototype.py -s <serial> -n <socket>
snapo tweaks apps --json
snapo tweaks list -s <serial> -n <socket> --json
snapo tweaks set 'Typography/Font size' 42 -s <serial> -n <socket>
snapo tweaks set 'Motion/Marker shape' RoundedSquare -s <serial> -n <socket>
snapo tweaks reset 'Typography/Font size' -s <serial> -n <socket>
snapo tweaks action 'Motion/Toggle animation' -s <serial> -n <socket>
```

Use the serial and socket returned by `network list` or `tweaks apps` in subsequent commands. For response editing, see [Network Interception](network-intercept.md).

## Bézier curves

Use the CLI bundled with Snap-O 8.0.0 or the script from `main` with an app using the Android 8.0.0 Tweaks libraries.
Pass all four coordinates as one quoted JSON object:

```bash
snapo tweaks set 'Motion/Curve' '{"x1":0.25,"y1":0.1,"x2":0.25,"y2":1}' -s <serial> -n <socket>
snapo tweaks reset 'Motion/Curve' -s <serial> -n <socket>
```

All four coordinates must be finite Float values between 0 and 1, inclusive.
Updates and resets apply to the complete curve. See [Bézier setup](tweaks.md#bezier-curves).

## Previously adjusted Tweaks

Include previously adjusted ordinary or app-owned values even after their owners leave composition or close their `TweakScope`:

```bash
snapo tweaks list --all -s <serial> -n <socket> --json
snapo tweaks get 'Motion/Duration' --all -s <serial> -n <socket> --json
```

The equivalent API is `GET /tweaks?include=adjusted`. Inactive tweaks remain read-only; app-owned history retains a value snapshot, not its source. See the [Tweaks protocol guide](https://github.com/openai/snap-o/blob/main/contracts/tweaks/README.md) for descriptors and updates.

## Codex plugin

Snap-O includes a Codex plugin for macOS and Linux. It bundles skills for network inspection and live Tweaks, along with their shared Python CLI, and requires Python 3 and Android Platform Tools.

Add the Snap-O marketplace and install the plugin:

```bash
codex plugin marketplace add openai/snap-o --ref main
codex plugin add snap-o@snap-o
```

If you previously installed this marketplace with sparse paths, migrate once:

```bash
codex plugin marketplace remove snap-o
codex plugin marketplace add openai/snap-o --ref main
codex plugin add snap-o@snap-o
```

Refresh the marketplace and reinstall the plugin to pick up updates:

```bash
codex plugin marketplace upgrade snap-o
codex plugin add snap-o@snap-o
```

Start a new Codex session after installing or updating the plugin.
