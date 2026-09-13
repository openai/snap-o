---
layout: guide
title: "Command-line inspection \xB7 Snap-O"
description: Install the Snap-O tool CLIs on macOS or Linux, inspect Android network requests,
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

The macOS app bundles `snapo`, a terminal entry point for Network and Tweaks.
Each tool also has a standalone CLI: `snapo-network` and `snapo-tweaks`.
Each requires Python 3, Android Platform Tools, and an Android app with the matching Snap-O integration.
The macOS app does not need to be running.

## Install

### macOS

The app bundles all three executables in `/Applications/Snap-O.app/Contents/MacOS`.
Add that directory to your `PATH`, or use the full executable path:

```bash
export PATH="/Applications/Snap-O.app/Contents/MacOS:$PATH"
snapo network list --json
snapo tweaks apps --json
```

Add the `export` line to your shell configuration to keep it across sessions.
`snapo network` forwards to `snapo-network`; `snapo tweaks` forwards to `snapo-tweaks`.
Both standalone commands also work directly.

### Linux and standalone macOS

Download either CLI, or both, from the `main` branch:

```bash
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/openai/snap-o/main/skills/snap-o-network-inspector/scripts/snapo-network -o ~/.local/bin/snapo-network
curl -fsSL https://raw.githubusercontent.com/openai/snap-o/main/skills/snap-o-tweaks/scripts/snapo-tweaks -o ~/.local/bin/snapo-tweaks
chmod +x ~/.local/bin/snapo-network ~/.local/bin/snapo-tweaks
```

Each CLI is one self-contained Python script. No reader JAR or Python packages are required.

Add `~/.local/bin` to your `PATH` if it is not already there:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Add the same line to your shell configuration to keep it across sessions.

Python API overrides are included in `snapo-network`. No checkout or extra Python package is required.

## ADB configuration

Connect an authorized Android device or emulator and check `adb devices -l`.
Both tools find ADB through `PATH`, `ANDROID_SDK_ROOT`, or `ANDROID_HOME`.
Use `--adb <path>` or `SNAPO_ADB` for a specific executable or wrapper.
For a remote ADB server, pass `--adb-host <host> --adb-port <port>` after the tool name.

## Tool commands

```bash
snapo network --help
snapo tweaks --help
snapo network requests --help
snapo tweaks set --help
```

App listings use process and package names, without friendly labels or icons.
Discovery does not require the Android app to respond; inspecting or changing data does.
Select a listed device and socket with `-s <serial> -n <socket>`.

See [Network inspection](network-inspector.md), [Network interception](network-intercept.md),
and [Tweaks commands](tweaks.md#agents) for tool-specific workflows.
On Linux or standalone macOS, use `snapo-network` or `snapo-tweaks` in place of `snapo network` or `snapo tweaks`.

## Codex plugin

Snap-O includes a Codex plugin for macOS and Linux. Each skill bundles its own Python CLI and requires only Python 3 and Android Platform Tools. Installing either skill individually also includes its executable. Skills call their own CLI directly; they do not require `snapo` or the macOS app.

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
