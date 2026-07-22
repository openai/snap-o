[![Download Snap-O for macOS](https://img.shields.io/github/v/release/openai/snap-o?label=Download%20for%20macOS&color=brightgreen)](https://github.com/openai/snap-o/releases/latest/download/Snap-O.dmg)

<p>
  <img src=".github/banner.webp" width="640" alt="Snap-O: Fast. Focused. Effortless.">
</p>

# Snap-O: Android Inspection System

Snap-O is a fast, tidy macOS app for Android inspection: capture screenshots and recordings, and inspect network traffic from Android devices and emulators.

It runs on macOS 15 or later and requires `adb` from the Android Platform Tools.

## Top-Level Features

- **Network Inspector:** Mirror app traffic into the macOS client, inspect requests and responses, and explore payloads with collapsible JSON pretty printing. Start with the [Network Inspector guide](https://openai.github.io/snap-o/network-inspector.html).
- **Screen Capture:** Grab screenshots and screen recordings quickly, preview recordings instantly, and drag captures directly into PRs, chat, and docs without save-first friction.

## Network Inspector

Curious about mirroring app traffic into the macOS client? Check the [Network Inspector guide](https://openai.github.io/snap-o/network-inspector.html) for setup steps, dependency coordinates, and configuration tips.

Snap-O can replay network requests that happened before you opened Snap-O, so you do not miss early events, and includes collapsible JSON pretty printing.

## Why build an Android inspection system?

Capturing visuals and validating traffic for teammates or pull requests adds many small paper cuts.
You might like Snap-O if you've ever wished you could:

- Share screenshots and recordings without littering your disk with throwaway files
- Preview a recording instantly without saving it first
- Scrub frame by frame to confirm an animation behaves as expected
- Use something that feels faster than the default capture tools

I've built variations of this tool a few times over the last decade; this is the first one
I'm open-sourcing.

## Screen Capture Features

- Shows a screenshot the moment the window opens
- Instantly preview screen recordings, and step through frame-by-frame.
- Lets you drag and drop captures anywhere without saving them first
- Multi-device support
- Supports multiple windows of captures at once
- Keeps your disk uncluttered by cleaning up after itself
- Integrates with Android Studio External Tools

## Usage

1. Connect an Android device with USB debugging enabled or start an emulator
2. Launch Snap-O
3. Enjoy the immediate screenshot
4. `⌘R` to refresh the screenshot. `⇧⌘R` to start a screen recording.

### ADB Selection (optional)

Snap-O talks to the ADB server directly without running `adb`.

If the ADB server is not running, Snap-O asks you to pick your `adb` binary so it can restart the server for you.

Note: Snap‑O uses the macOS Hardened Runtime. It will run the `adb` binary you select, so always choose a trusted `adb` from the official Android Platform Tools.

### Drag and Drop

After you capture a screenshot or screen recording, you can drag and drop it without saving first. Drop the capture straight into a GitHub pull request, a Slack message, or any app that accepts images and video.

### Keyboard Shortcuts

| Action                   | Shortcut |
|--------------------------|----------|
| New screenshot           | `⌘R`     |
| Start recording          | `⇧⌘R`    |
| Start live preview       | `⇧⌘L`    |
| Stop recording / preview | `⎋`      |
| Save as                  | `⌘S`     |
| Copy image to clipboard  | `⌘C`     |
| Previous device          | `⌘[`     |
| Next device              | `⌘]`     |

### Android Studio External Tools

Use Android Studio’s External Tools to trigger Snap-O directly from the IDE.

1. In Android Studio, open `Settings` → `Tools` → `External Tools` (or `Preferences` on macOS).
2. Click `+` and add a new tool named "Snap-O Screenshot".
   - Program: `open`
   - Arguments: `snapo://capture`
3. Repeat to add "Snap-O Recording" with the same Program and the Arguments `snapo://record`.
4. The new tools appear under `Tools` → `External Tools`.
5. Assign keymap shortcuts if you like, e.g. `⇧⌘S` to activate a screenshot.

Running these tools launches Snap-O (or brings it to the foreground) and immediately starts a capture or recording.

There is currently no support for choosing a specific device/emulator when starting Snap-O in this way.

### Command Line Network Inspector

Snap-O bundles a small Python command-line client at:

```bash
/Applications/Snap-O.app/Contents/MacOS/snapo
```

It uses the host computer's configured `adb` command, requires Python 3, and does not require the Snap-O app to be running.

```bash
snapo network list --json
snapo network requests -s <serial> -n <socket> --no-stream --json
snapo network show -s <serial> -n <socket> -r <request-id> --json
```

## Why a web UI for the Network Inspector?

The Network Inspector uses a React UI hosted in the macOS app's system WebKit runtime. Native Swift code handles ADB and network transport through the host computer's existing ADB server, so the distribution does not include Chromium, Node.js, or another ADB executable. The same UI can also run in a browser through its HTTP transport.

The screenshot tool remains in SwiftUI because it delivers a better macOS experience for video playback today. Snap-O uses AVKit because it gives a polished video player on macOS and keeps the download small. VLC-based playback felt clunky and the viewing experience suffered.

## Alternatives

Snap-O currently has only basic "Live Preview" support.

For a more feature-rich live preview, take a look at [scrcpy](https://github.com/Genymobile/scrcpy).

## Project status

Snap-O is a small side project kept alive when time allows. If it works for you, great! If it doesn't, feel free to open an issue or fork it to fit your needs.

## Building from source

The macOS app requires Xcode 16 or later.

1. Install the Android Platform Tools (via Android Studio or `brew install android-platform-tools`).
2. Open `Snap-O.xcodeproj` in Xcode.
3. Build and run.

### Notarizing or shipping builds

If you need to notarize the app yourself:

1. Copy `Config/Signing.xcconfig.sample` → `Config/Signing.xcconfig`.
2. Edit the new file with your Apple Developer Team ID and signing certificate name.
3. Use Xcode's Product → Archive flow, then distribute or upload as usual. The file is ignored by Git, so your credentials remain private.

## Codex Plugin

Snap-O includes a Codex plugin for macOS and Linux. It bundles the network-inspector skill and its Python CLI, and requires Python 3 and Android Platform Tools.

Add the Snap-O marketplace and install the plugin:

```bash
codex plugin marketplace add openai/snap-o --ref main \
  --sparse .agents/plugins \
  --sparse .codex-plugin \
  --sparse skills
codex plugin add snap-o@snap-o
```

Refresh the marketplace and reinstall the plugin to pick up updates:

```bash
codex plugin marketplace upgrade snap-o
codex plugin add snap-o@snap-o
```

Start a new Codex session after installing or updating the plugin.

## Linux Support

You can inspect network requests from Snap-O on a Linux machine by using the `snapo` Python CLI tool:

https://github.com/openai/snap-o/releases/latest/download/snapo

This CLI tool is also shipped as part of the macOS app at `Snap-O.app/Contents/MacOS/snapo`.

The dependency-free script is also available at `skills/snap-o-network-inspector/scripts/snapo`. Install Python 3 and Android Platform Tools, then put it on `PATH`:

```bash
mkdir -p ~/.local/bin
install -m 0755 skills/snap-o-network-inspector/scripts/snapo ~/.local/bin/snapo
```

The script supports `snapo network list`, `requests`, and `show`. It resolves `adb` from `PATH`, `ANDROID_SDK_ROOT`, or `ANDROID_HOME`; use `--adb <path>` or `SNAPO_ADB` to select a specific ADB executable or wrapper. By default, server selection is left to the configured ADB command, which normally connects to `127.0.0.1:5037`. Pass `--adb-host <host> --adb-port <port>` to use an explicit remote ADB server.

Verify that ADB can see your Android device, then inspect its available Snap-O servers:

```bash
adb devices -l
snapo network list --json
```

With the default ADB configuration, the CLI opens a localhost forward for the selected `snapo_network_<pid>` socket and removes it when the command exits. With an explicit ADB endpoint, it connects through the ADB server directly and does not create a forward. Treat captured bodies and URL query values as sensitive.

## Community

Bug reports and small patches are welcome, but there is no formal roadmap. If
you do decide to contribute, please take a quick look at
[CONTRIBUTING.md](CONTRIBUTING.md) and the
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## License

This project is licensed under the Apache License 2.0, Copyright 2025 OpenAI. See the [LICENSE](LICENSE) file for details.
