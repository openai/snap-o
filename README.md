[![Download Snap-O for macOS](https://img.shields.io/github/v/release/openai/snap-o?label=Download%20for%20macOS&color=brightgreen)](https://github.com/openai/snap-o/releases/latest/download/Snap-O.dmg)

<p>
  <img src=".github/banner.webp" width="640" alt="Snap-O: Fast. Focused. Effortless.">
</p>

Snap-O is a handy macOS app for inspecting Android apps. Capture screenshots and recordings, inspect network traffic, override responses, and adjust app values while your app runs.

[Documentation](https://openai.github.io/snap-o/)

## Get started

Requires macOS 26 or later and `adb` from Android Platform Tools.

If you don't already have `adb`, install Android Platform Tools through Android Studio or `brew install android-platform-tools`.

1. [Download Snap-O](https://github.com/openai/snap-o/releases/latest/download/Snap-O.dmg) and move it to Applications.
2. Connect a device with USB debugging enabled, or start an emulator.
3. Open Snap-O. Live Preview starts automatically. Option-drag the preview to share a screenshot, or press `⇧⌘R` to record.

Screen capture needs no library in your Android app. Network and Tweaks each require an Android integration; follow the guides below.

For capture controls and keyboard shortcuts, see the [Screen capture guide](docs/screen-capture.md).

## Screen capture

Snap-O automatically keeps screenshots and recordings in Capture History, including across app restarts. Open **Window → Capture History** (`⇧⌘H`) to browse captures by day and reopen them. Captures from multiple devices stay grouped together.

Drag screenshots and recordings straight into a pull request, chat, or document. Play recordings immediately and step through them frame by frame to check an animation. Work with multiple devices and keep captures open in separate windows.

History keeps captures for 30 days by default, with a 5 GB storage limit. Change these limits in **History Storage**, or use **Save As…** (`⌘S`) to keep a permanent copy.

[Capture History and storage](docs/screen-capture.md#capture-history)

## Network

Inspect HTTP requests and responses, JSON bodies, Server-Sent Events, and WebSocket messages. Snap-O buffers recent traffic on the device, so you can inspect requests made before you opened the tool.

The Android libraries support OkHttp, Ktor's OkHttp engine, and HttpURLConnection. Python handlers can edit or mock HTTP responses through the app's OkHttp connection.

[Set up Network](https://openai.github.io/snap-o/network-inspector.html)

## Tweaks

Change values in Compose, Views, and other Kotlin code without rebuilding or restarting your app. Adjust numbers, colors, booleans, strings, enums, and Bézier curves, or run actions registered by the app.

Use `tweaks-core` and `TweakScope` outside Compose. See [Tweaks without Compose](tools/tweaks/android/core/README.md) for setup and ownership examples.

Tweaks are available through the Tool pane, an optional on-device panel, the CLI, and the REST API.

[Set up Tweaks](https://openai.github.io/snap-o/tweaks.html)

## CLI and Codex

Network and Tweaks each have a standalone CLI and a Codex skill for macOS and Linux. They require Python 3, Android Platform Tools, and the matching Android integration. The macOS app does not need to be running.

See the feature guides for CLI setup and links to each skill:

- [Network CLI](docs/network-inspector.md#cli) · [Network skill](docs/network-inspector.md#agents)
- [Tweaks CLI](docs/tweaks.md#cli) · [Tweaks skill](docs/tweaks.md#agents)

## Plugins

Android apps bundle tool plugins that provide tools for inspecting data, changing settings, and running actions. A tool plugin includes its Android implementation and an optional frontend. Snap-O displays the selected tool’s frontend in the Tool pane; the Mac app does not bundle tool frontends. Network and Tweaks use the same extension model as custom tools.

Start with [Build a tool](docs/plugins.md). See [tool development](tools/README.md) for repository commands and host behavior.

## Build from source

Requires Xcode 26 or later and Android Platform Tools.

1. Clone this repository.
2. Open `app-macos/Snap-O.xcodeproj` in Xcode, then build and run.

Gradle downloads Node.js and npm when building the Android tool frontends. Direct frontend checks still require a local Node installation. See [tool development](tools/README.md).

See [Contributing](CONTRIBUTING.md) for development and signing instructions, and [Release requirements](release/README.md) for release checks.

## Contributing

Snap-O is maintained as time allows, with no formal roadmap. [Bug reports](https://github.com/openai/snap-o/issues) and small patches are welcome. Read the [contribution guide](CONTRIBUTING.md) and [code of conduct](CODE_OF_CONDUCT.md) before contributing.

## License

[Apache 2.0](LICENSE). Copyright 2025 OpenAI.
