# HTTP interception

Interception uses the existing `HelloSnapO` connection on `snapo_network_<pid>`. Commands use the same numeric `id`, `result`, and `error` envelope as inspection. Interception events go directly to the owning connection, without `SnapO.startStream`. They are not replayed or broadcast to inspectors.

## Register and release routes

Send `SnapO.intercept.enable` with `routes` and `timeoutMs`:

```json
{"id":1,"method":"SnapO.intercept.enable","params":{"routes":[{"id":"generation:0","method":"GET","path":"/api/profile"}],"timeoutMs":30000}}
```

Paths match the encoded URL path exactly, excluding the query. Methods are uppercase. Between 1 and 128 unique method/path pairs are accepted. The deadline must be between 100 and 120000 milliseconds. At most 64 exchanges may be paused at once.

One connection owns interception. Another connection cannot replace its routes or resolve its requests. Re-registering replaces routes for new calls. Existing exchanges retain their original route ids. Disconnecting, or sending `SnapO.intercept.disable`, removes the routes and fails outstanding exchanges. A later connection can become the owner.

## Handle an exchange

`SnapO.intercept.request` carries `exchangeId`, `routeId`, and `request`. The request has `method`, `url`, `headerEntries`, and `body`. Headers are an ordered list of `{ "name": "...", "value": "..." }` objects to preserve repeated headers. Body strings contain base64 bytes, including an empty string for an empty body.

Reply with `SnapO.intercept.resolve`, using the exchange id and one action:

- `upstream`: proceed with the original request on Android. The resulting `SnapO.intercept.response` event carries `exchangeId` and `response`.
- `fulfill`: return the supplied `response` to the app. This may replace an upstream response or complete the exchange without an upstream request.
- `fail`: fail the app request with the supplied `error` message. No upstream fallback is sent.

A response has `status`, `headerEntries`, and a base64 `body`. The runner must provide headers appropriate for the replacement body. Status codes must be between 200 and 599, and decoded bodies cannot exceed 1 MiB. The Python runner recomputes content length and removes transfer framing; JSON edits also replace content type and remove content encoding.

After `upstream`, only `fulfill` or `fail` can complete the exchange. A second upstream operation never sends another request. Only one decision is accepted per pause. Commands for completed exchanges return an error.

`SnapO.intercept.finished` carries `exchangeId`. It indicates that Android has stopped waiting for the handler, including after completion, cancellation, or failure. It does not mean that the app's UI has consumed the response.

## Boundaries

The handler deadline starts when Android matches a route. The runner also cancels timed-out handlers. Android checks cancellation while waiting for decisions; upstream I/O remains subject to the app's transport timeouts. The app may retry failed requests under its existing policy.

The OkHttp application interceptor implements this protocol. It buffers only matching, bounded, non-streaming requests and responses. It does not change TLS configuration or the upstream transport. Requests with an SSE Accept header bypass interception. Unexpected SSE response bodies fail without being read. WebSocket and HttpURLConnection integrations do not use these commands.
