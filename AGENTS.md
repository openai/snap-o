# AGENTS.md

For automated contributors:

- Follow the existing style. Defer to the repo configs:
  - SwiftLint: `.swiftlint.yml`
  - SwiftFormat: `.swiftformat`
- Do not run `swiftlint` or `swiftformat`; the user handles linting and formatting.
- Never run `git` commands; leave version control to the user.
- Do not modify these config files without explicit approval. If a change is needed,
  propose it with a short rationale in a separate PR (or commit) so it’s easy to review
  and doesn’t mix with code changes.
- NSWindow sizing must happen on the main thread and should use `setFrame` so the window animates; keep that logic in `WindowSizingController` unless explicitly instructed otherwise.
