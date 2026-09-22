# AGENTS.md

For automated contributors:

- This app targets macOS 26+ ONLY.
- Follow the existing style. Defer to the repo configs:
  - SwiftLint: `.swiftlint.yml`
  - SwiftFormat: `.swiftformat`
- Never add a `deinit`; rely on SwiftUI/Observation lifecycle instead.
- Never run `git` commands; leave version control to the user.
- Do not modify these config files without explicit approval. If a change is needed, propose it with a short rationale in a separate PR (or commit) so it’s easy to review and doesn’t mix with code changes.
- Before submitting macOS changes, run the native checks listed in `.github/workflows/mac.yml`, including its standalone test scripts. The Xcode test target does not cover those scripts.
- When changing dependencies, update the tracked `Package.resolved` and compare CI build times with and without a compiler cache. Local incremental builds do not measure fresh-runner cost.
- To build the app, use `xcodebuild`:
  ```sh
  xcodebuild -project Snap-O.xcodeproj \
             -scheme Snap-O \
             CODE_SIGNING_ALLOWED=NO \
             CODE_SIGNING_REQUIRED=NO \
             build
  ```
