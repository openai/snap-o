# Network Inspector (Alpha)

> **Status:** early preview. Details may change while the feature is stabilized.

The Network Inspector can display HTTP/S network requests from your Android app, including server-side events and websocket messages. Requests can be tracked from the beginning of the app.

Currently Snap-O only has an interceptor for OkHttp, but could easily support other engines in the future.

## 1. Add the dependencies

Artifacts are currently only published through JitPack. Point Gradle at the JitPack Maven repository, then depend on the debug interceptor and the no-op release variant:

```kotlin
repositories {
    maven { url = uri("https://jitpack.io") }
}

dependencies {
    debugImplementation("com.github.openai.snap-o:link-okhttp3:<version>")
    releaseImplementation("com.github.openai.snap-o:link-okhttp3-noop:<version>")
}
```

![version](https://img.shields.io/github/v/release/openai/snap-o?label=latest+version)

This release dependency lets your code be the same in debug and release builds, but the Snap-O server and interceptors will not run.

If you're using `HttpURLConnection`, depend on the corresponding interceptor instead:

```kotlin
dependencies {
    debugImplementation("com.github.openai.snap-o:link-httpurlconnection:<version>")
    releaseImplementation("com.github.openai.snap-o:link-httpurlconnection-noop:<version>")
}
```

## 2. Using OkHttp directly

See [samples/demo-okhttp](https://github.com/openai/snap-o/blob/b406e928499648a50b8141f0864206c20a5f10c3/snapo-link-android/samples/demo-okhttp/src/main/java/com/openai/snapo/demo/MainActivity.kt#L35).

Attach the interceptor while you build your `OkHttpClient`. Doing this once at client construction covers the whole app:

```kotlin
val client = OkHttpClient.Builder()
    .addInterceptor(SnapOOkHttpInterceptor())
    .build()
```

The interceptor mirrors each request, response, and failure whenever a Snap-O link is active. In release variants (where the noop artifact is used) this call becomes a pass-through.

### Optional: WebSockets

With OkHttp, you can capture WebSocket activity by wrapping your `webSocketFactory` via `.withSnapOInterceptor`.

For example:

```kotlin
// OkHttpClient implements WebSocket.Factory. Use [WebSocket.Factory.withSnapOInterceptor].
val webSocketFactory = client.withSnapOInterceptor()
```

## 3. Using Ktor

See [samples/demo-ktor-okhttp](https://github.com/openai/snap-o/blob/b406e928499648a50b8141f0864206c20a5f10c3/snapo-link-android/samples/demo-ktor-okhttp/src/main/java/com/openai/snapo/demo/ktor/MainActivity.kt#L37).

Attach the interceptor while you build your `OkHttpClient`. Doing this once at client construction covers the whole app:

```kotlin
HttpClient(OkHttp) {
    engine {
        addInterceptor(SnapOOkHttpInterceptor())
    }
}
```

or preconfiguring an OkHttpClient:

```
val okHttpClient = OkHttpClient.Builder()
    .addInterceptor(SnapOOkHttpInterceptor())
    .build()

HttpClient(OkHttp) {
    engine {
        preconfigured = okHttpClient
    }
}
```

The interceptor mirrors each request, response, and failure whenever a Snap-O link is active. In release variants (where the noop artifact is used) this call becomes a pass-through.

### Optional: WebSockets

With Ktor, you can capture WebSocket activity by wrapping the preconfigured OkHttpClient with `.withSnapOInterceptor`.

For example:

```kotlin
val okHttpClient = OkHttpClient.Builder()
    .addInterceptor(SnapOOkHttpInterceptor())
    .build()

HttpClient(OkHttp) {
    engine {
        preconfigured = okHttpClient
        // OkHttpClient implements WebSocket.Factory. Use [WebSocket.Factory.withSnapOInterceptor].
        webSocketFactory = client.withSnapOInterceptor()
    }
    install(WebSockets)
}
```

## 4. Using HttpURLConnection

Attach the interceptor when opening a connection. Calls to `connect()`, `getInputStream()`, and `getResponseCode()` trigger capture.

```kotlin
val interceptor = SnapOHttpUrlInterceptor()
val connection = interceptor.open(URL("https://example.com"))
connection.connect()
```

Or wrap an existing connection:

```kotlin
val connection = URL("https://example.com").openConnection() as HttpURLConnection
val intercepted = SnapOHttpUrlInterceptor().intercept(connection)
```

## 5. Optional: SnapOInitProvider configuration

Debug builds start the link server automatically—most apps do not need any extra setup, via a `SnapOInitProvider` ContentProvider.

Customize the provider only if you need to adjust behavior. Override its metadata in your manifest:

```xml
<provider
    android:name="com.openai.snapo.link.core.SnapOInitProvider"
    android:authorities="${applicationId}.snapo-init"
    android:exported="false">
    <!-- Override to not autostart the Snap-O Link Server. -->
    <meta-data android:name="snapo.auto_init" android:value="false" />
    <!-- Override to not start the server on non-debuggable builds builds. -->
    <meta-data android:name="snapo.allow_release" android:value="true" />
</provider>
```

- `snapo.auto_init` whether the server automatically runs on startup, or you call `SnapOLinkServer.start()` manually. (default: true)
- `snapo.allow_release` keeps the inspector available outside debug builds. (default: false)
- `snapo.main_process_only` whether SnapOInitProvider only runs on the main process. (default: true)
- `snapo.buffer_window_ms` increases the rolling window of captured events. (default: 300000)
- `snapo.max_events` the max number of events that can stay in the buffer. (default: 10000)
- `snapo.max_bytes` the max number of bytes that can stay in the buffer. (default: 16777216)

## 6. Verify the connection

1. Install your debug build on a device or emulator.
2. Launch Snap-O on macOS and connect to the device.
3. Trigger a request in-app; it should appear in the Network Inspector sidebar.

If nothing shows up, confirm the dependencies are present in the variant you installed and that the link icon in Snap-O indicates an active session.
