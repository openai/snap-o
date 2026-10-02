# AGENTS.md

For automated contributors:

- This app targets macOS 26+ ONLY.
- Do not use ellipses in status messages shown in the capture pane.
- Follow the existing style. Defer to the repo configs:
  - SwiftLint: `.swiftlint.yml`
  - SwiftFormat: `.swiftformat`
- Never add a `deinit`; rely on SwiftUI/Observation lifecycle instead.
- Never run `git` commands; leave version control to the user.
- Do not modify these config files without explicit approval. If a change is needed, propose it with a short rationale in a separate PR (or commit) so it’s easy to review and doesn’t mix with code changes.
- Select local checks by the behavior changed. Build code changes, lint changed Swift files, and default to `Snap-OUnitTests` for tests without an app host. See [Local test selection](Tests/README.md#local-test-selection).
- Run tests that launch apps or open windows locally only when the user explicitly requests or approves them. The `Snap-OIntegrationTests` scheme launches Snap-O, even with a test filter; some standalone scripts also open windows.
- Add independent logic tests to `Snap-OUnitTests`. Keep app, window, and real transport tests in `Snap-OIntegrationTests` or an explicit standalone integration script.
- Leave the full native suite to CI in `.github/workflows/mac.yml`, including its standalone scripts. Report local checks performed and any deferred coverage. Do not repeat successful checks unless relevant code, dependencies, or build inputs change.
- When changing dependencies, update the tracked `Package.resolved` and compare CI build times with and without a compiler cache. Local incremental builds do not measure fresh-runner cost.
- To build the app, use `xcodebuild`:
  ```sh
  xcodebuild -project Snap-O.xcodeproj \
             -scheme Snap-O \
             CODE_SIGNING_ALLOWED=NO \
             CODE_SIGNING_REQUIRED=NO \
             build
  ```
