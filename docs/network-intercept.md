---
layout: guide
title: Network Interception · Snap-O
description: Edit Android API responses and return mock data with Snap-O Python route
  handlers.
styles:
- guide.css
- network-intercept.css
languages:
- python
- bash
breadcrumbs:
- label: ← Network Inspector
  href: network-inspector.html
---

# Network Interception

Edit real API responses or return mock data with Python handlers. Test new app states, errors, and delays through your Android app's existing OkHttp integration.
{.lead}

Run handlers with `snapo network intercept` and inspect the results in Network Inspector.

## Check requirements {#requirements data-step="1"}

Start with the [Network Inspector setup](network-inspector.md). Your debug app must use `SnapOOkHttpInterceptor` as an OkHttp application interceptor, including when using Ktor's OkHttp engine. Keep the no-op artifact in release builds.

Run the CLI on macOS or Linux with Python 3 and Android Platform Tools. No Python package installation is needed. The Snap-O desktop app can stay open for inspection, but the CLI does not require it to be running.

The examples assume `snapo` is on your `PATH`. On macOS, you can use `/Applications/Snap-O.app/Contents/MacOS/snapo` instead. On Linux, follow the [CLI installation steps](cli.md#linux-and-standalone-macos).

Connect an authorized device or emulator and launch your debug app. List the available app processes:

``` { .bash title="Terminal" }
snapo network list --json
```

Use the target app's `deviceId` and `socketName` as `SERIAL` and `SOCKET` below. A network socket looks like `snapo_network_12345`.
{style="margin-top: 18px"}

## Intercept your first request {#first-request data-step="2"}

Save this as `prototype.py`. Replace `/api/tasks` with a JSON endpoint your app calls. This handler returns mock data without contacting the server.

``` { .python title="prototype.py" }
from snapo import route


@route("GET", "/api/tasks")
async def tasks(call):
    return call.json({
        "tasks": [{"id": "1", "title": "Example task"}]
    })
```

Check that the file loads, then connect to your app:
{style="margin-top: 18px"}

``` { .bash title="Terminal" }
snapo network intercept prototype.py --check
snapo network intercept prototype.py -s SERIAL -n SOCKET
```

`--check` loads and lists routes without ADB or a device; it does not run the handlers. The CLI provides the `snapo` Python module when it loads your file.
{style="margin-top: 18px"}

1. Wait for **Loaded 1 route(s)** in the terminal.
2. Trigger the matching request in your Android app.
3. Check the app's result and the terminal's method, path, and response status.
4. Open Network Inspector to inspect the response delivered to the app.

Keep the runner open while testing. Press **Ctrl+C** to stop it and remove its routes. Requests already paused by that runner fail; later requests follow the normal network path unless another runner matches them.
{style="margin-top: 18px"}

## Edit responses and mock state {#responses data-step="3"}

### Change a real response {style="margin-top: 0"}

`await call.upstream()` sends the original request on Android through the app's existing OkHttp chain, authentication, and TLS configuration. Edit the returned response and return it to the app. Repeated calls to `upstream()` reuse the same response.

``` { .python title="prototype.py · add a route" }
@route("GET", "/api/profile")
async def profile(call):
    response = await call.upstream()
    response.json["display_name"] = "Space Captain"
    response.headers["X-Demo"] = "profile-preview"
    return response
```

You can edit `response.json`, `response.status`, and `response.headers`. Nested JSON edits are detected when you return the response. Reading JSON without changing it preserves the original body bytes and content headers. For other formats, assign bytes to `response.body` and set the appropriate content type and encoding headers.
{style="margin-top: 18px"}

### Share state between requests

Module variables let handlers share mock state. Replace your file with this example to create and list tasks, with a short delay before each list response.

``` { .python title="prototype.py" }
import asyncio

from snapo import route

saved_tasks = []


@route("POST", "/api/tasks")
async def create_task(call):
    task = {
        "id": str(len(saved_tasks) + 1),
        "title": call.request.json["title"],
    }
    saved_tasks.append(task)
    return call.json(task, status=201)


@route("GET", "/api/tasks")
async def list_tasks(call):
    await asyncio.sleep(0.5)
    return call.json({"tasks": saved_tasks})
```

Handlers run concurrently. Use `await asyncio.sleep(...)` for delays; `time.sleep(...)` blocks every Python handler. To simulate an HTTP error response, return `call.json({"error": "Try again"}, status=503)`.
{style="margin-top: 18px"}

## Match the intended requests {#matching data-step="4"}

Routes match an exact HTTP method and encoded URL path on any host. A leading slash is optional. Query parameters do not affect matching, and paths do not support wildcards or parameters. Unmatched requests continue normally.

Read `call.request.method`, `url`, `path`, `headers`, `body` (bytes), or `json` inside a handler. Changing this request object does not rewrite the request sent upstream. To limit an override to one host or query value, check the full URL in your handler:

``` { .python title="prototype.py · replace the tasks route" }
from urllib.parse import parse_qs, urlsplit

from snapo import route


@route("GET", "/api/tasks")
async def tasks(call):
    url = urlsplit(call.request.url)
    query = parse_qs(url.query)
    if url.hostname != "api.example.com" or query.get("preview") != ["1"]:
        return await call.upstream()
    return call.json({"tasks": []})
```

Each file must contain unique method/path pairs and each handler must use `async def`. Multiple runners can coexist, but overlapping routes select one handler in an unspecified order. Handlers are not chained.
{style="margin-top: 18px"}

## Reload and stop handlers {#reload data-step="5"}

The runner watches your entry file by default. Save an edit to load new handlers for future requests. A successful reload resets module state; in-flight calls keep their original handlers and state. If an edit fails to load, the previous routes stay active. Imported helper files are not watched; restart after changing them.

| Option | Behavior |
| --- | --- |
| `--check` | Load and list routes, then exit without connecting to a device. |
| `--no-watch` | Keep the initially loaded handlers until the runner stops. |
| `--timeout 30` | Set the deadline in seconds, including upstream time. Default: 30; range: 0.1–120. |

Handler errors, deadlines, and runner disconnects fail affected requests. They do not send the request upstream as a fallback. Your app's own retry policy still applies.
{.notice}

Each runner owns its routes and paused requests. Reloading or stopping one runner leaves others active. Ordinary network inspectors may remain connected throughout testing.

## Supported traffic and limits {#limits data-step="6"}

- Interception supports OkHttp HTTP requests, including Ktor's OkHttp engine. HttpURLConnection and WebSocket traffic remain inspection-only; WebSocket upgrades bypass routes.
- Matching requests must have repeatable bodies with a known size of at most 1 MiB. One-shot, duplex, unknown-length, or larger request bodies fail when a route matches.
- Upstream and replacement response bodies are limited to 1 MiB. Replacement status codes must be between 200 and 599.
- Requests with an `Accept` header containing `text/event-stream` bypass interception. An unexpected SSE response to an intercepted upstream call fails without buffering the stream.
- Each runner can register up to 128 routes. An app process can have at most 64 paused exchanges across runners.
- Network Inspector shows the response delivered to the app. It does not show a before/after comparison.

Keep streaming and large-body endpoints outside your route set. Interception limits are separate from the inspector's capture limits.
{style="margin-top: 18px"}

## Troubleshooting {#troubleshooting data-step="7"}

<details markdown="1">
<summary>The app does not support routes</summary>

Update the Snap-O Android dependency, then rebuild and reinstall the app. Updating only the CLI or desktop app does not add interception to an older Android library.

</details>

<details markdown="1">
<summary>No servers appear, or the wrong app is selected</summary>

Check `adb devices`, launch the debug build, and run `network list --json` again. Select its device and socket explicitly. After an app process restarts, reconnect the runner to the new socket.

</details>

<details markdown="1">
<summary>The request does not reach my handler</summary>

Check the method and exact encoded path, including trailing slashes. Confirm the request uses your configured OkHttp client. SSE requests and WebSocket upgrades bypass interception. Avoid overlapping routes in other runners.

</details>

<details markdown="1">
<summary>A request fails or an edit has no effect</summary>

Read the runner's error output. Check body sizes, JSON shape, and the deadline. Return `call.json(...)` or a response from `await call.upstream()` from every handler. Look for a reload error if old behavior persists. `--check` validates loading, not handler execution.

</details>

Try shared state and delays with the [route examples](https://github.com/openai/snap-o/blob/8.0.0/examples/routes.py) and the [OkHttp and Ktor Tasks demos](https://github.com/openai/snap-o/blob/8.0.0/snapo-link-android/samples/README.md). See the [handler API reference](https://github.com/openai/snap-o/blob/8.0.0/skills/snap-o-network-inspector/references/interception.md) and [interception protocol](https://github.com/openai/snap-o/blob/8.0.0/contracts/network/interception.md) for more details.
{style="margin-top: 26px"}
