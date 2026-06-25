# Snap-O Architecture

Snap-O is a macOS host for Android capture and network inspection. The main app intentionally uses one
shared device-client module and keeps feature presentation in the app target.

## Dependency direction

```text
Snap-O app ─┐
            ├──> SnapODeviceClient
snapo CLI ──┘

Android integrations ──> :network ──wire protocol──> SnapODeviceClient
React inspector <──typed host bridge──> Snap-O app
```

`SnapODeviceClient` is Foundation/Darwin-only. It owns ADB transport, device and network-server discovery,
network wire types, and ordered network sessions. It must not import AppKit, SwiftUI, WebKit, AVKit, or CLI
formatting concerns.

The Android implementation remains idiomatic Kotlin. The React inspector remains idiomatic TypeScript.
These runtimes share contract fixtures and observable behavior, not generated implementation code.

## macOS runtime

`AppRuntime` is the composition root for app-scoped services:

- ADB setup and communication
- connected-device tracking
- capture resource coordination
- temporary media storage

SwiftUI creates one `@MainActor @Observable` feature model per window. Window models own presentation state;
app-scoped actors own device resources. Views render state and send intents, but do not own recordings,
live-preview processes, or network connections. Each window creates its Network Inspector service when the
pane is first shown and closes it with the window; transport and protocol behavior still come from the shared
device-client module.

## Capture ownership

`AppRuntime` composes three capability-focused actors: `ScreenshotService`, `RecordingService`, and
`LivePreviewService`. Each service owns its feature's ADB workflow, cancellation, and cleanup. The
per-window `CaptureWindowController` coordinates presentation modes; there is no catch-all capture service.

Recording and live-preview operations use explicit, idempotent handles. A handle owns every session it
starts and releases each session during finish, cancellation, partial failure, device removal, or window
closure. The small `CaptureCoordinator` owns only app-wide resource policy: it leases devices atomically,
prevents recording and live preview from using the same device across windows, and gates shutdown.
Screenshots remain independent because they do not hold a long-lived device resource.

Capture options are values passed into an operation. Capture services do not read UI globals or infer their
device set from mutable presentation state. A visible live-preview surface observes its stream lifecycle;
an unexpected stop releases the old operation and retries with bounded backoff while the surface remains
active.

## Network inspection

The Android library assigns a process-monotonic sequence to every network event. A replay snapshot includes
an atomic watermark, and queued live events at or below that watermark are skipped. A full delivery queue
closes the session so the host reconnects and obtains a complete snapshot instead of silently losing data.

The host uses protocol timestamps for request duration and event time. Arrival time is only a fallback for
legacy messages. Stores are bounded, ingestion is idempotent by server and sequence, and body loading uses
limited concurrency. Process-start identity scopes sequences, records, and body requests so Android PID
reuse cannot merge data from different app processes.

Delivery is bounded at every host hop, including the Swift-to-WebKit bridge. If a consumer falls behind or
WebKit delivery fails, the host closes that delivery path and reloads from a fresh Android replay instead of
silently dropping events. Request bodies load on demand into a bounded cache; the selected request remains
pinned while export commands hydrate any missing bodies explicitly.

Swift owns ADB and network transport. React owns inspector UI state. Native controls send intents to React;
React sends an immutable state projection back for native toolbar rendering.

## Testing seams

- Swift Testing covers discovery, wire compatibility, ordered sessions, cancellation, timeouts, and
  backpressure.
- Kotlin tests cover sequencing, replay overlap, compatibility, backpressure, and hard-limit eviction.
- TypeScript tests cover reducer idempotence, protocol timing, retention, restart identity, stream recovery,
  body scheduling, and export budgets.
- A shared JSONL replay fixture protects the Swift and TypeScript sides of the Android wire contract; Kotlin
  compatibility tests verify the producer schema.

UI tests are reserved for a small number of end-to-end capture and inspector flows.
