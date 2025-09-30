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

## 2. Wire the OkHttp interceptor

Attach the interceptor while you build your `OkHttpClient`. Doing this once at client construction covers the whole app:

```kotlin
val client = OkHttpClient.Builder()
    .addInterceptor(SnapOOkHttpInterceptor())
    .build()
```

The interceptor mirrors each request, response, and failure whenever a Snap-O link is active. In release variants (where the noop artifact is used) this call becomes a pass-through.

## 3. Capture WebSocket activity (optional)

With OkHttp, you can capture WebSocket activity by wrapping your `webSocketFactory` via `.withSnapOInterceptor`.

For example:

```kotlin
val client = OkHttpClient.Builder()....build()
engine {
    preconfigured = client
    webSocketFactory = client.withSnapOInterceptor()
}
```

## 4. Optional: SnapOInitProvider configuration

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

## 5. Verify the connection

1. Install your debug build on a device or emulator.
2. Launch Snap-O on macOS and connect to the device.
3. Trigger a request in-app; it should appear in the Network Inspector sidebar.

If nothing shows up, confirm the dependencies are present in the variant you installed and that the link icon in Snap-O indicates an active session.
