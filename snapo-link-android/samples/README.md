# Network samples

The OkHttp, Ktor, and HttpURLConnection demos have network test buttons and a shared Tasks section below them. All requests use an in-app server on localhost. The server deliberately leaves `GET /api/tasks` and `POST /api/tasks` unimplemented, so the Tasks section initially reports that the API is unavailable.

Use Snap-O interception with the OkHttp or Ktor demo to supply task responses. This exercises loading, task creation, errors, and Python state without a backend service. The HttpURLConnection integration currently supports inspection only.

## Run a sample

Build the debug app with Android Studio, or run these commands from the repository root. Select a connected device with `adb devices`.

```bash
./snapo-link-android/gradlew -p snapo-link-android :samples:demo-okhttp:assembleDebug
adb -s <serial> install -r snapo-link-android/samples/<demo>/build/outputs/apk/debug/<demo>-debug.apk
adb -s <serial> shell am start -n <package>/.MainActivity
```

Replace `demo-okhttp` in the build command and select the matching demo and package below:

| Demo | Package | API client |
| --- | --- | --- |
| `demo-okhttp` | `com.openai.snapo.demo` | OkHttp |
| `demo-ktor-okhttp` | `com.openai.snapo.demo.ktor` | Ktor with the OkHttp engine |
| `demo-httpurlconnection` | `com.openai.snapo.demo.httpurlconnection` | HttpURLConnection |

Scroll below the network buttons to **Tasks**. The first request returns HTTP 404. Refreshing or adding a task also fails until interception supplies those responses. Release builds use the no-op integration and do not support interception.

## Check implementation and no-op libraries

Debug samples use the implementation libraries by default. Add `-Psnapo.samples.noop=true` to build them against the no-op libraries instead. No-op samples do not support inspection or interception.

From `snapo-link-android`, run both modes without building release variants:

```bash
./gradlew assembleDebug lintDebug testDebugUnitTest
./gradlew -Psnapo.samples.noop=true assembleDebug lintDebug testDebugUnitTest
```

These commands also build, lint, and test the debug variants of all library modules.

## Supply task responses

From the repository root, list the sample's network socket and start the existing route example:

```bash
scripts/snapo network list -s <serial> --json
scripts/snapo network intercept examples/routes.py --check
scripts/snapo network intercept examples/routes.py -s <serial> -n <socket_name>
```

Select the socket for the OkHttp or Ktor sample's package. Keep the runner open, then tap **Refresh**. The task list starts empty. Enter a title and tap **Add**. The Python POST handler returns a task with status `pending`, and the app reloads the list. Both task handlers return synthetic responses without contacting the in-app server. Each running app needs its own runner and keeps its own Python task list.

Try these flows:

- **Loading:** the list handler waits half a second. Increase its `asyncio.sleep(...)` delay to keep the progress indicator visible longer.
- **State:** add several tasks and refresh. The Python module keeps them until the runner restarts or successfully reloads.
- **Reload:** save a change to `examples/routes.py`, then refresh. The runner reloads the file and resets its task list. Invalid Python edits keep the previous handlers active.
- **HTTP errors:** return `call.json({"error": "unavailable"}, status=503)` from the list handler. Refresh to see the error, then restore the handler and retry.
- **Timeouts:** restart the runner with `--timeout 1` and make the list handler wait longer than one second. The request fails and the controls become available again.
- **Stop:** stop the runner with Ctrl-C, then refresh. The app reports that the API is unavailable again.

The existing network buttons remain available while the task routes are active. Inspect task requests with Snap-O's network inspector or `network requests` and `network show`. The full route API is documented in the repository's [Python API overrides guide](../../README.md#python-api-overrides).
