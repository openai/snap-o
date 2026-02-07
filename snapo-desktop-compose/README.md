# Snap-O Desktop (Compose)

This is a macOS-only Compose Desktop implementation of Snap-O’s **Network Inspector**.

Important: this app is expected to be packaged alongside the Xcode-built Snap-O app in `snapo-app-mac`. It is not shipped as a standalone product. The Kotlin Multiplatform implementation is packaged as a separate app for now because it was simpler to build and embed, so Snap-O acts as the host app and includes Network Inspector as a helper app.

However, a user could open up the Network Inspector app directly if they want.

Scope (for now):
- Network Inspector only (requests, responses, SSE, WebSockets)
- No screenshot / recording / live preview windows

## Requirements

- macOS (but it's practically cross-platform)
- A running local ADB server (`adb start-server`)
- At least one connected device/emulator running an app that includes the Snap-O link dependencies

See the developer guide: https://github.com/openai/snap-o/blob/main/docs/network-inspector.md

## Run for development

```bash
cd snapo-desktop-compose
./gradlew run
```

## CLI (experimental)

The desktop app now supports CLI mode when arguments are provided.

```bash
cd snapo-desktop-compose
./gradlew run --args='network list'
./gradlew run --args='network list --json'
./gradlew run --args='network list --include-app-info'
./gradlew run --args='network requests emulator-5554/snapo_server_12345'
./gradlew run --args='network requests emulator-5554/snapo_server_12345 --json'
./gradlew run --args='network requests emulator-5554/snapo_server_12345 --no-stream'
./gradlew run --args='network response-body <requestId>'
./gradlew run --args='network response-body <requestId> --json'
```

By default, commands print human-readable output.
Use `--json` for machine-readable NDJSON output.

`network requests` emits CDP network messages in `--json` mode.
Sensitive headers are redacted by default (`Authorization`, `Cookie`, `Set-Cookie`).
`network list --include-app-info` also emits `packageName` and `appName` (process name) if available.

## Package (release)

Release packaging is handled by `snapo-app-mac`. Follow its packaging instructions (if present) since that build embeds this helper app alongside Snap-O.

That being said, it can be tested with `./gradlew create(Release)Distributable`
