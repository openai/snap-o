# Contributing to Snap-O

Thank you for considering contributing to Snap-O! We welcome improvements, bug fixes, and new features.

## Getting Started

1. Fork the repository on GitHub.
2. Clone your fork:
   ```bash
   git clone https://github.com/<your-username>/snap-o.git
   cd snap-o
   ```
3. Create a feature branch:
   ```bash
   git checkout -b feature/YourFeatureName
   ```

## Repository layout

| Folder | Purpose |
| --- | --- |
| `app-macos/` | Native app, device transport, and Xcode tests |
| `skills/` | Standalone Python CLIs and installable skills |
| `tools/` | Network and Tweaks implementations, each with `android/`, `frontend/`, and `cli/` tests |
| `tool-sdk/` | Plugin authoring APIs, runtime, and Gradle integration |
| `tool-reader/` | Android APK metadata and frontend asset reader |
| `examples/` | Demo apps, an independent plugin, and CLI examples |
| `contracts/` | Protocol definitions and shared fixtures |
| `docs/` | Documentation sources, theme, and tests |
| `build-logic/`, `gradle/` | Internal build conventions and Gradle wrapper configuration |
| `release/` | Release checks and authoring validation |
| `skills/` | Codex plugin skills |

Open the repository root in Android Studio. Gradle downloads Node.js and uses its bundled npm to build the tool frontends. No local Node installation is needed for Android builds. Run `./gradlew` from the repository root; published Android artifact names are independent of folder names.

### macOS source layout

The app stays in one Xcode target. Folders group code by responsibility; they do
not add modules or change which objects own resources.

| Folder under `app-macos/Snap-O/` | What belongs here |
| --- | --- |
| `App/` | Startup, app lifetime, commands, and window creation |
| `Workspace/` | Window composition, toolbar, pane layout, and sizing |
| `Capture/` | Capture-pane navigation and service assembly |
| `Capture/Operations/` | Capture batches, screenshots, and recordings |
| `Capture/Review/` | Review selection, playback, cropping, and trimming |
| `Capture/Export/` | Export requests and edited-media output |
| `LivePreview/` | Shared preview ownership and window attachments |
| `LivePreview/Input/` | Keyboard, pointer, clipboard, file drops, and device controls |
| `LivePreview/Rendering/` | Frame delivery, rendering, and thumbnails |
| `LivePreview/Views/` | Preview presentation and controls |
| `Device/` | Connections, ADB, emulator transport, and temporary device settings |
| `DeviceManager/` | Device inventory, open requests, and management UI |
| `History/` | Saved capture collection and its window |
| `Tools/` | Tool sessions, web content, and plugin presentation |
| `Storage/` | File storage and staged-file ownership |
| `Models/`, `UI/`, `Utilities/` | Data, UI, and small helpers shared across features |

Keep feature-specific views beside their feature. Use `UI/` for shared views,
not as a second home for capture or preview code. Name files after their main
type. Keep private helpers with their owner when splitting them would expose
internal APIs.

Test folders describe how tests run:

- `Snap-OUnitTests/`: headless Xcode tests, grouped by feature.
- `Snap-OIntegrationTests/`: tests hosted by the app, grouped by feature.
- `StandaloneTests/`: separate harnesses compiled by scripts. Each harness keeps
  its own entry point and fakes; some require an app or real device.

See [native test selection](app-macos/StandaloneTests/README.md#local-test-selection)
before running tests that may open windows.

### macOS build configurations

The shared macOS scheme uses the `Local` configuration for Run, Test, and Analyze.
It keeps app, helper, and test code unoptimized, with `DEBUG`, debug symbols,
and testability enabled. Swift package dependencies use Release optimization,
which improves emulator preview throughput. Initial dependency builds take longer,
and stepping through dependency code is less precise.

The configuration name matters: Xcode maps `Local` to Release for Swift packages.
Keep the app's Debug settings when editing this configuration. Use `Debug` instead
when debugging dependency internals. Profile and Archive still use `Release`.
Code coverage is off by default; enable it in the scheme when collecting coverage.

Debug and Local builds support ADB startup and emulator operations without an
Apple signing certificate. These builds skip the helper's signing checks and
launch constraints, while keeping its same-user check.

Release builds require the app and helper to be signed by the same Apple developer
team. Copy `app-macos/Config/Signing.xcconfig.sample` to `Signing.xcconfig` in the
same folder and set your team and signing identity. The file is ignored by Git.

Run headless unit tests with:

```sh
cd app-macos
xcodebuild -project Snap-O.xcodeproj -scheme Snap-OUnitTests -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test
```

### Testing remote ADB servers

Use **Device → ADB Servers…** or **Manage Servers…** in Device Manager to add,
edit, or remove SSH servers. Profiles are saved locally and always reconnect
when Snap-O starts. The remote server must already run ADB on its loopback
address and have a connected device. SSH uses the configured destination and
optional port; the remote ADB port defaults to 5037.

All builds start with no remote profiles. Add servers through the ADB Servers
window. Removing a server keeps it removed after relaunch. Saved profiles identify
their connection type.

Snap-O reads the existing SSH configuration and uses noninteractive authentication.
Its host helper owns a separate SSH connection and forwards ADB through a private
Unix socket. The app receives connected sockets through authenticated XPC; no
local TCP port exposes the remote ADB server.
It reconnects after failures and closes its forward when Snap-O quits. Existing
SSH sessions and manually created forwards are unaffected.

Device selection and tool references distinguish devices from different servers, even with identical
serials. Device links may specify `server=local` or the configured remote server's
UUID alongside `serial`. Serial-only links require an unambiguous match.

## Making Changes

- Follow the existing Swift style and code conventions.
- Write clear, concise commit messages.
- Include documentation updates when adding or changing functionality.
- Follow [the release requirements](release/README.md) when changing protocols, published APIs, versioning, or packaging.

### macOS Swift Tooling

The macOS app pins SwiftFormat and SwiftLint in `app-macos/mise.toml`. Install the repo-owned tool versions once, then use the shared `mise` tasks so local checks match CI:

```bash
cd app-macos
mise trust
mise install
mise run format
mise run lint
```

To update the pinned tools intentionally, bump the versions in `app-macos/mise.toml` and rerun `mise install` plus `mise run lint`.

## Documentation

Edit public guides in `docs/`. See [Documentation sources](docs/README.md) for setup, preview, and validation commands. The HTML on `gh-pages` is generated from these files.

## Notarizing or shipping builds

For release preparation and acceptance checks, see [Release requirements](release/README.md).

If you need to notarize the app yourself:

1. Copy `app-macos/Config/Signing.xcconfig.sample` → `app-macos/Config/Signing.xcconfig`.
2. Edit the new file with your Apple Developer Team ID and signing certificate name.
3. Use Xcode's Product → Archive flow, then distribute or upload as usual. The file is ignored by Git, so your credentials remain private.

## Pull Requests

1. Push your changes to your fork:
   ```bash
   git push origin feature/YourFeatureName
   ```
2. Open a pull request against the `main` branch.
3. Address any review comments and ensure the CI pipeline passes.

## Reporting Issues

If you encounter bugs or have feature requests, please open an issue. See [ISSUE_TEMPLATE/bug_report.md](.github/ISSUE_TEMPLATE/bug_report.md) or [ISSUE_TEMPLATE/feature_request.md](.github/ISSUE_TEMPLATE/feature_request.md).
