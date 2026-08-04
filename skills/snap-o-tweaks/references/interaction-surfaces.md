# Choosing a Snap-O Tweaks interaction surface

The same active Compose tweak registry can be inspected from several surfaces. Choose the lightest surface that fits the actual task; none requires changing the Network Inspector protocol.

## Command line: agents, automation, and repeatable checks

Use the dependency-free Snap-O CLI when a terminal, Codex agent, test script, or
Linux/macOS workflow needs app discovery, typed value inspection or updates,
atomic batches, resets, or live snapshots. Use `snapo tweaks list --all` or
`snapo tweaks get NAME --all` to include previously adjusted tweaks no longer in
composition; inactive historical tweaks are inspectable but not writable. Its
tweaks workflow documents command selection and options. The CLI owns temporary
local forwarding and cleanup; explicit remote ADB endpoints use direct
smart-socket transport.

## Snap-O macOS app: an existing desktop inspector

Choose the Snap-O macOS app when someone wants an existing graphical inspector. Its app picker discovers connected devices and `snapo_tweaks_<pid>` servers, identifies each app through `/app`, and combines the Network and Tweaks inspector choices when one app supports both. The Tweaks inspector displays live values, streams changes, edits typed controls, and supports resetting changes.

The macOS app manages ADB forwarding and streaming itself. It is an existing interaction option, not a required proxy, dependency, or prerequisite for the standalone CLI and REST protocol.

## Optional in-app Compose overlay

Choose the overlay when developers or designers should adjust values directly on the Android device without a separate desktop window. Add the published live artifacts to debug builds and matching no-op artifacts to release builds using the same Snap-O version:

```kotlin
val snapoVersion = "<version>"

dependencies {
    debugImplementation("com.openai.snapo:tweaks:$snapoVersion")
    releaseImplementation("com.openai.snapo:tweaks-noop:$snapoVersion")

    debugImplementation("com.openai.snapo:tweaks-overlay:$snapoVersion")
    releaseImplementation("com.openai.snapo:tweaks-overlay-noop:$snapoVersion")
}
```

Wrap the app root with the optional overlay:

```kotlin
import com.openai.snapo.tweaks.overlay.SnapOTweakOverlay

@Composable
fun App() {
    SnapOTweakOverlay {
        AppContent()
    }
}
```

The overlay is disabled by default. Provide a developer-setting toggle using the public setting:

```kotlin
import com.openai.snapo.tweaks.overlay.SnapOTweakOverlaySettings

Switch(
    checked = SnapOTweakOverlaySettings.isEnabled,
    onCheckedChange = { enabled ->
        SnapOTweakOverlaySettings.isEnabled = enabled
    },
)
```

The setting persists across launches in live builds. When enabled, the floating inspector appears only while at least one tweak is active. The release no-op overlay preserves the same wrapper and settings API but never displays a panel. It is separate from release server activation; avoid enabling live release tweaks unless explicitly required.

## Transport ownership

The CLI and Snap-O macOS app own socket discovery, forwarding, and cleanup. The in-app overlay runs inside the Android process and needs no forward. A custom external client must discover the app, create and remove its own forward, and reconnect if the app process changes. Follow [protocol.md](protocol.md) for the exact discovery, forwarding, remote-ADB, and cleanup instructions.

## Custom interfaces: browsers, Node, Swift, and Compose

Build a custom surface when an existing CLI, desktop inspector, or in-app overlay
does not match the desired controls or workflow. All external hosts should
discover the tweak socket, establish an accessible ADB transport, read `/app`
and `/tweaks`, send atomic `PATCH /tweaks` updates, and consume full active
snapshots from `/tweaks/events`. Request `/tweaks?include=adjusted` when a
workflow needs every retained user adjustment, including inactive declarations.

- A browser interface can use `fetch` and `EventSource` through a same-origin proxy; see [protocol.md](protocol.md) for browser transport restrictions.
- A Node host or terminal tool can use built-in `fetch` for requests and parse the response body as a standard SSE stream.
- A native Swift tool can use `URLSession` for ordinary JSON requests and `URLSession.bytes(for:)` for SSE. Decode `event: tweaks` frames as complete snapshots, ignore keepalive comments, and own the ADB forward lifecycle.
- A Compose Desktop or other JVM host can use its normal HTTP client against the forwarded server and render controls from each descriptor's `type`, constraints, `default`, and `value`. Stream SSE snapshots and batch related writes into one `PATCH`.
- Inside the Android app, declare adjustable state with the supported public Compose API:

```kotlin
import androidx.compose.runtime.getValue
import com.openai.snapo.tweaks.tweak

enum class MotionStyle { Standard, Emphasized }

@Composable
fun AnimatedContent() {
    val duration by tweak(400, "Motion/Duration", 100..1500, step = 50)
    val enabled by tweak(true, "Motion/Enabled")
    val style by tweak(MotionStyle.Standard, "Motion/Style")
    // Use duration, enabled, and style when rendering the current screen.
}
```

Those declarations are observable `State<T>` and update when any supported surface changes the shared registry. The registry-editing `SnapOTweaks` helpers are annotated `@RestrictTo(LIBRARY_GROUP)`; do not present them as a stable public app API for building arbitrary in-process inspectors. Use the supported overlay or an external REST client when an editable custom control surface is needed.

For wire formats, transport cleanup, SSE semantics, validation, and security details, see [protocol.md](protocol.md).
