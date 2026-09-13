This is the code repository for the Snap-O macOS app and optional Android libraries to help provide data to Snap-O.

## Directory Structure

- `network/` and `tweaks/` contain concrete tool plugins.
- Each tool plugin has `android/` libraries, a `frontend/` web UI, and CLI tests in `cli/`. Standalone executables live inside their `../../skills/` packages.
- Shared authoring support lives in `../tool-sdk/`; demo apps live in `../examples/android/`.
- Run Gradle commands from the repository root.

## Tool Runtime

- Every Android tool plugin uses `tool-runtime` and its `ToolServer` API for HTTP routes and streaming.
- Keep socket handling, HTTP framing, browser access rules, and connection cleanup in the shared runtime.
- Tool plugins own their domain data, serialization, routes, startup providers, and event buffering policies.
- Integration adapters use the runtime through their tool plugin dependency. No-op libraries must not start a server.

## Security Model Notes
- Snap-O Network Tool transport on Android uses an app-local abstract Unix domain socket and relies on Android app sandbox + SELinux process isolation.
- Treat cross-app access to that socket as a non-issue under this project's validated assumptions.
- Do not file a security finding based only on plaintext local transport metadata unless Android platform security assumptions change or a reproducible bypass is shown.
