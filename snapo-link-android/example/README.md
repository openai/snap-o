# Example tool

Copy this project to start a Snap-O tool. Its displayed name is **Example**, its ID is `example`, and every value is fake sample data. It demonstrates the APIs without collecting application data.

This is an independent Android build. It has its own Gradle wrapper and does not include Snap-O's source builds. The app depends on `example-tool` only in debug builds.

## Run before the packages are published

The package names are provisional. The runtime, Gradle plugin, and host SDK do not need to be published to try this example.

From a Snap-O checkout, with JDK 17, Android SDK 36, Python 3, and Node.js 22.12 or later:

```sh
python3 release/validate_authoring.py --output /tmp/snapo-example
```

Use a new or empty output directory. Set `ANDROID_HOME` to your Android SDK directory if needed. The command:

1. Stages the runtime and Gradle plugin in `/tmp/snapo-example/maven`.
2. Builds and packs the host SDK under `/tmp/snapo-example/npm`.
3. Copies this entire project to `/tmp/snapo-example/example`.
4. Installs the packed SDK and builds/tests the copied project.
5. Checks that the debug APK includes Example and the release APK excludes it.

It does not upload packages or use signing credentials. The copied project is the working starter. No source links to the Snap-O checkout are needed after staging.

Install the debug app:

```sh
adb install -r /tmp/snapo-example/example/app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.example.snapo/.MainActivity
```

Open a development build of Snap-O with app-bundled tool support. Select **Example app → Example**. You should see three fake values, an incrementable fake counter, and controls that exercise the native helpers. The validation command builds the app; it does not install it or perform this device smoke test.

## Edit the copied project

For subsequent Android builds, point Gradle at the staged repository:

```sh
cd /tmp/snapo-example/example
./gradlew -PsnapoRepository=/tmp/snapo-example/maven :app:assembleDebug
```

The validation command writes the staged package version and group into the copied `gradle.properties`. The settings plugin configures Node downloads; the inspector plugin builds the frontend automatically. Set `downloadNode = false` in `snapoInspector` to use Node/npm on `PATH`. Set `frontendAssets` to a task output or prebuilt directory to skip the default npm build. Frontend-only commands are available in `example-tool/frontend`:

```sh
npm ci
npm run build
npm test
npm run dev
```

For live development in Snap-O, choose Develop → Use Development Server and enter the URL from `npm run dev`.

After publication, replace the frontend's `file:vendor/host.tgz` dependency with the chosen npm package/version and regenerate its lockfile. Remove the `snapoRepository` option to resolve the runtime and plugin from Central. Keep `mavenCentral()` in both repository lists in `settings.gradle.kts`.

## What to copy or replace

- `app/`: a tiny Android app used to try the tool. Its main code has no dependency on the tool.
- `example-tool/build.gradle.kts`: runtime dependency and plugin configuration. The plugin generates the descriptor and frontend ZIP.
- `ExampleInitProvider.kt`: process-scoped startup and the release opt-in check.
- `ExampleServer.kt`: GET returns a synthetic snapshot, POST increments a fake counter, and SSE streams snapshots from a `StateFlow`. The runtime handles HTTP preflight, browser access, errors, and cleanup. The counter resets when the app process restarts.
- `frontend/src/snapshot.ts`: protocol validation, snapshot requests, the increment command, and event-stream cleanup on connection changes. Revisions prevent a late GET response from replacing newer streamed data.
- `frontend/src/main.ts`: native toolbar search/refresh, copy, save, and color-picker APIs.

Replace the package names, tool ID, display name, endpoint, and fake values for your own tool. The Gradle definition generates `SnapOInspector.ID` and `SnapOInspector.PROTOCOL_VERSION`, used by the server and its payload. Choose a protocol version for your own payload. `hostApiVersion` describes compatibility with the native bridge; it is separate from your protocol and package versions.

## Connection behavior

The macOS host isolates tools and app processes. A process identity change replaces the page. Before reusing a forwarded port, the host unloads pages that could access the old endpoint.

The frontend only manages its own resources. When it receives a disconnected state, it aborts pending snapshot and mutation requests, closes its event stream and sample color picker, and clears the displayed snapshot. Hidden pages can remain alive, so this cleanup also avoids keeping an inactive subscription alive. On activation, the frontend validates protocol 1 and fetches a new fake snapshot and subscribes to events.

To check manually, switch between tools, disconnect/reconnect the device, and force-stop/relaunch the Example app. Increment the fake counter and confirm it updates through the event stream. Example should resume after reconnection; a new app process starts the counter at zero. There is no additional process-routing or connection-session API in the frontend.
