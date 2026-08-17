Snap-O is a public, open-source Android inspection tool.

## Repository Layout

- `snapo-app-mac/`: macOS app and shared Swift device client.
- `snapo-network-inspector-web/`: React UI embedded in the macOS app.
- `snapo-link-android/`: Android libraries and sample apps.
- `contracts/`: shared protocol definitions and fixtures.
- `scripts/snapo` and `tests/snapo_cli/`: command-line client and tests.

## Public Repository

Use synthetic data in tests and examples. Never publish credentials, captured private traffic, confidential implementation details, or private issue-tracker links, identifiers, or content. Review the full diff, commit message, and PR text for sensitive information before publishing.

## Writing

Use plain technical English in all prose, including READMEs, docs, code comments, UI text, commit messages, and PR descriptions. Prefer common words, active voice, and sentences of about 15 words, with one main idea each. Keep necessary technical terms, explain unfamiliar jargon for the intended reader, and preserve exact meaning. Remove repetition, but do not make the prose choppy or omit useful detail.

Code comments should explain non-obvious reasons or constraints, not repeat what the code does. Before finishing, reread new or changed prose for clarity and accuracy.

## Pull Request Descriptions

Lead with a short paragraph explaining the problem, its impact, and why the PR is needed. Put it before `## Summary`, without a `## Why` heading. Follow the summary with `## Validation`, listing the checks performed and any remaining limitations. Keep the description concise and specific.
