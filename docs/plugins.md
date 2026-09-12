---
layout: guide
title: Build a plugin · Snap-O
description: Build an Android plugin with HTTP routes, live events, and a frontend in Snap-O's Tool pane.
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

# Build a plugin

Build a debugging tool for your Android app and use it from Snap-O on your Mac.
{.lead}

## About plugins {#model data-nav="About plugins"}

A plugin connects code in your Android app to a tool in Snap-O. A plugin with a frontend needs three things:

- **An Android socket serving HTTP.** Your app opens a named socket. Snap-O forwards HTTP requests from the frontend to that socket over ADB.
- **A plugin manifest.** Android resources describe the plugin's ID, display name, API version, and frontend asset path.
- **A frontend ZIP.** Your app's APK contains a ZIP of web assets. Snap-O opens it in a WebView. The frontend uses the host SDK to interact with the Mac app and HTTP requests to communicate with the Android app.

### How Snap-O uses a plugin {#how-the-ui-talks-to-your-app}

1. **The Android app starts the server.** Your app's initialization code opens the plugin's named socket and starts serving HTTP.
2. **Snap-O discovers the plugin.** Snap-O scans the device for plugin sockets to find running apps. It reads their plugin manifests to identify the available tools.
3. **Snap-O loads the frontend.** When you select a tool, Snap-O opens its frontend ZIP from the APK in the Tool pane.
4. **The frontend communicates with the app.** It sends HTTP requests, which Snap-O forwards to the app over ADB. Your server handles the requests and can stream updates.

## Define the plugin's identity {#definition data-step="1"}

Use Snap-O's Gradle plugin in the Android library module that contains your plugin.

Snap-O's Gradle plugin builds your web frontend, packages it into a ZIP, and includes it in the Android build. It also generates the descriptor and manifest entry that Snap-O uses to identify your tool and find its frontend.

### Add the Gradle plugin {#the-build-plugin-comopenaisnapoplugin}

``` { .toml title="gradle/libs.versions.toml" }
[versions]
snapo = "8.0.0"

[plugins]
snapo-plugin = { id = "com.openai.snapo.plugin", version.ref = "snapo" }
```

Apply the settings plugin so Gradle can download Node for the frontend build:

``` { .kotlin title="settings.gradle.kts" }
plugins {
    id("com.openai.snapo.plugin-settings") version "8.0.0"
}
```

Both plugins resolve from Maven Central. Most projects already have `mavenCentral()` in `pluginManagement.repositories`; add it if needed. Keep your existing Android plugin configuration.

### Configure your plugin {#manifest}

Apply the plugin to your Android library module and set its identity:

``` { .kotlin title="Your plugin module's build.gradle.kts" }
plugins {
    alias(libs.plugins.snapo.plugin)
}

snapoPlugin {
    id = "your-plugin"
    displayName = "Your plugin"
    protocolVersion = 1
    icon = "@drawable/plugin_icon"
}
```

Set `id` and `displayName` to your plugin's ID and name. The ID must be unique within the app and stay stable across releases. Use lowercase letters, digits, dots, or hyphens, starting with a letter. `protocolVersion` identifies your HTTP API; your frontend checks whether it supports that version.

Set `icon` to a drawable resource in your Android module. The names above are examples; use your plugin's name and icon resource.

The frontend directory defaults to `frontend/` inside your plugin module. Set `frontendDirectory` only if your web project is elsewhere. See the [Gradle API reference](plugin-api.md#packaging) for other options.

## Serve HTTP on Android {#the-android-library-plugin-runtime data-step="2"}

### How the socket connects to Snap-O {#android}

The plugin serves HTTP over an Android abstract Unix socket named `snapo_<plugin-id>_<pid>`. The name combines the plugin ID from your Gradle configuration with the running app's process ID. Snap-O finds this socket and forwards the frontend's HTTP requests to it over ADB.

### Use the Android Plugin SDK {#starter}

Add `plugin-runtime` to your Android module. Its `PluginServer` opens the socket, handles HTTP requests, and calls your route handlers. You define the routes and choose when to start the server.

<details id="support-requests-from-the-webview" markdown="1">
<summary>What the runtime server handles for you</summary>

- Opens the named socket and accepts connections in the background.
- Parses HTTP requests and writes responses from your handlers.
- Answers `OPTIONS` readiness checks and browser preflight requests.
- Validates `Host` and `Origin` headers for Snap-O's WebView and loopback development servers.
- Adds cross-origin response headers so the frontend can call your routes with `fetch` and `EventSource`.
- Limits request sizes, concurrent connections, and read and write times.
- Formats SSE events, sends heartbeat comments, and cancels stream handlers when clients disconnect.

See the [browser access rules](https://github.com/openai/snap-o/blob/main/contracts/network/README.md#limits-and-lifecycle) and [runtime implementation](https://github.com/openai/snap-o/blob/main/sdk/runtime/src/main/java/com/openai/snapo/plugin/PluginBrowserAccess.kt) for the exact host and origin checks.

</details>

<div class="dependency-tabs" data-label="Android Plugin SDK dependency format" markdown="1">
<div id="plugin-sdk-catalog-panel" data-tab="Version catalog" markdown="1">

``` { .toml title="gradle/libs.versions.toml" }
[versions]
snapo = "8.0.0"

[libraries]
snapo-plugin-runtime = { module = "com.openai.snapo:plugin-runtime", version.ref = "snapo" }
```

``` { .kotlin title="Your Android module's build.gradle.kts" }
dependencies {
    implementation(libs.snapo.plugin.runtime)
}
```

</div>
<div id="plugin-sdk-direct-panel" data-tab="Direct dependency" markdown="1">

``` { .kotlin title="Your Android module's build.gradle.kts" }
dependencies {
    implementation("com.openai.snapo:plugin-runtime:8.0.0")
}
```

</div>
</div>

The library comes from Maven Central. Most Android projects already include `mavenCentral()` in their dependency repositories.

The following example handles GET and POST requests and streams Server-Sent Events (SSE):

``` { .kotlin title="Handle HTTP requests" }
import com.openai.snapo.plugin.PluginHttpRequestPolicy
import com.openai.snapo.plugin.PluginServer
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

fun createPluginServer(pluginId: String): PluginServer {
    return PluginServer(pluginId) {
        requestPolicy = PluginHttpRequestPolicy(requireJsonContentType = false)

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

Usually, you want the plugin server to start when the Android app starts. One way to do this is with [AndroidX Startup](https://developer.android.com/topic/libraries/app-startup). With the setup below, adding your plugin library as an app dependency starts the server automatically.

Add the AndroidX Startup dependency to your plugin library:

``` { .toml title="gradle/libs.versions.toml" }
[versions]
androidx-startup = "1.2.0"

[libraries]
androidx-startup = { module = "androidx.startup:startup-runtime", version.ref = "androidx-startup" }
```

``` { .kotlin title="Your plugin module's build.gradle.kts" }
dependencies {
    implementation(libs.androidx.startup)
}
```

Create an initializer using `createPluginServer` from the example above. Put both in your module's namespace; `com.example.plugin` below is an example:

``` { .kotlin title="PluginInitializer.kt" }
package com.example.plugin

import android.content.Context
import androidx.startup.Initializer
import com.openai.snapo.plugin.PluginServer

class PluginInitializer : Initializer<PluginServer> {
    override fun create(context: Context): PluginServer =
        createPluginServer(SnapOPlugin.ID).apply { startIfAllowed(context) }

    override fun dependencies(): List<Class<out Initializer<*>>> = emptyList()
}
```

`startIfAllowed` checks whether the app allows inspection and starts the server. It returns `false` if startup is disallowed or the socket cannot be opened, logging socket failures. Repeated calls on a running server do not open another socket.

Register the initializer under AndroidX Startup's shared provider in your plugin library's manifest. Set `android:name` on the metadata entry to your initializer's full class name:

``` { .xml title="Your plugin library's AndroidManifest.xml" }
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">
    <application>
        <provider
            android:name="androidx.startup.InitializationProvider"
            android:authorities="${applicationId}.androidx-startup"
            android:exported="false"
            tools:node="merge">
            <meta-data
                android:name="com.example.plugin.PluginInitializer"
                android:value="androidx.startup" />
        </provider>
    </application>
</manifest>
```

Use a debug-only app dependency on the plugin library. `startIfAllowed` also checks the app's debuggable flag. A release app must explicitly opt in through `snapo.<plugin-id>.allow_release` application metadata or the helper's `allowRelease` argument.

For AndroidX Startup configuration and behavior, see the [AndroidX Startup documentation](https://developer.android.com/topic/libraries/app-startup).

See the [complete Example initializer](https://github.com/openai/snap-o/blob/main/examples/plugin/example-tool/src/main/java/com/example/snapo/tool/ExampleInitializer.kt) and [startup API reference](plugin-api.md#server).

## Build the web frontend {#the-frontend-library-snap-oplugin-host data-step="3"}

### Create your UI {#frontend}

For a new frontend, use [Preact with Vite](https://preactjs.com/guide/v10/getting-started/#create-a-vite-powered-preact-app). Open a terminal in your plugin's Android library module directory—the directory containing its `build.gradle.kts`. Then run:

``` { .bash title="From your Android library module directory" }
# Start in the library module directory containing build.gradle.kts.
npm create vite@latest frontend -- --template preact-ts
cd frontend
npm install @snap-o/plugin-host@1.0.0
npm pkg set 'scripts.build=tsc -b && vite build --base=./'
```

This creates a TypeScript project in `frontend/`. The build uses [relative asset URLs](https://vite.dev/guide/build.html#relative-base), as Snap-O requires. See the [Preact guide](https://preactjs.com/guide/v10/getting-started/) for framework setup and [Vite's build documentation](https://vite.dev/guide/build.html) for build options.

<span id="assets"></span>With `snapoPlugin` applied and your library included in the Android app, the app's build also builds and packages the frontend. Changed frontend sources are rebuilt automatically; no extra app configuration is needed.

The Vite starter already bundles imported code and local assets; no extra bundling setting is needed. Add images and fonts as local files using [Vite's asset handling](https://vite.dev/guide/assets.html).

#### WebView limits

Snap-O blocks remote scripts and requests to other servers. It also blocks WebAssembly and JavaScript built from strings, such as `eval`.

### Connect to the Snap-O Mac app {#connect-to-android}

The host SDK connects your frontend to the Snap-O Mac app. It provides the forwarded Android server address and native controls. Read the current Android connection through `host`:

``` { .typescript title="Read the connection" }
import { host } from "@snap-o/plugin-host";

host.connected;
host.baseURL;
host.plugin?.id;
host.plugin?.protocolVersion;
```

The connection may not be ready when the page loads. Listen for `connection` events and read the current values after adding the listener. The server address can change even if `connected` remains true.

Use `host.baseURL` to open the `/events` route from the Android example. Replace the starter's `src/app.tsx` with this component:

``` { .tsx title="frontend/src/app.tsx" }
import { useEffect, useState, useSyncExternalStore } from "preact/compat";
import { host } from "@snap-o/plugin-host";

function subscribe(update: () => void) {
  host.addEventListener("connection", update);
  return () => host.removeEventListener("connection", update);
}

const getURL = () => host.connected ? host.baseURL : null;

export function App() {
  const baseURL = useSyncExternalStore(subscribe, getURL);
  const [message, setMessage] = useState("Waiting for events…");

  useEffect(() => {
    if (!baseURL) return;
    setMessage("Waiting for events…");
    const stream = new EventSource(new URL("/events", baseURL));
    stream.addEventListener("tick", (event) => setMessage(`Tick: ${event.data}`));
    stream.onerror = () => setMessage("Connection lost. Retrying…");
    return () => stream.close();
  }, [baseURL]);

  return <output>{baseURL ? message : "Disconnected"}</output>;
}
```

The subscription keeps `baseURL` current. When it changes, Preact closes the old stream and opens a new one. Removing the component also closes the stream. See [Preact's subscription hook](https://preactjs.com/guide/v10/hooks/#usesyncexternalstore) for details.

This example uses API version 1 from the Android sample. Each `tick` updates the output; `EventSource` retries if the stream is interrupted.

Use `fetch` with the same base URL for HTTP requests. For a complete request and stream client, see the [Example frontend](https://github.com/openai/snap-o/blob/main/examples/plugin/example-tool/frontend/src/snapshot.ts).

### Toolbar settings {#native}

Use `host.setToolbar` to add native controls. For example, add a button that reloads your tool's frontend:

``` { .typescript title="Add a native toolbar button" }
import { host } from "@snap-o/plugin-host";

host.setToolbar({
  start: [{
    type: "button",
    id: "reload-tool",
    label: "Reload tool",
    icon: "reset",
    onClick: () => location.reload(),
  }],
}).catch(console.error);
```

Clear the toolbar with `host.setToolbar({ start: [] })` when removing the UI. See [toolbar options](plugin-api.md#native) for icons, search fields, and placement.

### Copy text and save files {#files}

Call these methods from your UI's button handlers:

``` { .typescript title="Copy and save" }
import { host } from "@snap-o/plugin-host";

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

Run your Android app with the plugin library included, using your usual workflow. Its build includes the updated frontend automatically.

<span id="verification"></span>In Snap-O, select your device, app, and tool. With the example above, the Tool pane displays a new tick each second. Try the native **Reload tool** button to reload the frontend and start a new stream.

## Develop the frontend {#develop-the-frontend data-step="5"}

Use a development server to edit the UI without rebuilding the Android app for each frontend change. From your `frontend/` directory, run:

``` { .bash title="Start the frontend development server" }
npm run dev
```

With your tool selected in Snap-O, choose **Develop → Use Development Server** and enter the local URL printed by Vite. Keep the Android app running so the frontend can call its API. Vite updates the UI as you edit; see its [development guide](https://vite.dev/guide/) for details.

The Gradle plugin's `pluginDev` task can also run the frontend's npm `dev` script. To inspect the page, choose **Develop → Inspect Current WebView in Safari…**.

Choose **Develop → Use Packaged Frontend** to return to the version bundled in the APK. Rebuild and reinstall through your usual Android workflow to update that version.

For a complete plugin implementation, see the [Example project](https://github.com/openai/snap-o/tree/main/examples/plugin). For SDK methods, see the [Plugin API reference](plugin-api.md).
