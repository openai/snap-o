---
layout: guide
title: Tool API reference · Snap-O
description: Configuration, Android HTTP and streaming APIs, and the TypeScript host API for Snap-O tool authors.
styles:
- guide.css
languages:
- kotlin
- toml
- typescript
breadcrumbs:
- label: Snap-O
  href: index.html
- label: Build a tool
  href: plugins.html
---

# Tool API reference

Use the Android library to handle requests inside your app. Use the frontend library to connect your web UI to Snap-O. Use the Tool Gradle Plugin to build and include that UI in your Android app.
{.lead}

Start with [Build a tool](plugins.md) to add a tool to your Android project.
{.note}

## Packaging {#packaging}

The Tool Gradle Plugin generates the descriptor, Android manifest entry, and frontend ZIP. Follow the [tool configuration](plugins.md#manifest) and [frontend packaging](plugins.md#assets) steps in the guide.

The default setup uses two Gradle plugins:

- `com.openai.snapo.tool` goes in your Android module and builds and packages the tool.
- `com.openai.snapo.tool-settings` goes in `settings.gradle.kts` and enables Node downloads for the build.

Gradle downloads and caches Node and npm automatically. You do not need to configure a Node installation for Gradle builds.

Add the module plugin to your version catalog:

``` { .toml title="gradle/libs.versions.toml" }
[versions]
snapo = "8.0.0"

[plugins]
snapo-tool = { id = "com.openai.snapo.tool", version.ref = "snapo" }
```

``` { .kotlin title="Your Android module's build.gradle.kts" }
plugins {
    alias(libs.plugins.snapo.tool)
}
```

Apply the companion settings plugin once per Android project, using the same Snap-O version:

``` { .kotlin title="settings.gradle.kts" }
plugins {
    id("com.openai.snapo.tool-settings") version "8.0.0"
}
```

Gradle does not support catalog aliases in settings files. Both Gradle components resolve from Maven Central; include `mavenCentral()` in `pluginManagement.repositories`.

Configure your tool in the Android module:

``` { .kotlin title="Tool definition" }
snapoTool {
    id = "example"
    displayName = "Example"
    icon = "@drawable/example_tool_icon"
}
```

Set `id`, `displayName`, and `icon` for every tool. Include the named drawable or mipmap resource in your Android resources. The plugin generates host compatibility metadata; bundled frontends do not need protocol-version configuration.

| Property | Type | Required or default | Meaning |
| --- | --- | --- | --- |
| `id` | `Property<String>` | Required | ID to keep across releases. Use up to 100 lowercase letters, digits, dots, or hyphens, starting with a letter. |
| `displayName` | `Property<String>` | Required | Name shown in Snap-O. Must not be blank; up to 200 characters. |
| `icon` | `Property<String>` | Required | Android drawable or mipmap resource reference, such as `@drawable/tool_icon`. |
| `frontendDirectory` | `DirectoryProperty` | `frontend/` | Folder with your UI source, `package.json`, and `package-lock.json`. |
| `frontendAssets` | `DirectoryProperty` | Output of `toolBuild` | Folder of built UI files to include in the APK. Must contain `index.html`. |

You can assign these Gradle properties as shown above, or use `.set(...)` with a Gradle provider. `toolBuild` runs the frontend's npm `build` script, which must write to `frontendDirectory/dist/`. `toolDev` runs the npm `dev` script. When you build the Android module, Gradle includes the frontend ZIP and tool metadata automatically.

### Advanced: independently shipped clients {#independent-clients}

Your tool owns its HTTP API and compatibility rules. If clients ship independently, expose any version or capability information through your own endpoints. The SDK does not define a tool protocol version or negotiate compatibility for you.

### Advanced: Node installation {#node-installation}

The default build uses its own cached Node installation, including when launched from Android Studio. Running `npm` commands directly in a terminal uses your local Node installation instead.

Override these settings only if your build needs a different Node version or your team already manages Node:

| Property | Type | Default | Meaning |
| --- | --- | --- | --- |
| `downloadNode` | `Property<Boolean>` | `true` | Use Gradle's managed Node and npm. Set to `false` to use the installation available to Gradle on `PATH`. |
| `nodeVersion` | `Property<String>` | `22.23.2` | Version of the managed Node installation. Ignored when `downloadNode` is `false`. |

``` { .kotlin title="Use your team's Node installation" }
snapoTool {
    downloadNode = false
}
```

In this mode, Node and npm must be available to Gradle, including builds launched from Android Studio or CI. You can omit `com.openai.snapo.tool-settings`.

The settings plugin registers the Node download repository. Keeping that repository in settings supports builds that use `FAIL_ON_PROJECT_REPOS`.

### Custom frontend builds

To include UI files you have already built, set `frontendAssets`. Gradle then skips the default npm build, so the settings plugin is unnecessary:

``` { .kotlin title="Package existing frontend files" }
snapoTool {
    frontendAssets = layout.projectDirectory.dir("prebuilt-frontend")
}
```

You can also set `frontendAssets` from a Gradle provider for another task's output directory. Gradle will run that task before packaging the files. See the [packaging source and contributor notes](https://github.com/openai/snap-o/tree/main/tool-sdk/gradle-plugin).

### Generated constants

The Tool Gradle Plugin generates a Java class in the Android module's namespace:

``` { .kotlin title="Constants available to Kotlin" }
SnapOTool.ID               // String: "example"
```

Each module defines one `snapoTool` and gets one generated `SnapOTool` class. Give each tool module its own Android namespace.

## Server and startup {#server}

Add `com.openai.snapo:tool-runtime` from Maven Central. Use the same version as the Snap-O Tool Gradle Plugins. Import its classes from `com.openai.snapo.tool`.

Create a `ToolServer` to receive HTTP requests in your Android app:

``` { .kotlin title="ToolServer signatures" }
class ToolServer(
    toolId: String,
    maxConnections: Int = 32,
    configure: ToolRoutes.() -> Unit,
) : Closeable {
    val isRunning: Boolean
    fun start()
    fun startIfAllowed(
        context: Context,
        releaseMetadataKey: String = "snapo.$toolId.allow_release",
        allowRelease: Boolean = false,
    ): Boolean
    override fun close()
    suspend fun serve(connection: ToolConnection)
}
```

This block lists the class signatures. `start()` opens an Android abstract Unix socket for receiving requests. Calling it again while the server is running has no effect. It throws if the socket cannot be opened. `close()` stops the server and closes its connections.

Tests can use `serve` to pass in a connection directly. The server handles the request and closes that connection.

Use `startIfAllowed(context)` from an AndroidX Startup initializer, as shown in the [startup guide](plugins.md#startup). It checks the policy below, returns `true` when the server starts or is already running, and returns `false` when the policy denies startup or binding throws an `IOException`. Socket failures are logged and can be retried. A denied call does not stop a running server. Configuration errors still throw.

The default release metadata key is `snapo.<tool-id>.allow_release`. Supply `releaseMetadataKey` to keep an existing key, or `allowRelease = true` for an explicit release opt-in.

The lower-level `start()` does not check policy or catch startup failures. For custom startup code, call `ToolStartupPolicy.isAllowed` before it:

``` { .kotlin title="Startup policy signatures" }
ToolStartupPolicy.isAllowed(
    context: Context,
    releaseMetadataKey: String,
    allowRelease: Boolean = false,
): Boolean

ToolStartupPolicy.isAllowed(
    isDebuggable: Boolean,
    allowRelease: Boolean,
    applicationAllowsRelease: Boolean = false,
): Boolean
```

The check allows startup when at least one of these is true:

- The app is debuggable.
- You pass `allowRelease = true`.
- The app sets the manifest metadata flag named by `releaseMetadataKey` to `true`.

Keep the tool dependency in debug builds unless you intend to inspect release builds. See the [startup guidance](plugins.md#startup).

## Requests and responses {#requests}

Inside `ToolServer { ... }`, use these `ToolRoutes` members:

| Route API | Argument or value | What it does |
| --- | --- | --- |
| `get`, `post`, `put`, `patch`, `delete` | `(path, suspend ToolCall.() -> Unit)` | Choose the code to run for an HTTP method and path. |
| `route` | `(method, path, handler)` | Handle another HTTP method, written in uppercase. The server handles `OPTIONS` automatically. |
| `sse` | `(path, heartbeatInterval = 30.seconds, handler)` | Handle a GET request by sending events. The block receives a `ToolSseSession`. |
| `validateRequest` | `(ToolHttpRequest) -> Unit` | Check the request before choosing a route or sending a response. |
| `onError` | `(Exception) -> ToolHttpResponse` | Choose the error response when a request fails before sending a response. |
| `notFound` | `suspend ToolCall.() -> Unit` | Choose what happens when no route matches the path. |
| `requestPolicy` | `ToolHttpRequestPolicy` | Set which requests to accept and how large their bodies can be. |
| `preflightStatusCode` | `Int`, default `204` | Status for the browser's automatic preflight request. |
| `exposedHeaders` | `String?`, default `null` | Name the response headers your frontend can read. |
| `vary` | `String`, default `"Origin"` | `Vary` response header |
| `cacheControl` | `String`, default `"no-store"` | `Cache-Control` response header |

Malformed HTTP requests return 400; request-read timeouts return 408. Unexpected handler failures are logged and return a generic 500. Throw `ToolHttpException` for an intentional HTTP error, or use `onError` to map domain exceptions.

A route matches the URL path, without its query parameters. You can name a variable path segment, such as `{id}` in `/items/{id}`.

The first matching route for the HTTP method handles the request. Put fixed paths before patterns that could also match them. An unknown path returns 404. A known path with an unsupported HTTP method returns 405 and an `Allow` header.

### Request data

| `ToolCall` member | Type | Meaning |
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

``` { .kotlin title="ToolCall response signatures" }
fun respondJson(json: String, statusCode: Int = 200)
fun respondText(text: String, statusCode: Int = 200)
fun respondNoContent()
fun respond(response: ToolHttpResponse, headers: Map<String, String> = emptyMap())
```

A route handler sends one response. If it returns without sending one, the server sends 204. Pass a JSON string to `respondJson`; use your preferred JSON library to convert objects first. Once a response starts, the server cannot replace it with an error response.

For custom bodies or content types, construct a response:

``` { .kotlin title="ToolHttpResponse constructor" }
data class ToolHttpResponse(
    val statusCode: Int,
    val body: ByteArray,
    val allowedMethods: String? = null,
    val contentType: String = "application/json; charset=utf-8",
)
```

You can also create responses with these methods:

- `ToolHttpResponse.json(json, statusCode)` for JSON.
- `ToolHttpResponse.text(text, statusCode)` for plain text.
- `ToolHttpResponse.error(statusCode, message, allowedMethods)` for an error.

Throw `ToolHttpException(statusCode, message)` for an intentional HTTP error, or configure `onError` to map domain exceptions. Other handler exceptions, including `IllegalArgumentException`, `IOException`, and `SocketTimeoutException`, are logged and return a generic 500. The default 400/408 mapping applies to failures while reading the HTTP request.

### Request policy

``` { .kotlin title="Default request policy" }
ToolHttpRequestPolicy(
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

``` { .kotlin title="Streaming response signatures on ToolCall" }
suspend fun respondSse(
    statusCode: Int = 200,
    headers: Map<String, String> = emptyMap(),
    chunked: Boolean = true,
    heartbeatInterval: Duration? = 30.seconds,
    block: suspend ToolSseSession.() -> Unit,
)

suspend fun respondStream(
    contentType: String,
    statusCode: Int = 200,
    headers: Map<String, String> = emptyMap(),
    block: suspend ToolResponseStream.() -> Unit,
)
```

`ToolSseSession` is a `CoroutineScope`. Its public operations include:

| Member | Behavior |
| --- | --- |
| `call` | Read the request through its `ToolCall`. |
| `send(data: String, event: String? = null, id: String? = null)` | Format the data as an SSE event and send it. |
| `heartbeat()` | Send one heartbeat comment to keep the stream active. |
| `write(bytes: ByteArray)` | Send bytes that you have already formatted as an SSE event. |
| `close()` | Close the connection and cancel the work sending events. |

The server sends heartbeat comments at the interval you choose. Use a positive, finite duration, or `null` to turn them off.

The coroutine sending events ends when the client disconnects, the handler returns, or the server closes. Its heartbeat job and child coroutines end too. Use suspending calls, or `runInterruptible` around blocking calls, so this work can be cancelled.

`ToolResponseStream.write(bytes)` writes one chunk of a response, such as a line of NDJSON. The runtime ends the response when the block returns. Your tool decides how to queue events, identify them, and replay missed events.

## Frontend host {#host}

Import `host` from `@snap-o/tool-host`. This object provides the current connection details and methods for using Snap-O's toolbar and macOS dialogs. The interface below lists its properties and methods; connection listeners are described later.

``` { .typescript title="Host interface" }
interface Host extends EventTarget {
  readonly connection: ToolConnection | null;
  onConnection(callback: (connection: ToolConnection | null) => void | (() => void)): () => void;
  setToolbar(toolbar: Toolbar): Promise<void>;
  openColorPicker(options: ColorPickerOptions): Promise<ColorPicker>;
  copyText(text: string): Promise<void>;
  saveFile(options: { name: string; data: Blob }): Promise<boolean>;
}
```

`host.connection` is `null` until Snap-O provides the server address and connection details. Requests can still fail while connected.

### Connection lifetime

``` { .typescript title="Connection subscription" }
interface ToolConnection {
  readonly baseURL: string;
  readonly processIdentity: string;
  readonly signal: AbortSignal;
}

const unsubscribe = host.onConnection(connection => {
  // Update the UI; null means disconnected.
  // Return a cleanup function for any stream or UI work started here.
});
```

`baseURL` is the forwarded Android server address. `processIdentity` is an opaque token that changes when the Android process restarts; use it to scope state you retain across reconnects.

The callback runs immediately and whenever the host reports a connection change. Its previous cleanup runs before the next callback and when unsubscribing. A new connection can reuse the same URL. Its `signal` aborts when that connection ends; use it with `fetch` for requests tied to the connection. Unsubscribing one UI does not abort another UI's requests.

Snap-O unloads pages before releasing their forwarded ports. Hidden pages may stay loaded and receive a disconnected state. In a loaded page, close an old `EventSource` before replacing it, or when removing its UI, to stop retries at its old URL. See the [connection example](plugins.md#frontend).

The lower-level `connection` event remains available through `addEventListener`. It reports a boolean `connected` property; read `host.connection` after subscribing and on each event.

The package also exports `Host`, `ToolHost`, and the related types. Most frontends use the `host` object. Tests can supply a fake with just the properties and methods their code uses. `ToolHost` accepts a custom transport for testing messages to and from Snap-O.

The SDK reports connection changes. Your frontend makes HTTP requests, reads JSON, checks protocol versions, and reconnects its event streams.

## Toolbar and native helpers {#native}

``` { .typescript title="Toolbar types" }
type ToolbarIcon = "clear" | "sortAscending" | "sortDescending"
  | "search" | "export" | "reset";

interface ToolbarAction {
  id: string;
  icon: ToolbarIcon;
  label: string;
  enabled?: boolean;
  onClick: () => void;
}

interface ToolbarSearch {
  label: string;
  value: string;
  enabled?: boolean;
  onChange: (value: string) => void;
}

interface Toolbar {
  actions?: readonly ToolbarAction[];
  search?: ToolbarSearch;
  endActions?: readonly ToolbarAction[];
}
```

`setToolbar` replaces the toolbar. The main area accepts at most three controls: up to three actions, or two actions plus search. `endActions` places buttons in the separate trailing area, such as Network's export action. There are at most eleven controls across both areas. Action IDs must be unique; `search` is reserved when the search field is present.

Clear the toolbar with `setToolbar({})` when removing the UI. Catch errors from asynchronous work inside callbacks.

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
| Maven/npm package version | SDK or tool author | Which release of a library or Gradle plugin you depend on. |
| `hostApiVersion` | Snap-O build tooling | Generated compatibility metadata for the host bridge. Currently version 2; not an author setting. |

The frontend and Android server ship together, so bundled tools do not need a protocol version. Validate incoming data for the shape your UI expects. Tools with independent clients define their [own compatibility rules](#independent-clients). The desktop checks generated host API metadata before loading a frontend because Snap-O and Android tools ship independently.

| Setting | Current default or limit |
| --- | --- |
| Runtime request body | 64 KiB; configurable with `requestPolicy` |
| Runtime connections | 32 per tool/process; constructor override available |
| Request read / finite request / blocked write | 5 seconds / 30 seconds / 5 seconds; write checks run once per second |
| SSE heartbeat | 30 seconds; configurable or disabled per stream |
| Frontend ZIP | 16 MiB compressed and expanded; at most 1,024 entries |
| Native file export | 64 MiB |

SSE connections can stay open beyond the 30-second request limit.

Include all files your frontend needs in its build. Snap-O blocks remote scripts, frames, workers, forms, and requests to servers other than your tool's Android server. It also blocks WebAssembly and running JavaScript from strings. If you select a local development server, Snap-O allows that server and its hot-reload connection.

These checks do not make JavaScript from an untrusted APK safe to run. See [WebView safeguards](https://github.com/openai/snap-o/blob/main/tools/README.md#webview-safeguards) for details.

The [runtime source](https://github.com/openai/snap-o/tree/main/tool-sdk/runtime/src/main/java/com/openai/snapo/tool) contains the HTTP and SSE implementation. Most tools can use `ToolServer` and its routes. Tool plugin discovery also supports tool plugins without a frontend; this guide covers tools with a web UI.
