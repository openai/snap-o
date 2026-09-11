This is the code repository for the Snap-O macOS app and optional Android libraries to help provide data to Snap-O.

## Directory Structure

- `network/` and `tweaks/` contain concrete plugins.
- Each plugin has `android/` libraries and a `frontend/` web UI.
- Shared authoring support lives in `../sdk/`; demo apps live in `../examples/android/`.
- Run Gradle commands from the repository root.

## Plugin Runtime

- Every Android plugin uses `plugin-runtime` and its `PluginServer` API for HTTP routes and streaming.
- Keep socket handling, HTTP framing, browser access rules, and connection cleanup in the shared runtime.
- Plugins own their domain data, serialization, routes, startup providers, and event buffering policies.
- Integration adapters use the runtime through their plugin dependency. No-op libraries must not start a server.

## Security Model Notes
- Snap-O Network Tool transport on Android uses an app-local abstract Unix domain socket and relies on Android app sandbox + SELinux process isolation.
- Treat cross-app access to that socket as a non-issue under this project's validated assumptions.
- Do not file a security finding based only on plaintext local transport metadata unless Android platform security assumptions change or a reproducible bypass is shown.
