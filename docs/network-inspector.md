---
layout: guide
title: Network Guide · Snap-O
description: Add Snap-O Network to an Android app using OkHttp, Ktor, or
  HttpURLConnection.
styles:
- guide.css
- network-inspector.css
languages:
- kotlin
- toml
breadcrumbs:
- label: Snap-O
  href: index.html
---

# Network Guide

Capture network requests from an Android app with Snap-O, including response bodies, Server-Sent Events, and WebSocket messages. Works with OkHttp, Ktor's OkHttp engine, and HttpURLConnection.
{.lead}

To edit API responses or return mock data with Python handlers, see [Network Interception](network-intercept.md).
{style="margin-top: 18px"}

## Use Maven Central {#maven-central data-step="1"}

Snap-O publishes Android libraries version 3.1.1 and newer to [Maven Central](https://central.sonatype.com/namespace/com.openai.snapo). Most Android projects already include `mavenCentral()`; add it to your dependency sources if yours does not.

``` { .kotlin title="settings.gradle.kts" data-emphasis-lines="4" }
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
```

## Add the Android dependency {#install data-step="2"}

Choose the dependency that matches your network client. Use the real interceptor in debug builds and its no-op counterpart in release builds. The no-op artifact preserves the same API while passing traffic through without starting the Snap-O server.

<div class="dependency-options" markdown="1">

<details markdown="1">
<summary>OkHttp or Ktor</summary>

Use the OkHttp interceptor for OkHttp directly or through Ktor's OkHttp engine.

<div class="dependency-tabs" data-label="OkHttp dependency format" markdown="1">

<div id="okhttp-catalog-panel" data-tab="Version catalog" markdown="1">

``` { .toml title="gradle/libs.versions.toml" data-emphasis-lines="2,5,6" }
[versions]
snapo = "8.0.0"

[libraries]
snapo-network-okhttp3 = { module = "com.openai.snapo:network-okhttp3", version.ref = "snapo" }
snapo-network-okhttp3-noop = { module = "com.openai.snapo:network-okhttp3-noop", version.ref = "snapo" }
```

``` { .kotlin title="app/build.gradle.kts" data-emphasis-lines="2,3" }
dependencies {
    debugImplementation(libs.snapo.network.okhttp3)
    releaseImplementation(libs.snapo.network.okhttp3.noop)
}
```

</div>

<div id="okhttp-direct-panel" data-tab="Direct dependency" markdown="1">

``` { .kotlin title="app/build.gradle.kts" data-emphasis-lines="2,3" }
dependencies {
    debugImplementation("com.openai.snapo:network-okhttp3:8.0.0")
    releaseImplementation("com.openai.snapo:network-okhttp3-noop:8.0.0")
}
```

</div>

</div>

</details>

<details markdown="1">
<summary>HttpURLConnection</summary>

Use the HttpURLConnection interceptor on Android 7.0 (API 24) or newer.

<div class="dependency-tabs" data-label="HttpURLConnection dependency format" markdown="1">

<div id="httpurlconnection-catalog-panel" data-tab="Version catalog" markdown="1">

``` { .toml title="gradle/libs.versions.toml" data-emphasis-lines="2,5,6" }
[versions]
snapo = "8.0.0"

[libraries]
snapo-network-httpurlconnection = { module = "com.openai.snapo:network-httpurlconnection", version.ref = "snapo" }
snapo-network-httpurlconnection-noop = { module = "com.openai.snapo:network-httpurlconnection-noop", version.ref = "snapo" }
```

``` { .kotlin title="app/build.gradle.kts" data-emphasis-lines="2,3" }
dependencies {
    debugImplementation(libs.snapo.network.httpurlconnection)
    releaseImplementation(libs.snapo.network.httpurlconnection.noop)
}
```

</div>

<div id="httpurlconnection-direct-panel" data-tab="Direct dependency" markdown="1">

``` { .kotlin title="app/build.gradle.kts" data-emphasis-lines="2,3" }
dependencies {
    debugImplementation("com.openai.snapo:network-httpurlconnection:8.0.0")
    releaseImplementation("com.openai.snapo:network-httpurlconnection-noop:8.0.0")
}
```

</div>

</div>

</details>

</div>

## Add request interceptors {#connect data-step="3"}

Add the interceptor once when the client is created. Requests made by that client can then be captured and made available to Snap-O. WebSockets require the wrapped factory shown below.

### OkHttp

``` { .kotlin title="Kotlin" }
import com.openai.snapo.network.okhttp3.SnapOOkHttpInterceptor

val client = OkHttpClient.Builder()
    .addInterceptor(SnapOOkHttpInterceptor())
    .build()
```

<div class="notice" markdown="span">
Requests are buffered on the device for up to five minutes by default, so Snap-O can open after the app starts and still show recent traffic.
</div>

<details markdown="1">
<summary>Ktor with the OkHttp engine</summary>

Attach the same interceptor through Ktor's OkHttp engine.

``` { .kotlin title="Kotlin" }
import com.openai.snapo.network.okhttp3.SnapOOkHttpInterceptor

val client = HttpClient(OkHttp) {
    engine {
        addInterceptor(SnapOOkHttpInterceptor())
    }
}
```

If your app already builds an OkHttp client, pass that client to Ktor instead.

``` { .kotlin title="Kotlin · preconfigured client" }
val okHttpClient = OkHttpClient.Builder()
    .addInterceptor(SnapOOkHttpInterceptor())
    .build()

val client = HttpClient(OkHttp) {
    engine {
        preconfigured = okHttpClient
    }
}
```

</details>

<details markdown="1">
<summary>HttpURLConnection</summary>

Open the connection through the Snap-O interceptor. Response details are captured when your app reads the response code or response stream.

``` { .kotlin title="Kotlin" }
import com.openai.snapo.network.httpurlconnection.SnapOHttpUrlInterceptor

val interceptor = SnapOHttpUrlInterceptor()
val connection = interceptor.open(URL("https://example.com"))

connection.connect()
connection.inputStream.use { body ->
    // Read the response.
}
connection.disconnect()
```

You can also wrap a connection created elsewhere.

``` { .kotlin title="Kotlin · existing connection" }
val existing = URL("https://example.com")
    .openConnection() as HttpURLConnection
val connection = SnapOHttpUrlInterceptor().intercept(existing)
```

</details>

<details markdown="1">
<summary>WebSockets</summary>

Create WebSockets through the wrapped factory. Regular HTTP calls can continue using the original client.

``` { .kotlin title="Kotlin · OkHttp" }
import com.openai.snapo.network.okhttp3.withSnapOInterceptor

val webSocketFactory = client.withSnapOInterceptor()
val webSocket = webSocketFactory.newWebSocket(request, listener)
```

For Ktor, use the same preconfigured OkHttp client for HTTP traffic, wrap its WebSocket factory, and install Ktor's `WebSockets` plugin.

``` { .kotlin title="Kotlin · Ktor WebSockets" }
val okHttpClient = OkHttpClient.Builder()
    .addInterceptor(SnapOOkHttpInterceptor())
    .build()

val client = HttpClient(OkHttp) {
    engine {
        preconfigured = okHttpClient
        webSocketFactory = okHttpClient.withSnapOInterceptor()
    }
    install(WebSockets)
}
```

</details>

## Verify the connection {#verify data-step="4"}

1. Install and launch the debug build on an authorized Android device or emulator.
2. Open Snap-O on macOS and select the connected device.
3. Open **Tools → Show Tool Pane**, use the toolbar tool button, or press **⌘⌥I**.
4. Find the app process in the picker and click its **Network** icon, then trigger a request in the Android app.
5. Open the request to inspect headers, bodies, timing, SSE, or WebSocket messages.

Each running app process has one picker row, with shortcuts for its available tools. At startup, Snap-O restores your last app and tool when available, or selects another available app. During a session, it keeps captured requests visible through disconnects and reconnects when the selected app returns.
{.notice}

If the selected Android app stops, click **Open app** on the waiting screen when available, or launch it on your device.

### Filter traffic

Right-click a request to add its host to the exclusion filter. Exclusion filters are saved across sessions. Use the settings button beside the exclusion summary to add or remove filters. You can also search requests without changing your saved filters.

### Inspect responses

Use the arrow keys to move between requests. Server-Sent Events show whether the stream is pending, streaming, closed, or offline. When a response body is unavailable, Snap-O explains whether it is no longer retained or is not cached on this Mac. If loading fails while connected, click **Retry**.

### Intercept requests {#python-overrides}

Use `snapo network intercept` to change a real API response or return mock data. The tool shows the response delivered to the app while your Python handlers run separately. Follow the [Network Interception guide](network-intercept.md) for requirements, examples, and supported traffic.

## Troubleshooting {#troubleshoot data-step="5"}

- Confirm the device is online and authorized in `adb devices`.
- Confirm the installed variant includes the debug interceptor, not the no-op release artifact.
- Make sure the request uses the exact OkHttp client, Ktor engine, or HttpURLConnection wrapper you configured.
- Keep the Android app process running and select the newest process after an app restart.
- Update the Snap-O desktop app and Android dependency together if a protocol mismatch appears.
- The replay buffer retains up to five minutes, 10,000 events, or 16 MiB of total event data, whichever limit is reached first.
- Individual request and response bodies are captured up to 5 MiB by default; larger bodies are truncated.

## Advanced setup {#advanced data-step="6"}

Debug builds initialize the on-device server automatically through `SnapONetworkInitProvider`. Release builds do not start the server unless Network is explicitly enabled. Most apps should keep the defaults and use the no-op release artifact.

<details markdown="1">
<summary>Enable Network in release builds</summary>

If you intentionally include the real network dependency in a release build, add the following metadata directly to your application's `<application>` element. This opt-in applies only to Network. No-op release artifacts remain the recommended setup for most apps.

``` { .xml title="AndroidManifest.xml" }
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application>
        <meta-data
            android:name="snapo.network.allow_release"
            android:value="true" />
    </application>
</manifest>
```

</details>

<details markdown="1">
<summary>Provider configuration</summary>

The provider supports automatic initialization, main-process filtering, and replay limits. Manifest overrides must use Android manifest-merger directives because the library already declares these metadata entries.

``` { .xml title="AndroidManifest.xml" }
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">

    <application>
        <provider
            android:name="com.openai.snapo.network.SnapONetworkInitProvider"
            android:authorities="${applicationId}.snapo-network-init"
            android:exported="false">
            <meta-data
                android:name="snapo.auto_init"
                android:value="false"
                tools:replace="android:value" />
        </provider>
    </application>
</manifest>
```

| Metadata key | Default | Purpose |
| --- | --- | --- |
| `snapo.auto_init` | `true` | Starts the tool during app initialization. |
| `snapo.main_process_only` | `true` | Restricts automatic initialization to the app's main process. |
| `snapo.buffer_window_ms` | `300000` | Sets the rolling replay window in milliseconds. |
| `snapo.max_events` | `10000` | Caps the number of events retained for replay. |
| `snapo.max_bytes` | `16777216` | Caps total retained event data at 16 MiB. |

</details>

<details markdown="1">
<summary>Manual initialization</summary>

If automatic initialization is disabled, initialize the tool from your application process with a custom `NetworkInspectorConfig`.

``` { .kotlin title="Kotlin" }
import com.openai.snapo.network.NetworkInspector
import com.openai.snapo.network.NetworkInspectorConfig
import kotlin.time.Duration.Companion.minutes

NetworkInspector.initialize(
    application,
    NetworkInspectorConfig(
        bufferWindow = 10.minutes,
        maxBufferedEvents = 20_000,
        maxBufferedBytes = 32L * 1024 * 1024,
    ),
)
```

</details>
