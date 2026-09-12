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

For keyboard shortcuts and ADB setup, see [Using the macOS app](docs/usage.md).

## Screen capture

Drag screenshots and recordings straight into a pull request, chat, or document without saving them first. Play recordings immediately and step through them frame by frame to check an animation. Work with multiple devices and keep captures open in separate windows.

## Network

Inspect HTTP requests and responses, JSON bodies, Server-Sent Events, and WebSocket messages. Snap-O buffers recent traffic on the device, so you can inspect requests made before you opened the tool.

The Android libraries support OkHttp, Ktor's OkHttp engine, and HttpURLConnection. Python handlers can edit or mock HTTP responses through the app's OkHttp connection.

[Set up Network](https://openai.github.io/snap-o/network-inspector.html)

## Tweaks (Alpha)

Change values in Compose, Views, and other Kotlin code without rebuilding or restarting your app. Adjust numbers, colors, booleans, strings, enums, and Bézier curves, or run actions registered by the app.

Use `tweaks-core` and `TweakScope` outside Compose. See [Tweaks without Compose](tools/tweaks/android/core/README.md) for setup and ownership examples.

Tweaks are available through the Tool pane, an optional on-device panel, the CLI, and the REST API. This feature is in alpha; its APIs and behavior may change.

[Set up Tweaks](https://openai.github.io/snap-o/tweaks.html)

## CLI and Codex

The `snapo` CLI supports network inspection, Python response overrides, and Tweaks on macOS and Linux. It requires Python 3 and Android Platform Tools and can run independently of the macOS app.

On macOS, the app includes the CLI:

```bash
/Applications/Snap-O.app/Contents/MacOS/snapo network list --json
```

The Codex plugin bundles the CLI with skills for network inspection and Tweaks:

```bash
codex plugin marketplace add openai/snap-o --ref main
codex plugin add snap-o@snap-o
```

Start a new Codex session after installation.

[CLI setup and commands](docs/cli.md) · [Linux installation](docs/cli.md#linux-and-standalone-macos) · [Plugin updates](docs/cli.md#codex-plugin)

## Plugins

Apps bundle tool plugins that provide tools for inspecting data, changing settings, and running actions. A tool plugin includes its Android implementation and an optional frontend. Snap-O displays the selected tool’s frontend in the Tool pane. Network and Tweaks use the same extension model as custom tools.

Start with [Build a tool plugin](docs/plugins.md) and the [Tool plugin API reference](docs/plugin-api.md). See [tool plugin development](tools/README.md) for repository commands and host behavior.

## Build from source

Requires Xcode 26 or later and Android Platform Tools.

1. Clone this repository.
2. Open `app-macos/Snap-O.xcodeproj` in Xcode, then build and run.

Tool plugin frontend development also requires Node.js 22.12 or later. See [tool plugin development](tools/README.md).

See [Contributing](CONTRIBUTING.md) for development and signing instructions, and [Release requirements](release/README.md) for release checks.

## Contributing

Snap-O is maintained as time allows, with no formal roadmap. [Bug reports](https://github.com/openai/snap-o/issues) and small patches are welcome. Read the [contribution guide](CONTRIBUTING.md) and [code of conduct](CODE_OF_CONDUCT.md) before contributing.

## License

[Apache 2.0](LICENSE). Copyright 2025 OpenAI.
