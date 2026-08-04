# Snap-O Tweaks protocol

Status: phase one. The network inspector protocol is unchanged.

Snap-O Tweaks exposes adjustable values from the currently composed Android UI
through an app-local socket, enabled by default only in debug builds. Agents
and desktop tools can use HTTP to inspect those values and change them while
the app runs.

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

Implement HTTP with Android `LocalServerSocket`, standard streams, and Android
`JsonReader`/`JsonWriter`. Use JSON for app and tweak responses, PNG for
`/app/icon`, and server-sent events for `/tweaks/events`. Ordinary responses
include `Content-Length` and close their connection. Event streams keep their
connection open. Bound request sizes and concurrent connections, and apply a
read timeout while receiving each request. No server dependency, Android TCP
port, or `INTERNET` permission is needed.

## REST API

### GET /app

Return exactly the app's user-facing Android label and package name:

```json
{
  "name": "Snap-O Tweaks Demo",
  "packageName": "com.openai.snapo.demo.tweaks"
}
```

Resolve `name` from the actual Android app label.

### GET /app/icon

Lazily return the app icon as a 96 × 96 PNG with `Content-Type: image/png`.
Return `404` when the icon is unavailable.

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
    }
  ]
}
```

A tweak name represents one shared value, not one composable. Multiple active
composables may register the same name; the tweak appears only once, and an
update changes the value observed by every usage. A tweak remains registered
until its last usage leaves composition. Its most recently edited value remains
available if the same complete declaration later returns, but inactive tweaks do
not appear in default responses or event snapshots.

Usages with the same name must agree on the tweak type, default, constraints,
and ordered enum options. Conflicting declarations are a configuration error.

Supported types are `int`, `float`, `boolean`, `color`, `string`, and `enum`.
Integer tweaks accept only whole numbers; float tweaks accept whole or
fractional numbers. Numeric tweaks may include `min`, `max`, and `step`. Only
include constraints actually supplied by the app. A `step` is relative to
`min`, or to `default` if no `min` is supplied. Colors use `#RRGGBB`, or
`#RRGGBBAA` when translucent.

Enum tweaks include an ordered, nonempty `options` array containing the unique
enum constant names. The descriptor's `default`, current `value`, picker text,
and `PATCH` values all use those exact names. Preserve declaration order when
rendering pickers; reject any value not present in `options`.

Compose color defaults keep their exact in-process identity, including color
space, component precision, and `Color.Unspecified`. The HTTP protocol still
presents colors as sRGB hex; non-sRGB defaults are projected, and
`Color.Unspecified` appears as `#00000000`. Patching a color with that presented
default remains the legacy reset operation, so the same projected hex cannot
also express a distinct sRGB edit for a non-round-trippable default.

Numeric JSON values may contain at most 128 characters and 64 significant
digits, with a decimal scale between -64 and 64. Reject values outside those
limits with `422` before changing any tweaks.

### GET /tweaks?include=adjusted

Opt in to a complete list of active tweaks and previously adjusted tweaks that
have since left composition:

```bash
curl -fsS 'http://127.0.0.1:43817/tweaks?include=adjusted'
```

The response uses the same `{"tweaks":[...]}` shape and complete tweak
descriptors as `GET /tweaks`. Include every currently active tweak, whether or
not it has been adjusted, and every inactive tweak whose value was actually
changed by a successful user adjustment. Preserve the tweak's original
declaration, constraints, and latest value after its final usage leaves
composition. Separate screens may reuse a name with different declarations;
include each independently adjusted complete descriptor, even when names
repeat. Repeated names occur only for distinct complete descriptors; active-only
listings and updates still resolve at most one active descriptor per name.
Order names by first observation, regardless of later activation or adjustment.
For repeated names, list the active declaration first, followed by historical
declarations in stable adjustment order.

An adjusted tweak remains in this history even after its value is reset to its
default. An inactive tweak that was never changed, a no-op update that leaves
its value unchanged, and a rejected or atomically rolled-back update do not
create history entries. Adjustment history exists only for the current app
process and is discarded when that process exits.

Historical inactive tweaks are read-only: `PATCH /tweaks` still accepts only
currently active names and returns `404` for an inactive name. Plain
`GET /tweaks` and `GET /tweaks/events` remain active-only. The only supported
query is exactly `include=adjusted` on `GET /tweaks`; unsupported, repeated,
or additional query parameters and queries on other endpoints or methods
return `400`.

### GET /tweaks/events

Stream the current tweaks using standard server-sent events:

```bash
curl --no-buffer http://127.0.0.1:43817/tweaks/events
```

```text
event: tweaks
data: {"tweaks":[{"name":"Motion/Show","type":"boolean","default":true,"value":true},{"name":"Motion/Duration","type":"int","default":400,"value":400,"min":100,"max":1500,"step":50}]}

event: tweaks
data: {"tweaks":[{"name":"Motion/Show","type":"boolean","default":true,"value":false}]}

```

The response uses `Content-Type: text/event-stream`. Its first event contains
the complete current tweak list. Each later event also contains a complete,
ordered list using exactly the `GET /tweaks` response shape. Clients replace
their previous snapshot; a missing tweak has left composition.

Changes are published after the current Android main-thread turn. Tweaks added,
removed, or changed during the same Compose update appear together in one
event. Value changes are streamed whether they originated from an HTTP request
or a Compose snapshot. Idle connections receive occasional SSE comments as
keep-alives. A slow client receives the latest complete snapshot rather than
an unbounded queue of intermediate states.

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
    { "name": "Font size", "value": 48 },
    { "name": "Font weight", "value": 700 },
    { "name": "Accent color", "value": "#3B82F6" },
    { "name": "Animation duration", "value": 550 },
    { "name": "Spring damping", "value": 0.8 },
    { "name": "Use spring", "value": false },
    { "name": "Preview text", "value": "A calmer direction." },
    { "name": "Marker shape", "value": "RoundedSquare" }
  ]
}
```

Validate all values before changing any of them. Return `400` for malformed
requests, `404` when an endpoint or requested tweak does not exist, `405`
for an unsupported method, `413` for an oversized body, and `422` when a value
has the wrong type, violates a constraint, or is not one of the declared enum
option values. Errors use a small JSON body:

```json
{
  "error": "Unknown tweak: Font size"
}
```

Apply changes on the Android main thread. If any value is invalid, do not update
any tweaks in that request. Reset a value by patching it with its default.

## Compose API

```kotlin
import androidx.compose.runtime.getValue
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

Each tweak function returns `State<T>`. Read it with `.value`, or delegate it
with `by`; `androidx.compose.runtime.getValue` supplies the delegate operator.
Theme colors are intentionally read at the theme boundary; font, text, and
animation changes recompose their respective leaf composables rather than the
entire screen. Both typography composables read the same Font size state, so
one host update changes both. When a value only affects layout or drawing,
read the delegated value inside the corresponding callback instead of
composition:

```kotlin
val horizontalOffset by tweak(0, "Horizontal offset", 0..200)

Box(
    modifier = Modifier.offset {
        IntOffset(x = horizontalOffset, y = 0)
    },
)
```

Each remembered usage registers with composition and removes the tweak from
the active list only after its final usage leaves. Returning declarations
restore their previously edited values. Screen navigation therefore determines
what appears in the default response without discarding edits; request
`GET /tweaks?include=adjusted` to also recover previously adjusted values from
screens that are no longer in composition.

Provide overloaded `tweak(default, name)` functions for `Int`, `Float`,
`Color`, `Boolean`, `String`, and enum defaults; each returns its corresponding
`State<T>`. For strings, name the second argument to distinguish the label from
the default, as in `tweak("Hello", name = "Greeting")`. Numeric tweaks accept
an optional range and `step` of the same type. Enum tweaks infer their options
from declaration order and use each constant's name everywhere. Convert
delegated integer values into Compose units at the call site, such as
`fontSize.sp`. The real and no-op artifacts expose the same package and public
Compose API.

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
:tweaks-overlay-noop    Matching overlay wrapper without the inspector.
:samples:demo-tweaks    Standalone Compose sample with no network integration.
```

### Optional in-app overlay

Wrap the app's root content with `SnapOTweakOverlay`:

```kotlin
import androidx.compose.runtime.Composable
import com.openai.snapo.tweaks.overlay.SnapOTweakOverlay

@Composable
fun App() {
    SnapOTweakOverlay {
        AppContent()
    }
}
```

The overlay is disabled by default. Expose its app-wide setting from a
developer-settings screen:

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

The setting persists between app launches. When enabled, a movable button
appears only while at least one tweak is in composition. Tap it to inspect or
edit the active tweaks, and minimize the panel to return to the button. The
panel stays synchronized with host-side changes, remembers its position, and
disappears when the last tweak leaves composition. The no-op overlay keeps the
same wrapper and settings APIs without showing a panel in release builds.

Install the standalone debug sample on a connected Android device:

```bash
./gradlew :samples:demo-tweaks:installDebug
```

From the repository root, start the sample's optional host-side tweak panel:

```bash
node snapo-link-android/samples/demo-tweaks/panel/server.mjs
```

Open `http://127.0.0.1:4175`. The dependency-free panel discovers connected
devices and live tweak sockets, creates its own ADB forward, displays the app
icon and tweaks, and reconnects when the app process changes. It is a model-built
demo, not a required setup step or the expected way to use Snap-O Tweaks. Any
agent or host can use the same endpoints to create its own UI. See the sample
panel's README for device and package selection.

A non-exported `ContentProvider` in the live artifact starts the runtime by
default only when `ApplicationInfo.FLAG_DEBUGGABLE` is set. To intentionally
enable live Snap-O Tweaks in a non-debuggable app, set its application flag:

```xml
<application>
    <meta-data android:name="snapo.tweaks.allow_release" android:value="true" />
</application>
```

This flag allows the Tweaks server and, if installed and enabled, the in-app
overlay. It does not enable Network Inspector, which has its own
`snapo.network.allow_release` application flag. The no-op release artifacts are
still recommended: they return default values, contain no provider, and let R8
remove unused calls and tweak-name strings. Verify the release APK contains
neither tweak-only strings nor the live provider, registry, server, or socket.

Phase one requires no Ktor, OkHttp, extra JSON library, Snap-O Mac UI, network
protocol change, actions, groups, scopes, units, separate tweak IDs, or
revisions.
