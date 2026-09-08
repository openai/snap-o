---
layout: guide
title: Tweaks Protocol · Snap-O
description: Reference for the Snap-O Tweaks HTTP and event-stream protocol, including
  protocol versions, endpoints, JSON responses, updates, resets, actions, and errors.
styles:
- guide.css
- tweaks-protocol.css
languages:
- json
- http
breadcrumbs:
- label: Snap-O
  href: index.html
- label: Tweaks Guide
  href: tweaks.html
---

# Tweaks Protocol

Read live Compose values, change or reset them, invoke app-owned actions, and subscribe to updates through the Snap-O Tweaks HTTP and event-stream protocol.
{.lead}

## Protocol overview {#overview data-step="1"}

The Tweaks module exposes HTTP over an app-local abstract Unix-domain socket. Snap-O, custom clients, and authorized agents connect through ADB forwarding. The server does not listen on an Android TCP port or a public network interface, and does not require the `INTERNET` permission.

``` { .shell title="Terminal · discover and connect" }
serial=emulator-5554
socket=snapo_tweaks_12345

adb -s "$serial" shell cat /proc/net/unix
port="$(adb -s "$serial" forward tcp:0 "localabstract:$socket")"
base="http://127.0.0.1:$port"

curl -fsS "$base/app"
curl -fsS "$base/tweaks"
```

Socket names follow `snapo_tweaks_<pid>`. Keep the forward alive while your client uses it, and discover and forward the new socket again when the Android app process restarts. When finished, remove only the forward you created:

``` { .shell title="Terminal · remove your ADB forward" }
adb -s "$serial" forward --remove "tcp:$port"
```

The Snap-O CLI manages this discovery and cleanup automatically. For a remote ADB server, an ADB forward is local to the server’s host; tunnel it to your client, or use the CLI with both `--adb-host` and `--adb-port` for direct ADB transport.

Debug builds enable the server by default. A nondebuggable app can enable it only by including the real Tweaks dependency and setting `snapo.tweaks.allow_release` to `true` in its application's `<application>` metadata. Release no-op artifacts remain the recommended default. See [release setup](tweaks.md#install) for the manifest example. Network Inspector has its own independent `snapo.network.allow_release` opt-in.

When its optional dependency is installed and its developer setting is enabled, the on-device floating panel observes the same tweak registry directly. Changes from the panel, Snap-O, and custom clients update that shared registry without a separate panel-specific HTTP connection. Host applications observe updates through the event stream or their normal refresh behavior. See the [floating overlay setup](tweaks.md#floating-overlay) for Android integration.

| Method | Endpoint | Purpose |
| --- | --- | --- |
| `GET` | `/app` | Read app metadata and the supported protocol version. |
| `GET` | `/app/icon` | Read the app icon. |
| `GET` | `/tweaks` | List currently composed value tweaks and actions. |
| `GET` | `/tweaks?include=adjusted` | Include inactive, previously adjusted value tweaks. |
| `PATCH` | `/tweaks` | Update or reset one or more live values. |
| `POST` | `/tweaks/action` | Invoke a registered, parameterless app-owned action. |
| `GET` | `/tweaks/events` | Subscribe to complete live tweak and action snapshots. |

**Composition determines visibility.** Value tweaks and actions can be changed, invoked, or streamed only while their owners are in composition. The adjusted-history endpoint can also return inactive, read-only value snapshots.
{.notice}

## GET /app {#get-app data-step="2"}

Read the running app’s user-visible name, Android package name, and supported Tweaks protocol version. Request this endpoint first so your client can select compatible behavior.

``` { .http title="Example Request" }
GET /app HTTP/1.1
Host: 127.0.0.1
```

``` { .json title="Example Response · 200 OK" }
{
  "name": "Snap-O Tweaks Demo",
  "packageName": "com.openai.snapo.demo.tweaks",
  "protocolVersion": 4
}
```

| Version | Behavior |
| --- | --- |
| `1` | Value tweaks only. Updates are atomic, and resets send the reported default. A missing `protocolVersion` means version 1. |
| `2` | Adds action descriptors and `POST /tweaks/action`. Batch updates and resets retain version-1 behavior. |
| `3` | Applies valid batch items independently and reports rejected items in `errors`. Resets still send the reported default. |
| `4` | Adds explicit `null` resets and authoritative, sparse `modified: true` status. |

The Tweaks protocol version is independent of the Network Inspector protocol version.

## GET /app/icon {#get-app-icon data-step="3"}

Read the running app’s icon. Use the response’s `Content-Type` without assuming a particular image format or size.

``` { .http title="Example Request" }
GET /app/icon HTTP/1.1
Host: 127.0.0.1
```

``` { .http title="Example Response · 200 OK" }
HTTP/1.1 200 OK
Content-Type: <image media type>

<image bytes>
```

The server returns `404 Not Found` if an app icon cannot be loaded.
{.notice}

## GET /tweaks {#get-tweaks data-step="4"}

List value tweaks and app-owned actions currently in composition. Value descriptors include their full name, type, default, and current value. Numeric controls also include any configured `min`, `max`, and `step`.

``` { .http title="Example Request" }
GET /tweaks HTTP/1.1
Host: 127.0.0.1
```

``` { .json title="Example Response · 200 OK" }
{
  "tweaks": [
    {
      "name": "Typography/Font size",
      "type": "int",
      "default": 36,
      "value": 48,
      "modified": true,
      "min": 16,
      "max": 72,
      "step": 1
    },
    {
      "name": "Colors/Text",
      "type": "color",
      "default": "#18212F",
      "value": "#18212F"
    },
    {
      "name": "Motion/Show",
      "type": "boolean",
      "default": true,
      "value": true
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
      "name": "Motion/Toggle animation",
      "type": "action"
    }
  ]
}
```

Supported value types are `int`, `float`, `boolean`, `color`, `string`, and `enum`. Colors use `#RRGGBB` or `#RRGGBBAA`. Enum descriptors include an ordered, nonempty `options` array; their default, value, and updates use an exact option name. Preserve the declared option order in clients.

Actions use `"type": "action"` and have no `default`, `value`, `modified`, options, or numeric constraints. Invoke them through `POST /tweaks/action` rather than patching their descriptors.

**Modification status is authoritative in version 4.** Only modified values include `"modified": true`. An absent field means false, even if `value` differs from `default`. App-owned settings report whether their own override exists; do not infer their status from their effective value. Versions 1–3 omit this field, so compare `value` with `default` instead.
{.notice}

Compose color defaults retain their original color space and precision in the app, while HTTP represents them as sRGB hex. `Color.Unspecified` appears as `#00000000`. An explicit version-4 reset restores the original Compose value, including when that value does not round-trip through its sRGB hex form.

Integer values must be whole numbers. Floating-point values may be whole or fractional. When present, a numeric `step` is relative to `min`, or to the tweak's `default` when no minimum is specified. Reusing an ordinary tweak name shares one value across active composables; its type, default, constraints, and enum options must match. App-owned sources sharing a name must represent the same setting and value type. Their first active source owns the value until it leaves composition.

## GET /tweaks?include=adjusted {#adjusted-tweaks data-step="5" data-nav="Adjusted history"}

Include previously adjusted value tweaks after their owners leave composition. The response retains the same descriptor shape as `GET /tweaks` and includes every active value and action as well as inactive, adjusted value snapshots.

``` { .http title="Example Request" }
GET /tweaks?include=adjusted HTTP/1.1
Host: 127.0.0.1
```

``` { .json title="Example Response · 200 OK" }
{
  "tweaks": [
    {
      "name": "Typography/Font size",
      "type": "int",
      "default": 36,
      "value": 48,
      "modified": true,
      "min": 16,
      "max": 72,
      "step": 1
    },
    {
      "name": "Settings/Reduce motion",
      "type": "boolean",
      "default": false,
      "value": true
    }
  ]
}
```

Each retained snapshot preserves its complete descriptor, latest effective value, and modification status. History can remain after a reset; an app-owned value may then differ from its captured default without being modified, as shown above. Separate screens may reuse a name with different descriptors, so preserve repeated names instead of deduplicating them. An active descriptor takes precedence over its matching historical snapshot.

**Inactive history is read-only.** Only active value tweaks can be updated or reset. App-owned history keeps an immutable snapshot, not its source or observers, and never replays an old value into a returning source. Actions do not create adjustment history. Retention ends when the app process exits.
{.notice}

Unchanged tweaks, no-op adjustments, and rejected updates do not create history entries. Plain `GET /tweaks` and event snapshots remain active-only. The only supported query is exactly `include=adjusted` on `GET /tweaks`; unsupported, repeated, or additional query parameters return `400 Bad Request`.

## PATCH /tweaks {#patch-tweaks data-step="6"}

Update one or more registered tweaks in a single request. Send `application/json` and put the complete tweak names and their new primitive values in a `values` object. In version 4, use `null` for an explicit reset.

``` { .http title="Example Request" }
PATCH /tweaks HTTP/1.1
Host: 127.0.0.1
Content-Type: application/json
Content-Length: 78

{
  "values": {
    "Typography/Font size": 48,
    "Motion/Show": false
  }
}
```

``` { .json title="Example Response · 200 OK" }
{
  "tweaks": [
    {
      "name": "Typography/Font size",
      "value": 48,
      "modified": true
    },
    {
      "name": "Motion/Show",
      "value": false,
      "modified": true
    }
  ]
}
```

**Version 3 and later use best-effort batches.** Valid changes remain applied even if another item fails. A valid request returns `200 OK` with successful items in `tweaks` and rejected items in an optional `errors` array. Versions 1 and 2 validate the whole batch before applying it and reject every change if any item fails.
{.notice}

### Partial success

Unknown or inactive names, invalid values, and action targets become per-item errors without rolling back successful values. Every error contains only its tweak `name` and `error` message. The `errors` field is absent when every item succeeds.

``` { .json title="Example Response · 200 OK · Partial Success" }
{
  "tweaks": [
    {
      "name": "Typography/Font size",
      "value": 48,
      "modified": true
    }
  ],
  "errors": [
    {
      "name": "Motion/Show",
      "error": "Invalid value for Motion/Show: Expected a boolean."
    }
  ]
}
```

### Reset a value

In version 4, reset an active value by sending `null`. Updates and resets can appear in the same request. Actions cannot be patched or reset.

``` { .json title="Example Request · Version 4 Reset" }
{
  "values": {
    "Typography/Font size": null,
    "Motion/Show": null
  }
}
```

``` { .json title="Example Response · 200 OK" }
{
  "tweaks": [
    {
      "name": "Typography/Font size",
      "value": 36
    },
    {
      "name": "Motion/Show",
      "value": true
    }
  ]
}
```

Ordinary tweaks reset to their original defaults. App-owned tweaks call their source’s `reset()` behavior, such as removing a stored override, and return its current effective value. That value can differ from the default first observed by Snap-O; writing the captured default would create an override instead of clearing it. Reset all only active, non-action values marked `"modified": true`.

Versions 1, 2, and 3 do not support explicit `null` resets. Reset their changed values by sending each descriptor’s reported `default` instead.

## POST /tweaks/action {#tweak-actions data-step="7"}

Invoke one app-owned, parameterless action registered with `TweakAction`. Actions are available from protocol version 2 and run synchronously on the Android main thread.

``` { .http title="Example Request" }
POST /tweaks/action HTTP/1.1
Host: 127.0.0.1
Content-Type: application/json
Content-Length: 39

{
  "name": "Motion/Toggle animation"
}
```

``` { .json title="Example Response · 200 OK" }
{
  "name": "Motion/Toggle animation"
}
```

The JSON body must contain exactly one nonblank string field, `name`. Unknown names and value-only names return `404 Not Found`. Additional fields, arguments, blank names, and malformed requests return `400 Bad Request`.

### Conflicting actions

When more than one live owner registers the same action name, its descriptor remains visible but is marked as conflicted:

``` { .json title="Example Descriptor · Conflicting Action" }
{
  "name": "Motion/Toggle animation",
  "type": "action",
  "conflicted": true
}
```

**Conflicting actions cannot run.** Invoking one returns `409 Conflict` until exactly one owner remains. Register each shared action once at the composable that owns its behavior. The server never chooses between callbacks or executes arbitrary code.
{.notice}

## GET /tweaks/events {#tweak-events data-step="8"}

Subscribe to the current full tweak snapshot and subsequent changes as controls are registered, removed, or updated. The response uses server-sent events with the `text/event-stream` content type.

``` { .http title="Example Request" }
GET /tweaks/events HTTP/1.1
Host: 127.0.0.1
Accept: text/event-stream
```

``` { .http title="Example Response · 200 OK" }
HTTP/1.1 200 OK
Content-Type: text/event-stream; charset=utf-8
Cache-Control: no-cache

event: tweaks
data: {"tweaks":[{"name":"Typography/Font size","type":"int","default":36,"value":36,"min":16,"max":72,"step":1},{"name":"Motion/Toggle animation","type":"action"}]}

event: tweaks
data: {"tweaks":[{"name":"Typography/Font size","type":"int","default":36,"value":48,"modified":true,"min":16,"max":72,"step":1},{"name":"Motion/Toggle animation","type":"action"}]}

: keep-alive
```

Each `tweaks` event contains a complete current snapshot of active values and actions, not a patch. Replace your client’s current control list with the received `tweaks` array. Lines starting with `:` are keep-alive comments.
{.notice}

The first event arrives immediately. Later changes made within the same Android main-thread turn are combined into one ordered snapshot, including values changed by the on-device overlay or an app-owned source. An omitted tweak or action has left composition. Inactive adjustment history never appears in event snapshots. Slow clients receive the newest complete snapshot instead of accumulating every intermediate state.

**Browser clients need a same-origin proxy.** The Android server does not provide CORS headers or handle browser `OPTIONS` preflight. Serve your interface and its forwarded API through the same origin; native and server-side HTTP clients do not have this restriction.
{.notice}

## Error responses {#errors data-step="9"}

Request-level failures return a JSON object containing an `error` message and the relevant HTTP status. These failures are distinct from the per-item `errors` returned inside successful version-3 and version-4 batch responses.

``` { .json title="Example Response · 422 Unprocessable Entity" }
{
  "error": "Tweak values must be primitive JSON values."
}
```

| Status | Meaning |
| --- | --- |
| `400 Bad Request` | Malformed request, unsupported query, invalid JSON, or an invalid update or action request body. |
| `404 Not Found` | Unknown endpoint, unavailable icon, unknown action, or a version-1 or version-2 tweak not currently in composition. |
| `405 Method Not Allowed` | Unsupported endpoint method. The `Allow` response header lists valid methods. |
| `408 Request Timeout` | The request did not complete within the server’s timeout. |
| `409 Conflict` | More than one live owner registered the requested action name. |
| `413 Payload Too Large` | The JSON request exceeds the server’s maximum request size. |
| `422 Unprocessable Entity` | An invalid numeric literal or nonprimitive value; versions 1 and 2 also reject an invalid tweak value at the request level. |
| `500 Internal Server Error` | An unexpected failure occurred while updating a tweak or invoking an action callback. |
| `503 Service Unavailable` | The connection limit was reached, or the Android main thread is unavailable. |
| `504 Gateway Timeout` | A tweak update, initial snapshot, or action timed out waiting for the Android main thread. |

**Inspect both the HTTP status and the response body.** In versions 3 and 4, an invalid, unknown, inactive, or action update can appear in `errors` even when the response status is `200 OK`. Each item contains only `name` and `error`; it does not include a separate HTTP status or error code.
{.notice}
