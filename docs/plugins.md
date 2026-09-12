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
- **A tool plugin manifest.** Android resources describe the tool's ID, display name, API version, and frontend asset path.
- **A frontend ZIP.** Your app's APK contains a ZIP of web assets. Snap-O opens it in a WebView. The frontend uses the host SDK to interact with the Mac app and HTTP requests to communicate with the Android app.

### How Snap-O uses a tool {#how-the-ui-talks-to-your-app}

1. **The Android app starts the server.** Your app's initialization code opens the tool's named socket and starts serving HTTP.
2. **Snap-O discovers the tool.** Snap-O scans the device for tool sockets to find running apps. It reads their tool manifests to identify the available tools.
3. **Snap-O loads the frontend.** When you select a tool, Snap-O opens its frontend ZIP from the APK in the Tool pane.
4. **The frontend communicates with the app.** It sends HTTP requests, which Snap-O forwards to the app over ADB. Your server handles the requests and can stream updates.

## Define the tool's identity {#definition data-step="1"}

Use Snap-O's Tool Gradle Plugin in the Android library module that contains your tool.

Snap-O's Tool Gradle Plugin builds your web frontend, packages it into a ZIP, and includes it in the Android build. It also generates the descriptor and manifest entry that Snap-O uses to identify your tool and find its frontend.

### Add the Tool Gradle Plugin {#the-build-plugin-comopenaisnapoplugin}

``` { .toml title="gradle/libs.versions.toml" }
[versions]
snapo = "8.0.0"

[plugins]
snapo-tool = { id = "com.openai.snapo.tool", version.ref = "snapo" }
```

Apply the Tool settings integration so Gradle can download Node for the frontend build:

``` { .kotlin title="settings.gradle.kts" }
plugins {
    id("com.openai.snapo.tool-settings") version "8.0.0"
}
```

Both Gradle components resolve from Maven Central. Most projects already have `mavenCentral()` in `pluginManagement.repositories`; add it if needed. Keep your existing Android Gradle configuration.

### Configure your tool {#manifest}

Apply the Tool Gradle Plugin to your Android library module and set its identity:

``` { .kotlin title="Your tool module's build.gradle.kts" }
plugins {
    alias(libs.plugins.snapo.tool)
}

snapoTool {
    id = "your-tool"
    displayName = "Your tool"
    protocolVersion = 1
    icon = "@drawable/tool_icon"
}
```

Set `id` and `displayName` to your tool's ID and name. The ID must be unique within the app and stay stable across releases. Use lowercase letters, digits, dots, or hyphens, starting with a letter. `protocolVersion` identifies your HTTP API; your frontend checks whether it supports that version.

Set `icon` to a drawable resource in your Android module. The names above are examples; use your tool's name and icon resource.

The frontend directory defaults to `frontend/` inside your tool module. Set `frontendDirectory` only if your web project is elsewhere. See the [Gradle API reference](plugin-api.md#packaging) for other options.

## Serve HTTP on Android {#the-android-library-tool-runtime data-step="2"}

### How the socket connects to Snap-O {#android}

The tool serves HTTP over an Android abstract Unix socket named `snapo_<tool-id>_<pid>`. The name combines the tool ID from your Gradle configuration with the running app's process ID. Snap-O finds this socket and forwards the frontend's HTTP requests to it over ADB.

### Use the Android Tool SDK {#starter}

Add `tool-runtime` to your Android module. Its `ToolServer` opens the socket, handles HTTP requests, and calls your route handlers. You define the routes and choose when to start the server.

<details id="support-requests-from-the-webview" markdown="1">
<summary>What the runtime server handles for you</summary>

- Opens the named socket and accepts connections in the background.
- Parses HTTP requests and writes responses from your handlers.
- Answers `OPTIONS` readiness checks and browser preflight requests.
- Validates `Host` and `Origin` headers for Snap-O's WebView and loopback development servers.
- Adds cross-origin response headers so the frontend can call your routes with `fetch` and `EventSource`.
- Limits request sizes, concurrent connections, and read and write times.
- Formats SSE events, sends heartbeat comments, and cancels stream handlers when clients disconnect.

See the [browser access rules](https://github.com/openai/snap-o/blob/main/contracts/network/README.md#limits-and-lifecycle) and [runtime implementation](https://github.com/openai/snap-o/blob/main/tool-sdk/runtime/src/main/java/com/openai/snapo/tool/ToolBrowserAccess.kt) for the exact host and origin checks.

</details>

<div class="dependency-tabs" data-label="Android Tool SDK dependency format" markdown="1">
<div id="tool-sdk-catalog-panel" data-tab="Version catalog" markdown="1">

``` { .toml title="gradle/libs.versions.toml" }
[versions]
snapo = "8.0.0"

[libraries]
snapo-tool-runtime = { module = "com.openai.snapo:tool-runtime", version.ref = "snapo" }
```

``` { .kotlin title="Your Android module's build.gradle.kts" }
dependencies {
    implementation(libs.snapo.plugin.runtime)
}
```

</div>
<div id="tool-sdk-direct-panel" data-tab="Direct dependency" markdown="1">

``` { .kotlin title="Your Android module's build.gradle.kts" }
dependencies {
    implementation("com.openai.snapo:tool-runtime:8.0.0")
}
```

</div>
</div>

The library comes from Maven Central. Most Android projects already include `mavenCentral()` in their dependency repositories.

The following example handles GET and POST requests and streams Server-Sent Events (SSE):

``` { .kotlin title="Handle HTTP requests" }
import com.openai.snapo.tool.ToolHttpRequestPolicy
import com.openai.snapo.tool.ToolServer
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

fun createToolServer(toolId: String): ToolServer {
    return ToolServer(toolId) {
        requestPolicy = ToolHttpRequestPolicy(requireJsonContentType = false)

        get("/status") {
            respondJson("""{"ready":true}""")
        }

        post("/echo") {
            val text = request.bodyText()
            if (text.isBlank()) {
                respondText("A text body is required.", statusCode = 400)
            } else {
                respondText(text)
            }
        }

        sse("/events") {
            var sequence = 0L
            while (isActive) {
                send(sequence.toString(), event = "tick")
                sequence += 1
                delay(1000)
            }
        }
    }
}
```

`requestPolicy` allows the plain-text body used by `/echo`. `GET /status` returns JSON. `POST /echo` reads the request body and returns it as text, or returns HTTP 400 when it is blank. These routes demonstrate request handling; replace them with routes that read your app's data or perform actions. `respondJson` accepts a JSON string, so use your app's serializer for real objects.

`GET /events` keeps the connection open and sends a `tick` event every second. Each event contains an increasing number, starting at zero for each connection. The SDK formats the events and cancels the handler's coroutine when the client disconnects, stopping the loop. For app updates, replace the loop with a collection from your app's `Flow` and call `send` for each value.

### Start the server with AndroidX Startup {#startup}

Usually, you want the tool server to start when the Android app starts. One way to do this is with [AndroidX Startup](https://developer.android.com/topic/libraries/app-startup). With the setup below, adding your tool library as an app dependency starts the server automatically.

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

Use a debug-only app dependency on the tool library. `startIfAllowed` also checks the app's debuggable flag. A release app must explicitly opt in through `snapo.<tool-id>.allow_release` application metadata or the helper's `allowRelease` argument.

For AndroidX Startup configuration and behavior, see the [AndroidX Startup documentation](https://developer.android.com/topic/libraries/app-startup).

See the [complete Example initializer](https://github.com/openai/snap-o/blob/main/examples/tool/example-tool/src/main/java/com/example/snapo/tool/ExampleInitializer.kt) and [startup API reference](plugin-api.md#server).

## Build the web frontend {#the-frontend-library-snap-oplugin-host data-step="3"}

### Create your UI {#frontend}

For a new frontend, use [Preact with Vite](https://preactjs.com/guide/v10/getting-started/#create-a-vite-powered-preact-app). Open a terminal in your tool's Android library module directory—the directory containing its `build.gradle.kts`. Then run:

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

#### WebView limits

Snap-O blocks remote scripts and requests to other servers. It also blocks WebAssembly and JavaScript built from strings, such as `eval`.

### Connect to the Snap-O Mac app {#connect-to-android}

The host SDK connects your frontend to the Snap-O Mac app. It provides the forwarded Android server address and native controls.

Use `host.onConnection` to receive the current connection immediately and respond when it changes. The callback can return a cleanup function for that connection's work.

Replace the starter's `src/app.tsx` with this component to monitor the Android example's `/events` route:

``` { .tsx title="frontend/src/app.tsx" }
import { useEffect, useState } from "preact/hooks";
import { host } from "@snap-o/tool-host";

export function App() {
  const [message, setMessage] = useState("Disconnected");

  useEffect(() => host.onConnection(connection => {
    setMessage(connection ? "Waiting for events…" : "Disconnected");
    if (!connection) return;
    if (connection.protocolVersion !== 1) {
      setMessage("Unsupported tool API version");
      return;
    }
    const events = new EventSource(new URL("events", connection.baseURL));
    events.addEventListener("tick", event => setMessage(`Tick: ${event.data}`));
    events.onerror = () => setMessage("Connection lost. Retrying…");
    return () => events.close();
  }), []);

  return <output>{message}</output>;
}
```

The SDK runs the previous cleanup before delivering another connection, even when its URL is unchanged. Preact unsubscribes when the component unmounts. Unloading the page closes its streams automatically; while a page remains loaded, `EventSource` retries interrupted connections until closed.

Use `fetch` with the same base URL for HTTP requests. For a complete request and stream client, see the [Example frontend](https://github.com/openai/snap-o/blob/main/examples/tool/example-tool/frontend/src/snapshot.ts).

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

Clear the toolbar with `host.setToolbar({})` when removing the UI. See [toolbar options](plugin-api.md#native) for icons, search fields, and placement.

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

Snap-O asks the user to confirm before copying text. `saveFile` opens a save dialog and returns `false` if the user cancels. Catch errors and show them in your UI.

### Color picker {#color-picker}

If your tool edits colors, use `host.openColorPicker({ value, onChange })`. It returns an object with `setValue` and `close` methods. Keep it so you can close the picker when the device disconnects or the UI is removed.

## Try your tool in Snap-O {#development data-step="4"}

Run your Android app with the tool library included, using your usual workflow. Its build includes the updated frontend automatically.

<span id="verification"></span>In Snap-O, select your device, app, and tool. With the example above, the Tool pane displays a new tick each second. Try the native **Reload tool** button to reload the frontend and start a new stream.

## Develop the frontend {#develop-the-frontend data-step="5"}

Use a development server to edit the UI without rebuilding the Android app for each frontend change. From your `frontend/` directory, run:

``` { .bash title="Start the frontend development server" }
npm run dev
```

With your tool selected in Snap-O, choose **Develop → Use Development Server** and enter the local URL printed by Vite. Keep the Android app running so the frontend can call its API. Vite updates the UI as you edit; see its [development guide](https://vite.dev/guide/) for details.

The Tool Gradle Plugin's `toolDev` task can also run the frontend's npm `dev` script. To inspect the page, choose **Develop → Inspect Current WebView in Safari…**.

Choose **Develop → Use Packaged Frontend** to return to the version bundled in the APK. Rebuild and reinstall through your usual Android workflow to update that version.

For a complete tool implementation, see the [Example project](https://github.com/openai/snap-o/tree/main/examples/tool). For SDK methods, see the [Tool API reference](plugin-api.md).
