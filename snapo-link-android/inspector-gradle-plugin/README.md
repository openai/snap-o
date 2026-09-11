# Inspector Gradle plugin

This local Gradle plugin builds an inspector frontend and packages it in an Android library or app. It generates the manifest entry, XML descriptor, Android identity constants, and APK asset ZIP. The plugin is configured for Maven Central publication, but has not been published.

For Android socket serving and HTTP handling, use [inspector-runtime](../inspector-runtime/README.md). The runtime and this packaging plugin have separate responsibilities.

## Configuration

The Snap-O build includes this plugin through `pluginManagement.includeBuild("inspector-gradle-plugin")`. Independent projects resolve its versioned plugin marker from Maven Central or a local staging repository. Apply it alongside an Android library or application plugin:

```kotlin
plugins {
    id("com.android.library")
    id("com.openai.snapo.inspector")
}

snapoInspector {
    id = "example"
    displayName = "Example"
    protocolVersion = 1
    icon = "@drawable/example_inspector_icon" // Optional.
}
```

Place `package.json`, `package-lock.json`, and frontend sources in the module's `frontend/` directory. Its `build` script must write `dist/index.html` and use relative asset URLs. Its `dev` script starts a local development server. Set `frontendDirectory` to use another source directory. The default host bridge API version is 1.

The normal Android build downloads Node.js 22.23.2 and its bundled npm, then runs `npm ci`, `npm run build`, and ZIP packaging through Gradle task dependencies. The runtime is cached under the module’s `.gradle/` directory. Gradle builds and `inspectorDev` do not require Node or npm on `PATH`, including when launched from Android Studio. Running npm commands directly still requires a local Node installation. Apps consuming a published AAR only use its packaged frontend files.

Apply the companion settings plugin in `settings.gradle.kts`, using the same package version:

```kotlin
plugins {
    id("com.openai.snapo.inspector-settings") version "<snapo-version>"
}
```

It declares the Node download repository and works with `FAIL_ON_PROJECT_REPOS`. No Ivy artifact patterns are needed in the consuming build. Declare `mavenCentral()` in `pluginManagement.repositories`, or use the local staging repository before publication. The settings plugin has a separate artifact so loading it does not move Android plugin classes into the settings classloader.

To use Node and npm already on `PATH`, set `downloadNode = false` in `snapoInspector`. In that mode the settings plugin is optional. To download a different supported Node version, set `nodeVersion`; its default is `22.23.2`. Node must satisfy the frontend package's `engines` requirement.

The plugin generates a Java `SnapOInspector` class in the module's Android namespace, accessible from Java or Kotlin. Its `ID`, `PROTOCOL_VERSION`, and `HOST_API_VERSION` constants come from the same definition as the discovery descriptor. For example:

```kotlin
val server = InspectorServer(SnapOInspector.ID) {
    get("/example") { respondJson(exampleSnapshot(SnapOInspector.PROTOCOL_VERSION)) }
}
```

Frontend code still declares the domain protocol versions it supports. That compatibility check is independent of the backend's advertised version.

Each variant receives generated resources and assets through Android Gradle Plugin source APIs. No source manifest edit is needed. The metadata references `snapo/inspectors/<id>/frontend.zip`. `index.html` is implicit. The ZIP uses reproducible file order and timestamps.

## Custom frontend build

Set `frontendAssets` from a task's output directory provider to replace the default npm build:

```kotlin
snapoInspector {
    frontendAssets.set(customFrontendBuild.flatMap { it.outputDirectory })
}
```

Gradle follows that provider's task dependency. The directory must contain `index.html`; ZIP packaging and metadata generation stay the same. Declare all inputs and outputs on the custom task. For already built files, set `frontendAssets = layout.projectDirectory.dir("prebuilt-frontend")`. Neither form runs the default Node/npm tasks during Android packaging, and neither needs the settings plugin.

## Development

Run either command from `snapo-link-android/`, in separate terminals if needed:

```sh
./gradlew :network:inspectorDev
./gradlew :tweaks-core:inspectorDev
```

In Snap-O, select the app and inspector, then choose Develop → Use Development Server. Enter the URL printed by the development server. There is no default URL. The override is saved separately for each device, Android user, app, and inspector. Choose Develop → Use Packaged Frontend to remove it.

Only use a trusted local server. Its code can contact the inspector's Android endpoint and request native host actions. HTTP, HTTPS, and HMR WebSocket traffic to that server are allowed while other endpoint restrictions remain in effect.

Both frontends depend on `@snap-o/host` through a local npm file dependency. The SDK is not published to npm yet. Once published, inspector authors can use a versioned dependency; the compiled SDK remains inside the frontend ZIP, so consuming Android apps still need no npm setup.

## Local publication validation

Run `python3 release/validate_authoring.py` from the repository root. It stages the plugin implementations and both markers in a temporary Maven repository, packages the host SDK, and builds a copied [Example tool](../example/README.md). It does not upload anything or require signing credentials.

The plugin's Maven group comes from `snapo-link-android/gradle.properties`, its artifact names from this build's `settings.gradle.kts`, and its version from the root `VERSION`. Its plugin ID is declared in `build.gradle.kts`. See [publication preparation](../../release/authoring.md) for future publishing and renames.
