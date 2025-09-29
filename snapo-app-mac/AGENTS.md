# AGENTS.md

For automated contributors:

- This app targets macOS 15+ ONLY.
- Follow the existing style. Defer to the repo configs:
  - SwiftLint: `.swiftlint.yml`
  - SwiftFormat: `.swiftformat`
- Never run `git` commands; leave version control to the user.
- Do not modify these config files without explicit approval. If a change is needed,
  propose it with a short rationale in a separate PR (or commit) so it’s easy to review
  and doesn’t mix with code changes.
- To build the app, use `xcodebuild`:
  ```sh
  xcodebuild -project Snap-O.xcodeproj \
             -scheme Snap-O \
             CODE_SIGNING_ALLOWED=NO \
             CODE_SIGNING_REQUIRED=NO \
             build
  ```
