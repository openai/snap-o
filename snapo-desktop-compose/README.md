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

The distributed `Snap-O.app` bundle includes a `snapo` launcher at `Contents/MacOS/snapo`:

```bash
SNAPO_APP="/Applications/Snap-O.app"
SNAPO_CLI="$SNAPO_APP/Contents/MacOS/snapo"
snapo() { "$SNAPO_CLI" "$@"; }

snapo network list
snapo network list --json
snapo network list --no-app-info
snapo network requests -e -n snapo_server_12345
snapo network requests -s emulator-5554 -n snapo_server_12345 --json
snapo network requests -d --no-stream
snapo network show -e -n snapo_server_12345 -r <requestId>
snapo network show -s emulator-5554 -n snapo_server_12345 -r <requestId> --json
```

For local development only, you can still invoke the same CLI entrypoint via Gradle:
`./gradlew run --args='network list'`

By default, commands print human-readable output.
Use `--json` for machine-readable NDJSON output.

`network requests` emits CDP network messages in `--json` mode.
`network show` prints request/response headers plus request/response bodies for one request id.
Sensitive headers are redacted by default (`Authorization`, `Cookie`, `Set-Cookie`).
`network list` includes package and app metadata by default.
Use `--no-app-info` to skip metadata lookup.
`-n/--socket` is optional when exactly one Snap-O socket is available for the selected device scope.

## Package (release)

Release packaging is handled by `snapo-app-mac`. Follow its packaging instructions (if present) since that build embeds this helper app alongside Snap-O.

That being said, it can be tested with `./gradlew create(Release)Distributable`
