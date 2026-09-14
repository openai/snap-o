---
layout: guide
title: Build a tool · Snap-O
description: Build an Android tool with HTTP routes, live events, and a frontend in Snap-O's Tool pane.
styles:
- guide.css
languages:
- kotlin
- toml
- typescript
- jsx
- tsx
- json
- bash
breadcrumbs:
- label: Snap-O
  href: index.html
---

# Build a tool

Build a debugging tool for your Android app and use it from Snap-O on your Mac.
{.lead}

## About tools {#model data-nav="About tools"}

A tool plugin connects your tool to Snap-O. For a tool with a web frontend, that integration has three parts:

- **An Android socket serving HTTP.** Your app opens a named socket. Snap-O forwards HTTP requests from the frontend to that socket over ADB.
- **A tool plugin manifest.** Android resources describe the tool's ID, display name, icon, and frontend asset path.
- **A frontend ZIP.** Your app's APK contains a ZIP of web assets. Snap-O opens it in a WebView. The frontend uses the host SDK to interact with the Mac app and HTTP requests to communicate with the Android app.

### How Snap-O uses a tool {#how-the-ui-talks-to-your-app}

1. **The Android app starts the server.** Your app's initialization code opens the tool's named socket and starts serving HTTP.
2. **Snap-O discovers the tool.** Snap-O scans the device for tool sockets to find running apps. It reads their tool manifests to identify the available tools.
3. **Snap-O loads the frontend.** When you select a tool, Snap-O opens its frontend ZIP from the APK in the Tool pane.
4. **The frontend communicates with the app.** It sends HTTP requests, which Snap-O forwards to the app over ADB. Your server handles the requests and can stream updates.

## Define the tool's identity {#definition data-step="1"}

We recommend Snap-O's Tool Packager Gradle Plugin to simplify tool development and packaging. Apply it in the Android library module that contains your tool.

Snap-O's Tool Packager Gradle Plugin builds your web frontend, packages it into a ZIP, and includes it in the Android build. It also generates the descriptor and manifest entry that Snap-O uses to identify your tool and find its frontend.

### Getting started with the Tool Packager Gradle Plugin {#the-build-plugin-comopenaisnapoplugin}

We recommend Node and npm for frontend development and testing. The plugin's default frontend build uses them, but you can package existing frontend files with `frontendAssets` without running npm.

The plugin downloads Node.js 22.23.2 and uses its bundled npm for Android Studio and CI builds. You do not need either on Gradle's `PATH`. Direct `npm` commands still require a local Node installation. Apps consuming a finished tool library do not need Node or npm.

The Node Gradle plugin adds its download repository automatically. If your build uses `FAIL_ON_PROJECT_REPOS` or `PREFER_SETTINGS`, follow the [central repository setup](https://github.com/openai/snap-o/blob/main/tool-sdk/gradle-plugin/README.md#repositories-declared-in-settings). The Example project already includes that override because it forbids project repositories.

``` { .toml title="gradle/libs.versions.toml" }
[versions]
snapo = "8.0.0"

[plugins]
snapo-tool-packager = { id = "com.openai.snapo.tool-packager", version.ref = "snapo" }
```

The plugin resolves from Maven Central. Most projects already have `mavenCentral()` in `pluginManagement.repositories`; add it if needed. Keep your existing Android Gradle configuration.

### Configure your tool {#manifest}

Apply the Tool Packager Gradle Plugin to your Android library module and set its identity:

``` { .kotlin title="Your tool module's build.gradle.kts" }
plugins {
    alias(libs.plugins.snapo.tool.packager)
}

snapoTool {
    id = "your-tool"
    displayName = "Your tool"
    icon = "@drawable/tool_icon"
}
```

Set `id`, `displayName`, and `icon` for your tool. The ID must be unique within the app and stay stable across releases. Use lowercase letters, digits, dots, or hyphens, starting with a letter.

The icon must be an Android drawable or mipmap resource, referenced as `@drawable/tool_icon` or `@mipmap/tool_icon`. Android checks that the resource exists when linking the app.

The frontend ships with its Android server, so you do not need to configure or check a protocol version.

The frontend directory defaults to `frontend/` inside your tool module. Set `frontendDirectory` only if your web project is elsewhere.

<details markdown="1">
<summary>Configuration limits and custom frontend builds</summary>

| Property | Required or default | Meaning |
| --- | --- | --- |
| `id` | Required | Stable tool ID, up to 100 characters. |
| `displayName` | Required | Nonblank name shown in Snap-O, up to 200 characters. |
| `icon` | Required | Android drawable or mipmap resource reference. |
| `frontendDirectory` | `frontend/` | npm project containing `package.json` and `package-lock.json`. |
| `frontendAssets` | Output of `toolBuild` | Built frontend files, including `index.html`. |

These are Gradle properties: assign values directly or use `.set(...)` with a provider. The default `toolBuild` task runs `npm run build`, which must write to `frontendDirectory/dist/`.

To package files you have already built, set `frontendAssets`. Gradle then skips the default npm tasks:

``` { .kotlin title="Package existing frontend files" }
snapoTool {
    frontendAssets = layout.projectDirectory.dir("prebuilt-frontend")
}
```

You can also set `frontendAssets` from another task's output directory provider. Gradle runs that task before packaging.

Use the existing `node` extension if your frontend needs another Node version: `node { version.set("24.21.0") }`. To use Node and npm from Gradle's `PATH`, set `node { download.set(false) }`.

The plugin generates `SnapOTool.ID` in your Android module's namespace. Each module defines one tool; give each tool module its own namespace.

The plugin also generates `hostApiVersion`, which lets Snap-O check frontend compatibility before loading it. It is not an author setting. If your tool has independently shipped clients, define their compatibility rules through your own HTTP endpoints.

</details>

## Serve HTTP on Android {#the-android-library-tool-core data-step="2"}

### How the socket connects to Snap-O {#android}

The tool serves HTTP over an Android abstract Unix socket named `snapo_<tool-id>_<pid>`. The name combines the tool ID from your Gradle configuration with the running app's process ID. Snap-O finds this socket and forwards the frontend's HTTP requests to it over ADB.

### Use the Android Tool SDK {#starter}

Add `tool-core` to your Android module. Its `ToolServer` opens the socket, handles HTTP requests, and calls your route handlers. You define the routes and choose when to start the server.

<details id="support-requests-from-the-webview" markdown="1">
<summary>What the server handles for you</summary>

- Opens the named socket and accepts connections in the background.
- Parses HTTP requests and writes responses from your handlers.
- Answers `OPTIONS` readiness checks and browser preflight requests.
- Validates `Host` and `Origin` headers for Snap-O's WebView and loopback development servers.
- Adds cross-origin response headers so the frontend can call your routes with `fetch` and `EventSource`.
- Limits request sizes, concurrent connections, and read and write times.
- Formats SSE events, sends heartbeat comments, and cancels stream handlers when clients disconnect.

See the [browser access rules](https://github.com/openai/snap-o/blob/main/contracts/network/README.md#limits-and-lifecycle) and [server implementation](https://github.com/openai/snap-o/blob/main/tool-sdk/core/src/main/java/com/openai/snapo/tool/ToolBrowserAccess.kt) for the exact host and origin checks.

</details>

<div class="dependency-tabs" data-label="Android Tool SDK dependency format" markdown="1">
<div id="tool-sdk-catalog-panel" data-tab="Version catalog" markdown="1">

``` { .toml title="gradle/libs.versions.toml" }
[versions]
snapo = "8.0.0"

[libraries]
snapo-tool-core = { module = "com.openai.snapo:tool-core", version.ref = "snapo" }
```

``` { .kotlin title="Your Android module's build.gradle.kts" }
dependencies {
    implementation(libs.snapo.tool.core)
}
```

</div>
<div id="tool-sdk-direct-panel" data-tab="Direct dependency" markdown="1">

``` { .kotlin title="Your Android module's build.gradle.kts" }
dependencies {
    implementation("com.openai.snapo:tool-core:8.0.0")
}
```

</div>
</div>

The library comes from Maven Central. Most Android projects already include `mavenCentral()` in their dependency repositories.

This example returns a JSON message:

``` { .kotlin title="Handle an example request" }
import com.openai.snapo.tool.ToolServer

fun createToolServer(toolId: String): ToolServer = ToolServer(toolId) {
    get("/example") {
        respondJson("""{"message":"Hello, world!"}""")
    }
}
```

`respondJson` accepts a JSON string. Use your app's serializer to encode objects.

<details markdown="1">
<summary>Routes, request data, and custom responses</summary>

Use `get`, `post`, `put`, `patch`, or `delete` to register a handler. Use `route(method, path)` for another uppercase HTTP method. Snap-O handles `OPTIONS` automatically.

Paths can contain parameters, such as `/items/{id}`. Put fixed paths before overlapping patterns; the first match handles the request. Unknown paths return 404. Unsupported methods on known paths return 405 with an `Allow` header.

Inside a handler, these properties provide request data:

| Property | Meaning |
| --- | --- |
| `pathParameters` | Decoded path parameters. `+` remains a plus sign. |
| `request.method` | HTTP method. |
| `request.path` | Path without its query; URL escapes remain encoded. |
| `request.requestTarget` | Original path and query. |
| `request.queryParameters` | Decoded query names mapped to lists of values, including repeated values. |
| `request.headers` | Headers with lowercase names. |
| `request.body` | Body bytes. |
| `request.bodyText()` | Body decoded as strict UTF-8. |

The server creates `ToolHttpRequest` instances. Request construction and HTTP parsing are internal.

Use `respondJson(json, statusCode)`, `respondText(text, statusCode)`, or `respondNoContent()`. The first two default to status 200. A handler sends one response; returning without one sends 204.

For custom content types or headers, use `respond(ToolHttpResponse(...))`:

``` { .kotlin title="Return a custom response" }
respond(
    ToolHttpResponse(
        statusCode = 200,
        body = "one,two\n".toByteArray(),
        contentType = "text/csv; charset=utf-8",
        headers = mapOf("X-Example" to "sample"),
    ),
)
```

Import `ToolHttpResponse` from `com.openai.snapo.tool`. Set `exposedHeaders` inside `ToolServer` if the frontend must read custom response headers. `vary` defaults to `"Origin"`; extend it if responses also vary by other request headers.

Handle expected domain errors in the route or a shared helper. Return an error response with its own headers:

``` { .kotlin title="Return an error from a route" }
respond(
    ToolHttpResponse.error(
        statusCode = 409,
        message = "An update is already running.",
        headers = mapOf("Retry-After" to "1"),
    ),
)
```

`ToolHttpResponse.error` encodes the message as a JSON object with an `error` field. A helper can instead throw `ToolHttpException(statusCode, message, headers = ...)` to stop the handler with an HTTP error. Import `ToolHttpException` from `com.openai.snapo.tool`.

Unexpected handler failures are logged and return a generic 500. Once a response starts, failures close the connection instead of sending another response.

</details>

<details markdown="1">
<summary>Request limits and HTTP behavior</summary>

The server accepts HTTP/1.1 requests with a known body length, not chunked request bodies. Route handlers validate content types and parse bodies. The defaults are:

``` { .kotlin title="Inside ToolServer" }
requestPolicy = ToolHttpRequestPolicy(
    maxBodyBytes = 64 * 1024,
    bodyMethods = setOf("POST", "PUT", "PATCH"),
)
```

Import `ToolHttpRequestPolicy` from `com.openai.snapo.tool` to change those limits. `ToolServer` allows 32 connections by default; pass `maxConnections` to its constructor to change this.

Request reads time out after five seconds. Finite requests have a 30-second deadline. Writes blocked for five seconds are closed, with checks once per second. SSE connections can stay open beyond the finite-request deadline.

Malformed HTTP requests return 400, read timeouts return 408, and oversized bodies return 413. Preflight requests return 204. Responses default to `Cache-Control: no-store`. The server checks Host and Origin headers and adds CORS response headers.

</details>

### Starting the tool on startup {#startup}

Use [AndroidX Startup](https://developer.android.com/topic/libraries/app-startup) when apps should start your tool simply by adding the library dependency. The initializer and manifest entry below belong to your tool library. Consuming apps do not need initialization code.

For an app you control, you can instead create and retain the server in your existing initialization code and call `startIfAllowed(context)`. In that case, skip the AndroidX Startup setup below.

Add the AndroidX Startup dependency to your tool library:

``` { .toml title="gradle/libs.versions.toml" }
[versions]
androidx-startup = "1.2.0"

[libraries]
androidx-startup = { module = "androidx.startup:startup-runtime", version.ref = "androidx-startup" }
```

``` { .kotlin title="Your tool module's build.gradle.kts" }
dependencies {
    implementation(libs.androidx.startup)
}
```

Create an initializer using `createToolServer` from the example above. Put both in your module's namespace; `com.example.tool` below is an example:

``` { .kotlin title="ExampleToolInitializer.kt" }
package com.example.tool

import android.content.Context
import androidx.startup.Initializer
import com.openai.snapo.tool.ToolServer

class ExampleToolInitializer : Initializer<ToolServer> {
    override fun create(context: Context): ToolServer =
        createToolServer(SnapOTool.ID).apply { startIfAllowed(context) }

    override fun dependencies(): List<Class<out Initializer<*>>> = emptyList()
}
```

`startIfAllowed` checks whether the app allows inspection and starts the server. It returns `false` if startup is disallowed or the socket cannot be opened, logging socket failures. Repeated calls on a running server do not open another socket.

Register the initializer under AndroidX Startup's shared provider in your tool library's manifest. Set `android:name` on the metadata entry to your initializer's full class name:

``` { .xml title="Your tool library's AndroidManifest.xml" }
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">
    <application>
        <provider
            android:name="androidx.startup.InitializationProvider"
            android:authorities="${applicationId}.androidx-startup"
            android:exported="false"
            tools:node="merge">
            <meta-data
                android:name="com.example.tool.ExampleToolInitializer"
                android:value="androidx.startup" />
        </provider>
    </application>
</manifest>
```

Add the tool library to your app's debug build, replacing `:your-tool` with your library module's path:

``` { .kotlin title="app/build.gradle.kts" }
dependencies {
    debugImplementation(project(":your-tool"))
}
```

`startIfAllowed` also checks the app's debuggable flag. A release app must explicitly opt in through `snapo.<tool-id>.allow_release` application metadata or the helper's `allowRelease` argument.

For AndroidX Startup configuration and behavior, see the [AndroidX Startup documentation](https://developer.android.com/topic/libraries/app-startup).

See the [complete Example initializer](https://github.com/openai/snap-o/blob/main/examples/tool/example-tool/src/main/java/com/example/snapo/tool/ExampleInitializer.kt).

<details markdown="1">
<summary>Server lifecycle and release builds</summary>

Keep the server for the tool's lifetime. `isRunning` reports whether it is listening. `close()` stops it and closes its connections; the server can then start again.

`startIfAllowed(context)` allows startup when the app is debuggable, `allowRelease = true`, or the app sets the `snapo.<tool-id>.allow_release` manifest flag. You can supply `releaseMetadataKey` to use another flag. A denied call does not stop a running server. Binding failures are logged and can be retried; configuration errors still throw.

The lower-level `start()` skips the policy check and throws if binding fails. Use `ToolStartupPolicy.isAllowed(context, releaseMetadataKey, allowRelease)` if you need to check policy separately. Keep the library in debug builds unless release inspection is intentional.

Tests can call `server.serve(connection)` with a `ToolConnection` implementation. It provides input/output streams, `setReadTimeout(millis)`, and `close()`. The server handles one request and closes the connection.

</details>

## Build the web frontend {#the-frontend-library-snap-oplugin-host data-step="3"}

### Create your UI {#frontend}

For a new frontend, we recommend [Preact with Vite](https://preactjs.com/guide/v10/getting-started/#create-a-vite-powered-preact-app). Preact provides components and hooks with a small runtime. Vite provides fast updates during development and bundles the frontend for packaging. You can use another framework or plain JavaScript, provided the output meets the bundle requirements below.

To follow this example, open a terminal in your tool's Android library module directory—the directory containing its `build.gradle.kts`. Then run:

``` { .bash title="From your Android library module directory" }
# Start in the library module directory containing build.gradle.kts.
npm create vite@latest frontend -- --template preact-ts
cd frontend
npm install @snap-o/tool-host@1.0.0
npm pkg set 'scripts.build=tsc -b && vite build --base=./'
```

This creates a TypeScript project in `frontend/`. The build uses [relative asset URLs](https://vite.dev/guide/build.html#relative-base), as Snap-O requires. See the [Preact guide](https://preactjs.com/guide/v10/getting-started/) for framework setup and [Vite's build documentation](https://vite.dev/guide/build.html) for build options.

<span id="assets"></span>With `snapoTool` applied and your library included in the Android app, the app's build also builds and packages the frontend. Changed frontend sources are rebuilt automatically; no extra app configuration is needed.

The Vite starter already bundles imported code and local assets; no extra bundling setting is needed. Add images and fonts as local files using [Vite's asset handling](https://vite.dev/guide/assets.html).

<details markdown="1">
<summary>Frontend bundle limits and WebView restrictions</summary>

The ZIP can contain up to 1,024 entries and 16 MiB of compressed and expanded data. Its `index.html` must be UTF-8 and no larger than 4 MiB. Include all required files in the bundle.

Snap-O blocks remote scripts, frames, workers, forms, and requests to servers other than the tool's Android server. It also blocks WebAssembly and JavaScript built from strings, such as `eval`. A selected development server and its hot-reload connection are allowed.

These restrictions do not guarantee that JavaScript from an untrusted APK is safe. See [WebView safeguards](https://github.com/openai/snap-o/blob/main/tools/README.md#webview-safeguards) for details.

</details>

### Connect to the Snap-O Mac app {#connect-to-android}

The host SDK connects your frontend to the Snap-O Mac app. It provides connection state and native controls. Frontends use ordinary `fetch` and `EventSource` with relative `/api/...` URLs. Pages and API requests share the `snapo://tool` origin, so no frontend CORS setup is needed. Snap-O removes `/api` before forwarding the request to Android. Frontend assets keep their build paths, without an added `/assets` prefix.

Use `host.onConnection` to receive the current connection immediately and respond when it changes. The callback can return a cleanup function for that connection's work.

First, wait for the host in the starter's `src/main.tsx`. This distinguishes a failed connection to Snap-O from a disconnected Android app:

``` { .tsx title="frontend/src/main.tsx" }
import { render } from "preact";
import { host } from "@snap-o/tool-host";
import { App } from "./app";

const root = document.getElementById("app")!;
void host.ready().then(
  () => render(<App />, root),
  error => render(<p role="alert">Could not connect to Snap-O: {String(error)}</p>, root),
);
```

Keep the starter's CSS imports. If startup fails, open the tool in Snap-O and reload it.

Replace the starter's `src/app.tsx` with this component to fetch the Android example's `/example` route:

``` { .tsx title="frontend/src/app.tsx" }
import { useEffect, useState } from "preact/hooks";
import { host } from "@snap-o/tool-host";

export function App() {
  const [message, setMessage] = useState("Disconnected");

  useEffect(() => host.onConnection(connection => {
    setMessage(connection ? "Connecting…" : "Disconnected");
    if (!connection) return;
    const request = new AbortController();
    fetch("/api/example", {
      signal: AbortSignal.any([connection.signal, request.signal]),
      cache: "no-store",
      redirect: "error",
    })
      .then(response => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        return response.json();
      })
      .then(data => {
        if (!request.signal.aborted) {
          setMessage(data.message);
        }
      })
      .catch(error => {
        if (!request.signal.aborted) setMessage(`Request failed: ${error.message}`);
      });
    return () => request.abort();
  }), []);

  return <output>{message}</output>;
}
```

The SDK runs the previous cleanup before delivering another connection. Preact also unsubscribes when the component unmounts. The cleanup aborts the old request so it cannot update a disconnected or replaced UI.

<details markdown="1">
<summary>Connection state, cancellation, and reconnects</summary>

`host.ready()` resolves after the initial host state arrives, even without a connected Android app. It rejects if that request fails. Concurrent calls share one request; calling it again retries a failure.

`host.connection` is either `null` or an object with these properties:

| Property | Meaning |
| --- | --- |
| `processIdentity` | Opaque token that changes when the Android process restarts. Use it to scope retained state. |
| `signal` | Abort signal for this connection. Use it with requests that should end on disconnection. |

`host.onConnection` calls its callback immediately and on connection changes. It returns an unsubscribe function. Cleanup runs before the next callback and when unsubscribing. Unsubscribing one UI does not abort another UI's requests.

Hidden pages may stay loaded and receive a disconnected state. Close each `EventSource` when replacing it or removing its UI so it stops retrying after disconnection.

Requests can fail while connected. Your frontend owns response validation, error display, and event-stream reconnection.

</details>

### Store preferences safely {#frontend-storage}

Snap-O scopes persistent browser storage to the device, Android user, package name, and tool ID. It reuses that storage after app updates and reinstalls with the same identifiers. Another installation can therefore read data left by the previous installation.

Use browser storage only for disposable UI preferences. Do not store credentials, access tokens, captured traffic, personal data, or other sensitive information. This rule applies to `localStorage` and other persistent browser APIs. See the [host SDK browser storage contract](https://github.com/openai/snap-o/blob/main/tool-sdk/host/README.md#browser-storage) for details.

## Try your tool in Snap-O {#development data-step="4"}

Build and run your Android app with the tool library included, using your usual workflow. Its build includes the frontend automatically.

<span id="verification"></span>In Snap-O, select your device, app, and tool. The Tool pane should display **Hello, world!**.

If the tool is missing, check that you installed a debug build containing the tool library. If the page shows a request error, check Logcat for server startup failures and confirm the `/example` route matches the example.

## Add functionality {#add-functionality}

The following examples show live updates and actions. Use the routes your tool needs.

### Stream live updates {#live-updates}

Add the imports at the top of your server file and the SSE route inside the existing `ToolServer` block:

``` { .kotlin title="Add a live event route" }
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

// Inside ToolServer(toolId) { ... }
sse("/events") {
    var sequence = 0L
    while (isActive) {
        send(sequence.toString(), event = "tick")
        sequence += 1
        delay(1000)
    }
}
```

`GET /events` sends a `tick` event every second, starting at zero for each connection. The SDK formats the events and cancels the handler's coroutine when the client disconnects. For app updates, collect your app's `Flow` and call `send` for each value.

Replace `frontend/src/app.tsx` with this component to display the stream:

``` { .tsx title="frontend/src/app.tsx" }
import { useEffect, useState } from "preact/hooks";
import { host } from "@snap-o/tool-host";

export function App() {
  const [message, setMessage] = useState("Disconnected");

  useEffect(() => host.onConnection(connection => {
    setMessage(connection ? "Waiting for events…" : "Disconnected");
    if (!connection) return;
    const events = new EventSource("/api/events");
    events.addEventListener("tick", event => setMessage(`Tick: ${event.data}`));
    events.onerror = () => setMessage("Connection lost. Retrying…");
    return () => events.close();
  }), []);

  return <output>{message}</output>;
}
```

Rebuild and run the Android app. The Tool pane now displays a new tick each second.

The cleanup closes the previous stream before a connection changes or the component unmounts. Unloading the page also closes its streams; while a page remains loaded, `EventSource` retries interrupted connections until closed.

<details markdown="1">
<summary>Stream options, heartbeats, and finite responses</summary>

`send(data, event, id)` formats an SSE event. `event` and `id` are optional. `write(bytes)` sends bytes you have already formatted. The session exposes the request through `call` and is a coroutine scope.

The server sends a heartbeat comment every 30 seconds. Pass a positive, finite `heartbeatInterval` to `sse` or `respondSse`, or `null` to disable it. `heartbeat()` sends a comment immediately.

Use `respondSse` inside an ordinary route when you need to validate the request or choose response headers before streaming:

``` { .kotlin title="Streaming response options" }
respondSse(
    statusCode = 200,
    headers = emptyMap(),
    heartbeatInterval = 30.seconds,
) {
    send("Hello", event = "example")
}
```

Import `kotlin.time.Duration.Companion.seconds` for the duration. The session and its child coroutines end when the handler returns, the client disconnects, or the server closes. `close()` ends the session explicitly. Use suspending operations or `runInterruptible` for blocking event sources so they can be cancelled.

For a finite stream, use `respondStream(contentType) { write(bytes) }`, with optional `statusCode` and `headers`. Each write becomes an HTTP chunk; the server completes the response when the block returns. Your tool owns event buffering, IDs, and replay behavior.

</details>

### Handle actions {#actions}

Use a POST route for actions. This example echoes text to demonstrate reading a request body and returning an error. Add the route inside the existing `ToolServer` block:

``` { .kotlin title="Add a POST route" }
post("/echo") {
    val text = request.bodyText()
    if (text.isBlank()) {
        respondText("A text body is required.", statusCode = 400)
    } else {
        respondText(text)
    }
}
```

Route handlers choose which content types to accept. This example reads the body as UTF-8 text. Call `/echo` from a frontend event handler:

``` { .typescript title="Send an action request" }
const connection = host.connection;
if (connection) {
  const response = await fetch("/api/echo", {
    method: "POST",
    headers: { "Content-Type": "text/plain" },
    body: "Hello from the frontend",
    signal: connection.signal,
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  console.log(await response.text());
}
```

Catch request errors in your UI. For a complete request and stream client, see the [Example frontend](https://github.com/openai/snap-o/blob/main/examples/tool/example-tool/frontend/src/snapshot.ts).

### Toolbar settings {#native}

Use `host.setToolbar` to add native controls. For example, add a button that reloads your tool's frontend:

``` { .typescript title="Add a native toolbar button" }
import { host } from "@snap-o/tool-host";

host.setToolbar({
  actions: [{
    id: "reload-tool",
    label: "Reload tool",
    icon: "reset",
    onClick: () => location.reload(),
  }],
}).catch(console.error);
```

Clear the toolbar with `host.setToolbar({})` when removing the UI.

<details markdown="1">
<summary>Toolbar actions, search, and placement</summary>

`setToolbar` replaces the toolbar. Each action has an `id`, `icon`, `label`, and `onClick` callback. Set `enabled: false` to disable it. Icons are `clear`, `sortAscending`, `sortDescending`, `search`, `export`, or `reset`.

Use `search` to add a search field:

``` { .typescript title="Toolbar with search" }
await host.setToolbar({
  search: {
    label: "Search",
    value: query,
    onChange: value => setQuery(value),
  },
});
```

The main area accepts up to three controls: three actions, or two actions and search. Use `endActions` for buttons in the separate trailing area. Both areas together allow up to eleven controls. Action IDs must be unique; `search` is reserved when the search field is present.

The search field also accepts `enabled`. Catch errors from asynchronous work inside callbacks.

</details>

### Copy text and save files {#files}

Call these methods from your UI's button handlers:

``` { .typescript title="Copy and save" }
import { host } from "@snap-o/tool-host";

await host.copyText("Tick: 42");

const saved = await host.saveFile({
  name: "events.txt",
  data: new Blob(["Tick: 42\n"], { type: "text/plain" }),
});
```

Snap-O asks the user to confirm before copying text. `saveFile` accepts a `Blob` up to 64 MiB and opens a save dialog. It returns `true` when saved or `false` when cancelled, without returning a file path. Catch errors and show them in your UI.

### Color picker {#color-picker}

If your tool edits colors, use `await host.openColorPicker({ value, onChange })`. Colors use hexadecimal RGBA, such as `#6688ccff`. Snap-O asks the user to confirm before opening the picker.

The returned object has asynchronous `setValue(value)` and `close()` methods. Keep it so you can close the picker when the device disconnects or the UI is removed. You can supply an `onClose` callback; closing an old picker object does not close a newer picker.

## Develop the frontend {#develop-the-frontend data-step="5"}

Use a development server to edit the UI without rebuilding the Android app for each frontend change. From your project root, run the tool module's `toolDev` task:

``` { .bash title="Start the frontend development server" }
./gradlew :your-tool:toolDev
```

With your tool selected in Snap-O, choose **Develop → Use Development Server** and enter the local URL printed by Vite. Snap-O proxies frontend files from that URL under `snapo://tool/`, while `/api/...` still goes to Android. Keep the Android app running. Vite’s hot-reload WebSocket connects directly to the selected local server. Configure its host and port explicitly:

``` { .ts title="vite.config.ts" }
server: {
  host: "127.0.0.1",
  port: 5173,
  strictPort: true,
  hmr: { host: "127.0.0.1", clientPort: 5173 },
}
```

Add this `server` option to your Vite config. Use the same port for `port` and `hmr.clientPort`. No Vite API proxy or CORS option is needed. See Vite’s [development guide](https://vite.dev/guide/) for details.

The `toolDev` task installs dependencies and runs the frontend's npm `dev` script with the managed Node runtime. You can also run `npm run dev` from the frontend directory with a local Node installation. To inspect the page, choose **Develop → Inspect Current WebView in Safari…**.

Choose **Develop → Use Packaged Frontend** to return to the version bundled in the APK. Rebuild and reinstall through your usual Android workflow to update that version.

For a complete tool implementation, see the [Example project](https://github.com/openai/snap-o/tree/main/examples/tool).
