# Example tool

Copy this project to start a Snap-O tool. Its displayed name is **Example**, its ID is `example`, and every value is fake sample data. It demonstrates the APIs without collecting application data.

This is an independent Android build. It has its own Gradle wrapper and does not include Snap-O's source builds. The app depends on `example-tool` only in debug builds.

See the [tool plugin authoring guide](../../docs/plugins.md) for setup, examples, and optional API details.

## Run the example

Copy this directory to your own project location. Use JDK 17 and Android SDK 36. Set `ANDROID_HOME` to your Android SDK directory if needed.

The example resolves the core library and Tool Packager Gradle Plugin from Maven Central. Its `gradle.properties` selects the package version. The plugin supplies the host SDK from its JAR and manages Node/npm automatically:

```sh
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.example.snapo/.MainActivity
```

Open Snap-O and select **Example app → Example**. You should see three fake values, an incrementable fake counter, and controls that exercise the native helpers.

## Edit your tool

Run `./gradlew :app:assembleDebug` to rebuild the Android app and its frontend. Reinstall the APK to try the updated tool.

The Tool Packager Gradle Plugin downloads Node and uses its bundled npm. Android Studio and CI builds do not need Node or npm on `PATH`. This example forbids project repositories, so it declares the Node download source in settings and sets `node.distBaseUrl` to `null` in the tool module. Builds that allow project repositories need neither change. See [Node configuration](../../tool-sdk/gradle-plugin/README.md#node-configuration) for version overrides and using an existing installation.

Run `./gradlew :example-tool:devSnapoToolFrontend` to start the development server with managed Node. Set `frontendAssets` to a task output or prebuilt directory to skip the default npm build. After the first Gradle build, frontend-only commands are also available in `example-tool/frontend` with a local Node installation. After a clean checkout or plugin upgrade, first run `./gradlew :example-tool:prepareSnapoToolHost` from the project root:

```sh
npm ci
npm run build
npm test
npm run dev
```

For live development in Snap-O, choose Develop → Use Development Server and enter the URL printed by the development server. Snap-O proxies its frontend files under `snapo://tool/`; `/api/...` still calls the Android app. Vite’s hot-reload WebSocket connects directly to the local server.

## Validate local SDK changes

Contributors can build the example against local package artifacts. From a Snap-O checkout, with the requirements above and Python 3:

```sh
python3 release/validate_authoring.py --output /tmp/snapo-example
```

Use a new or empty output directory. The command:

1. Stages the core library and Tool Packager Gradle Plugin in `/tmp/snapo-example/maven`.
2. Verifies the compiled host SDK and declarations inside the plugin JAR.
3. Copies this entire project to `/tmp/snapo-example/example`.
4. Restores the SDK through Gradle and builds/tests the copied project, including clean restoration and SDK upgrades.
5. Checks that the debug APK includes Example and the release APK excludes it.

It does not upload packages or use signing credentials. The validation command writes the staged package version and group into the copied `gradle.properties`. No source links to the Snap-O checkout are needed after staging.

For subsequent builds of that copy, point Gradle at the staged repository:

```sh
cd /tmp/snapo-example/example
./gradlew -PsnapoRepository=/tmp/snapo-example/maven :app:assembleDebug
```

Install and launch the debug APK using the commands in **Run the example** from this directory. The validation command does not install the app or perform a device smoke test.

## What to copy or replace

- `app/`: a tiny Android app used to try the tool. Its main code has no dependency on the tool.
- `example-tool/build.gradle.kts`: core library dependency and tool plugin configuration. The tool plugin generates the descriptor and frontend ZIP.
- `ExampleInitializer.kt`: AndroidX Startup retains the server for the process. `startIfAllowed` checks the release opt-in and logs socket failures.
- `ExampleServer.kt`: GET returns a synthetic snapshot, POST increments a fake counter, and SSE streams snapshots from a `StateFlow`. The core library handles HTTP preflight, browser access, errors, and cleanup. The counter resets when the app process restarts. The core library automatically sends heartbeat comments every 30 seconds while waiting for changes.
- `frontend/src/snapshot.ts`: snapshot validation, snapshot requests, the increment command, and event-stream cleanup on connection changes. Revisions prevent a late GET response from replacing newer streamed data.
- `frontend/src/main.ts`: native toolbar search/refresh, copy, save, and color-picker APIs.

Replace the package names, tool ID, display name, required icon, routes, and fake values for your own tool. The Gradle definition generates `SnapOTool.ID` for the server. The frontend ships with that server, so Example does not declare or check a protocol version. Host bridge compatibility metadata is generated by the plugin.

## Connection behavior

The macOS host isolates tools and app processes. A process identity change replaces the page and its direct Android connection.

The frontend only manages its own resources. When it receives a disconnected state, it aborts pending snapshot and mutation requests, closes its event stream and sample color picker, and clears the displayed snapshot. Hidden pages can remain alive, so this cleanup also avoids keeping an inactive subscription alive. On activation, the frontend fetches a new fake snapshot and subscribes to events.

To check manually, switch between tools, disconnect/reconnect the device, and force-stop/relaunch the Example app. Increment the fake counter and confirm it updates through the event stream. Example should resume after reconnection; a new app process starts the counter at zero. There is no additional process-routing or connection-session API in the frontend.
