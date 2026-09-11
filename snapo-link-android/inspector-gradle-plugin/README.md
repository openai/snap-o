# Inspector Gradle plugin

This local Gradle plugin builds an inspector frontend and packages it in an Android library or app. It generates the manifest entry, XML descriptor, and APK asset ZIP. The plugin is not published yet.

## Configuration

The build includes this plugin through `pluginManagement.includeBuild("inspector-gradle-plugin")`. Apply it alongside an Android library or application plugin:

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

The build uses centralized repositories. Its `settings.gradle.kts` declares the Node.js distribution repository with the `org.nodejs:node` artifact pattern described in the [Node Gradle plugin FAQ](https://github.com/node-gradle/gradle-node-plugin/blob/7.1.0/docs/faq.md#is-this-plugin-compatible-with-centralized-repositories-declaration). Keep that repository when using this plugin in another build.

Each variant receives generated resources and assets through Android Gradle Plugin source APIs. No source manifest edit is needed. The metadata references `snapo/inspectors/<id>/frontend.zip`. `index.html` is implicit. The ZIP uses reproducible file order and timestamps.

## Custom frontend build

Set `frontendAssets` from a task's output directory provider to replace the default npm build:

```kotlin
snapoInspector {
    frontendAssets.set(customFrontendBuild.flatMap { it.outputDirectory })
}
```

Gradle follows that provider's task dependency. The directory must contain `index.html`; ZIP packaging and metadata generation stay the same. Declare all inputs and outputs on the custom task.

## Development

For Tweaks, run this from `snapo-link-android/`:

```sh
./gradlew :tweaks-core:inspectorDev
```

In Snap-O, select the app and inspector, then choose Develop → Use Development Server. Enter the URL printed by the development server. There is no default URL. The override is saved separately for each device, Android user, app, and inspector. Choose Develop → Use Packaged Frontend to remove it.

Only use a trusted local server. Its code can contact the inspector's Android endpoint and request native host actions. HTTP, HTTPS, and HMR WebSocket traffic to that server are allowed while other endpoint restrictions remain in effect.

The Tweaks frontend depends on `@snap-o/host` through a local npm file dependency. The SDK is not published to npm yet. Once published, inspector authors can use a versioned dependency; the compiled SDK remains inside the frontend ZIP, so consuming Android apps still need no npm setup.
