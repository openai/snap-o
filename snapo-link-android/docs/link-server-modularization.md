# Snap-O Link modularization: server + features

## Goals
- Split the base Snap-O Link server (transport, connection, app info) from feature-specific (e.g. network inspector) payloads.
- Make it easy to add future features (e.g. Stylo) without changing the server core.
- Keep the OkHttp network-inspector integration as a separate, optional module.

## Non-goals
- Redesign the desktop UI or change client behavior beyond what is required for multi-feature support.
- Introduce new feature protocols beyond the network inspector in this phase.

## Proposed module layout
- `:link-core` (existing): Snap-O Link server and shared protocol types.
- `:network` (new): network inspector records, buffering, and replay logic. -- this is the new naming convention we will start to employ.
- `:link-okhttp3` (existing): OkHttp interceptor + WebSocket hooks; depends on `:network`.
- `:link-okhttp3-noop` (existing): no-op shim; depends on `:network` or re-exports stubs.

## No-op strategy
- No `:link-core-noop`. The server is only needed when a real feature is used.
- Each feature module may provide its own `-noop` artifact (e.g. `:link-okhttp3-noop`) that does not depend on `:link-core`.

## `:link-core` responsibilities
**Purpose:** run the local socket server, manage connections, and multiplex feature data streams.

**Contains:**
- `SnapOLinkServer` lifecycle: socket binding, accept loop, single-client policy.
- `SnapOLink` process-local handle (`serverOrNull()`, `isEnabled()`).
- `SnapOInitProvider` (auto-start when using the real implementation).
- Base protocol records:
  - `LinkHello` (app identity, server start times, feature list).
  - `LinkFeature` (feature metadata; sent immediately after `LinkHello` for each registered feature).
  - `LinkReplayComplete`.
  - `AppIcon` (optional).
- Base config (renamed from `SnapONetConfig`):
  - `allowRelease`, `singleClientOnly`, base `modeLabel`.

**Feature registration:** features register themselves with the server at startup, even when the app does not explicitly call `SnapOLinkServer.start()`. Current implementation snapshots features at connection time; late registrations are picked up on the next connection (no live listener yet). If we need hot attach later, we can reintroduce a listener/observer.

**Feature interface:** the server hosts any number of feature modules.
```kotlin
interface SnapOLinkFeature {
    val featureId: String            // e.g. "network"
    val schemaVersion: Int
    fun onClientConnected(sink: LinkEventSink)
    fun onFeatureOpened(sink: LinkEventSink)
    fun onClientDisconnected()
}

interface LinkEventSink {
    fun <T> sendHighPriority(payload: T, serializer: KSerializer<T>)
    fun <T> sendLowPriority(payload: T, serializer: KSerializer<T>)
}
```
- Features send `@Serializable` objects; the server handles NDJSON serialization.
- `:link-core` should provide inline reified convenience extensions so call sites do not pass serializers manually.
```kotlin
import kotlinx.serialization.serializer

inline fun <reified T> LinkEventSink.sendHighPriority(payload: T) {
    sendHighPriority(payload, serializer())
}
```
- A `LinkFeature` message is sent through the server on startup, for each registered feature (right after `LinkHello`), and on late registration.
- The server is responsible for:
  - sending `LinkHello`, `AppIcon`, `LinkFeature`
  - invoking `onClientConnected()` for connection-level setup; features may wait for `FeatureOpened` before emitting.
  - invoking `onFeatureOpened()` when receiving a message in the server that a feature window has opened for a particular feature.
  - enforcing single-client policy
  - parsing inbound NDJSON after handshake completes to dispatch host → device messages (e.g. feature window open)

So now Snap-O mac app will start sending a message when a feature window has opened for the first time:
```
@Serializable
@SerialName("FeatureOpened")
data class FeatureOpened(
    val feature: String,
)
```

A Snap-O app feature window will send this message to a Snap-O Link server whenever it decides, e.g. when the Network Inspector is opened for a particular selected device.
- `FeatureOpened` is per-connection; on disconnect, features revert to closed until another `FeatureOpened` arrives.
- The host may send `FeatureOpened` multiple times; features should treat it as idempotent.
- The host only sends `FeatureOpened` for registered features; the server ignores unknown features.

## `:network` responsibilities
**Purpose:** network inspector protocol, caching, and replay.

**Contains:**
- Network records: `RequestWillBeSent`, `ResponseReceived`, `WebSocket*`, `ResponseStream*`, etc.
- `NetworkInspectorConfig` (renamed from `SnapONetConfig`): buffer window, max bytes/events.
- `EventBuffer` and dump-on-reconnect logic.
- Priority/deferred streaming for large response bodies.

**Feature implementation:**
```kotlin
class NetworkInspectorFeature(
    config: NetworkInspectorConfig = NetworkInspectorConfig()
) : SnapOLinkFeature {
    fun publish(record: SnapONetRecord)
}
```
- `onClientConnected()` does not do anything for network inspector, because the feature hasn't necessarily been opened yet.
- `onFeatureOpened()` starts streaming, replays buffered history, then emits `LinkReplayComplete`.
- `publish()` buffers records (default last 5 minutes) and only writes NDJSON through the provided `LinkEventSink` after the feature is opened.
- `onClientDisconnected()` returns the feature to a closed state while continuing to buffer.
- Response body deferral and SSE/WebSocket ordering stay in this module.

## Wire protocol changes (multi-feature aware)
**Current:** all records are top-level NDJSON items, single feature.

**Proposed:** add a minimal feature envelope while keeping NDJSON:
```json
{"type":"FeatureEvent","feature":"network","payload":{"type":"RequestWillBeSent", ...}}
```
- `type` identifies the top-level record kind; only `FeatureEvent` acts as an envelope for feature payloads (e.g. `LinkHello`, `LinkFeature` remain top-level records).
- `feature` is always required for feature payloads to avoid namespacing collisions.
- `payload.type` keeps existing record names.
- `LinkHello` advertises features to allow clients to filter.
- Parsing strategy: decode the line into the top-level record; when it is `FeatureEvent`, the payload is a `JsonElement` and is handed to the owning feature to deserialize as needed.
- The payload schema is feature-defined; the link server treats it as opaque JSON.

**Compatibility strategy:**
- No backwards compatibility is necessary at this time. Snap-O is not widely adopted.

## Transport format notes
- NDJSON is a good fit for streaming and line-by-line parsing.
- For binary payloads, the current approach should remain: base64 within JSON fields (e.g. `AppIcon`).
- If binary payload sizes become problematic, consider a length-prefixed framing protocol later, but keep NDJSON for now to minimize client/server churn.

## Build + artifact naming
- `:network` publishes `com.openai.snapo:network`.

## Implementation plan (detailed)
1. Module scaffolding
   - Add `:network` to `settings.gradle.kts` and create `build.gradle.kts` with namespace `com.openai.snapo.network`.
   - New code uses `com.openai.snapo.network`; existing `com.openai.snapo.link.network` is left as-is for now and migrated later.
   - Move network-only types from `:link-core`:
     - `SnapONetRecord` hierarchy, `Timings`, `EventBuffer`, `NetworkInspectorConfig`.
2. Core protocol model
   - In `:link-core`, introduce a top-level `LinkRecord` sealed interface (or similar) with:
     - `LinkHello`, `LinkFeature`, `LinkReplayComplete`, `AppIcon`, `FeatureEvent`, `FeatureOpened`.
   - `FeatureEvent` fields: `feature: String`, `payload: JsonElement`.
   - Keep NDJSON with `type` discriminator for top-level records.
3. Feature registry
   - Implement `SnapOLinkRegistry` in `:link-core`:
     - `register(feature)`, `snapshot()`.
     - (Future) Optional observer/listener API to attach late registrations to active servers.
4. Feature auto-registration
   - Add `SnapONetworkInitProvider` in `:network` to register `NetworkInspectorFeature` on startup.
   - Keep manual registration path intact for apps that disable `SnapOInitProvider`.
5. Server integration
   - Update `SnapOLinkServer` to snapshot `SnapOLinkRegistry` on connection:
     - Attach currently registered features at start.
     - (Future) Emit `LinkFeature` on late registrations (and on next connection) if we add a listener.
   - Provide `LinkEventSink` to features:
     - `sendHighPriority(payload, serializer)` and `sendLowPriority(payload, serializer)`.
     - Server wraps the payload into `FeatureEvent` and serializes to NDJSON.
   - Add inline reified convenience extensions in `:link-core` to avoid manual serializer plumbing.
6. Inbound message parsing
   - Replace `tailClient()` with a line-reader that parses NDJSON into `LinkRecord` after handshake completes.
   - Route `FeatureOpened` to the matching feature by `featureId` (`FeatureOpened.feature`).
   - Unknown feature IDs are ignored (with logging).
7. NetworkInspectorFeature extraction
   - Move buffering, replay, and response-body deferral into `NetworkInspectorFeature`.
   - Implement `onClientConnected()` to remain idle until the feature is opened.
   - Implement `onFeatureOpened()` to begin streaming, replay buffered history, then emit `LinkReplayComplete`.
   - Implement `onClientDisconnected()` to reset the open state while continuing to buffer.
8. OkHttp integration updates
   - Update `:link-okhttp3` to publish via `NetworkInspectorFeature`.
   - Provide a simple accessor in `:network` (e.g. `NetworkInspector.featureOrNull()`) so interceptors do not manage registration directly.
9. No-op strategy
   - Optional: introduce `:network-noop` (stubs for the network feature).
   - Update `:link-okhttp3-noop` to depend on `:network-noop` (not `:link-core`).
10. Desktop client changes
   - Update the mac app client to read `LinkHello` + `LinkFeature`, then decode `FeatureEvent`.
   - Emit `FeatureOpened` when a feature UI is opened.
11. Verification
   - Run `samples/demo-okhttp` to verify auto-start + network events.
   - Add serialization tests for `FeatureEvent` + `LinkFeature` in `:link-core`.
   - Add buffer/replay tests in `:network`.

## Example usage (automatic)
Including `:link-core` and `:network` (via `:link-okhttp3`) keeps the current behavior:
- `SnapOInitProvider` auto-starts the server.
- `SnapONetworkInitProvider` auto-registers the feature.

If the app disables `SnapOInitProvider`, it can manually start the server:
```kotlin
SnapOLinkRegistry.register(NetworkInspectorFeature())
val server = SnapOLinkServer.start(application = app)
```
