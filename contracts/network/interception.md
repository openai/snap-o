# HTTP interception

Interception uses the [Network Tool HTTP protocol](README.md) on `snapo_network_<pid>`. A POST registers routes and returns their owning SSE connection. Decisions travel over separate HTTP requests. Interception events are sent only to that runner; they are never replayed or broadcast to tools.

## Register and release routes

Send `POST /interception` with a JSON body:

```json
{"routes":[{"id":"generation:0","method":"GET","path":"/api/profile"}],"timeoutMs":30000}
```

The POST response uses `text/event-stream`. Python reads it directly; a browser client would use a streaming `fetch`, because built-in `EventSource` only supports GET.

Android validates the configuration before returning `201 Created`. The `Location` response header contains the runner URL, such as `/interception/example-runner-id`. Events begin immediately; there is no separate readiness event.

Paths match the encoded URL path exactly, excluding the query. Methods are uppercase. Between 1 and 128 unique method/path pairs are accepted. The deadline must be between 100 and 120000 milliseconds. At most 64 exchanges may be paused across all runners.

Each runner owns a separate route list. Keep its id within the owning client. Send `PUT /interception/{runnerId}/routes` with the same configuration shape to replace its routes for new calls. Existing exchanges retain their original route ids and owner. Other runners cannot resolve those exchanges using their own ids. When multiple runners match a request, one is selected; ordering is unspecified and handlers are not chained.

Closing the SSE connection removes that runner's routes and fails its outstanding exchanges. Other runners remain active. Disconnect detection depends on socket closure, heartbeat writes, and deadlines; it is not instantaneous. An ended runner returns `410` to subsequent control requests. Reconnecting requires a new registration and does not resume prior exchanges.

## Handle an exchange

SSE `data` contains a JSON object with `method` and `params`. `SnapO.intercept.request` carries `exchangeId`, `routeId`, and `request`. The request has `method`, `url`, `headerEntries`, and `body`. Headers are an ordered list of `{ "name": "...", "value": "..." }` objects to preserve repeated headers. Body strings contain base64 bytes, including an empty string for an empty body.

Send `POST /interception/{runnerId}/exchanges/{exchangeId}`, with `phase` and an action:

```json
{"phase":"request","action":"upstream"}
```

- `upstream`: send the original request on Android. A later `SnapO.intercept.response` event carries `exchangeId` and `response`. The POST acknowledges the decision without waiting for upstream I/O.
- `fulfill`: return the supplied `response` to the app, with or without an upstream request.
- `fail`: fail the app request with the supplied `error` string. No upstream fallback is sent.

Use `phase: "request"` after the request event and `phase: "response"` after the response event. A response has `status`, `headerEntries`, and a base64 `body`:

```json
{"phase":"response","action":"fulfill","response":{"status":200,"headerEntries":[{"name":"Content-Type","value":"application/json"}],"body":"e30="}}
```

The runner must provide headers appropriate for the replacement body. Status codes must be between 200 and 599, and decoded bodies cannot exceed 1 MiB. The Python runner recomputes content length and removes transfer framing; JSON edits also replace content type and remove content encoding.

After `upstream`, only `fulfill` or `fail` can complete the response pause. Only one decision is accepted per pause. Stale phases, duplicate decisions, and decisions for completed or foreign exchanges return `409`. Do not retry decisions after an uncertain HTTP result: Android may already have applied them.

`SnapO.intercept.finished` carries `exchangeId`. It indicates that Android has stopped waiting for the handler, including after completion, cancellation, or failure. It does not mean that the app's UI has consumed the response.

## Boundaries

The handler deadline starts when Android matches a route. The runner also cancels timed-out handlers. Android checks cancellation while waiting for decisions; upstream I/O remains subject to the app's transport timeouts. The app may retry failed requests under its existing policy.

The OkHttp application interceptor implements this protocol. It buffers only matching, bounded, non-streaming requests and responses. It does not change TLS configuration or the upstream transport. Requests with an SSE Accept header bypass interception. Unexpected SSE response bodies fail without being read. WebSocket and HttpURLConnection integrations do not support interception.

Clients must read SSE independently of their handlers and HTTP decisions. The Python runner limits concurrent control requests to 16 and never holds an HTTP request open while waiting for upstream traffic. This permits all 64 exchanges to wait without exhausting its HTTP workers.
