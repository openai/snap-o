# Snap-O Tweaks protocol

Snap-O Tweaks exposes a small HTTP API through an Android abstract Unix socket. It is separate from the Network Inspector socket and does not use the `HelloSnapO` handshake.

## Discover and forward a server

Each app process publishes `snapo_tweaks_<pid>`. List attached devices and their abstract sockets:

```bash
adb devices -l
adb -s emulator-5554 shell cat /proc/net/unix
```

Create a temporary local forward and capture the port ADB actually assigns:

```bash
serial=emulator-5554
socket=snapo_tweaks_12345
port="$(adb -s "$serial" forward tcp:0 "localabstract:$socket")"
base="http://127.0.0.1:$port"
```

Keep that forward alive for every request or event stream that uses it. Once finished, remove only the forward you created:

```bash
adb -s "$serial" forward --remove "tcp:$port"
```

For remote ADB servers, an `adb forward` is local to the ADB server's host, not necessarily the machine running your client. Either tunnel that forwarded port back to your client, or use the Snap-O CLI with both `--adb-host HOST --adb-port PORT`; the CLI opens a direct ADB smart-socket connection to `localabstract:snapo_tweaks_<pid>` instead of relying on an inaccessible remote forward.

## Endpoints

| Request | Result |
| --- | --- |
| `GET /app` | JSON app metadata: `{"name":"Example","packageName":"com.example"}`. |
| `GET /app/icon` | Optional application icon image; `404` if unavailable. Use its response `Content-Type` without assuming a particular format or size. |
| `GET /tweaks` | Current active tweak descriptors and values. |
| `PATCH /tweaks` | One atomic update containing one or more named values. |
| `GET /tweaks/events` | Server-sent events containing complete current snapshots. |

Ordinary responses close their connection and include a content length. The event response stays open and uses `Content-Type: text/event-stream`.

### Read metadata and active values

```bash
curl -fsS "$base/app"
curl -fsS "$base/tweaks"
curl -fsS "$base/app/icon" -o /tmp/snapo-tweak-app-icon
```

The tweak response has this shape:

```json
{
  "tweaks": [
    {
      "name": "Motion/Duration",
      "type": "int",
      "default": 400,
      "value": 550,
      "min": 100,
      "max": 1500,
      "step": 50
    },
    {
      "name": "Motion/Enabled",
      "type": "boolean",
      "default": true,
      "value": false
    }
  ]
}
```

The available types are `int`, `float`, `boolean`, `color`, and `string`. Preserve actual JSON types: booleans are not strings, integer values cannot be fractional, and floats accept whole or fractional finite numbers. Colors are strings in `#RRGGBB` or `#RRGGBBAA` format. Numeric descriptors may include `min`, `max`, and `step`; step alignment starts at `min`, or at `default` if there is no minimum.

A tweak exists only while its declaration is active in Compose. Names are shared identifiers: two active declarations of the same complete descriptor observe the same value. Names may contain spaces and `/`; send the entire name unchanged.

### Update or reset values atomically

```bash
curl -fsS -X PATCH "$base/tweaks" \
  -H 'Content-Type: application/json' \
  -d '{"values":{"Motion/Duration":550,"Motion/Enabled":false}}'
```

The response contains the changed names and their resulting values:

```json
{"tweaks":[{"name":"Motion/Duration","value":550},{"name":"Motion/Enabled","value":false}]}
```

Every value is validated before any update is applied. An invalid or unknown entry prevents the entire batch from changing. Reset by fetching `GET /tweaks` and sending the target descriptor's `default` value back in a patch; reset all by patching every active name to its own default in one request. There is no separate get-by-name, reset, delete, action, or grouping endpoint.

### Watch complete snapshots

```bash
curl --no-buffer "$base/tweaks/events"
```

```text
event: tweaks
data: {"tweaks":[{"name":"Motion/Enabled","type":"boolean","default":true,"value":true}]}

: keep-alive

event: tweaks
data: {"tweaks":[{"name":"Motion/Enabled","type":"boolean","default":true,"value":false}]}

```

The first event is the complete current list. Every later `event: tweaks` is also a complete, ordered replacement snapshot, not a delta. Remove items absent from the newest snapshot. Ignore lines starting with `:`; they are idle keepalives. Reconnect and replace state when the app process or socket changes.

For a browser, serve a same-origin proxy that forwards these routes to the ADB-forwarded target:

```js
const events = new EventSource("/tweaks/events");
events.addEventListener("tweaks", (event) => {
  renderTweaks(JSON.parse(event.data).tweaks);
});

await fetch("/tweaks", {
  method: "PATCH",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ values: { "Motion/Duration": 550 } }),
});
```

These relative URLs assume your host serves both the page and the proxy. The Android server does not supply CORS headers or implement browser `OPTIONS` preflight, so a browser page hosted on another origin cannot reliably use `fetch` or `EventSource` against the forwarded port directly. Native and server-side HTTP clients do not have this browser restriction.

## Errors and security

Errors use `{"error":"description"}`. Expect `400` for malformed input, `404` for missing endpoints or inactive tweak names, `405` for unsupported methods, `413` for oversized bodies, and `422` for invalid JSON value types, numeric bounds, numeric steps, or color formats.

The socket is app-local and normally enabled only when the Android app is debuggable. Release activation requires an explicit `snapo.tweaks.allow_release` manifest opt-in; release no-op artifacts are preferred. There is no HTTP bearer-token layer: access is controlled by the local socket and the connected ADB boundary. Do not expose a forwarded port or proxy publicly, and treat tweak names and values as potentially sensitive.
