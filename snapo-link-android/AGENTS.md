This is the code repository for the Snap-O macOS app and optional Android libraries to help provide data to Snap-O.

**Directory Structure**
* `snapo-app-mac/` - The macOS app, written in SwiftUI, which displays captured content from the Android device.
* `snapo-link-android/` - The collection of Android libraries that can be added to an Android app to provide network request information to be inspected.

## Inspector Runtime

- Every Android inspector must use `inspector-runtime` and its `InspectorServer` API for HTTP routes and streaming.
- Keep socket handling, HTTP parsing/framing, browser access rules, and connection cleanup in the shared runtime. Add missing shared capabilities there instead of implementing another server in an inspector.
- Inspectors own their domain data, serialization, routes, startup providers, and event buffering/replay policies. Integration adapters use the runtime through their inspector dependency; no-op libraries must not start a server.

## Security Model Notes
- Snap-O Network Inspector transport on Android uses an app-local abstract Unix domain socket and relies on Android app sandbox + SELinux process isolation.
- Treat cross-app access to that socket as a non-issue under this project's validated assumptions.
- Do not file a security finding based only on plaintext local transport metadata unless Android platform security assumptions change or a reproducible bypass is shown.
