# Releasing Snap-O

Run commands below from the repository root. Check product behavior and version metadata against the source commit being released.

## Choose the version and scope

Choose a `MAJOR.MINOR.PATCH` version newer than the relevant public versions. Inspect any existing tag, release, appcast entry, or Maven upload before resuming; never replace a published version.

Choose `mac`, `android`, or `both` from the changes since the last public versions:

- For macOS, use the latest published [GitHub Release](https://github.com/openai/snap-o/releases). An Android-only tag may be newer.
- For each Android library, check its latest public Maven metadata and files. A tag or successful staging run does not prove publication.

Fetch the required Git refs, then run:

```bash
bash release/preflight.sh \
  --snapo-dir . \
  --ref <source-commit> \
  --candidate <target-version> \
  --mac-base <published-macos-tag> \
  --android-base <public-android-tag>
```

The script reports changed files and protocol definitions at `--ref` (default: `HEAD`), plus public GitHub release, appcast, and CI data. Use this report with the criteria below to choose release scope and required tests. The macOS base defaults to the latest public release; supply the Android base after checking Maven. Repeat the comparison if libraries have different public versions. Resolve missing refs, bases, and protocol definitions before continuing. Local edits are shown but are not included in the comparison.

## Check protocol changes

Complete this review before updating the version, including for mac-only releases. Compare the [protocol definitions](../contracts/), Android command handlers and payloads, and Mac, web, and CLI clients. Check new or moved code as well as the paths listed by preflight.

- Record old and new Network and Tweaks protocol numbers, client-supported versions, and the versions that enable optional features. List changes to commands, events, fields, and behavior.
- Classify changes as none, additive, or breaking. Record the required version bump, or explain why keeping the number is compatible and how clients detect new features. An unchanged constant does not prove the API is unchanged.
- Check clients before bumping a server number. Network clients have used an exact supported version. Tweaks uses version checks to enable features. See the [Tweaks](../contracts/tweaks/README.md) and [interception](../contracts/network/interception.md) definitions.
- For changed protocols or version handling, test new clients with public servers, public clients with new servers, and the new pair. Check the changed feature and the error or fallback when it is unavailable. Use existing tests where they cover these cases.

Record the decision and test results with the source SHA. Fix failures and merge required protocol, client, and test changes before the version update. Repeat the review if later source changes affect it.

## Build and test

Run the normal checks for changed code. Use the setup and commands in the [macOS/web](../.github/workflows/mac.yml), [Android](../.github/workflows/android-link.yml), and [CLI](../.github/workflows/snapo-cli.yml) workflows. Confirm CI passed on the commit being released.

Before the version update, run the macOS build for `mac` or `both`, and Android publication validation for `android` or `both`:

```bash
(cd snapo-app-mac && \
  xcodebuild -project Snap-O.xcodeproj -scheme Snap-O \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build)

(cd snapo-link-android && \
  ./gradlew --no-daemon validateMavenCentralRelease)
```

Use `snapo-link-android/build/reports/maven-central/publications.tsv` for the complete Android library and file list. Do not use a fixed module count or an old README list.

Test the release workflow before updating the version when build, signing, packaging, or publishing code changes. Check changes to the Xcode project, macOS build scripts, source CI, and web build files against the release workflow's setup. Source-only changes still need normal tests, but do not require an extra release workflow run when that workflow is unchanged.

For a macOS test run, verify the signed and notarized app, then open a temporary copy and confirm it works. Keep the installed prior release for the Sparkle update test. Android test runs must validate files without publishing them. Fix failures and repeat affected checks after changes.

To test the release scripts:

```bash
python3 -m unittest discover -s release/tests -p 'test_*.py' -v
```

## Update the version and tag

Use a clean checkout based on current `main`. Update `VERSION` and `.codex-plugin/plugin.json` together:

```text
VERSION = MAJOR.MINOR.PATCH
BUILD_NUMBER = YYYYMMDD.NN
```

The plugin version must match `VERSION`, which supplies the macOS app and Maven versions. `BUILD_NUMBER` is the Sparkle version; it must be higher than the top public appcast build. Use the release date and a sequence number for that day.

Keep the version PR limited to those two files. Repeat the applicable build/publication checks, merge the PR, and confirm required PR and main checks pass. Repeat a release test run if packaging changed or the earlier run did not cover the final source.

Tag the validated version-update commit with `VERSION`, without a `v` prefix. Confirm it is reachable from `main`. Retry failed workflow steps on the same tag only if source is unchanged. If source must change after tagging, use a new release version. Do not move the tag or replace Maven files.

## Check the final macOS files

A tagged build must produce `Snap-O.dmg`, `Snap-O.dmg.sha256`, and a generated Sparkle `<item>`. The checksum file contains only the SHA-256 digest. Compare it with the final DMG. Test builds may omit the checksum and Sparkle item.

Mount the DMG and check the app's signature, notarization, embedded web files, and bundled CLI. Confirm the app version and build match the tag. Test relevant CLI commands, including route loading if interception changed. The normal `snapo --help` invocation must exit successfully; a notarization check alone is not enough.

Open a temporary copy of the final app and confirm the changed flows work. Review the release notes before publishing.

## Publish Android libraries

Check every library and file in the tag's generated `publications.tsv`. Compare the staged files and signatures with that list before publishing.

After Maven Central finishes publishing, fetch each library's POM, Gradle metadata, AAR, sources, and javadocs directly from Maven Central. Also resolve all modules from a clean Android Gradle project using the Android plugin, `google()`, and `mavenCentral()`. Direct Central-only checks must skip transitive dependencies because AndroidX and Compose may require Google's repository.

## Release notes and website

Describe user-visible changes since the last public macOS release in short, plain sentences. Before claiming a bug fix, check that the bug existed in that release. Omit fixes for regressions introduced and fixed within the unreleased changes.

Publish the GitHub Release with the version alone as its title and the final DMG and checksum under their exact filenames. Confirm the DMG download works before updating the appcast.

Use the generated Sparkle item without changing or regenerating its signature. Check its app version, build number, minimum macOS version, byte length, URL, and signature. Add it to the latest `gh-pages` appcast after the channel description. Preserve prior entries.

Update affected `gh-pages` documentation from public versions. Use the exact release tag for macOS and the latest public Maven version of each Android library. Do not document dependencies or features that users cannot download. Keep unrelated page design and assets unchanged.

| Page | Sources |
| --- | --- |
| `index.html` | Released features and root `README.md` |
| `network-inspector.html` | Released APIs, setup, and `skills/snap-o-network-inspector/SKILL.md` |
| `tweaks.html` | Released APIs, setup, CLI examples, `skills/snap-o-tweaks/SKILL.md`, and its interaction-surfaces reference |
| `tweaks-protocol.html` | `contracts/tweaks/README.md` and `skills/snap-o-tweaks/references/protocol.md` |

Check appcast XML, HTML with a browser or HTML5 parser, links, assets, dependency versions, and API/CLI examples. Confirm the updated pages and appcast are public. Check the downloaded DMG against its checksum. Use a prior published Snap-O app to confirm Sparkle finds and installs the new version.

Android-only releases also need affected dependency examples and guides updated after Maven publication. If no page needs a change, record why.

## Finish

Record the version, source/tag SHA, protocol decisions, test results, release URLs, and website changes. Include build run URLs and any unfinished checks.

Do not mark the release complete while a required publication, website change, app confirmation, Maven resolution, or Sparkle upgrade test is pending.
