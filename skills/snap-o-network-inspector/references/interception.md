# Network interception

Use `network intercept` to change HTTP responses delivered to an Android app. The app must use a Snap-O OkHttp integration that supports interception. If it reports unsupported routes, rebuild the app with that integration; updating the CLI alone is insufficient.

## Write and check routes

Resolve `SNAPO_BIN` as described in the skill. Save handlers in a Python file in the user's workspace. Run that file through the bundled CLI, not `python prototype.py`: the CLI provides `from snapo import route` without an installed Python package.

```python
import asyncio

from snapo import route


@route("GET", "/api/profile")
async def profile(call):
    response = await call.upstream()
    response.json["display_name"] = "Space Captain"
    return response


@route("GET", "/api/tasks")
async def tasks(call):
    await asyncio.sleep(0.5)
    return call.json({"tasks": [{"id": "1", "title": "Example task"}]})
```

Adapt the method, path, and response shape to the app. The profile handler sends the original request through Android, then edits its response. The tasks handler returns synthetic JSON without contacting the server. Every handler must use `async def` and return a response; returning a plain dictionary or `None` fails the request.

Validate the file before connecting:

```bash
"$SNAPO_BIN" network intercept /path/to/prototype.py --check
```

`--check` loads the file and prints its routes without ADB or a device. It executes module-level code but does not run handlers or prove the app supports interception.

## Run and verify

List servers with `network list --json`, then select the device serial and network socket:

```bash
"$SNAPO_BIN" network intercept /path/to/prototype.py -s <serial> -n <socket_name>
```

Keep the runner alive while triggering the matching request in the app. Wait for `Loaded N route(s)` before reproducing the behavior. Check runner logs for the method, path, and returned status, or handler errors. `network requests` and `network show` can inspect the delivered response from another connection. Inspection shows what the app received, without a before/after diff; also verify the requested app behavior.

Stop this runner with Ctrl-C when the override session is finished, unless the user wants it left running. Stopping removes its routes and fails its paused calls. New calls then follow normal behavior unless another runner matches them.

## Matching and response APIs

- Routes match the exact HTTP method and encoded URL path on any host. A leading slash is optional. Query parameters are ignored. Wildcards, regular expressions, and `network requests --filter` syntax are not supported for routes.
- For host or query conditions, inspect `call.request.url` inside the handler. Return `await call.upstream()` when the condition does not apply. Requests without a matching route follow their normal path.
- Register between 1 and 128 unique method/path pairs per file. Avoid overlapping routes across runners: only one matching handler runs, and selection order is unspecified.
- `call.request` exposes `method`, `url`, `path`, `headers`, `body` (bytes), and `json`. Editing it does not rewrite the original request.
- `await call.upstream()` uses the Android app's authentication and transport. Repeated calls reuse the same response; they do not resend the request. For a mocked operation that must avoid server changes, return a synthetic response without calling upstream.
- Edit `response.json`, `response.status`, or `response.headers`, then return the response. Nested JSON edits are detected. Reading JSON alone preserves the original body. `response.body` accepts bytes; when replacing raw bytes, keep content type and encoding consistent with them.
- `call.json(value, status=201, headers={"X-Example": "mock"})` creates a synthetic response. Status defaults to 200; supported response statuses are 200–599. Responses to HEAD and statuses 204, 205, and 304 have no delivered body.
- Headers are case-insensitive. Use `headers.add(name, value)` and `headers.get_all(name)` for repeated values. The runner adjusts content length and removes transfer framing. JSON edits also set JSON content type and remove content encoding.

## Reloads, state, and failures

The runner watches the entry file by default. Successful reloads reset module state for new calls. Calls already in progress finish with their original handlers and state. Invalid file edits keep the previous handlers active; check the reload logs. Only the entry file is watched, so restart after changing imported helpers. `--no-watch` disables automatic reloads.

Module variables can share state across handlers. Handlers run concurrently; use `await asyncio.sleep(...)` for delays or `asyncio.Event` for coordination. Blocking calls such as `time.sleep(...)` block all handlers.

`--timeout 30` sets the deadline in seconds, including upstream waiting time. The default is 30; accepted values are 0.1–120. Handler errors and deadlines fail the affected request without sending it upstream as a fallback. The app's own retry policy still applies. Each runner owns its routes: stopping or reloading one leaves other runners active.

## Supported traffic

Interception supports bounded, non-streaming OkHttp HTTP traffic with bodies up to 1 MiB. Request bodies must be repeatable and declare their size. Requests accepting SSE and WebSocket upgrades bypass interception. Unexpected SSE responses fail without buffering the stream. HttpURLConnection traffic remains inspection-only.

Use the normal network path for larger uploads and streaming traffic. Interception uses the app's existing transport and does not require a proxy certificate.
