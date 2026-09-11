# Inspector runtime

Shared Android infrastructure for Snap-O inspectors. Network and Tweaks depend on this library. It has no frontend, discovery entry, content provider, or automatic startup of its own.

The runtime provides:

- HTTP routes, request/response helpers, and coroutine-scoped SSE sessions.
- An abstract Unix socket server with bounded connections, request read timeouts, and shutdown cleanup.
- HTTP request parsing with configurable body limits, methods, and protocol versions.
- Host and Origin validation, CORS headers, and HTTP response writing.
- A common debuggable-app and explicit release opt-in check.
- SSE event framing and automatic heartbeat comments.

Each inspector owns its routes, JSON payloads, startup provider, release metadata key, and event delivery policy. Network retains its ordered event queue and replay history. Tweaks retains its latest-snapshot publisher and main-thread updates.

## Use in this build

```kotlin
dependencies {
    implementation(project(":inspector-runtime"))
}
```

Apply the [inspector Gradle plugin](../inspector-gradle-plugin/README.md) separately to package the frontend and discovery metadata. The plugin generates `SnapOInspector` in the Android namespace. Use `SnapOInspector.ID` for the socket server and `SnapOInspector.PROTOCOL_VERSION` for versioned payloads.

This module uses the repository's Maven publishing convention. Consumers of Network or Tweaks receive it transitively. A new release must publish the runtime alongside the inspector libraries that depend on it.

## Serve an inspector

Use `InspectorServer` for normal HTTP tools. Keep the server for the inspector's lifetime and close it when that lifetime ends. Startup remains in the inspector's existing provider or explicit initialization function.

```kotlin
val server = InspectorServer(SnapOInspector.ID) {
    get("/snapshot") {
        respondJson("""{"fake":true}""")
    }
    post("/reset") {
        example.reset()
        respondNoContent()
    }
    sse("/events") {
        example.events.collect { json ->
            send(data = json, event = "sample")
        }
    }
}
server.start()
```

`start()` is idempotent and throws if binding fails. The server owns parsing, Host/Origin checks, CORS, preflight, response framing, and connection cleanup. Unknown routes return 404; unsupported methods return 405 with an `Allow` header. Handlers that return without responding produce 204.

### Requests and responses

Register `get`, `post`, `put`, `patch`, or `delete` routes. `route(method, path)` supports other methods; `OPTIONS` is handled by the server. Routes match the path without query parameters. Register specific routes before overlapping parameter routes.

```kotlin
get("/items/{id}") {
    val id = pathParameters.getValue("id")
    val filters = request.queryParameters["filter"].orEmpty()
    respondJson(items.read(id, filters))
}
post("/items") {
    val json = request.bodyText()
    respondJson(items.create(json), statusCode = 201)
}
```

Path parameters are percent-decoded without converting `+` to a space. Query parameters retain repeated values. `request.requestTarget` preserves the original target, including its query. `request.path` is the encoded path without the query; encoded slashes remain part of their segment. `request.queryParameters` contains decoded names and values. Header names are lowercase. `request.body` provides bounded bytes; `bodyText()` validates UTF-8.

`respondJson` accepts already-serialized JSON. The runtime does not select a serialization library. `respondText` returns plain text. For custom status, content type, or headers, use `respond(InspectorHttpResponse(...), headers = ...)`.

The default request policy accepts HTTP/1.1, caps bodies at 64 KiB, and requires JSON content types for nonempty bodies. Set `requestPolicy` only when a protocol needs different limits or accepted forms. `validateRequest` adds protocol-specific checks. `onError` maps domain exceptions to responses; unexpected failures default to a generic 500. Once a response starts, failures close the connection without appending another HTTP response.

### Streaming

SSE handlers run in a coroutine scope. `send(data, event, id)` frames an event. The runtime sends a `: keep-alive` comment every 30 seconds automatically, including while the producer waits for data. Writes are serialized with events, and comments do not become frontend message events.

Both `sse` and `respondSse` accept `heartbeatInterval`. Use a positive, finite Kotlin `Duration` to override the interval, or `null` to disable automatic heartbeats. `heartbeat()` still writes one immediate comment when needed:

```kotlin
sse("/events", heartbeatInterval = 15.seconds) {
    example.events.collect { send(it, event = "sample") }
}
sse("/manual-events", heartbeatInterval = null) {
    example.events.collect { send(it, event = "sample") }
}
```

The inspector chooses event sources, buffering, and replay policies. Cancelling the server or disconnecting the client closes the socket and cancels the producer, heartbeat job, and other child coroutines. They also end when the handler returns. Use suspending operations or `runInterruptible` for blocking event sources. Network, Tweaks, and Example all use the shared 30-second default; none schedules its own heartbeat loop.

Use `respondSse` inside an ordinary route when streaming depends on request headers or setup can fail before sending response headers. It supports status and headers such as Network's interception `Location`. Its default is chunked HTTP/1.1 framing; `chunked = false` preserves protocols that end their body by closing the connection. `InspectorSseSession.write` sends an already-framed SSE event for inspectors that queue encoded bytes.

For finite streams such as NDJSON history, use `respondStream(contentType) { write(bytes) }`. The runtime writes chunk boundaries and the terminating chunk.

Connections use a five-second request read timeout, a thirty-second finite-request deadline, and a five-second blocked-write limit checked once per second. SSE disables the finite-request deadline. The default is 32 concurrent connections per inspector/process; Network retains its existing override of 128 and separate limit of 16 event streams. Excess socket connections close immediately.

### Advanced transport and testing

`InspectorServer.serve(connection)` handles and closes an externally supplied `InspectorConnection`. This lets tests exercise the real parser, router, and response writer using memory or loopback TCP streams. Normal tools only call `start()` and `close()`.

`InspectorSocketServer`, `InspectorHttpRequest`, `InspectorHttpResponse`, and `InspectorSse` remain available for custom transports. Apply `InspectorStartupPolicy` from the tool's initializer. The HTTP API does not add a provider or change process startup.

## Compatibility

This extraction keeps Network protocol 3 and Tweaks protocol 7. Socket names, endpoint paths, payloads, startup opt-ins, and SSE event semantics remain unchanged. Existing HTTP/1.1 clients continue to work; Tweaks also keeps HTTP/1.0 support and its optional request content type.

Both inspectors now use the same bounded ASCII/CRLF header parser. Tweaks no longer accepts malformed header names, duplicate headers, or LF-only request headers. Excess connections close at the shared server's limit. The first-party clients use the accepted request forms.

## Validation

From `snapo-link-android/`:

```sh
./gradlew :inspector-runtime:testDebugUnitTest :network:testDebugUnitTest :tweaks-core:testDebugUnitTest
./gradlew :inspector-runtime:lintDebug :network:lintDebug :tweaks-core:lintDebug
./gradlew assembleDebug validateMavenCentralRelease
```

Runtime tests use memory and loopback TCP streams to exercise routing, framing, browser access, and disconnect cancellation without an Android device. Production uses only Android abstract Unix sockets. Existing Network tests cover history, SSE subscriptions, interception, and browser preflight behavior.
