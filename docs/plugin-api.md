---
layout: guide
title: Plugin API reference · Snap-O
description: Configuration, Android HTTP and streaming APIs, and the TypeScript host API for Snap-O plugin authors.
styles:
- guide.css
languages:
- kotlin
- toml
- typescript
breadcrumbs:
- label: Snap-O
  href: index.html
- label: Build a plugin
  href: plugins.html
---

# Plugin API reference

Use the Android library to handle requests inside your app. Use the frontend library to connect your web UI to Snap-O. Use the Gradle plugin to build and include that UI in your Android app.
{.lead}

Start with [Build a plugin](plugins.md) to add a tool to your Android project.
{.note}

## Packaging {#packaging}

The Gradle plugin generates the descriptor, Android manifest entry, and frontend ZIP. Follow the [plugin configuration](plugins.md#manifest) and [frontend packaging](plugins.md#assets) steps in the guide.

Add the build plugin to your version catalog:

``` { .toml title="gradle/libs.versions.toml" }
[versions]
snapo = "8.0.0"

[plugins]
snapo-plugin = { id = "com.openai.snapo.plugin", version.ref = "snapo" }
```

``` { .kotlin title="Your Android module's build.gradle.kts" }
plugins {
    alias(libs.plugins.snapo.plugin)
}
```

Apply the settings plugin in `settings.gradle.kts` with the same version:

``` { .kotlin title="settings.gradle.kts" }
plugins {
    id("com.openai.snapo.plugin-settings") version "8.0.0"
}
```

Gradle does not support catalog aliases in settings files. Both plugins resolve from Maven Central; include `mavenCentral()` in `pluginManagement.repositories`.

The settings plugin lets Gradle download Node for the frontend build. The module plugin builds and packages the frontend using the settings below.

``` { .kotlin title="Plugin definition" }
snapoPlugin {
    id = "example"
    displayName = "Example"
    protocolVersion = 1
    hostApiVersion = 1
    icon = "@drawable/example_tool_icon"
}
```

Set `id`, `displayName`, and `protocolVersion` for every plugin. `hostApiVersion` defaults to 1. If you set `icon`, include the named drawable in your Android resources.

| Property | Type | Required or default | Meaning |
| --- | --- | --- | --- |
| `id` | `Property<String>` | Required | ID to keep across releases. Use up to 100 lowercase letters, digits, dots, or hyphens, starting with a letter. |
| `displayName` | `Property<String>` | Required | Name shown in Snap-O. Must not be blank; up to 200 characters. |
| `protocolVersion` | `Property<Int>` | Required | Version of the data format your server and UI use. Must be greater than zero. |
| `hostApiVersion` | `Property<Int>` | `1` | Version of the Snap-O host API your UI needs. Must be greater than zero. |
| `icon` | `Property<String>` | Optional | Android drawable or mipmap resource reference |
| `frontendDirectory` | `DirectoryProperty` | `frontend/` | Folder with your UI source, `package.json`, and `package-lock.json`. |
| `frontendAssets` | `DirectoryProperty` | Output of `pluginBuild` | Folder of built UI files to include in the APK. Must contain `index.html`. |
| `downloadNode` | `Property<Boolean>` | `true` | Whether Gradle downloads Node. Set to `false` to use Node on `PATH`. |
| `nodeVersion` | `Property<String>` | `22.23.2` | Node version that Gradle downloads. |

You can assign these Gradle properties as shown above, or use `.set(...)` with a Gradle provider. `pluginBuild` runs the frontend's npm `build` script, which must write to `frontendDirectory/dist/`. `pluginDev` runs the npm `dev` script. When you build the Android module, Gradle includes the frontend ZIP and plugin details automatically.

To use an existing Node installation:

``` { .kotlin title="Use Node and npm on PATH" }
snapoPlugin {
    downloadNode = false
}
```

With `downloadNode = false`, you can omit `com.openai.snapo.plugin-settings`. To include UI files you have already built, set `frontendAssets`. Gradle then skips the default npm build:

``` { .kotlin title="Package existing frontend files" }
snapoPlugin {
    frontendAssets = layout.projectDirectory.dir("prebuilt-frontend")
}
```

You can also set `frontendAssets` from a Gradle provider for another task's output directory. Gradle will run that task before packaging the files. See the [packaging source and contributor notes](https://github.com/openai/snap-o/tree/main/sdk/gradle-plugin).

### Generated constants

The plugin generates a Java class in the Android module's namespace:

``` { .kotlin title="Constants available to Kotlin" }
SnapOPlugin.ID               // String: "example"
SnapOPlugin.PROTOCOL_VERSION // Int: 1
SnapOPlugin.HOST_API_VERSION // Int: 1
```

Each module defines one `snapoPlugin` and gets one generated `SnapOPlugin` class. Give each plugin module its own Android namespace.

## Server and startup {#server}

Add `com.openai.snapo:plugin-runtime` from Maven Central. Use the same version as the Snap-O Gradle plugins. Import its classes from `com.openai.snapo.plugin`.

Create a `PluginServer` to receive HTTP requests in your Android app:

``` { .kotlin title="PluginServer signatures" }
class PluginServer(
    pluginId: String,
    maxConnections: Int = 32,
    configure: PluginRoutes.() -> Unit,
) : Closeable {
    val isRunning: Boolean
    fun start()
    fun startIfAllowed(
        context: Context,
        releaseMetadataKey: String = "snapo.$pluginId.allow_release",
        allowRelease: Boolean = false,
    ): Boolean
    override fun close()
    suspend fun serve(connection: PluginConnection)
}
```

This block lists the class signatures. `start()` opens an Android abstract Unix socket for receiving requests. Calling it again while the server is running has no effect. It throws if the socket cannot be opened. `close()` stops the server and closes its connections.

Tests can use `serve` to pass in a connection directly. The server handles the request and closes that connection.

Use `startIfAllowed(context)` from an AndroidX Startup initializer, as shown in the [startup guide](plugins.md#startup). It checks the policy below, returns `true` when the server starts or is already running, and returns `false` when the policy denies startup or binding throws an `IOException`. Socket failures are logged and can be retried. A denied call does not stop a running server. Configuration errors still throw.

The default release metadata key is `snapo.<plugin-id>.allow_release`. Supply `releaseMetadataKey` to keep an existing key, or `allowRelease = true` for an explicit release opt-in.

The lower-level `start()` does not check policy or catch startup failures. For custom startup code, call `PluginStartupPolicy.isAllowed` before it:

``` { .kotlin title="Startup policy signatures" }
PluginStartupPolicy.isAllowed(
    context: Context,
    releaseMetadataKey: String,
    allowRelease: Boolean = false,
): Boolean

PluginStartupPolicy.isAllowed(
    isDebuggable: Boolean,
    allowRelease: Boolean,
    applicationAllowsRelease: Boolean = false,
): Boolean
```

The check allows startup when at least one of these is true:

- The app is debuggable.
- You pass `allowRelease = true`.
- The app sets the manifest metadata flag named by `releaseMetadataKey` to `true`.

Keep the plugin dependency in debug builds unless you intend to inspect release builds. See the [startup guidance](plugins.md#startup).

## Requests and responses {#requests}

Inside `PluginServer { ... }`, use these `PluginRoutes` members:

| Route API | Argument or value | What it does |
| --- | --- | --- |
| `get`, `post`, `put`, `patch`, `delete` | `(path, suspend PluginCall.() -> Unit)` | Choose the code to run for an HTTP method and path. |
| `route` | `(method, path, handler)` | Handle another HTTP method, written in uppercase. The server handles `OPTIONS` automatically. |
| `sse` | `(path, heartbeatInterval = 30.seconds, handler)` | Handle a GET request by sending events. The block receives a `PluginSseSession`. |
| `validateRequest` | `(PluginHttpRequest) -> Unit` | Check the request before choosing a route or sending a response. |
| `onError` | `(Exception) -> PluginHttpResponse` | Choose the error response when a request fails before sending a response. |
| `notFound` | `suspend PluginCall.() -> Unit` | Choose what happens when no route matches the path. |
| `requestPolicy` | `PluginHttpRequestPolicy` | Set which requests to accept and how large their bodies can be. |
| `preflightStatusCode` | `Int`, default `204` | Status for the browser's automatic preflight request. |
| `exposedHeaders` | `String?`, default `null` | Name the response headers your frontend can read. |
| `vary` | `String`, default `"Origin"` | `Vary` response header |
| `cacheControl` | `String`, default `"no-store"` | `Cache-Control` response header |

A route matches the URL path, without its query parameters. You can name a variable path segment, such as `{id}` in `/items/{id}`.

The first matching route for the HTTP method handles the request. Put fixed paths before patterns that could also match them. An unknown path returns 404. A known path with an unsupported HTTP method returns 405 and an `Allow` header.

### Request data

| `PluginCall` member | Type | Meaning |
| --- | --- | --- |
| `pathParameters` | `Map<String, String>` | Values from variable path segments, with URL escapes decoded. `+` stays a plus sign. |
| `request.method` | `String` | HTTP method |
| `request.requestTarget` | `String` | The path and query as sent in the request, including URL escapes. |
| `request.path` | `String` | The path without its query; URL escapes remain unchanged. |
| `request.queryParameters` | `Map<String, List<String>>` | Query names and values with URL escapes decoded. Repeated values stay in the list. |
| `request.headers` | `Map<String, String>` | Headers with lowercase names |
| `request.body` | `ByteArray` | Request body bytes, limited by `requestPolicy`. |
| `request.bodyText()` | `String` | Body decoded as strict UTF-8 |

### Response helpers

``` { .kotlin title="PluginCall response signatures" }
fun respondJson(json: String, statusCode: Int = 200)
fun respondText(text: String, statusCode: Int = 200)
fun respondNoContent()
fun respond(response: PluginHttpResponse, headers: Map<String, String> = emptyMap())
```

A route handler sends one response. If it returns without sending one, the server sends 204. Pass a JSON string to `respondJson`; use your preferred JSON library to convert objects first. Once a response starts, the server cannot replace it with an error response.

For custom bodies or content types, construct a response:

``` { .kotlin title="PluginHttpResponse constructor" }
data class PluginHttpResponse(
    val statusCode: Int,
    val body: ByteArray,
    val allowedMethods: String? = null,
    val contentType: String = "application/json; charset=utf-8",
)
```

You can also create responses with these methods:

- `PluginHttpResponse.json(json, statusCode)` for JSON.
- `PluginHttpResponse.text(text, statusCode)` for plain text.
- `PluginHttpResponse.error(statusCode, message, allowedMethods)` for an error.

Throw `PluginHttpException(statusCode, message)` to return that HTTP error status. By default, invalid arguments and I/O errors return 400, and socket timeouts return 408. Other unexpected exceptions return 500 with a general error message.

### Request policy

``` { .kotlin title="Default request policy" }
PluginHttpRequestPolicy(
    maxBodyBytes = 64 * 1024,
    bodyMethods = setOf("POST", "PUT", "PATCH"),
    httpVersions = setOf("HTTP/1.1"),
    requireJsonContentType = true,
)
```

By default, a request with a body must use the JSON content type. The server accepts request bodies with a known length, not chunked request bodies. It can send chunked responses.

The server checks the browser's Host and Origin headers and adds CORS response headers. Your frontend can use ordinary `fetch` or `EventSource` calls.

## Streaming {#streaming}

Use `sse` to keep an HTTP connection open and send events as they happen. If you need to check the request first, use `respondSse` inside a normal route.

``` { .kotlin title="Streaming response signatures on PluginCall" }
suspend fun respondSse(
    statusCode: Int = 200,
    headers: Map<String, String> = emptyMap(),
    chunked: Boolean = true,
    heartbeatInterval: Duration? = 30.seconds,
    block: suspend PluginSseSession.() -> Unit,
)

suspend fun respondStream(
    contentType: String,
    statusCode: Int = 200,
    headers: Map<String, String> = emptyMap(),
    block: suspend PluginResponseStream.() -> Unit,
)
```

`PluginSseSession` is a `CoroutineScope`. Its public operations include:

| Member | Behavior |
| --- | --- |
| `call` | Read the request through its `PluginCall`. |
| `send(data: String, event: String? = null, id: String? = null)` | Format the data as an SSE event and send it. |
| `heartbeat()` | Send one heartbeat comment to keep the stream active. |
| `write(bytes: ByteArray)` | Send bytes that you have already formatted as an SSE event. |
| `close()` | Close the connection and cancel the work sending events. |

The server sends heartbeat comments at the interval you choose. Use a positive, finite duration, or `null` to turn them off.

The coroutine sending events ends when the client disconnects, the handler returns, or the server closes. Its heartbeat job and child coroutines end too. Use suspending calls, or `runInterruptible` around blocking calls, so this work can be cancelled.

`PluginResponseStream.write(bytes)` writes one chunk of a response, such as a line of NDJSON. The runtime ends the response when the block returns. Your plugin decides how to queue events, identify them, and replay missed events.

## Frontend host {#host}

Import `host` from `@snap-o/plugin-host`. This object provides the current connection details and methods for using Snap-O's toolbar and macOS dialogs. The interface below lists its properties and methods; connection listeners are described later.

``` { .typescript title="Host interface" }
interface Host extends EventTarget {
  readonly connected: boolean;
  readonly baseURL: string | null;
  readonly manifest: ProcessManifest | null;
  readonly plugin: PluginDescriptor | null;
  setToolbar(toolbar: Toolbar): Promise<void>;
  openColorPicker(options: ColorPickerOptions): Promise<ColorPicker>;
  copyText(text: string): Promise<void>;
  saveFile(options: { name: string; data: Blob }): Promise<boolean>;
}
```

`connected` means Snap-O has a server address for the current page. Requests to it can still fail. Read `baseURL` after every `connection` event because the address can change. Reading these properties starts setup with Snap-O, so the first read may show no connection.

### Metadata

``` { .typescript title="Plugin and app metadata" }
interface PluginDescriptor {
  id: string;
  name: string;
  protocolVersion: number;
  iconBase64?: string;
  frontend?: { assetPath: string; hostApiVersion: number };
}

interface ProcessManifest {
  version: number;
  pid: number;
  processName?: string;
  androidUserId?: number;
  processIdentity: string;
  app: {
    packageName: string;
    name: string;
    revision: string;
    iconBase64?: string;
    inspectors: PluginDescriptor[];
  };
}
```

`host.plugin` contains details about the plugin shown in this page. `host.manifest` contains details about the Android app process. `processIdentity` changes when that process restarts. `app.revision` identifies the installed version of the app package.

`app.inspectors` lists the app's plugins. It keeps its old name so existing clients can still read it. Messages between Snap-O and the SDK also keep the internal `inspector` key. Use `host.plugin` to read the selected plugin's details; the SDK handles these messages for you.

### Connection events and disposal

``` { .typescript title="Listen for connection changes" }
import { host } from "@snap-o/plugin-host";

const onConnection = () => {
  // Read host.connected, host.baseURL, and host.plugin here.
};
host.addEventListener("connection", onConnection);
onConnection();

// During component or page disposal:
host.removeEventListener("connection", onConnection);
```

A connection listener receives a `ConnectionEvent` with a boolean `connected` property. The event can also mean that the app details or server address changed. Read the current host properties on each event, even if `connected` has not changed.

Snap-O replaces a page when the app or process it belongs to changes. It closes old pages before releasing the ADB connection they used.

Your frontend must still cancel unfinished requests, close event streams and color pickers, and remove listeners. A hidden page can stay loaded after you switch tools, and can receive a disconnected state. See the [connection example](plugins.md#frontend).

The package also exports `Host`, `PluginHost`, and the related types. Most frontends use the `host` object. Tests can supply a fake with just the properties and methods their code uses. `PluginHost` accepts a custom transport for testing messages to and from Snap-O.

The SDK reports connection changes. Your frontend makes HTTP requests, reads JSON, checks protocol versions, and reconnects its event streams.

## Toolbar and native helpers {#native}

``` { .typescript title="Toolbar types" }
type ToolbarIcon = "clear" | "sortAscending" | "sortDescending"
  | "search" | "export" | "reset";

type ToolbarAction =
  | { type: "button"; id: string; icon: ToolbarIcon; label: string;
      enabled?: boolean; onClick: () => void }
  | { type: "search"; id: string; label: string; value: string;
      enabled?: boolean; onChange: (value: string) => void };

interface Toolbar {
  start: readonly ToolbarAction[];
  end?: readonly ToolbarAction[];
}
```

`setToolbar` replaces the toolbar. The `start` group accepts up to three controls, with at most one search field. The `end` group accepts buttons only. Give each control a unique ID across both groups.

Clear the toolbar with `setToolbar({ start: [] })` when removing the UI. Callbacks return `void`, so catch errors from async work inside each callback.

``` { .typescript title="Native color picker types" }
interface ColorPickerOptions {
  value: string;
  onChange: (value: string) => void;
  onClose?: () => void;
}

interface ColorPicker {
  setValue(value: string): Promise<void>;
  close(): Promise<void>;
}
```

Colors use hexadecimal RGBA, such as `#6688ccff`. `openColorPicker` returns a promise for an object with `setValue` and `close` methods. Keep that object so you can close the picker when disconnecting or removing the UI. Closing an old picker object does not close a newer picker.

`copyText(text)` returns a promise that completes after the text is copied. `saveFile({ name, data })` opens a macOS save dialog for the supplied `Blob`. It returns `true` if the file was saved, or `false` if the user cancelled. It does not return the file path. Catch rejected promises and show their errors in your UI.

Snap-O asks the user to confirm before copying text or opening a color picker. Saving a file opens a save dialog. Use ordinary HTTP/HTTPS links to open web pages outside your frontend; Snap-O handles those links. Users select and launch Android apps through Snap-O's own UI.

## Versions and limits {#compatibility data-nav="Versions and limits"}

These versions describe different things:

| Version | Who sets it | What it means |
| --- | --- | --- |
| Maven/npm package version | SDK or plugin author | Which release of a library or build plugin you depend on. |
| `protocolVersion` | Your plugin | Which data format the Android server uses. Your frontend checks whether it supports it. |
| `hostApiVersion` | Snap-O | Which Snap-O host API the frontend needs. Currently version 1. |

Your frontend must check the server's protocol version; Snap-O cannot check your data format for you. Example accepts only protocol 1. Choose whether your frontend supports one version or several, and check incoming data too. A change to your data format does not require a change to `hostApiVersion`.

| Setting | Current default or limit |
| --- | --- |
| Runtime request body | 64 KiB; configurable with `requestPolicy` |
| Runtime connections | 32 per plugin/process; constructor override available |
| Request read / finite request / blocked write | 5 seconds / 30 seconds / 5 seconds; write checks run once per second |
| SSE heartbeat | 30 seconds; configurable or disabled per stream |
| Frontend ZIP | 16 MiB compressed and expanded; at most 1,024 entries |
| Native file export | 64 MiB |

SSE connections can stay open beyond the 30-second request limit.

Include all files your frontend needs in its build. Snap-O blocks remote scripts, frames, workers, forms, and requests to servers other than your plugin's Android server. It also blocks WebAssembly and running JavaScript from strings. If you select a local development server, Snap-O allows that server and its hot-reload connection.

These checks do not make JavaScript from an untrusted APK safe to run. See [WebView safeguards](https://github.com/openai/snap-o/blob/main/plugins/README.md#webview-safeguards) for details.

The [runtime source](https://github.com/openai/snap-o/tree/main/sdk/runtime/src/main/java/com/openai/snapo/plugin) also provides APIs for working directly with sockets, HTTP parsing, and event formatting. Most plugins can use `PluginServer` and its routes. Plugin discovery also supports plugins without a frontend; this guide covers tools with a web UI.
