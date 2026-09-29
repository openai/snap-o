# Network Tool protocol

Network Tool serves HTTP on `snapo_network_<pid>`, an Android abstract Unix socket. Forward it with ADB to connect from a desktop client. The library does not open a TCP listener on Android.

## Endpoints

| Request | Response |
| --- | --- |
| `OPTIONS /` | Empty readiness response. |
| `GET /network/protocol` | Network compatibility metadata: `{"version":2}`. |
| `GET /network` | A finite NDJSON snapshot, or live Server-Sent Events (SSE), selected by `Accept`. |
| `GET /network/requests/{requestId}/request-body` | JSON with `postData`. |
| `GET /network/requests/{requestId}/response-body` | JSON with `body` and `base64Encoded`. |
| `POST /network/search` | Matching search terms and short text samples from stored request and response bodies. |
| `POST /interception` | Register routes; return `201`, the runner URL in `Location`, and its owning SSE stream. |
| `PUT /interception/{runnerId}/routes` | Replace a runner's routes. |
| `POST /interception/{runnerId}/exchanges/{exchangeId}` | Decide a paused exchange. |

Percent-encode request ids as one path component. Body reads return `404` when the capture is unavailable. Successful updates return `{}`. HTTP errors use a JSON `error` string.

The Network CLI calls `GET /network/protocol` and requires `{"version":2}` before reading data or opening a stream. The bundled frontend uses its matching Android server without a version check. This endpoint belongs to Network, not the shared tool SDK. The desktop gets app labels and icons from [manifest discovery](../discovery/README.md). The CLI reads package and process identity through ADB without a reader.

Protocol 2 replaces the protocol 1 newline transport released in Snap-O 8.0.0. It uses a tool-owned compatibility endpoint, HTTP history and body reads, and SSE for live events and interception. History uses event sequence IDs without a separate snapshot header. Old clients and servers are unsupported; there is no transport fallback.

`GET /network` uses the standard `Accept` header to select its response:

- `application/x-ndjson` returns a finite snapshot.
- `text/event-stream` opens a live stream. Browser `EventSource` sends this header automatically.
- An absent header or `*/*` defaults to the snapshot. Unsupported types return `406`.

Responses include `Vary: Accept, Origin`. Clients can use quality weights to express a preference; equal weights prefer the snapshot.

## Join history and live events

The snapshot responds with `application/x-ndjson` and chunked HTTP framing. Each line contains one event with a top-level `snapoSequence`, ordered by increasing sequence. There is no separate snapshot header or metadata record. Only a complete HTTP response marks the snapshot complete. A truncated record or incomplete chunked response is an error.

For a combined history and live view:

1. Select the tool socket, then request `/network/protocol` and require version 2.
2. Open `/network` with `Accept: text/event-stream` and buffer incoming events.
3. After the SSE response headers arrive, fetch `/network` with `Accept: application/x-ndjson`.
4. Process the snapshot events, retaining the last processed `snapoSequence`.
5. Process buffered and subsequent live events only when their sequence is higher, advancing the saved sequence each time.

An empty snapshot or SSE heartbeat leaves the saved sequence unchanged. Buffering a live event does not advance it. Events received live may still be displayed after eviction from server history. Start with no saved sequence for a new view, and reset it when the Android process changes.

Android registers the live subscription before returning its headers. Clients must bound their live buffer while loading history. If it fills, disconnect and start again; do not silently drop events. A history-only view requests the snapshot without opening SSE.

Closing the SSE connection stops that subscription. Capture in the app continues. After a stream failure, reconnect with a new snapshot. `Last-Event-ID` does not request replay; clients must not rely on automatic EventSource reconnection to fill gaps.

## Event and body payloads

SSE responses use `text/event-stream` and chunked HTTP framing. Each network event has an `id` containing its sequence and `data` containing a JSON object:

```text
id: 42
data: {"method":"Network.loadingFinished","params":{"requestId":"request-1","timestamp":100.25,"encodedDataLength":12},"snapoSequence":42}

```

The event id must match `snapoSequence`. Comment lines provide heartbeats. Events have `method` and `params`; there is no command or reply envelope on this stream.

Snap-O retains CDP-shaped Network request, response, completion, failure, SSE, and WebSocket capture events. Timestamps use seconds. This is a subset of CDP event data for Android inspection, not a Chrome browser target. Payloads omit browser-specific fields and retain Snap-O body, sequence, and truncation metadata. Capturing an app's WebSocket traffic is separate from the tool's HTTP transport.

Body reads return plain JSON, without `id` or `result` wrappers:

```json
{"postData":"example request body"}
```

```json
{"body":"example response body","base64Encoded":false}
```

Capture limits and redaction remain configured by the Android app. Interception uses a separate SSE subscription and is defined in [HTTP interception](interception.md).

## Limits and lifecycle

HTTP request bodies are limited to 2 MiB. Individual event JSON payloads and history records are limited to 16 MiB of UTF-8. Each Android SSE queue holds at most 512 events and 32 MiB; overflow closes the stream. A slow reader also causes closure after a blocked write exceeds five seconds. Heartbeats run every ten seconds, and client reads have finite inactivity deadlines.

Android accepts at most 128 simultaneous tool connections, including at most 16 SSE streams. Clients should bound concurrent HTTP operations. Each HTTP request uses one connection; SSE and history responses stream without buffering their full contents.

Every request received by Android must use a loopback `Host` (`localhost`, `127.0.0.1`, or `[::1]`, with an optional port). This blocks DNS rebinding through attacker-owned names. Browser requests must use an HTTP or HTTPS loopback `Origin`, or the desktop origin `snapo://tool`. Other origins, including `null`, are rejected. Native clients may omit `Origin`.

Desktop frontends call `snapo://tool/api/network` with `fetch` and `EventSource`. The macOS host strips `/api`, sends the request directly over ADB, and supplies the required Android headers. Development frontends use the same origin: only their frontend files come from the local development server. Standalone loopback browser clients can use HTTP. CORS responses allow the validated origin and expose `Location`. `OPTIONS` permits `GET`, `POST`, and `PUT` with `Content-Type`; credentials are not required.

## Compatibility

The updated Android API removes `NetworkInspectorConfig.modeLabel` and the `snapo.mode_label` manifest option. Remove these settings when updating the Android library. The label was descriptive and never changed capture behavior or release-build permissions.

Version **2** is a breaking transport change. Updated clients require HTTP + SSE instead of the released newline command protocol. They do not fall back to older transports. Interception decisions are never retried automatically after an uncertain result.

The [history](v2/history.jsonl) fixture remains valid for the current protocol; metadata follows the [discovery contract](../discovery/README.md). Compatibility checks cover version rejection, HTTP framing, history/live ordering, body reads, and interception ownership and decisions. Before release, test the updated pair on a device and check older-server failures as required by the [release checklist](../../release/README.md).

### HTTP routing defaults

Unknown paths return `404` for every method. A known path with an unsupported method returns `405`. Expired interception runners still return `410` on matching interception routes.

### Body search

`POST /network/search` takes JSON with `requestIds` and `terms` arrays. Use request IDs from the connected Android process.

- Include 1–64 different request IDs, each at most 512 characters long.
- Include 1–64 search terms, each 1–256 characters long.
- Terms match plain text, not regular expressions. Matching ignores letter case.

Invalid queries return `400`. Android runs at most two body searches at once; further searches return `429`.

```json
{"requestIds":["request-1"],"terms":["needle"]}
```

The response has one result for each request ID. It includes a result even when the body is missing:

```json
{"results":[{"requestId":"request-1","request":{"terms":[],"complete":true},"response":{"terms":["needle"],"complete":false,"snippet":"a needle in the captured response"}}]}
```

Each result has separate `request` and `response` fields:

- `terms` lists the matching search terms in lowercase.
- `complete` is true when the search covered the whole body, including a known empty body.
- `snippet`, when present, contains up to 160 characters of text around a match.

A missing or partial body cannot prove that a term is absent. The same is true for bodies still arriving, binary bodies, and bodies over the search limit. These results have `complete: false`.

Search reads stored text; it never fetches a body from the network. It also reads gzip and x-gzip request bodies, with an 8 MiB limit after decompression. Plain text search reads at most 8,388,608 UTF-16 code units.

Clients combine matches from metadata and the request and response bodies. Different search terms can match different parts of a request. An excluded term in any part hides the request. Queries with excluded terms show a request only after both bodies have been fully searched.

The Mac also searches bodies in its local cache. It combines results using both the process identity and request ID. This lets it find older bodies, including those Android has removed from its cache. Saved exclusion filters search only metadata.

Selecting a match fetches the body through the existing body-read endpoints, unless it is already cached. Android may remove the body from its cache between search and selection.

The protocol version stays at **2** because this endpoint adds a feature without breaking existing calls. Existing Mac and Python clients keep using their current endpoints. Older protocol-2 servers return `404` for body search. The frontend then searches cached bodies. The Tweaks protocol does not change.

Request events include the optional `request.postDataTruncatedBytes` field. Zero means the full request body was captured; a positive value counts omitted bytes. A missing value means truncation is unknown. Decoding can change the byte count. Use capture metadata to decide whether the body is complete. This field is an additive change to protocol 2; older clients can ignore it.
