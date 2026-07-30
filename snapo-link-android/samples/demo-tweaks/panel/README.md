# Snap-O Tweaks inspector demo

A model built this inspector as one way to find running apps and change live
values. Each app must use Snap-O Tweaks.

This is only a demo, not part of the feature or the expected way to use it.
You do not need this inspector. Any tool can use `/app`, `/tweaks`, and
`/tweaks/events` to build its own live UI.

## What you need

- `Node.js 22.12+`.
- `Android Platform Tools` (`adb`).
- An Android device or emulator with `USB debugging` on.
- A debug app with Snap-O Tweaks.

## Run the Android app

From `snapo-link-android`, run:

```bash
./gradlew :samples:demo-tweaks:installDebug
```

Open **Snap-O Tweaks Demo** on your device.

## Run the tweaks inspector

From the root of this project, run:

```bash
node snapo-link-android/samples/demo-tweaks/panel/server.mjs
```

Or run:

```bash
cd snapo-link-android/samples/demo-tweaks/panel
npm start
```

Open `http://127.0.0.1:4175`.

To preview the app and inspector menu without a device, open
`http://127.0.0.1:4175/?mock`. The mock stays in the browser and does not
run `adb` or connect to an Android app. Apps appear under **Network** and
**Tweaks**. Each row shows the app and its phone or emulator. Hover over a
row to see the app's package name.

To compare a second layout with compact app headings and larger inspector
rows, open `http://127.0.0.1:4175/?mock=apps`.

There is no install or build step. The inspector sets up its own `adb` port
forwards. It can also start before an Android app is open.

## Find and switch apps

The inspector finds every running Snap-O Tweaks app on each connected device.
The app picker shows the app name, icon, and device. Its menu shows each app
once, with a short app-and-device heading above a **Tweaks** row. Select that
row to see and change the app's values. The picker becomes a menu only when
more than one app is available.

To find apps, the inspector:

1. Lists the devices that `adb` can use.
2. Puts real devices before emulators.
3. Finds each live `snapo_tweaks_<pid>` socket.
4. Uses or creates an `adb` port forward.
5. Reads `/app` to get the app name and package.

It checks for new apps every few seconds. Tweak and screen changes stream from
the app as they happen. If an app starts again, the inspector keeps the same app
selected when possible. If no app is running, it shows an empty state and waits.

App discovery and selection belong to this demo server. `/apps` and
`/apps/selection` are not part of the Android Snap-O Tweaks protocol.

## Group tweaks

To put a tweak in a section, use a `/` in its name:

```kotlin
val fontSize by tweak(36, "Typography/Font size", 16..72)
val isMotionEnabled by tweak(true, "Motion/Enabled")
val animationDuration by tweak(400, "Motion/Duration", 100..1500)
```

The part before `/` is the section. The part after `/` is the label. A tweak
without `/` has no section. The full name is still used for changes.

Sections and tweaks keep the order in which the app first shows them. If one
goes away and comes back, it returns to the same place. On wide screens,
sections stack in two stable columns and do not move between them.

## Use a different device or app

To choose a device:

```bash
npm start -- --serial YOUR_DEVICE_SERIAL
```

To choose an app:

```bash
npm start -- --package com.openai.snapo.demo.tweaks
```

You can use both at once:

```bash
npm start -- --serial YOUR_DEVICE_SERIAL \
  --package com.openai.snapo.demo.tweaks
```

To use a local endpoint:

```bash
npm start -- --target http://127.0.0.1:43817
```

A target set this way will not follow an app that starts again. To use a
different port:

```bash
npm start -- --port 4176
```

## Change a live value

Move a slider or choose a color. The app changes at once. The inspector waits
for each request before it sends the next value or switches to another app.
You can set one value or all values back.

Turn off **Show** in the **Motion** section to hide the motion preview in the
sample app. Its animation tweaks leave the composition and vanish from the
inspector. Turn it back on to see them appear again.

## Test the panel

```bash
npm test
```

Or run:

```bash
node --test
```
