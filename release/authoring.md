# Prepare the tool authoring packages

This setup prepares packages for future publication. It does not publish them. Names remain provisional until the planned renames are settled.

## Package destinations

| Package | Destination | Name/version source |
| --- | --- | --- |
| Android runtime | Maven Central | Module name, Android `GROUP`, root `VERSION` |
| Gradle plugin implementations | Maven Central | Project names in the plugin build's settings, Android `GROUP`, root `VERSION` |
| Gradle plugin markers | Maven Central | Plugin IDs in each project's `build.gradle.kts`, root `VERSION` |
| Host JavaScript SDK | npm | `inspectors/host-sdk/package.json` |

The Gradle plugin configures both project/settings implementations and their marker publications. The marker lets a consumer use `id("com.openai.snapo.inspector") version "…"` with `mavenCentral()` in `pluginManagement.repositories`. A Plugin Portal release is optional and is not configured here.

The SDK exports compiled ES modules and declarations. It has a public npm publication configuration and a `prepack` build. The first-party frontends still use a local package dependency, compiling the SDK during installation and before frontend builds.

## Validate without publishing

From the repository root:

```sh
python3 release/validate_authoring.py --output /tmp/snapo-authoring
```

Use a new or empty directory outside the checkout. Requirements: JDK 17, Android SDK 36, Python 3, and Node.js 22.12 or later. The validation uses the repository's npm registry for downloads. There are no credential or signing requirements for local staging.

The command stages five Maven publications and an npm tarball, checks their metadata/files, and builds a copied [Example tool](../snapo-link-android/example/README.md). The consumer resolves real package artifacts, with no composite build or SDK source dependency. It builds debug and release APKs, runs the example's Android and frontend tests, and runs Android lint. It checks that the debug APK includes the generated frontend ZIP and the release APK does not.

The output includes `report.json`, the copied example, local Maven repository, npm tarball, and debug APK. It also builds with Node from `PATH` and prebuilt frontend assets, checking that prebuilt mode schedules no Node/npm tasks. CI runs the same command. This check does not prove that registry credentials, namespace ownership, signing keys, or a device integration work; those are release-time checks.

To inspect plugin artifacts without copying the example:

```sh
cd snapo-link-android
./gradlew -p inspector-gradle-plugin assembleMavenCentralPublication
```

For manual local Maven staging, use the explicitly local `Authoring` repository tasks and `-Psnapo.localAuthoring=true`. That option skips signatures only for this unsigned staging workflow. Do not use it for a real release.

## Before a later publication

1. Finish renames and choose versions. Update the source locations in the table, Kotlin/TypeScript imports, the Example project, and documentation. Rerun the independent consumer check after renaming.
2. Confirm ownership of the final Central namespaces, including the plugin marker namespace, and the final npm scope. Configure credentials outside the repository.
3. Follow [release readiness](README.md), including publication checks, signatures, and protocol compatibility review. Package version changes do not automatically change the host bridge API or domain protocols.
4. With explicit authorization to publish, use the existing Android publication tasks and the plugin build's `publishToMavenCentral` task. The plugin configures `automaticRelease = false`, so uploading does not automatically release a deployment.
5. With explicit authorization, publish the SDK with `npm publish --workspace=<final-sdk-name>` from `inspectors/`. Its `prepack` script builds the same files checked by local validation. Configure npm publishing authentication or trusted publishing for the final package at that time.
6. Resolve the released packages from clean projects before updating public dependency examples.

No registry upload or scheduled publishing workflow is added by this change.
