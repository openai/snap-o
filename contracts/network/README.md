# Network Inspector protocol

Network Inspector serves HTTP on `snapo_network_<pid>`, an Android abstract Unix socket. Forward it with ADB to connect from a desktop client. The library does not open a TCP listener on Android.

## Endpoints

| Request | Response |
| --- | --- |
| `GET /.snap-o/info` | JSON app metadata, including `pid` and `protocolVersion`. |
| `GET /.snap-o/appicon` | PNG app icon, or `404` when unavailable. |
| `GET /network` | A finite NDJSON snapshot, or live Server-Sent Events (SSE), selected by `Accept`. |
| `GET /network/requests/{requestId}/request-body` | JSON with `postData`. |
| `GET /network/requests/{requestId}/response-body` | JSON with `body` and `base64Encoded`. |
| `POST /interception` | Register routes; return `201`, the runner URL in `Location`, and its owning SSE stream. |
| `PUT /interception/{runnerId}/routes` | Replace a runner's routes. |
| `POST /interception/{runnerId}/exchanges/{exchangeId}` | Decide a paused exchange. |

Percent-encode request ids as one path component. Body reads return `404` when the capture is unavailable. Successful updates return `{}`. HTTP errors use a JSON `error` string.

Native clients check that `protocolVersion` is exactly **2** before using these endpoints.

`GET /network` uses the standard `Accept` header to select its response:

- `application/x-ndjson` returns a finite snapshot.
- `text/event-stream` opens a live stream. Browser `EventSource` sends this header automatically.
- An absent header or `*/*` defaults to the snapshot. Unsupported types return `406`.

Responses include `Vary: Accept, Origin`. Clients can use quality weights to express a preference; equal weights prefer the snapshot.

## Join history and live events

The snapshot responds with `application/x-ndjson`, chunked HTTP framing, and `SnapO-Sequence`. The sequence header is the snapshot watermark. Each line contains one event with a top-level `snapoSequence` at or below that watermark. Only a complete HTTP response marks the snapshot complete. A truncated record or incomplete chunked response is an error.

For a combined history and live view:

1. Read `/.snap-o/info` and check its protocol version.
2. Open `/network` with `Accept: text/event-stream` and buffer incoming events.
3. After the SSE response headers arrive, fetch `/network` with `Accept: application/x-ndjson`.
4. Read the complete snapshot and retain its watermark.
5. Apply buffered and subsequent live events only when their sequence exceeds the watermark.

Android registers the live subscription before returning its headers. Clients must bound their live buffer while loading history. If it fills, disconnect and start again; do not silently drop events. A history-only view requests the snapshot without opening SSE.

Closing the SSE connection stops that subscription. Capture in the app continues. After a stream failure, reconnect with a new snapshot. `Last-Event-ID` does not request replay; clients must not rely on automatic EventSource reconnection to fill gaps.

## Event and body payloads

SSE responses use `text/event-stream` and chunked HTTP framing. Each network event has an `id` containing its sequence and `data` containing a JSON object:

```text
id: 42
data: {"method":"Network.loadingFinished","params":{"requestId":"request-1","timestamp":100.25,"encodedDataLength":12},"snapoSequence":42}

```

The event id must match `snapoSequence`. Comment lines provide heartbeats. Events have `method` and `params`; there is no command or reply envelope on this stream.

Snap-O retains CDP-shaped Network request, response, completion, failure, SSE, and WebSocket capture events. Timestamps use seconds. This is a subset of CDP event data for Android inspection, not a Chrome browser target. Payloads omit browser-specific fields and retain Snap-O body, sequence, and truncation metadata. Capturing an app's WebSocket traffic is separate from the inspector's HTTP transport.

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

Android accepts at most 128 simultaneous inspector connections, including at most 16 SSE streams. Clients should bound concurrent HTTP operations. Each HTTP request uses one connection; SSE and history responses stream without buffering their full contents.

Browser requests may use an HTTP or HTTPS origin matching `Host`, or a loopback origin (`localhost`, `127.0.0.1`, or `[::1]`). Other origins, including `null`, are rejected. Native clients may omit `Origin`.

The desktop host provides the forwarded base URL. Browser clients connect directly with `fetch` and `EventSource`. CORS responses allow the validated origin and expose `SnapO-Sequence` and `Location`. `OPTIONS` permits `GET`, `POST`, and `PUT` with `Content-Type`; credentials are not required.

## Compatibility

Version **2** is a breaking transport change. The newline command protocol and inspector WebSocket endpoint are removed. Updated clients require HTTP + SSE and do not fall back to older transports. Interception decisions are never retried automatically after an uncertain result.

Shared [app metadata](v2/app.json) and [history](v2/history.jsonl) fixtures describe version 2. Compatibility checks cover version rejection, HTTP framing, history/live ordering, body reads, and interception ownership and decisions. Before release, test the updated pair on a device and check older-server failures as required by the [release checklist](../../release/README.md).
