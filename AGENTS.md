Snap-O is a public, open-source Android inspection tool.

## Repository Layout

- `app-macos/`: macOS app, device transport, and native tests.
- `cli/`: standalone Python client and its tests.
- `plugins/`: Network and Tweaks, each with Android libraries and a frontend.
- `sdk/`: plugin authoring APIs, runtime, and Gradle integration.
- `plugin-reader/`: Android helper used by the macOS app and CLI to read plugin metadata and frontend assets.
- `examples/`: Android demo apps, an independent plugin project, and CLI examples.
- `build-logic/` and `gradle/`: internal Gradle conventions and root build tooling.
- `contracts/`: shared protocol definitions and fixtures.
- `docs/`: GitHub Pages sources and theme. See `docs/README.md` for build conventions.
- `scripts/`: contributor utilities.

## Working Across Components

- Read the component's `AGENTS.md` before changing it.
- Keep macOS ADB and device transport in `app-macos/Snap-O/Device/`. Keep UI code in the app and plugin frontends.
- Android plugins use `sdk/runtime` and its `PluginServer` API. Keep shared socket and HTTP behavior in the runtime.
- The Python CLI implements its own transport; it does not use the Swift client.
- When changing shared behavior, check the Android libraries, macOS client, web tool, and Python CLI. Use `contracts/` and its fixtures to keep them compatible.

## Public Repository

Use synthetic data in tests and examples. Never publish credentials, captured private traffic, confidential implementation details, or private issue-tracker links, identifiers, or content. Review the full diff, commit message, and PR text for sensitive information before publishing.

## Release readiness

Follow [release/README.md](release/README.md) when changing protocols, published APIs, version metadata, or packaging. Update `release/` checks and tests when protocol definitions or source paths change.

## Writing

Use plain technical English in all prose, including READMEs, docs, code comments, UI text, commit messages, and PR descriptions. Prefer common words, active voice, and sentences of about 15 words, with one main idea each. Keep necessary technical terms, explain unfamiliar jargon for the intended reader, and preserve exact meaning. Remove repetition, but do not make the prose choppy or omit useful detail.

Code comments should explain non-obvious reasons or constraints, not repeat what the code does. Before finishing, reread new or changed prose for clarity and accuracy.

## Pull Request Descriptions

Lead with a short paragraph explaining the problem, its impact, and why the PR is needed. Put it before `## Summary`, without a `## Why` heading. Follow the summary with `## Validation`, listing the checks performed and any remaining limitations. Keep the description concise and specific.
