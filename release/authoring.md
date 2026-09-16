# Release the tool authoring packages

The tool plugin SDK is distributed through Maven Central. The Gradle plugin includes the host JavaScript SDK; it is not published to npm. Use this workflow to validate and release package updates. Local validation does not upload packages.

## Package destinations

| Package | Destination | Name/version source |
| --- | --- | --- |
| Android core library | Maven Central | Module name, Android `GROUP`, root `VERSION` |
| Tool Packager Gradle Plugin implementation | Maven Central | Project name in the Gradle build's settings, Android `GROUP`, root `VERSION` |
| Tool Packager Gradle Plugin marker | Maven Central | Gradle plugin ID in `build.gradle.kts`, root `VERSION` |
| Host JavaScript SDK | Inside the Gradle plugin JAR | Gradle plugin version |

The Tool Packager Gradle Plugin configures its implementation and marker publications. The marker lets a consumer use `id("com.openai.snapo.tool-packager") version "…"` with `mavenCentral()` in `pluginManagement.repositories`. A Gradle Plugin Portal release is optional and is not configured here.

The SDK exports compiled ES modules and declarations. The Gradle plugin build compiles it with managed Node/npm and creates a reproducible SDK archive inside the JAR. The first-party frontends use a local package dependency, compiling the SDK during installation and before frontend builds.

## Validate without publishing

For core API changes, run `./gradlew :tool-core:apiCheck` first. Review any changes to the [public API baseline](../tool-sdk/core/README.md#public-api-baseline); rebuilding the Example alone does not check compatibility with already-compiled tools.

From the repository root:

```sh
python3 release/validate_authoring.py --output /tmp/snapo-authoring
```

Use a new or empty directory outside the checkout. Requirements: JDK 17, Android SDK 36, Python 3, and Node.js 22.12 or later. The validation uses the repository's npm registry for downloads. There are no credential or signing requirements for local staging.

The command stages three Maven publications, checks their metadata and embedded SDK files, and builds a copied [Example tool](../examples/tool/README.md). The consumer resolves real package artifacts, with no composite build or SDK source dependency. It builds debug and release APKs, runs the example's Android and frontend tests, and runs Android lint. It checks that the debug APK includes the generated frontend ZIP and the release APK does not. It also checks that the bundled Example descriptor has its required icon and generated host API version, without a synthetic protocol version.

The output includes `report.json`, the copied example, local Maven repository, and debug APK. The consumer build runs without Node or npm on `PATH` and verifies that its frontend uses the downloaded runtime.

The SDK checks cover `npm ci` builds, unchanged lockfiles on repeat builds, restoration after clean/deletion, and synthetic plugin upgrades and downgrades. The upgrade test changes SDK JavaScript and declarations, then verifies installed bytes and typechecking. Both unchanged and changed SDKs must leave the npm manifest and lockfile unchanged.

A missing or incomplete lockfile must fail without being rewritten or falling back to `npm install`. The check then repairs it with `installSnapoToolDependencies` and retries the build. Dependency installation must preserve frontend sources.

The validator also creates and builds the bundled frontend starter in a custom directory, checks that initialization preserves existing files, and verifies the development task. It checks configuration cache reuse, an explicit installed-Node override, and prebuilt assets that schedule no Node/npm tasks. It also builds without the centralized repository override to verify automatic Node repository setup.

The plugin build also uses managed Node to compile the SDK. Local Node remains required for the validator’s direct npm checks. CI runs the same command. This check does not prove that Central credentials, namespace ownership, signing keys, or a device integration work; those are release-time checks.

### Release smoke test

After full Android CI passes on the exact source commit, release automation uses:

```sh
python3 release/validate_authoring.py --mode release-smoke --output /tmp/snapo-release-smoke
```

This mode stages and checks the same three publications and bundled SDK. It builds one independent debug/release APK pair with managed Node, verifies the installed SDK bytes, and checks the tool assets and initialization metadata. It skips unit tests, lint, and authoring regression scenarios already covered by full CI. The report records the mode and only claims checks that ran. The default mode remains `full`.

Both modes reuse Gradle daemons within the job. The independent example enables build caching and parallel execution. CI caches npm downloads; each copied consumer still starts without installed packages or generated SDK files.

To inspect Tool Packager Gradle Plugin artifacts without copying the example:

```sh
./gradlew -p tool-sdk/gradle-plugin assembleMavenCentralPublication
```

For manual local Maven staging, use the explicitly local `Authoring` repository tasks and `-Psnapo.localAuthoring=true`. That option skips signatures only for this unsigned staging workflow. Do not use it for a real release.

## Release a package update

1. Choose package versions and update the Example project and documentation. Rerun the independent consumer check after API or packaging changes.
2. Confirm ownership of the final Central namespaces, including the Gradle marker namespace. Configure credentials outside the repository.
3. Follow [release readiness](README.md), including publication checks, signatures, and protocol compatibility review. Package version changes do not automatically change the host bridge API or domain protocols.
4. With explicit authorization, run both upload commands below from the repository root. Review and publish both deployments in the Central Portal.
5. Resolve the released packages from clean projects before updating public dependency examples.

```sh
./gradlew --no-daemon publishToMavenCentral
./gradlew --no-daemon -p tool-sdk/gradle-plugin publishToMavenCentral
```
