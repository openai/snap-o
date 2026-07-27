# Snap-O Tweaks panel demo

A model built this panel as one way to see and change live app values.
The app must use Snap-O Tweaks.

This is only a demo, not part of the feature. It is not the expected way to use
Snap-O Tweaks. You do not need this panel. Any tool can use `/app` and
`/tweaks` to build its own UI.

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

## Run the tweaks panel

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

There is no install or build step. The panel will set up its own `adb` port
forward.

## How it can find an app

To find an app, the panel will:

1. List each device that `adb` can use.
2. Put a real device before an emulator.
3. Start with the last real device.
4. Find a live app by its `snapo_tweaks_<pid>` name.
5. Use or make an `adb` port forward.
6. Use `/app` to find the app name.

The panel can connect to any Snap-O Tweaks app. It does not depend on one app
or process. If the app starts again, the next request will find it.

The panel can only show values from the current screen. After a screen change,
use **Refresh** to load the new values.

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

Move a slider or choose a color. The app will change at once. The panel will
wait for each request before it can send the next value. You can set one value
or all values back.

## Test the panel

```bash
npm test
```

Or run:

```bash
node --test
```
