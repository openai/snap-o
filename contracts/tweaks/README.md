# Snap-O Tweaks protocol

Status: phase one. The network inspector protocol is unchanged.

Snap-O Tweaks exposes adjustable values and explicitly registered, parameterless actions from the currently composed Android UI through an app-local socket, enabled by default only in debug builds. Agents and desktop tools can use HTTP to inspect those values, change them, and invoke app-owned callbacks while the app runs.

## Transport

Android listens on:

```text
snapo_tweaks_<pid>
```

Discover and forward the socket:

```bash
adb -s emulator-5554 shell cat /proc/net/unix
adb -s emulator-5554 forward tcp:0 localabstract:snapo_tweaks_12345
```

ADB prints the assigned localhost port:

```bash
curl -fsS http://127.0.0.1:43817/tweaks
```

Implement HTTP with Android `LocalServerSocket`, standard streams, and Android `JsonReader`/`JsonWriter`. Use JSON for app and tweak responses, PNG for `/app/icon`, and server-sent events for `/tweaks/events`. Ordinary responses include `Content-Length` and close their connection. Event streams keep their connection open. Bound request sizes and concurrent connections, and apply a read timeout while receiving each request. No server dependency, Android TCP port, or `INTERNET` permission is needed.

## REST API

### GET /app

Return the app's user-facing Android label, package name, and Tweaks protocol version:

```json
{
  "name": "Snap-O Tweaks Demo",
  "packageName": "com.openai.snapo.demo.tweaks",
  "protocolVersion": 4
}
```

Resolve `name` from the actual Android app label. An absent `protocolVersion` identifies the original version 1, which exposes value tweaks only. Version 2 adds action descriptors and `POST /tweaks/action`. Version 3 adds best-effort batch updates with per-item errors. Version 4 adds explicit null resets and authoritative modification status. The Tweaks protocol version is independent of the Network Inspector protocol version; hosts can use it to select compatible behavior.

### GET /app/icon

Lazily return the app icon as a 96 × 96 PNG with `Content-Type: image/png`. Return `404` when the icon is unavailable.

### GET /tweaks

Return a flat list of currently registered tweaks:

```json
{
  "tweaks": [
    {
      "name": "Font size",
      "type": "int",
      "default": 36,
      "value": 36,
      "min": 16,
      "max": 72,
      "step": 1
    },
    {
      "name": "Font weight",
      "type": "int",
      "default": 600,
      "value": 600,
      "min": 100,
      "max": 900,
      "step": 100
    },
    {
      "name": "Text color",
      "type": "color",
      "default": "#18212F",
      "value": "#18212F"
    },
    {
      "name": "Background color",
      "type": "color",
      "default": "#F7F8FA",
      "value": "#F7F8FA"
    },
    {
      "name": "Accent color",
      "type": "color",
      "default": "#5468FF",
      "value": "#5468FF"
    },
    {
      "name": "Animation duration",
      "type": "int",
      "default": 400,
      "value": 400,
      "min": 100,
      "max": 1500,
      "step": 50
    },
    {
      "name": "Spring stiffness",
      "type": "float",
      "default": 280.0,
      "value": 280.0,
      "min": 80.0,
      "max": 800.0,
      "step": 20.0
    },
    {
      "name": "Spring damping",
      "type": "float",
      "default": 0.7,
      "value": 0.7,
      "min": 0.1,
      "max": 1.0,
      "step": 0.05
    },
    {
      "name": "Use spring",
      "type": "boolean",
      "default": true,
      "value": true
    },
    {
      "name": "Preview text",
      "type": "string",
      "default": "Make it feel right.",
      "value": "Make it feel right."
    },
    {
      "name": "Marker shape",
      "type": "enum",
      "default": "Circle",
      "value": "Circle",
      "options": ["Circle", "RoundedSquare", "Square"]
    },
    {
      "name": "Motion/Toggle animation",
      "type": "action"
    }
  ]
}
```

A tweak name represents one shared value, not one composable. Multiple active composables may register the same name; the tweak appears only once, and an update changes the value observed by every usage. A tweak remains registered until its last usage leaves composition. Registry-owned tweaks restore their most recently edited value if the same complete declaration returns. App-owned sources remain authoritative and control their own persistence; historical snapshots are never replayed into a returning source. Inactive tweaks do not appear in default responses or event snapshots.

Registry-owned usages with the same name must agree on the tweak type, default, constraints, and ordered enum options. App-owned sources with the same name must use the same setting and value type.

In protocol version 4, only modified value tweaks include `"modified": true`; otherwise the field is absent. A missing field always means false, even when `value` differs from `default`. Standard tweaks compare value and default. App-owned tweaks report whether their own override exists. Versions 1, 2, and 3 omit this field; determine their modification status by comparing `value` with `default`. Action descriptors never include `modified`.

Supported value types are `int`, `float`, `boolean`, `color`, `string`, and `enum`. The `action` type describes an explicitly registered parameterless app-owned callback. Actions do not have `value`, `default`, options, or numeric constraints; clients must not attempt to patch or reset them. Integer tweaks accept only whole numbers; float tweaks accept whole or fractional numbers. Numeric tweaks may include `min`, `max`, and `step`. Only include constraints actually supplied by the app. A `step` is relative to `min`, or to `default` if no `min` is supplied. Colors use `#RRGGBB`, or `#RRGGBBAA` when translucent.

Enum tweaks include an ordered, nonempty `options` array containing the unique enum constant names. The descriptor's `default`, current `value`, picker text, and `PATCH` values all use those exact names. Preserve declaration order when rendering pickers; reject any value not present in `options`.

Action names must be explicit, stable, and unique among live registrations. Register a shared action once at the composable that owns its behavior rather than registering separate callbacks with the same name in multiple consumers. If multiple live owners register the same action name, the descriptor becomes:

```json
{
  "name": "Motion/Toggle animation",
  "type": "action",
  "conflicted": true
}
```

Conflicting actions remain discoverable but cannot be invoked until exactly one owner remains. Callbacks are never silently deduplicated, replaced, or renamed with generated suffixes.

Compose color defaults keep their exact in-process identity, including color space, component precision, and `Color.Unspecified`. The HTTP protocol still presents colors as sRGB hex; non-sRGB defaults are projected, and `Color.Unspecified` appears as `#00000000`. An explicit reset restores the original in-process color, even when its wire representation is projected.

Numeric JSON values may contain at most 128 characters and 64 significant digits, with a decimal scale between -64 and 64. Reject values outside those limits with `422` before changing any tweaks.

### GET /tweaks?include=adjusted

Opt in to a complete list of active tweaks and previously adjusted ordinary or app-owned tweaks that have since left composition:

```bash
curl -fsS 'http://127.0.0.1:43817/tweaks?include=adjusted'
```

The response uses the same `{"tweaks":[...]}` shape and complete tweak descriptors as `GET /tweaks`. Include every currently active tweak, whether or not it has been adjusted, and every inactive ordinary or app-owned tweak whose effective value or modification status changed after a successful inspector adjustment. Preserve its complete descriptor, last effective value, and authoritative modification status after its final usage leaves composition. App-owned history retains only an immutable snapshot, never its source, callbacks, or observers; a returning source supplies its own current value. Separate screens may reuse a name with different declarations; include each independently adjusted complete descriptor, even when names repeat. An active descriptor takes precedence over its matching historical snapshot. Order names by first observation, regardless of later activation or adjustment. For repeated names, list the active declaration first, followed by historical declarations in stable adjustment order.

An adjusted tweak remains in this history even after it is reset. An app-owned reset can leave an effective value different from the captured default while its modification status is false. An inactive tweak that was never adjusted, a no-op update that changes neither its value nor its modification status, and a rejected update do not create history entries. Adjustment history exists only for the current app process and is discarded when that process exits.

Historical inactive tweaks are read-only: `PATCH /tweaks` still accepts only currently active names. Versions 1 and 2 return `404` for an inactive name; later versions report a named per-item error. Actions appear while active but never create adjusted-history entries because they have no editable or retained value. Plain `GET /tweaks` and `GET /tweaks/events` remain active-only. The only supported query is exactly `include=adjusted` on `GET /tweaks`; unsupported, repeated, or additional query parameters and queries on other endpoints or methods return `400`.

### GET /tweaks/events

Stream the current tweaks using standard server-sent events:

```bash
curl --no-buffer http://127.0.0.1:43817/tweaks/events
```

```text
event: tweaks
data: {"tweaks":[{"name":"Motion/Show","type":"boolean","default":true,"value":true},{"name":"Motion/Duration","type":"int","default":400,"value":400,"min":100,"max":1500,"step":50}]}

event: tweaks
data: {"tweaks":[{"name":"Motion/Show","type":"boolean","default":true,"value":false,"modified":true}]}

```

The response uses `Content-Type: text/event-stream`. Its first event contains the complete current tweak list. Each later event also contains a complete, ordered list of value and action descriptors using exactly the `GET /tweaks` response shape. Clients replace their previous snapshot; a missing tweak has left composition.

Changes are published after the current Android main-thread turn. Tweaks added, removed, or changed during the same Compose update appear together in one event. Value changes are streamed whether they originated from an HTTP request or a Compose snapshot. Idle connections receive occasional SSE comments as keep-alives. A slow client receives the latest complete snapshot rather than an unbounded queue of intermediate states.

### PATCH /tweaks

```bash
curl -fsS -X PATCH http://127.0.0.1:43817/tweaks \
  -H 'Content-Type: application/json' \
  -d '{
    "values": {
      "Font size": 48,
      "Font weight": 700,
      "Accent color": "#3B82F6",
      "Animation duration": 550,
      "Spring damping": 0.8,
      "Use spring": false,
      "Preview text": "A calmer direction.",
      "Marker shape": "RoundedSquare"
    }
  }'
```

```json
{
  "tweaks": [
    { "name": "Font size", "value": 48, "modified": true },
    { "name": "Font weight", "value": 700, "modified": true },
    { "name": "Accent color", "value": "#3B82F6", "modified": true },
    { "name": "Animation duration", "value": 550, "modified": true },
    { "name": "Spring damping", "value": 0.8, "modified": true },
    { "name": "Use spring", "value": false, "modified": true },
    { "name": "Preview text", "value": "A calmer direction.", "modified": true },
    { "name": "Marker shape", "value": "RoundedSquare", "modified": true }
  ]
}
```

In protocol versions 3 and later, each value is applied separately on the Android main thread. A valid request returns HTTP 200 with successful changes in `tweaks` and any rejected changes in `errors`; earlier successful changes are not rolled back. Each error contains only its tweak `name` and `error` message. The `errors` field is omitted when every change succeeds:

```json
{
  "tweaks": [
    { "name": "Font size", "value": 48, "modified": true }
  ],
  "errors": [
    {
      "name": "Font weight",
      "error": "Invalid value for Font weight: Expected an integer."
    }
  ]
}
```

Reset tweaks explicitly:

```bash
curl -fsS -X PATCH http://127.0.0.1:43817/tweaks \
  -H 'Content-Type: application/json' \
  -d '{"values":{"Accent color":null,"Use spring":null}}'
```

```json
{
  "tweaks": [
    { "name": "Accent color", "value": "#5468FF" },
    { "name": "Use spring", "value": true }
  ]
}
```

For protocol version 4, use `null` to reset a tweak; a request can mix changes and resets. App-owned tweaks call their source's `reset()` method and return the current effective value. Reset all only active, non-action tweaks marked `"modified": true`. For versions 1, 2, and 3, reset each changed tweak by sending its `default` value instead.

Return `400` for malformed requests, `404` when an endpoint does not exist, `405` for an unsupported method, `413` for an oversized body, and `422` for invalid numeric literals or nonprimitive values. In protocol versions 1 and 2, an unknown tweak returns `404`, an invalid value returns `422`, and the entire batch is rejected. In versions 3 and later, unknown tweaks, invalid values, and action targets are reported as per-item errors without preventing other changes. Request-level errors use a small JSON body:

```json
{
  "error": "Unknown tweak: Font size"
}
```

Actions are not valid patch or reset targets. For versions 3 and later, an action target produces a named per-item error while other valid changes are applied.

### POST /tweaks/action

Invoke one explicitly registered parameterless app-owned action:

```bash
curl -fsS -X POST http://127.0.0.1:43817/tweaks/action \
  -H 'Content-Type: application/json' \
  -d '{"name":"Motion/Toggle animation"}'
```

```json
{
  "name": "Motion/Toggle animation"
}
```

The JSON body must contain exactly one nonblank string field named `name`. The registered callback executes synchronously on the Android main thread. This endpoint accepts no arguments, arbitrary code, or dynamic invocation targets; only explicitly registered app-owned callbacks are available.

Return `400` for malformed bodies, unsupported content types, additional fields, blank names, or unsupported query parameters; `404` for an unknown action or a name belonging to a value tweak; `405` for methods other than `POST`; and `409` when more than one live owner registered the same name. Duplicate registration errors explain that the action must be registered once at its owner. Main-thread unavailability, callback failures, and timeouts return `503`, `500`, and `504`, respectively. Errors use the same `{"error":"..."}` response shape as tweak updates.

## Compose API

```kotlin
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.openai.snapo.tweaks.TweakAction
import com.openai.snapo.tweaks.tweak

enum class MarkerShape { Circle, RoundedSquare, Square }

@Composable
fun TweakSpecimen() {
    val textColor by tweak(Color(0xFF18212F), "Text color")
    val backgroundColor by tweak(Color(0xFFF7F8FA), "Background color")
    val accentColor by tweak(Color(0xFF5468FF), "Accent color")

    MaterialTheme(
        colorScheme = lightColorScheme(
            primary = accentColor,
            background = backgroundColor,
            onBackground = textColor,
            surface = backgroundColor,
            onSurface = textColor,
        ),
    ) {
        TypographySpecimen()
        MotionSpecimen()
    }
}

@Composable
fun TypographySpecimen() {
    Text(
        text = tweak("Make it feel right.", name = "Preview text").value,
        fontSize = tweak(36, "Font size", 16..72, step = 1).value.sp,
        fontWeight = FontWeight(tweak(600, "Font weight", 100..900, step = 100).value),
        color = MaterialTheme.colorScheme.onSurface,
    )

    SpecimenAccessory()
}

@Composable
fun SpecimenAccessory() {
    val fontSize by tweak(36, "Font size", 16..72, step = 1)

    Text(text = "$fontSize sp")
}

@Composable
fun MotionSpecimen() {
    var isAnimating by remember { mutableStateOf(false) }
    TweakAction("Motion/Toggle animation") { isAnimating = !isAnimating }
    val useSpring by tweak(true, "Use spring")
    val markerShape by tweak(MarkerShape.Circle, "Marker shape")

    val animationSpec = if (useSpring) {
        val stiffness by tweak(280f, "Spring stiffness", 80f..800f, step = 20f)
        val dampingRatio by tweak(0.7f, "Spring damping", 0.1f..1f, step = 0.05f)

        spring<Float>(dampingRatio = dampingRatio, stiffness = stiffness)
    } else {
        val durationMillis by tweak(400, "Animation duration", 100..1_500, step = 50)

        tween<Float>(durationMillis = durationMillis)
    }

    MotionContent(animationSpec, markerShape)
}
```

Each tweak function returns `State<T>`. Read it with `.value`, or delegate it with `by`; `androidx.compose.runtime.getValue` supplies the delegate operator. Theme colors are intentionally read at the theme boundary; font, text, and animation changes recompose their respective leaf composables rather than the entire screen. Both typography composables read the same Font size state, so one host update changes both. When a value only affects layout or drawing, read the delegated value inside the corresponding callback instead of composition:

```kotlin
val horizontalOffset by tweak(0, "Horizontal offset", 0..200)

Box(
    modifier = Modifier.offset {
        IntOffset(x = horizontalOffset, y = 0)
    },
)
```

Each remembered usage registers with composition and removes the tweak from the active list only after its final usage leaves. Returning registry-owned declarations restore their previously edited values; app-owned sources control their own persistence. Request `GET /tweaks?include=adjusted` to inspect prior ordinary or app-owned adjustments from screens no longer in composition.

Provide overloaded `tweak(default, name)` functions for `Int`, `Float`, `Color`, `Boolean`, `String`, and enum defaults; each returns its corresponding `State<T>`. For strings, name the second argument to distinguish the label from the default, as in `tweak("Hello", name = "Greeting")`. Numeric tweaks accept an optional range and `step` of the same type. Enum tweaks infer their options from declaration order and use each constant's name everywhere. Convert delegated integer values into Compose units at the call site, such as `fontSize.sp`. The real and no-op artifacts expose the same package and public Compose API.

Declare a parameterless action with the `TweakAction(name) { ... }` composable. It returns `Unit` and does not execute its callback during composition or return a callable function. The action is available only while its owning composable is in composition, always uses its most recent callback, and is exposed with its explicit name rather than an inferred or generated identifier. Register each action exactly once at the composable that owns the state or operation; multiple owners using the same name produce a visible conflict and all invocation attempts fail closed. The release/no-op implementation accepts the same API without retaining or invoking the callback.

App-owned tweaks implement `TweakSource<T>`, supporting `Boolean`, `Int`, `Float`, `String`, and `Color`. The source owns its current value, reset behavior, modification status, and change notifications:

```kotlin
private class SharedPreferencesBooleanSource(
    private val preferences: SharedPreferences,
    private val key: String,
    private val default: Boolean,
) : TweakSource<Boolean> {
    override var value: Boolean
        get() = preferences.getBoolean(key, default)
        set(value) {
            preferences.edit().putBoolean(key, value).apply()
        }

    override val isModified: Boolean
        get() = preferences.contains(key)

    override fun reset() {
        preferences.edit().remove(key).apply()
    }

    override fun observe(): Flow<Unit> = callbackFlow {
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, changedKey ->
            if (changedKey == key || changedKey == null) trySend(Unit)
        }
        preferences.registerOnSharedPreferenceChangeListener(listener)
        awaitClose { preferences.unregisterOnSharedPreferenceChangeListener(listener) }
    }
}

@Composable
private fun SharedPreferences.tweak(
    key: String,
    default: Boolean,
    name: String = key,
): State<Boolean> {
    val source = remember(this, key, default) {
        SharedPreferencesBooleanSource(this, key, default)
    }
    return tweak(source, name)
}
```

The inspector captures the source's initial value when first observed. Snap-O accesses the source and updates its observable value and modification status on the Android main thread. The first app read or inspector request initializes this snapshot and may wait for the main thread; later inspector requests use cached values without accessing the source, even when the main thread is blocked. Reset calls `reset()`, and `isModified` reports whether the setting is stored. Source changes update the snapshot and stream when `observe()` emits; no polling is needed. Previously adjusted sources leave immutable history without retaining their sources or restoring values into returning sources. Both live and no-op artifacts defer reading the source until its value or default is observed. The no-op artifact never registers a tweak, edits the source, or observes it.

Multiple composables can expose the same app-owned tweak. The first active source handles its value, updates, resets, and modification status. Only its `observe()` flow is collected. When it leaves composition, the next active source takes over. Sources with the same name must use the same setting and value type. Conflicts are not checked and can cause wrong values or runtime errors.

## Setup

```kotlin
dependencies {
    debugImplementation(project(":tweaks"))
    releaseImplementation(project(":tweaks-noop"))

    // Optional: include the floating on-device inspector.
    debugImplementation(project(":tweaks-overlay"))
    releaseImplementation(project(":tweaks-overlay-noop"))
}
```

```text
:tweaks                 Compose API, live registry, HTTP, and abstract socket.
:tweaks-noop            Matching Compose API that returns default values.
:tweaks-overlay         Optional floating Compose tweak inspector.
:tweaks-overlay-noop    Matching no-op overlay without the inspector.
:samples:demo-tweaks    Standalone Compose sample with no network integration.
```

### Optional in-app overlay

Place `SnapOTweakOverlay` after the app content in a fullscreen `Box`:

```kotlin
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.openai.snapo.tweaks.overlay.SnapOTweakOverlay

@Composable
fun App() {
    Box(modifier = Modifier.fillMaxSize()) {
        AppContent()
        SnapOTweakOverlay(modifier = Modifier.fillMaxSize())
    }
}
```

The overlay is disabled by default. Expose its app-wide setting from a developer-settings screen:

```kotlin
import androidx.compose.material3.Switch
import androidx.compose.runtime.Composable
import com.openai.snapo.tweaks.overlay.SnapOTweakOverlaySettings

@Composable
fun DeveloperSettings() {
    Switch(
        checked = SnapOTweakOverlaySettings.isEnabled,
        onCheckedChange = { enabled ->
            SnapOTweakOverlaySettings.isEnabled = enabled
        },
    )
}
```

The setting persists between app launches. When enabled, a movable button appears only while at least one tweak is in composition. Tap it to inspect or edit the active tweaks, run registered actions, and minimize the panel to return to the button. Conflicted actions are visible but cannot be run. The panel stays synchronized with host-side changes, remembers its position, and disappears when the last tweak or action leaves composition. The no-op overlay keeps the same composable and settings APIs without showing a panel in release builds.

Install the standalone debug sample on a connected Android device:

```bash
./gradlew :samples:demo-tweaks:installDebug
```

From the repository root, start the sample's optional host-side tweak panel:

```bash
node snapo-link-android/samples/demo-tweaks/panel/server.mjs
```

Open `http://127.0.0.1:4175`. The dependency-free panel discovers connected devices and live tweak sockets, creates its own ADB forward, displays the app icon and tweaks, and reconnects when the app process changes. It is a model-built demo, not a required setup step or the expected way to use Snap-O Tweaks. Any agent or host can use the same endpoints to create its own UI. See the sample panel's README for device and package selection.

A non-exported `ContentProvider` in the live artifact starts the runtime by default only when `ApplicationInfo.FLAG_DEBUGGABLE` is set. To intentionally enable live Snap-O Tweaks in a non-debuggable app, set its application flag:

```xml
<application>
    <meta-data android:name="snapo.tweaks.allow_release" android:value="true" />
</application>
```

This flag allows the Tweaks server and, if installed and enabled, the in-app overlay. It does not enable Network Inspector, which has its own `snapo.network.allow_release` application flag. The no-op release artifacts are still recommended: they return default values, contain no provider, and let R8 remove unused calls and tweak-name strings. Verify the release APK contains neither tweak-only strings nor the live provider, registry, server, or socket.

Phase one requires no Ktor, OkHttp, extra JSON library, Snap-O Mac UI, network protocol change, groups, scopes, units, separate tweak IDs, or revisions.
