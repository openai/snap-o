# Release the tool authoring packages

The tool plugin SDK is distributed through Maven Central and npm. Use this workflow to validate and release package updates. Local validation does not upload packages.

## Package destinations

| Package | Destination | Name/version source |
| --- | --- | --- |
| Android core library | Maven Central | Module name, Android `GROUP`, root `VERSION` |
| Tool Packager Gradle Plugin implementation | Maven Central | Project name in the Gradle build's settings, Android `GROUP`, root `VERSION` |
| Tool Packager Gradle Plugin marker | Maven Central | Gradle plugin ID in `build.gradle.kts`, root `VERSION` |
| Host JavaScript SDK | npm | `tool-sdk/host/package.json` |

The Tool Packager Gradle Plugin configures its implementation and marker publications. The marker lets a consumer use `id("com.openai.snapo.tool-packager") version "…"` with `mavenCentral()` in `pluginManagement.repositories`. A Gradle Plugin Portal release is optional and is not configured here.

The SDK exports compiled ES modules and declarations. It has a public npm publication configuration and a `prepack` build. The first-party frontends use a local package dependency, compiling the SDK during installation and before frontend builds.

## Validate without publishing

For core API changes, run `./gradlew :tool-core:apiCheck` first. Review any changes to the [public API baseline](../tool-sdk/core/README.md#public-api-baseline); rebuilding the Example alone does not check compatibility with already-compiled tools.

From the repository root:

```sh
python3 release/validate_authoring.py --output /tmp/snapo-authoring
```

Use a new or empty directory outside the checkout. Requirements: JDK 17, Android SDK 36, Python 3, and Node.js 22.12 or later. The validation uses the repository's npm registry for downloads. There are no credential or signing requirements for local staging.

The command stages three Maven publications and an npm tarball, checks their metadata/files, and builds a copied [Example tool](../examples/tool/README.md). The consumer resolves real package artifacts, with no composite build or SDK source dependency. It builds debug and release APKs, runs the example's Android and frontend tests, and runs Android lint. It checks that the debug APK includes the generated frontend ZIP and the release APK does not. It also checks that the bundled Example descriptor has its required icon and generated host API version, without a synthetic protocol version.

The output includes `report.json`, the copied example, local Maven repository, npm tarball, and debug APK. The consumer build runs without Node or npm on `PATH` and verifies that its frontend uses the downloaded runtime. It also creates and builds the bundled frontend starter in a custom directory, checks that initialization preserves existing files, and verifies the deprecated task aliases. It checks configuration cache reuse, an explicit installed-Node override, and prebuilt assets that schedule no Node/npm tasks. It also builds without the centralized repository override to verify automatic Node repository setup. Local Node remains required to stage and test the host SDK. CI runs the same command. This check does not prove that registry credentials, namespace ownership, signing keys, or a device integration work; those are release-time checks.

To inspect Tool Packager Gradle Plugin artifacts without copying the example:

```sh
./gradlew -p tool-sdk/gradle-plugin assembleMavenCentralPublication
```

For manual local Maven staging, use the explicitly local `Authoring` repository tasks and `-Psnapo.localAuthoring=true`. That option skips signatures only for this unsigned staging workflow. Do not use it for a real release.

## Release a package update

1. Choose package versions and update the Example project and documentation. Rerun the independent consumer check after API or packaging changes.
2. Confirm ownership of the final Central namespaces, including the Gradle marker namespace, and the final npm scope. Configure credentials outside the repository.
3. Follow [release readiness](README.md), including publication checks, signatures, and protocol compatibility review. Package version changes do not automatically change the host bridge API or domain protocols.
4. With explicit authorization to publish, use the existing Android publication tasks and the Gradle build's `publishToMavenCentral` task. The Tool Packager Gradle Plugin configures `automaticRelease = false`, so uploading does not automatically release a deployment.
5. With explicit authorization, publish the SDK with `npm publish` from `tool-sdk/host/`. Its `prepack` script builds the same files checked by local validation. Configure npm publishing authentication or trusted publishing for the final package at that time.
6. Resolve the released packages from clean projects before updating public dependency examples.

The local validation command does not upload to registries or schedule publication.

## Host SDK initialization API change

The next host SDK release removes the public `ready()` method. Consumers render immediately and subscribe with `onConnection()` and `onError()`. Async connection callbacks are supported; stream cleanup functions must still be returned synchronously. This is a breaking JavaScript API change and requires a major version increment if version 1.0.0 has been published. The native host bridge and Android tool protocols are unchanged. Validate initialization failure reporting, late error subscriptions, internal initialization waits, and async callback cleanup handling before publishing.
