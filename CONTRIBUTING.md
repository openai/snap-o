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
| `cli/` | Python CLI and tests |
| `tools/` | Network and Tweaks implementations, each with `android/` and `frontend/` |
| `tool-sdk/` | Plugin authoring APIs, runtime, and Gradle integration |
| `tool-reader/` | Android APK metadata and frontend asset reader |
| `examples/` | Demo apps, an independent plugin, and CLI examples |
| `contracts/` | Protocol definitions and shared fixtures |
| `docs/` | Documentation sources, theme, and tests |
| `build-logic/`, `gradle/` | Internal build conventions and Gradle wrapper configuration |
| `release/`, `scripts/` | Release checks and contributor utilities |
| `skills/` | Codex plugin skills |

Open the repository root in Android Studio. Run `./gradlew` from that root; published Android artifact names are independent of folder names.

The macOS app owns its device code under `Snap-O/Device/`. Run its unit tests with:

```sh
cd app-macos
xcodebuild -project Snap-O.xcodeproj -scheme Snap-O -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test
```

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
