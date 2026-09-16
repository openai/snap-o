---
layout: guide
title: Build a tool · Snap-O
description: Create your first Snap-O tool, connect its Android server and web frontend, and run it on your Mac.
styles:
- guide.css
- network-inspector.css
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

## What you’ll build {#model data-nav="Overview"}

A tool that displays **Hello, world!** from your Android app in Snap-O’s Tool pane.
You’ll need an Android app and an Android library module for your tool. Manual frontend setup also requires Node.js and npm. Merge the snippets below into your existing Gradle files and version catalog.

<span id="how-the-ui-talks-to-your-app"></span>Your tool has two parts: an Android server and a web frontend. The frontend calls your server over HTTP. Snap-O connects them over ADB, and the Gradle plugin bundles the frontend into your APK.

For a working starting point, use the [Example tool](https://github.com/openai/snap-o/tree/main/examples/tool).

## Set up the tool {#definition data-step="1"}

Apply the Tool Packager Gradle Plugin in your tool’s Android library module. It builds the frontend and generates the metadata Snap-O needs to find your tool.

<span id="the-build-plugin-comopenaisnapoplugin"></span>Add dependencies to your version catalog:

``` { .toml title="gradle/libs.versions.toml" }
[versions]
snapo = "9.0.0"

[plugins]
snapo-tool-packager = { id = "com.openai.snapo.tool-packager", version.ref = "snapo" }

[libraries]
snapo-tool-core = { module = "com.openai.snapo:tool-core", version.ref = "snapo" }
```

Make sure `pluginManagement.repositories` in `settings.gradle.kts` includes `mavenCentral()`.

### Configure your tool {#manifest}

Apply the Tool Packager Gradle Plugin to your tool’s Android library module and set its identity:

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

Use a stable, unique `id` starting with a lowercase letter and containing only lowercase letters, digits, dots, or hyphens. Set `icon` to an existing drawable or mipmap resource. Use a single-color icon with a transparent background.

The plugin expects a web project in your module’s `frontend/` directory. You’ll create it in step 3.

<details markdown="1">
<summary>Custom builds and Node setup</summary>

Gradle downloads Node and npm automatically. To use a different frontend directory, set it in your tool module:

``` { .kotlin title="Your tool module's build.gradle.kts" }
snapoTool {
    frontendDirectory = layout.projectDirectory.dir("web")
}
```

To package files built elsewhere, set `frontendAssets` to their directory instead. It must contain `index.html` and use relative asset URLs. This skips the default npm build:

``` { .kotlin title="Package prebuilt files" }
snapoTool {
    frontendAssets = layout.projectDirectory.dir("prebuilt-frontend")
}
```

Use `node { version.set("24.21.0") }` to select another Node version, or `node { download.set(false) }` to use Node and npm on Gradle’s `PATH`.

If your build uses `FAIL_ON_PROJECT_REPOS` or `PREFER_SETTINGS`, add the Node download repository alongside your existing repositories:

``` { .kotlin title="settings.gradle.kts" }
dependencyResolutionManagement {
    repositories {
        ivy {
            name = "Node.js"
            url = uri("https://nodejs.org/dist/")
            patternLayout { artifact("v[revision]/[artifact](-v[revision]-[classifier]).[ext]") }
            metadataSources { artifact() }
            content { includeModule("org.nodejs", "node") }
        }
    }
}
```

Then disable the plugin’s automatic repository in each tool module:

``` { .kotlin title="Your tool module's build.gradle.kts" }
node { distBaseUrl.set(null as String?) }
```

</details>

## Serve HTTP on Android {#the-android-library-tool-core data-step="2"}

<span id="android"></span><span id="starter"></span>Add `tool-core` to your tool library. Its `ToolServer` handles the connection and HTTP; you provide the routes.

<span id="support-requests-from-the-webview"></span>

<div class="dependency-tabs" data-label="Android Tool SDK dependency format" markdown="1">
<div id="tool-sdk-catalog-panel" data-tab="Version catalog" markdown="1">

``` { .kotlin title="Your Android module's build.gradle.kts" }
dependencies {
    implementation(libs.snapo.tool.core)
}
```

</div>
<div id="tool-sdk-direct-panel" data-tab="Direct dependency" markdown="1">

``` { .kotlin title="Your Android module's build.gradle.kts" }
dependencies {
    implementation("com.openai.snapo:tool-core:9.0.0")
}
```

</div>
</div>

The library comes from Maven Central. Most Android projects already include `mavenCentral()` in their dependency repositories.

This example returns a JSON message:

``` { .kotlin title="Handle an example request" }
import com.openai.snapo.tool.ToolServer

fun createToolServer(toolId: String) = ToolServer(toolId) {
    get("/example") {
        respondJson("""{"message":"Hello, world!"}""")
    }
}
```

`respondJson` accepts a JSON string. Use your app's serializer to encode objects.

See [Actions and request bodies](#actions) for more HTTP examples.

### Start the server with your app {#startup}

You can use [AndroidX Startup](https://developer.android.com/topic/libraries/app-startup) to start the server when your app launches. Add the initializer and manifest entry below to your tool library.

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

The Gradle plugin generates `SnapOTool.ID` in your module’s namespace. `startIfAllowed` starts the server in debuggable apps and logs socket startup failures.

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

Keep the tool in debug builds.

<details markdown="1">
<summary>Custom startup and release builds</summary>

You can call `startIfAllowed(context)` from your own initialization code instead of AndroidX Startup. Keep the server for your tool’s lifetime and call `close()` when that lifetime ends.

To inspect a release build, include the tool library in that variant and add this metadata inside the app’s `<application>` element. Replace `your-tool` with your tool ID:

``` { .xml title="App manifest release opt-in" }
<meta-data
    android:name="snapo.your-tool.allow_release"
    android:value="true" />
```

</details>

### Set the app's tool order

Add this optional setting inside your app's `<application>` element:

``` { .xml title="App manifest tool order" }
<meta-data
    android:name="snapo.tool_order"
    android:value="network,tweaks" />
```

Listed tools appear first, in the order you specify. Other tools follow alphabetically
by tool ID. For example, this setting produces Network, Tweaks, Analytics, then Logs
when all four tools are available.

Use tool IDs, not display names. Spaces around IDs are allowed; duplicates and invalid
IDs are ignored. Unavailable tools are skipped. Without this setting, tools appear
alphabetically by ID. Snap-O still remembers your selected tool.

The app owns this setting. Individual tool libraries do not need changes.

## Build the web frontend {#the-frontend-library-snap-oplugin-host data-step="3"}

### Create your UI {#frontend}

The plugin expects your web project in `frontend/`, beside your tool module’s `build.gradle.kts`. Create it with Gradle:

``` { .bash title="Create the frontend" }
# Run from your Android project root
./gradlew :your-tool:initSnapoToolFrontend
```

This creates a Preact and TypeScript starter with the host SDK and installs its dependencies. Gradle manages Node/npm automatically. It uses `frontendDirectory` if configured and stops if the directory already contains files.

Commit the generated source files, `package.json`, and `package-lock.json`. Subsequent Android builds and `devSnapoToolFrontend` runs prepare the SDK and dependencies automatically. For an existing web project, see [frontend configuration](https://github.com/openai/snap-o/blob/main/tool-sdk/gradle-plugin/README.md#migrate-an-existing-frontend).

<span id="assets"></span>The Android build packages the frontend automatically. Include scripts, images, and fonts in the bundle; the packaged page cannot load remote scripts or call unrelated servers.

**Preact is optional.** We recommend [Preact](https://preactjs.com/) because its lightweight runtime helps keep the frontend bundled in your APK small. You can use plain JavaScript or another framework that builds bundled web assets with an `index.html`.
{.notice}

### Connect to the Snap-O Mac app {#connect-to-android}

The host SDK tells your frontend when Android is connected. Call Android routes with `/api/` in front: `/api/example` reaches your server’s `/example` route. The generated `src/main.tsx` contains this example. For an existing frontend, adapt the code below and keep your CSS imports:

``` { .tsx title="frontend/src/main.tsx" }
import { render } from "preact";
import { useEffect, useState } from "preact/hooks";
import { host } from "@snap-o/tool-host";

function App() {
  const [message, setMessage] = useState("Disconnected");

  useEffect(() => host.onError(error => {
    setMessage(`Could not connect to Snap-O: ${error.message}`);
  }), []);

  useEffect(() => host.onConnection(async connection => {
    setMessage(connection ? "Connecting…" : "Disconnected");
    if (!connection) return;
    try {
      const response = await fetch("/api/example");
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      setMessage(data.message);
    } catch (error) {
      setMessage(`Request failed: ${String(error)}`);
    }
  }), []);

  return <output>{message}</output>;
}

render(<App />, document.getElementById("app")!);
```

If startup fails, open the tool in Snap-O and reload it.

`host.onConnection` runs when the Android connection changes. `host.onError` reports SDK initialization failures. Both effects unsubscribe when the component unmounts.

<span id="frontend-storage"></span>Use browser storage only for disposable UI preferences. Stored data can survive app reinstalls; don’t persist credentials, captured traffic, or personal data.

## Try your tool in Snap-O {#development data-step="4"}

Build and run your Android app with the tool library included, using your usual workflow. Its build includes the frontend automatically.

<span id="verification"></span>In Snap-O, select your device, app, and tool. The Tool pane should display **Hello, world!**.

If the tool is missing, check that you installed a debug build containing the tool library. If the page shows a request error, check Logcat for server startup failures and confirm the `/example` route matches the example.

## Frontend hot reload {#develop-the-frontend data-step="5"}

Use a development server to edit the UI without rebuilding the Android app for each frontend change. From your project root, run the tool module's `devSnapoToolFrontend` task:

``` { .bash title="Start the frontend development server" }
./gradlew :your-tool:devSnapoToolFrontend
```

With your tool selected in Snap-O, choose **Develop → Use Development Server** and enter the local URL printed by Vite. Keep the Android app running. Add this `server` option to your Vite config so frontend changes reload correctly:

``` { .ts title="vite.config.ts" }
server: {
  host: "127.0.0.1",
  port: 5173,
  strictPort: true,
  hmr: { host: "127.0.0.1", clientPort: 5173 },
}
```

Use the same port for `port` and `hmr.clientPort`. Requests to `/api/...` still go to Android.

The `devSnapoToolFrontend` task installs dependencies and runs the frontend's npm `dev` script with the managed Node runtime. You can also run `npm run dev` from the frontend directory with a local Node installation. In a Debug build of Snap-O, choose **Develop → Show Web Inspector** to inspect the page in a separate window.

Choose **Develop → Use Packaged Frontend** to return to the version bundled in the APK. Rebuild and reinstall through your usual Android workflow to update that version.

For a complete tool implementation, see the [Example project](https://github.com/openai/snap-o/tree/main/examples/tool).

## Add more features {#add-functionality}

Once the example works, add the features your tool needs. Frontend snippets below use `host` from `@snap-o/tool-host`. The SDK initializes automatically.

<details id="live-updates" markdown="1">
<summary>Live streaming with SSE</summary>

Use server-sent events (SSE) to send updates without polling. This route sends a message every second. Add it inside your `ToolServer` block:

``` { .kotlin title="Android route" }
sse("/events") {
    while (true) {
        send(data = "Hello from Android", event = "message")
        kotlinx.coroutines.delay(1_000)
    }
}
```

In `App`, replace the request effect with a stream subscription:

``` { .tsx title="Inside App" }
useEffect(() => host.onConnection(connection => {
  setMessage(connection ? "Connecting…" : "Disconnected");
  if (!connection) return;
  const events = new EventSource("/api/events");
  events.onmessage = event => setMessage(event.data);
  return () => events.close();
}), []);
```

Replace the timer with your app’s event source. The cleanup closes the stream when the connection changes or the component unmounts.

</details>

<details id="actions" markdown="1">
<summary>Actions and request bodies</summary>

Use `post`, `put`, `patch`, or `delete` for actions. This route receives text and returns it as a response:

``` { .kotlin title="Android route" }
post("/message") {
    val message = request.bodyText()
    respondText(message)
}
```

Call it from a frontend event handler while Android is connected:

``` { .typescript title="Send an action" }
const connection = host.connection;
if (!connection) throw new Error("Android is disconnected");

const response = await fetch("/api/message", {
  method: "POST",
  headers: { "Content-Type": "text/plain" },
  body: "Hello from the frontend",
});
if (!response.ok) throw new Error(`HTTP ${response.status}`);
const message = await response.text();
```

For JSON bodies, use `JSON.stringify` and `Content-Type: application/json`, then parse the body with your Android serializer. Use `respondNoContent()` when an action has no response body.

Routes can include parameters, such as `/items/{id}`. Read them with `pathParameters.getValue("id")`; read query values with `request.queryParameters["filter"]`.

</details>

<details id="native" markdown="1">
<summary>Toolbar buttons and search</summary>

Use `host.setToolbar` to add controls to Snap-O’s native toolbar. Connect the callbacks to your UI’s state and actions:

``` { .typescript title="Configure the toolbar" }
await host.setToolbar({
  actions: [
    { id: "clear", icon: "clear", label: "Clear", onClick: clear },
  ],
  search: { label: "Search", value: query, onChange: setQuery },
});
```

Here, `clear`, `query`, and `setQuery` come from your component. Each call replaces the toolbar. The main area fits three controls, including search; use `endActions` for trailing buttons. Set `enabled: false` to disable a button, and call `host.setToolbar({})` when removing the UI.

</details>

<details id="files" markdown="1">
<summary>Copy text and save files</summary>

Call these APIs from your frontend’s button handlers:

``` { .typescript title="Copy text" }
await navigator.clipboard.writeText("Hello, world!");
```

``` { .typescript title="Open a save dialog" }
const saved = await host.saveFile({
  name: "message.txt",
  data: new Blob(["Hello, world!"], { type: "text/plain" }),
});
```

`saveFile` returns `false` if the user cancels the dialog.

</details>

<details id="color-picker" markdown="1">
<summary>Pick a color</summary>

Open Snap-O’s native color picker from a button handler. Colors use hexadecimal RGBA values:

``` { .typescript title="Open the color picker" }
const picker = await host.openColorPicker({
  value: "#3366FFFF",
  onChange: color => console.log(color),
});
```

Replace `console.log` with your color update handler. Use `picker.setValue(color)` to update the picker or `picker.close()` to dismiss it.

</details>
