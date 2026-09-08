# Tweaks without Compose

`tweaks-core` exposes live values from Views, ViewModels, services, controllers, and ordinary Kotlin classes. It uses Kotlin coroutines and has no Compose dependency. The existing `tweaks` artifact adds Compose integration over the same registry and transport.

## Dependencies

Use matching versions for all Snap-O artifacts:

```kotlin
// Replace snapoVersion with the version you use for other Snap-O artifacts.
debugImplementation("com.openai.snapo:tweaks-core:$snapoVersion")
releaseImplementation("com.openai.snapo:tweaks-core-noop:$snapoVersion")
```

For this repository's local modules, use `project(":tweaks-core")` and `project(":tweaks-core-noop")`. Apps that already depend on `tweaks` receive the core transitively. Do not combine a live artifact and its no-op replacement in the same variant.

## Declare and read a value

```kotlin
import com.openai.snapo.tweaks.TweakScope

private val tweaks = TweakScope()
private val damping = tweaks.tweak(
    default = 0.7f,
    name = "Motion/Damping",
    range = 0f..1f,
)

fun replay() {
    startAnimation(damping = damping.value)
}

fun dispose() {
    tweaks.close()
}
```

Each declaration returns a read-only `StateFlow<T>`. Registration is immediate and does not depend on collectors. Read `.value` without launching a coroutine, or collect changes using your owner's coroutine scope. Changes are conflated: a slow collector gets the latest value and may skip intermediate slider positions.

Supported defaults are `Boolean`, `Int`, `Float`, `String`, `BezierCurve`, and enums. Numbers accept optional `range` and `step`. Use `tweakColor(defaultArgb, name)` for Android ARGB colors; an ordinary integer declaration remains a numeric control. Use `action(name) { ... }` for parameterless actions. Declaring an action never invokes it.

Matching live declarations share one value. Their name, type, default, constraints, and enum options must agree. Conflicting declarations are rejected. Duplicate action names remain visible but cannot be invoked until only one owner remains.

Closing a scope unregisters its declarations, releases its callbacks, and stops observing its app-owned sources. Repeated closes are harmless. New declarations after close fail. Previously returned flows retain their last value; they do not complete or cancel callers' collecting coroutines. A later matching ordinary declaration restores the last edited value within the same process.

## Bézier curves

```kotlin
val falloff = tweaks.tweak(
    BezierCurve(0.25f, 0.1f, 0.25f, 1f),
    "Halo/Curve",
    yRange = 0f..1f,
)
```

Read `falloff.value` and apply its four coordinates to your renderer.
All coordinates stay between 0 and 1. Optional `yRange` can narrow the Y range.
Snap-O edits and resets each curve as one value. The overlay opens a dedicated curve editor.

## ViewModels

```kotlin
class PreviewViewModel : ViewModel() {
    private val tweaks = TweakScope()
    val radius = tweaks.tweak(64f, "Shape/Radius", 16f..128f)

    init {
        addCloseable(tweaks)
    }
}
```

The ViewModel owns registration. A screen observing its values can stop and restart collection without removing those tweaks from the inspector. Activity and Fragment UI collectors should use `repeatOnLifecycle` with their appropriate lifecycle owner.

## Views

Add the optional `tweaks-views` artifact for View bindings:

```kotlin
implementation("com.openai.snapo:tweaks-views:$snapoVersion")
```

Use `project(":tweaks-views")` with local modules. This adapter accepts `StateFlow` and works with either `tweaks-core` or `tweaks-core-noop`. It does not depend on either core artifact or include an inspector server, so the same adapter is used in debug and release builds.

```kotlin
import com.openai.snapo.tweaks.views.bindTweak

// Install once, after the view's drawing objects have been initialized.
val binding = preview.bindTweak(viewModel.radius) { radius ->
    preview.setRadius(radius)
}
```

`bindTweak` collects on main while the View is attached. It applies the current value on each attachment and cancels collection on detachment. Call `binding.close()` on main to remove the binding permanently. This never closes the underlying tweak scope. Attachment is distinct from visibility: a GONE View can remain attached.

Setters must apply the value to the app. For custom drawing, update fields and call `invalidate()`. Rebuild cached filters or shaders when their inputs change, outside `onDraw()`. Request layout only when the change affects measurement or placement.

A View that owns its own tweaks must also manage that scope. Use a fresh scope for each attachment if the tweaks should exist only while attached, or close it when the containing controller is disposed.

## App-owned settings

```kotlin
val setting = tweaks.tweak(source = mySettingSource, name = "Settings/Show hints")
```

`TweakSource<T>` supplies the current value, a setter, `reset()`, `isModified`, and `observe(): Flow<Unit>`. Emit when either the effective value or override status changes. Generic sources support Boolean, Int, Float, String, and BezierCurve; `tweakColor(source, name)` supports an ARGB Int source.

Sources sharing a name must represent the same setting and type. The first active source supplies the authoritative value and handles edits, resets, status, and observation. The next source takes over when that owner closes. Their consistency remains the caller's responsibility. A returning source supplies its current value; Snap-O never replays historical values into it.

Register app-owned sources and close scopes containing them on main. Source methods run on main. Ordinary declarations and returned flow reads can be used from other threads. Inspector actions run on main; offload expensive work in the callback when necessary.

## No-op builds

`tweaks-core-noop` exposes the same public API without a registry, initialization provider, or inspector server. Ordinary values stay at their defaults, and actions never run. App-owned sources still follow their application's changes, without Snap-O writing, resetting, or inspecting their override status. Close the scope to stop that observation.

## Local sample

The `samples:demo-tweaks-views` app uses a ViewModel and custom Canvas drawing without the Compose runtime or UI. AndroidX Activity includes standalone Compose annotations. From `snapo-link-android`:

```sh
./gradlew :samples:demo-tweaks-views:assembleDebug
./gradlew -Psnapo.samples.noop=true :samples:demo-tweaks-views:assembleDebug
```

The package is `com.openai.snapo.demo.tweaks.views`. Use Snap-O to edit its shape radius, blur, and color. Rotate the device to recreate the Activity while retaining the ViewModel's tweaks.
