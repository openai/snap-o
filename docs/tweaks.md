---
layout: guide
title: Tweaks Guide (Alpha) · Snap-O
description: Expose values from Compose, Views, and Kotlin code, app-owned settings,
  and actions to Snap-O and adjust them with App Inspector, an on-device panel, the
  REST API, or an agent.
styles:
- guide.css
- tweaks.css
languages:
- kotlin
- toml
breadcrumbs:
- label: Snap-O
  href: index.html
---

# Tweaks Guide (Alpha)

Expose values, app-owned settings, and actions from Compose, Views, ViewModels, and other Kotlin code. Interact with them through Snap-O’s Mac App Inspector, an optional on-device panel, the REST API, or an agent.
{.lead}

## Use Maven Central {#maven-central data-step="1"}

Snap-O publishes its Android libraries to [Maven Central](https://central.sonatype.com/namespace/com.openai.snapo). Most Android projects already include `mavenCentral()`; add it to your dependency sources if yours does not.

``` { .kotlin title="settings.gradle.kts" data-emphasis-lines="4" }
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
```

## Add the Android dependencies {#install data-step="2"}

Add the real Tweaks implementation to debug builds and the matching no-op implementation to release builds. Both expose the same Compose functions without shipping the live registry or server in release. Ordinary tweaks return their defaults; app-owned tweaks return their source’s current value without registering or observing it. Actions are not registered or invoked. The no-op artifacts remain the recommended release setup.

The overlay dependencies are optional. Add both only if you want an on-device floating panel. Their matching public APIs let the same app-root code compile in debug and release.

<div class="dependency-tabs" data-label="Tweaks dependency format" markdown="1">

<div id="tweaks-catalog-panel" data-tab="Version catalog" markdown="1">

``` { .toml title="gradle/libs.versions.toml" data-emphasis-lines="2,5,6,8,9,10" }
[versions]
snapo = "7.0.0"

[libraries]
snapo-tweaks = { module = "com.openai.snapo:tweaks", version.ref = "snapo" }
snapo-tweaks-noop = { module = "com.openai.snapo:tweaks-noop", version.ref = "snapo" }

# Optional: add both if you want the in-app overlay panel.
snapo-tweaks-overlay = { module = "com.openai.snapo:tweaks-overlay", version.ref = "snapo" }
snapo-tweaks-overlay-noop = { module = "com.openai.snapo:tweaks-overlay-noop", version.ref = "snapo" }
```

``` { .kotlin title="app/build.gradle.kts" data-emphasis-lines="2,3,5,6,7" }
dependencies {
    debugImplementation(libs.snapo.tweaks)
    releaseImplementation(libs.snapo.tweaks.noop)

    // Optional: add both if you want the in-app overlay panel.
    debugImplementation(libs.snapo.tweaks.overlay)
    releaseImplementation(libs.snapo.tweaks.overlay.noop)
}
```

</div>

<div id="tweaks-direct-panel" data-tab="Direct dependency" markdown="1">

``` { .kotlin title="app/build.gradle.kts" data-emphasis-lines="2,3,5,6,7" }
dependencies {
    debugImplementation("com.openai.snapo:tweaks:7.0.0")
    releaseImplementation("com.openai.snapo:tweaks-noop:7.0.0")

    // Optional: add both if you want the in-app overlay panel.
    debugImplementation("com.openai.snapo:tweaks-overlay:7.0.0")
    releaseImplementation("com.openai.snapo:tweaks-overlay-noop:7.0.0")
}
```

</div>

</div>

Add the Tweaks dependencies to each Android module that calls the `tweak(...)` function. In a multi-module app, a shared Gradle convention plugin can apply the debug and release pair consistently. Only the module that installs the optional overlay needs its additional overlay dependencies.

If a real Tweaks artifact is included in a nondebuggable app, ordinary tweaks still return their defaults and app-owned tweaks return their source’s current value. The server does not start and the floating overlay stays hidden unless you explicitly enable Tweaks for that app.
{.notice}

<details markdown="1">
<summary>Enable Tweaks in release builds</summary>

Only when you intentionally include the real Tweaks artifacts in a release build, add this metadata directly to your application's `<application>` element. It enables the Tweaks server and, if installed and enabled, the on-device overlay.

``` { .xml title="AndroidManifest.xml" }
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application>
        <meta-data
            android:name="snapo.tweaks.allow_release"
            android:value="true" />
    </application>
</manifest>
```

This setting applies only to Tweaks. `snapo.network.allow_release` controls Network Inspector separately; enabling either feature does not enable the other. Prefer no-op release artifacts unless you need live inspection in a release build.

</details>

## Use tweaks without Compose {#without-compose}

Use `tweaks-core` in Views, ViewModels, services, and ordinary Kotlin classes. It has no Compose dependency and shares the registry with the Compose API. Use matching versions for all Snap-O artifacts. Existing Compose apps keep using `tweaks` and `tweaks-noop`; these bring in `tweaks-core` and `tweaks-core-noop` transitively. Add the core dependencies directly only when using tweaks without Compose.

``` { .kotlin title="build.gradle.kts" }
dependencies {
    debugImplementation("com.openai.snapo:tweaks-core:7.0.0")
    releaseImplementation("com.openai.snapo:tweaks-core-noop:7.0.0")
    // Optional View bindings work with both core variants.
    implementation("com.openai.snapo:tweaks-views:7.0.0")
}
```

A `TweakScope` registers values immediately and returns read-only `StateFlow` values. Read `.value` directly or collect changes. Close the scope when its owner is disposed. A ViewModel can own the scope across Activity recreation:

``` { .kotlin title="ViewModel" }
import androidx.lifecycle.ViewModel
import com.openai.snapo.tweaks.TweakScope

class PreviewViewModel : ViewModel() {
    private val tweaks = TweakScope()
    val radius = tweaks.tweak(64f, "Shape/Radius", 16f..128f)

    init {
        addCloseable(tweaks)
    }
}
```

Defaults can be Boolean, Int, Float, String, or enum values. Source builds also support [Bézier curves](#bezier-curves). Numbers accept optional ranges and steps. Use `tweakColor(defaultArgb, name)` for ARGB colors, `action(name) { ... }` for callbacks, and `tweak(source, name)` for app-owned settings. Declaring an action never runs it; inspector callbacks run on main.

### Bind values to a View

Install a binding once on main, after the View is initialized. The callback applies the current value on each attachment and collects changes until detachment. For custom drawing, update fields and call `invalidate()` in the setter.

``` { .kotlin title="View binding" }
import com.openai.snapo.tweaks.views.bindTweak

val binding = preview.bindTweak(viewModel.radius) { radius ->
    preview.setRadius(radius)
}

// Remove the binding permanently when its controller is disposed.
binding.close()
```

Closing a binding does not close its tweak scope. Attachment does not imply visibility: a GONE View can remain attached. Closing a scope unregisters its declarations and stops observing app-owned sources. Returned flows retain their last value; callers still own their collecting coroutines.

Register app-owned sources and close scopes containing them on main. Ordinary declarations and reads can use other threads. Matching live declarations share one value; names, types, defaults, constraints, and enum options must agree.

`tweaks-core-noop` has no registry or inspector server. Ordinary values stay at their defaults and actions never run. App-owned sources still follow application changes without Snap-O writing or resetting them; close the scope to stop observation. Do not combine a live core with its no-op replacement in one variant.

## Expose values from Compose {#expose-values data-step="3"}

Replace a fixed UI value with a tweak at the place that consumes it. Snap-O registers the control while that composable is in composition and returns observable `State<T>` that updates as you edit its value. Ordinary tweaks support integers, floating-point numbers, booleans, strings, colors, and enums. Source builds also support [Bézier curves](#bezier-curves).

``` { .kotlin title="Kotlin · typography" }
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.openai.snapo.tweaks.tweak

@Composable
fun TypographyPreview() {
    val text by tweak(
        stringResource(R.string.preview_text),
        name = "Typography/Preview text",
    )

    Text(
        text = text,
        fontSize = tweak(36, "Typography/Font size", 16..72).value.sp,
        fontWeight = FontWeight(tweak(600, "Typography/Font weight", 100..900, step = 100).value),
        color = tweak(Color(0xFF18212F), "Colors/Text").value,
    )
}
```

### Compose function reference

Import `com.openai.snapo.tweaks.tweak` and call the overload matching your default value from composition. Every overload returns `State<T>`. Delegate the state with `by`, or read `tweak(...).value` immediately. Numeric ranges and increments are optional. Enum options follow declaration order and use each constant’s name. For strings, name the `name` argument to distinguish it from the default value.

``` { .kotlin title="com.openai.snapo.tweaks · Kotlin" }
@Composable
fun tweak(
    default: Int,
    name: String,
    range: IntRange? = null,
    step: Int? = null,
): State<Int>

@Composable
fun tweak(
    default: Float,
    name: String,
    range: ClosedFloatingPointRange<Float>? = null,
    step: Float? = null,
): State<Float>

@Composable
fun tweak(
    default: Color,
    name: String,
): State<Color>

@Composable
fun tweak(
    default: Boolean,
    name: String,
): State<Boolean>

@Composable
fun tweak(
    default: String,
    name: String,
): State<String>

@Composable
fun <E : Enum<E>> tweak(
    default: E,
    name: String,
): State<E>
```

``` { .kotlin title="Kotlin · enum options" }
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import com.openai.snapo.tweaks.tweak

enum class MarkerShape { Circle, RoundedSquare, Square }

@Composable
fun MarkerPreview() {
    val shape by tweak(MarkerShape.Circle, "Motion/Marker shape")
    Text(shape.name)
}
```

Keep the returned state unread until the phase that needs it. For a value used only during drawing or layout, read the delegated value inside the draw or layout callback to avoid recomposing the caller.

``` { .kotlin title="Kotlin · deferred draw read" }
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.openai.snapo.tweaks.tweak

@Composable
fun MotionTrack(modifier: Modifier = Modifier) {
    val thickness by tweak(
        default = 2f,
        name = "Motion/Track thickness",
        range = 1f..8f,
        step = 0.5f,
    )

    Box(
        modifier = modifier.drawBehind {
            drawLine(
                color = Color.Black,
                start = Offset(x = 0f, y = center.y),
                end = Offset(x = size.width, y = center.y),
                strokeWidth = thickness.dp.toPx(),
            )
        },
    )
}
```

### Bézier curves {#bezier-curves}

Bézier curve support is available on `main` and is not included in Android 7.0.0 or macOS 6.0.0.
Build the Android libraries and inspector from source to use it. Curve inspection requires Tweaks protocol 5 support.

A `BezierCurve` has fixed endpoints `(0, 0)` and `(1, 1)`, plus two editable control points.
Declare one inside a composable:

``` { .kotlin title="Kotlin · inside a composable" }
val curve by tweak(
    BezierCurve(0.25f, 0.1f, 0.25f, 1f),
    "Motion/Curve",
)
```

Import `BezierCurve` and `tweak` from `com.openai.snapo.tweaks`, and `getValue` from `androidx.compose.runtime`.
Read `curve.x1`, `curve.y1`, `curve.x2`, and `curve.y2` where your animation or renderer consumes them.

Outside Compose, use the same overload on an existing `TweakScope`:

``` { .kotlin title="Kotlin · TweakScope" }
val curve = tweaks.tweak(
    BezierCurve(0.25f, 0.1f, 0.25f, 1f),
    "Motion/Curve",
)
```

This returns `StateFlow<BezierCurve>`; read `curve.value` or collect changes. Close the scope when its owner is disposed.
All coordinates must be finite Float values. X coordinates must be between 0 and 1. Y coordinates may extend outside that range for anticipation and overshoot.
App-owned `TweakSource<BezierCurve>` values are also supported. The matching no-op artifacts expose the same API.

Open a curve control in App Inspector or the on-device panel to drag its control points, enter coordinates, or select a preset.
In App Inspector, focused handles support arrow keys; hold Shift for larger steps.
Each edit replaces the complete curve. Reset restores the whole default curve or calls the app-owned source's reset.
See [CLI commands](cli.md#bezier-curves) and the [protocol reference](tweaks-protocol.md#bezier-curves) for JSON updates.

## Delegate to app-owned settings {#app-owned-settings data-step="4"}

Snap-O normally owns a tweak’s value. To expose a value already owned by your app instead, implement `TweakSource<T>` and call `tweak(source, name)` from composition. The source can own a boolean, integer, floating-point number, string, color, or Bézier curve; enum values are supported only by ordinary tweaks.

``` { .kotlin title="com.openai.snapo.tweaks · source contract" }
interface TweakSource<T : Any> {
    var value: T
    val isModified: Boolean

    fun reset()
    fun observe(): Flow<Unit>
}

@Composable
fun <T : Any> tweak(
    source: TweakSource<T>,
    name: String,
): State<T>
```

### Example: SharedPreferences-backed settings {#shared-preferences-source}

This source reads and writes an existing preference. A stored key is an override, so resetting removes the key instead of writing the originally observed value back into the app.

``` { .kotlin title="Kotlin · app-owned boolean preference" }
import android.content.SharedPreferences
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.remember
import com.openai.snapo.tweaks.TweakSource
import com.openai.snapo.tweaks.tweak
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

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
fun SharedPreferences.tweak(
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

Use it from composition with `preferences.tweak("motion_show", true, "Motion/Show")`. Snap-O edits `source.value`, calls `source.reset()` for resets, and uses `source.isModified` to decide whether an override exists. The initial value is shown as the inspector default; the app remains responsible for the setting’s effective value, persistence, and reset behavior.

### Source updates and lifecycle {#source-lifecycle}

Compose source values are read lazily when your app reads the returned state or an inspector first requests the tweak. Snap-O reads and writes the source, checks its modification status, resets it, and collects `observe()` on the Android main thread. After the initial read, inspectors use a cached snapshot instead of polling the source.

**Notify on value and status changes.** `observe(): Flow<Unit>` must emit when either `value` or `isModified` may have changed. A preference can become modified even when its effective value remains the same, so value-only notifications are not sufficient.
{.notice}

If several active owners expose the same source-backed tweak name, the first active source owns its value, edits, reset behavior, modification status, and observation. Only that source’s flow is collected. When its owner is released, ownership transfers to the next active source. Sources that share a name must represent the same underlying setting and value type; conflicting sources are not checked and can produce incorrect values or runtime errors.

### Actions {#app-owned-actions}

Use `TweakAction` to expose an operation owned by your app, such as restarting an animation. The callback is invoked only when an inspector requests the action; declaring the composable does not run it.

``` { .kotlin title="Kotlin · app-owned action" }
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.openai.snapo.tweaks.TweakAction

@Composable
fun MotionPreview() {
    var isAnimating by remember { mutableStateOf(false) }

    TweakAction("Motion/Toggle animation") {
        isAnimating = !isAnimating
    }

    Text(if (isAnimating) "Animating" else "Paused")
}
```

Actions are parameterless, run on the Android main thread, and remain available only while their owner is active. A composable stays in composition or its `TweakScope` stays open. Register each action name once at its owner; multiple active owners create a visible conflict and prevent invocation. See [Invoke an app-owned action](tweaks-protocol.md#tweak-actions) for the corresponding REST endpoint.

## Group tweaks by section (optional) {#groups-and-lifecycle data-step="5"}

Tweaks work without sections. When grouping would make a screen easier to inspect, use a slash-separated name to place a control in a visible inspector section. For example, `Typography/Font size` appears under **Typography**, and `Motion/Duration` appears under **Motion**.

``` { .kotlin title="Kotlin · visibility and motion" }
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.openai.snapo.tweaks.tweak

@Composable
fun MotionSection(isExpanded: Boolean) {
    if (!tweak(true, "Motion/Show").value) return

    val useSpring by tweak(true, "Motion/Use spring")
    val animationSpec = if (useSpring) {
        spring<Float>(
            dampingRatio = tweak(0.7f, "Motion/Spring damping", 0.1f..1f, step = 0.05f).value,
            stiffness = tweak(280f, "Motion/Spring stiffness", 80f..800f, step = 20f).value,
        )
    } else {
        tween<Float>(
            durationMillis = tweak(400, "Motion/Duration", 100..1500, step = 50).value,
            easing = FastOutSlowInEasing,
        )
    }

    AnimatedVisibility(
        visible = isExpanded,
        enter = fadeIn(animationSpec),
        exit = fadeOut(animationSpec),
    ) {
        Box(modifier = Modifier.size(48.dp)) {
            // Animated content.
        }
    }
}
```

**One name, one tweak.** Reusing the exact same name in multiple active owners shares one control and current value. Ordinary tweaks must use matching types, defaults, numeric constraints, and enum options. App-owned sources must represent the same underlying setting and value type.
{.notice}

Controls appear only while their composables are in composition. In the example, turning off `Motion/Show` removes the motion controls; changing `Motion/Use spring` swaps the spring settings for the duration control. When the same UI returns during the app process, ordinary controls register again with their last edited values and original ordering. App-owned controls use the current value from their source instead.

## Interact with tweaks {#interact data-step="6"}

Once the enabled app exposes a tweak, choose the interaction that fits your workflow: inspect the app on your Mac, use an optional panel on the device, call the REST API, or let an agent work with the same live values.

### Mac App Inspector {#app-inspector}

Snap-O’s App Inspector shows one picker row per running app process, with shortcuts for Network and Tweaks when available. The Tweaks inspector shows controls registered by the app’s active owners, including Compose and `TweakScope`.

1. Install and launch the debug build, or an explicitly enabled release build, on a connected, authorized Android device or emulator.
2. Open Snap-O on macOS and select the device.
3. Choose **Tools → Show App Inspector**, or press **⌘⌥I**.
4. Find your app process in the picker and click its **Tweaks** icon. Click the row instead to keep your current inspector type when available.
5. Adjust a value or enum option, or invoke an app-owned action, and watch the running app update.
6. Reset an individual control or use **Reset all tweaks**; app-owned settings use their source’s reset behavior.

At startup, Snap-O restores your last app and inspector when available, or selects another available app. During a session, disconnects do not switch apps. If the selected Android app stops, click **Open app** on the waiting screen when available, or launch it on your device.

Navigate through your Android app to change which controls are visible. Only tweaks with active owners appear in the inspector.
{.notice}

### On-device panel {#on-device-panel}

For a developer-facing UI on the Android device, the optional `SnapOTweakOverlay` starts as a movable floating control and expands into an editable panel. Install it at the app root and expose Snap-O’s built-in overlay setting from your developer settings. The panel automatically observes the same registered tweaks as the Mac inspector. See [Add an on-device floating panel](#floating-overlay) for the module and root layout.

### REST API {#rest-api}

The Tweaks server exposes a small HTTP API for reading registered controls, updating their values, invoking app-owned actions, and streaming changes. Use it to build your own inspection tools, integrations, and custom panels.

See the [Tweaks protocol reference](tweaks-protocol.md) for every endpoint, example requests and responses, live events, resets, and error handling.

### Agents (e.g. Codex) {#agents}

Install the official Snap-O Codex plugin to give an agent the dedicated Tweaks skill and shared command-line client. The plugin requires Python 3 and Android Platform Tools.

``` { .shell title="Terminal · install the Codex plugin" }
codex plugin marketplace add openai/snap-o --ref main
codex plugin add snap-o@snap-o
```

<details markdown="1">
<summary>Migrate an existing sparse marketplace installation</summary>

If Snap-O was previously installed with sparse paths, remove and add its marketplace again so the shared CLI and both plugin skills are available:

``` { .shell title="Terminal · migrate the Codex plugin" }
codex plugin marketplace remove snap-o
codex plugin marketplace add openai/snap-o --ref main
codex plugin add snap-o@snap-o
```

</details>

Start a new Codex session after installation. Ask the agent to inspect the available controls, apply a requested design direction, or reset a value. For example: “Make this screen feel calmer; try the typography, color, and motion tweaks and tell me what changed.” The skill discovers the running app, reads typed descriptors, and changes or resets values only when requested.

Snap-O for macOS also bundles the same CLI. Use it directly for discovery, automation, live snapshots, and explicitly requested updates:

``` { .shell title="Terminal · inspect and update live tweaks" }
SNAPO_BIN="/Applications/Snap-O.app/Contents/MacOS/snapo"

"$SNAPO_BIN" tweaks apps --json
"$SNAPO_BIN" tweaks list -s emulator-5554 -n snapo_tweaks_12345 --json
"$SNAPO_BIN" tweaks set 'Typography/Font size' 42 -s emulator-5554 -n snapo_tweaks_12345
"$SNAPO_BIN" tweaks action 'Motion/Toggle animation' -s emulator-5554 -n snapo_tweaks_12345
"$SNAPO_BIN" tweaks reset 'Typography/Font size' -s emulator-5554 -n snapo_tweaks_12345
"$SNAPO_BIN" tweaks watch -s emulator-5554 -n snapo_tweaks_12345 --once --json
```

Successful `set`, `reset`, and `action` commands produce no output and do not accept `--json`. For batch updates, replace the former `set --values-json` option with [PATCH /tweaks](tweaks-protocol.md#patch-tweaks).

The CLI manages Android socket discovery, forwarding, and cleanup. Device serials and socket names come from the discovery output and change when the app process restarts.
{.notice}

You can also ask an agent to create a small custom panel for a specific workflow, such as typography comparisons, animation tuning, or a curated set of design controls. The panel can read `GET /tweaks`, send `PATCH /tweaks`, and subscribe to `GET /tweaks/events`. No separate Snap-O agent API or automatic panel integration is required or implied.

## Apply tweaks to your codebase {#apply-tweaks data-step="7"}

Once you are happy with the adjustments you made in your app, ask an AI agent, such as Codex, to apply them to your codebase:

“Apply all the tweak adjustments I made in the app to my codebase.”
{.notice}

The agent can read the latest tweaked values from your running app and update the corresponding values in your source code so your adjustments become part of the app.

Adjustment history also includes ordinary and app-owned values from owners that have since been released. An agent can request `GET /tweaks?include=adjusted` to recover those read-only snapshots while the app process remains alive. Inactive values cannot be edited or reset until their controls return; app-owned snapshots do not retain or restore their original source. See [Include previously adjusted tweaks](tweaks-protocol.md#adjusted-tweaks) for the response format.

## Optional: add an on-device floating panel {#floating-overlay data-step="8" data-nav="Optional floating panel"}

The optional overlay provides `SnapOTweakOverlay` for apps that also want to edit live tweaks on the device. Place it after your app content in a fullscreen `Box`. Snap-O owns and persists the developer setting, and the overlay automatically discovers tweaks from active owners. Its matching no-op artifact draws nothing in release, so this code belongs in your shared source set.

**Upgrading from 4.0.0?** The overlay no longer wraps app content. Replace `SnapOTweakOverlay { ... }` with a fullscreen `Box` containing your content followed by `SnapOTweakOverlay()`.
{.notice}

``` { .kotlin title="Kotlin · shared root content" }
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.sp
import com.openai.snapo.tweaks.overlay.SnapOTweakOverlay
import com.openai.snapo.tweaks.overlay.SnapOTweakOverlaySettings
import com.openai.snapo.tweaks.tweak

@Composable
fun AppRoot() {
    Box(modifier = Modifier.fillMaxSize()) {
        ProfileScreen()
        SnapOTweakOverlay(modifier = Modifier.fillMaxSize())
    }
}

@Composable
fun OverlayDeveloperSetting() {
    Switch(
        checked = SnapOTweakOverlaySettings.isEnabled,
        onCheckedChange = { SnapOTweakOverlaySettings.isEnabled = it },
    )
}

@Composable
fun ProfileScreen() {
    val fontSize by tweak(
        default = 16,
        name = "Typography/Font size",
        range = 12..32,
    )

    Text(
        text = "Profile",
        fontSize = fontSize.sp,
    )
}
```

The panel starts as a collapsed floating button that can be moved anywhere on the screen. Tap it to expand the panel and edit numeric, boolean, color, text, enum, or Bézier curve values, or invoke app-owned actions. Reset an individual tweak or restore every modified tweak; app-owned settings use their source’s reset behavior. Changes update the running app immediately and are available to the Mac inspector through its normal updates. Snap-O saves the button’s horizontal and vertical position, restoring it when the button returns or the app restarts.

**Visibility follows registered tweaks.** The button appears only when the real overlay is installed, the Tweaks runtime is enabled, `SnapOTweakOverlaySettings.isEnabled` is `true` and at least one tweak has an active owner. The setting defaults to off and survives app restarts. As screens and sections appear or disappear, the panel updates automatically. The no-op overlay never appears, and its setting remains disabled. No manually supplied values, update callback, or build-specific root layout is required.
{.notice}

## Troubleshooting {#troubleshoot data-step="9"}

- Confirm the installed app contains the live `tweaks` or `tweaks-core` artifact for its API.
- For a nondebuggable app, set `snapo.tweaks.allow_release` to `true` in its `<application>` metadata.
- If no Tweaks server appears, check device authorization, app startup, the live dependency, and whether the current build allows the runtime.
- If the server appears but its tweak list is empty, register a value with `tweak(...)` in composition or an open `TweakScope`.
- Use the same type, default, numeric constraints, and enum options wherever an ordinary tweak name is shared.
- For an app-owned setting, emit from `observe()` whenever its value or modification status changes.
- Ensure sources sharing a name represent the same setting and value type, and register each action name only once.
- Choose your app’s **Tweaks** entry inside **App Inspector**.
- After the Android app restarts, select its current running app or process if prompted.
- For the optional overlay, confirm its developer setting is enabled and at least one tweak has an active owner.
