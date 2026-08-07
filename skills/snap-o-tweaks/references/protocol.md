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
| `GET /app` | JSON app metadata: `{"name":"Example","packageName":"com.example","protocolVersion":4}`. |
| `GET /app/icon` | Optional application icon image; `404` if unavailable. Use its response `Content-Type` without assuming a particular format or size. |
| `GET /tweaks` | Current active tweak and app-owned action descriptors. |
| `GET /tweaks?include=adjusted` | Active descriptors plus previously adjusted ordinary or app-owned value snapshots retained outside composition. |
| `PATCH /tweaks` | One update containing one or more named values. Version 3 and later apply valid entries and report individual errors. |
| `POST /tweaks/action` | Invoke one explicitly registered parameterless app-owned action by name. |
| `GET /tweaks/events` | Server-sent events containing complete current tweak and action snapshots. |

Ordinary responses close their connection and include a content length. The event response stays open and uses `Content-Type: text/event-stream`.

`protocolVersion` is specific to Tweaks and independent of the Network Inspector protocol. Version 1 predates this field and supports only value tweaks; treat a missing version as 1. Version 2 adds app-owned action descriptors and `POST /tweaks/action`. Version 3 adds best-effort batch updates with per-item errors. Version 4 adds explicit null resets and authoritative modification status. Use the reported version to select compatible update, status, and reset behavior.

### Read metadata and active values

```bash
curl -fsS "$base/app"
curl -fsS "$base/tweaks"
curl -fsS "$base/tweaks?include=adjusted"
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
      "modified": true,
      "min": 100,
      "max": 1500,
      "step": 50
    },
    {
      "name": "Motion/Enabled",
      "type": "boolean",
      "default": true,
      "value": false,
      "modified": true
    },
    {
      "name": "Appearance/Theme",
      "type": "enum",
      "default": "System",
      "value": "Dark",
      "modified": true,
      "options": ["System", "Light", "Dark"]
    },
    {
      "name": "Preview/Refresh visible content",
      "type": "action"
    }
  ]
}
```

In protocol version 4, only modified value tweaks include `"modified": true`. A missing `modified` field always means false, even when `value` differs from `default`; never infer version-4 status by comparing those fields. Registry-owned tweaks compare their current value with their default, while app-owned tweaks report whether their owner has an override. In versions 1, 2, and 3, `modified` is absent; compare `value` with `default` instead. Actions never include `modified`.

The available value types are `int`, `float`, `boolean`, `color`, `string`, and `enum`. Preserve actual JSON types: booleans are not strings, integer values cannot be fractional, and floats accept whole or fractional finite numbers. Colors are strings in `#RRGGBB` or `#RRGGBBAA` format. Numeric descriptors may include `min`, `max`, and `step`; step alignment starts at `min`, or at `default` if there is no minimum. Actions use `"type":"action"` and have no `value`, `default`, or `options`.

Enum descriptors include a nonempty, ordered `options` array containing unique, nonblank enum name strings. The `default` and current `value` are names from that list. Send an exact option name in `PATCH /tweaks`.

An action descriptor with `"conflicted":true` has multiple live registrations for the same name. It remains visible so clients can surface the conflict, but the server rejects invocation instead of choosing a callback, merging owners, or inventing unstable names. Register a shared action once at its owner, or use explicit, stable, unique names for distinct actions.

Plain `GET /tweaks` includes only value and action declarations active in Compose. An app-owned tweak's first observation initializes its value and modification status on the Android main thread; subsequent inspector requests read an immutable cached snapshot without accessing its source. Add `?include=adjusted` to include ordinary or app-owned tweaks successfully adjusted through the inspector, including immutable snapshots whose declarations have since left composition. Each snapshot preserves its complete descriptor, effective value, and authoritative modification status; app-owned sources, callbacks, and observers are not retained, and values are not replayed into returning sources. Untouched tweaks, no-op adjustments, and rejected updates do not create history. The expanded response also includes current active tweaks and actions; actions have no adjustment history. Separate screens can reuse a value tweak name with different complete declarations; preserve every returned descriptor instead of deduplicating by name. An active descriptor takes precedence over its matching historical snapshot. An adjusted tweak that was later reset can remain in the history without `modified`, even if its effective value differs from its captured default. Retention lasts for the current app process and is cleared with the registry.

Names may contain spaces and `/`; send the entire name unchanged. Two active declarations of the same complete value descriptor observe the same value. App-owned sources with the same name must use the same setting and value type. The first active source handles their value, updates, resets, and modification status. Only its `observe()` flow is collected. When it leaves composition, the next active source takes over. Conflicts are not checked and can cause wrong values or runtime errors. Repeated value names in expanded results represent distinct complete descriptors; active-only snapshots and updates still resolve at most one currently active value descriptor per name. Historical descriptors are read-only while inactive: `PATCH /tweaks` still rejects their names until their declarations return. Separate active callbacks with the same action name are not interchangeable and are reported as conflicted.

### Update or reset values

```bash
curl -fsS -X PATCH "$base/tweaks" \
  -H 'Content-Type: application/json' \
  -d '{"values":{"Motion/Duration":550,"Motion/Enabled":false,"Appearance/Theme":"Dark"}}'
```

The response contains the changed names and their resulting values:

```json
{"tweaks":[{"name":"Motion/Duration","value":550,"modified":true},{"name":"Motion/Enabled","value":false,"modified":true},{"name":"Appearance/Theme","value":"Dark","modified":true}]}
```

Protocol versions 3 and later apply valid entries independently. Invalid, unknown, inactive, or action entries appear in `errors` with their tweak names and error messages, while successful changes remain applied:

```json
{"tweaks":[{"name":"Motion/Duration","value":550,"modified":true}],"errors":[{"name":"Motion/Enabled","error":"Invalid value for Motion/Enabled: Expected a boolean."}]}
```

The `errors` field is absent when every entry succeeds. Versions 1 and 2 reject the entire batch if any entry is invalid. In version 4, reset a value by sending `null` instead of a replacement value:

```bash
curl -fsS -X PATCH "$base/tweaks" \
  -H 'Content-Type: application/json' \
  -d '{"values":{"Motion/Enabled":null}}'
```

A version-4 registry-owned reset restores its original default. An app-owned reset calls the source's `reset()` method and returns its current effective value, which may differ from the captured default. For version 4, reset all by sending `null` only for active, non-action descriptors with `"modified": true`. For versions 1, 2, and 3, compare each value with its default and reset changed values by sending their defaults. Actions cannot be patched or reset. There is no separate get-by-name, reset, delete, or grouping endpoint.

### Invoke an app-owned action

```bash
curl -fsS -X POST "$base/tweaks/action" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Preview/Refresh visible content"}'
```

The name identifies an explicitly registered, parameterless app callback. Android apps expose these callbacks using the `TweakAction(name) { ... }` composable, imported from `com.openai.snapo.tweaks.TweakAction`. Declaring the action returns `Unit`, does not execute its callback, and registers it only while its owner remains in composition. A successful response is HTTP 200 with the invoked action's name:

```json
{"name":"Preview/Refresh visible content"}
```

Unknown names and value-only names return HTTP 404; conflicting live action registrations return HTTP 409. Malformed request bodies return HTTP 400, and unsupported methods return HTTP 405. The endpoint does not accept arguments, schemas, scripts, or arbitrary code.

### Watch complete snapshots

```bash
curl --no-buffer "$base/tweaks/events"
```

```text
event: tweaks
data: {"tweaks":[{"name":"Motion/Enabled","type":"boolean","default":true,"value":true}]}

: keep-alive

event: tweaks
data: {"tweaks":[{"name":"Motion/Enabled","type":"boolean","default":true,"value":false,"modified":true}]}

```

The first event is the complete current active list. Every later `event: tweaks` is also a complete, ordered replacement snapshot of active values and actions, not a delta. Historical inactive tweaks are not included in event snapshots; request `GET /tweaks?include=adjusted` separately when their retained values are needed. Remove items absent from the newest snapshot. Ignore lines starting with `:`; they are idle keepalives. Reconnect and replace state when the app process or socket changes.

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

Request-level errors use `{"error":"description"}`. Expect `400` for malformed input, `404` for missing endpoints, `405` for unsupported methods, `409` for conflicting action registrations, `413` for oversized bodies, and `422` for invalid numeric literals or nonprimitive values. Versions 1 and 2 also return `404` for inactive tweaks and `422` for invalid values. Versions 3 and later report unknown or invalid tweaks as named per-item errors in an HTTP 200 response.

The socket is app-local and normally enabled only when the Android app is debuggable. Release activation requires an explicit `snapo.tweaks.allow_release` manifest opt-in; release no-op artifacts are preferred. There is no HTTP bearer-token layer: access is controlled by the local socket and the connected ADB boundary. Do not expose a forwarded port or proxy publicly, and treat tweak names and values as potentially sensitive.
