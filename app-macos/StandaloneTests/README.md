# Native test synchronization

Test code has three homes: `Snap-OUnitTests/` for headless Xcode tests,
`Snap-OIntegrationTests/` for app-hosted tests, and `StandaloneTests/` for
script-built harnesses. Unit and integration folders group tests by feature.
Standalone harnesses keep separate entry points and fakes; folder separation
prevents unrelated harnesses from being compiled together.

See the [source layout](../../CONTRIBUTING.md#macos-source-layout) for production
code locations. The scripts in `app-macos/scripts/` select each standalone
harness's production sources and test support.

CI uses Xcode 26.4.1. Use the same version for local validation; Xcode 26.1.1
fails to compile the locked dependency test support. The app still targets macOS 26+.

CI builds the unit and integration schemes in Debug. The custom Local configuration makes
Swift packages use release optimization, which slows fresh test builds.
CI resolves locked packages during that build, then runs the generated `.xctestrun`
file directly. The test step does not need to resolve packages again.

Do not encode, decode, export, or play real video in automated tests. Test the
settings passed to the media boundary and supply controlled results. `VideoFileClient`
uses failing defaults in tests so an unexpected media call cannot reach macOS.
Playback and native recording tests use fake drivers and writers. Frame-copy tests
use a fake renderer. File ownership tests may use placeholder bytes.

State tests also use an in-memory `TextPasteboard`, injected thumbnail images, and
fake frame encoders. Recording deadline tests use a controlled stream and `TestClock`;
they do not wait for a kernel socket timeout. Standalone scripts run their own suites,
without repeating tests already run by an Xcode target.

ADB client tests inject `ScriptedADBConnection` through the `ADBConnection` protocol.
Script replies and failures directly. Use its entry signal and explicit close for
cancellation tests; do not open a socket just to hold a request pending.
A simulated transport timeout tests error handling. Advancing `TestClock` tests
code that owns a timer. These are separate checks.

Tool request tests inject `ToolHTTPExchange` for responses and pending requests.
The production exchange owns NIO setup; tests of routing, headers, cancellation,
and deadline handling do not need a live HTTP peer. Keyboard and clipboard tests
also inject helper bytes, so they do not require a bundled Android JAR.

Test one behavior at a time. Use controlled inputs for everything outside that
behavior, including discovery, device operations, framework results, and time.
Use a fresh fixture for each independent failure cause. Keep assertions together
when they prove the same contract, such as cancelled work retaining its resource
until cleanup finishes. Avoid checking unrelated metadata or internal phases.
When testing overlapping calls, prove that every call entered before releasing
the blocked operation; creating a task does not prove that it started.

Use [swift-dependencies](https://github.com/pointfreeco/swift-dependencies) for
clocks. Declare `@Dependency(\.continuousClock)` where time is used instead of
forwarding sleep closures through initializers. Keep operation results and
completion signals explicit.

- Await an operation's task before checking its final result.
- Wait for observable state with `waitForState` in the Xcode tests or
  `waitForObservedTestState` in standalone tests. Both use macOS 26 `Observations`.
  Every value read by the condition must support Observation.
- Use `TestSignal` for actor and lock-protected fakes. Read its revision before
  checking the condition so a change cannot be lost before waiting.
- Let fixture operations finish by default. Pass a closed `TestGate` only for
  the operation whose pending state matters to the test.
- Use `await gate.waitUntilEntered()` before testing a blocked operation. This
  waits for entry even if several device operations have already entered. Check
  exact request counts after completion when the count is part of the contract.
- Keep cleanup gates blocked until the test releases them. Cancellation alone
  must not release a fake used to verify that shutdown joins unfinished work.
- Use `TestClock` from [swift-clocks](https://github.com/pointfreeco/swift-clocks)
  for deadlines, retries, and pacing. Override `continuousClock` with a test trait
  or `withDependencies`, then advance time and await the operation's result.
- A clock controls time, not completion of unrelated tasks. Await the fake
  operation's entry signal when the test depends on reaching a particular state.
- Use `clock.checkSuspension()` after cancellation to verify no sleeps remain.
- Give parallel tests independent overrides with `.dependency(\.continuousClock,
  TestClock())`. The library's test default fails if time is used without an override.
- Apply overrides before constructing a model and keep them active through the
  test operation. A current override takes precedence over a captured value.
  Use `withDependencies(from:)` when creating child models later, and
  `withEscapedDependencies` across detached tasks.
- Use `ImmediateClock` only when elapsed time is irrelevant to the assertion.
- Check canceled or superseded results after the original task finishes.
- Use test time limits to bound failures, not to synchronize successful tests.

Do not use a fixed number of `Task.yield()` calls or a short sleep to settle work.
Do not add sleep-based watchdogs; bound failures with test or CI time limits.
Do not send probe gestures or trigger repeated discovery to detect readiness.
Do not mock the model whose behavior the test is checking.

Review Escape decisions run in `CaptureReviewEscapeActionTests` without a window.
`CaptureReviewOwnershipTests` and `CaptureReviewTests` cover save, discard, and file ownership;
`CaptureReviewPlaybackTests` covers trim changes with a fake player. The two native
`CaptureReviewEscapeTests` only check keyboard routing after remounting and from a
focused video view. They load no media and wait for focus events, not elapsed time.

## Local test selection

Choose tests for the changed behavior and its callers, not just the changed filename.
Shared lifecycle or transport changes need broader coverage than a toolbar layout change.
CapturePaneTests checks pane commands, selection, and cleanup without native windows.
The AppKit ownership check also runs without windows.
Window notification, hidden-launch, and view-remount checks still need native coverage.
See the migration table below before selecting an older runner.
Use the smallest set that covers the affected behavior. Do not rerun successful checks
without a relevant source, dependency, build-input change, or unresolved failure.
An unchanged patch with recorded validation does not need another full local run.

For Swift code changes, build the app and lint the changed files. A `build` or
`build-for-testing` action compiles code without running the test app.
Documentation-only changes need a content and link review, not an app build.
Use `scripts/test-live-preview-frame-export.sh --build-only` to compile its window
harness without launching it. Running that harness still requires approval below.

### Headless unit tests

`Snap-OUnitTests` is the default local test scheme. It uses the command-line `xctest`
runner with no application host or app target dependency. The normal `Snap-O` scheme's
Test action selects these tests too; its Run and Archive actions still build the app.

From `app-macos/`:

```sh
xcodebuild -project Snap-O.xcodeproj -scheme Snap-OUnitTests -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test
```

Use `-only-testing:Snap-OUnitTests/DeviceOpenResolverTests`, for example, to narrow a run.
Build the app separately when production code changes; unit tests compile only their
selected production sources.

The headless target covers settings, device links and resolution, clipboard state,
history selection, crop geometry, trim decisions, playback seek state, visibility, and
workspace persistence. It also covers preview startup, retry and cleanup, session readiness,
density changes, screenshot deadlines, capture conflicts, and file-command and video-packet parsing.
Discovery parsing, app-launch commands, tool selection and web policies, review
ownership, clipboard synchronization, thumbnail state, and recording deadlines also
run headless. Their tests check decisions and supplied values without launching a
device, browser, media service, or system pasteboard.
It compiles the same production files as the app, with explicit membership
under **Unit test sources** in the Xcode project. No source copies or new libraries are
needed. New independent tests belong in `Snap-OUnitTests/`; add any additional production
files to that target's Sources phase. Keep app startup, window creation, and real
transport operations out of this target. Async work alone does not require an app host.
Use controlled sources and clocks to test retries, cancellation, and cleanup here.
When changing an app-hosted test, first check whether its assertions need a running app.
Use real sockets only to test transport behavior, such as framing, cancellation, and closure.
Test state and result-handling rules with controlled inputs. A test clock does not control OS socket deadlines.
Keep assertions tied to the behavior named by the test. Remove duplicate cases and unrelated metadata or exact-message checks.
A regression test checks that the runner has
no `NSApplication` instance and is not an application bundle.

### App integration tests

The `Snap-OIntegrationTests` scheme is opt-in locally. It builds the app and runs the
remaining tests from `Snap-OIntegrationTests/` inside Snap-O. Both `test` and `test-without-building`
launch the app, even with `-only-testing`. Run it locally only when the user explicitly
requests or approves it; otherwise leave this coverage to CI.

```sh
xcodebuild -project Snap-O.xcodeproj -scheme Snap-OIntegrationTests -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -only-testing:Snap-OIntegrationTests/CaptureViewTests test
```

`build-for-testing` compiles either scheme without launching the tests. CI builds both
schemes and runs their `.xctestrun` files in separate steps. Select the file by scheme
name; a shared build directory can contain both files and stale files from older schemes.
The full native CI run remains the submission check. Report actual results and deferred
coverage; a unit pass does not verify app integration or visual behavior.

### Standalone checks

Use these existing console-only suites when their coverage matches the change.
Paths are relative to `app-macos/`:

| Changed behavior | Local check |
| --- | --- |
| Preview setup, touch settings, and pending input requests | `scripts/test-preview-input.sh` |
| Preview stream readiness, formats, and cleanup | `scripts/test-video-stream.sh` |
| Physical video sharing and source teardown | `scripts/test-video-stream.sh` |
| Pane selection, startup and capture transitions | `scripts/test-media-lifetime.sh` |
| Preview visibility, setup and teardown | `scripts/test-preview-input.sh` |
| View remount input ownership, without windows | `scripts/test-live-preview-frame-export.sh --ownership-only` |
| Recording batch failures, deadlines, and cleanup | `scripts/test-recording.sh` |
| App shutdown order, target lifetime, and deadline reporting | `scripts/test-app-runtime.sh` |
| Emulator frame conversion, launch arguments, and discovery parsing | `scripts/test-emulator-preview.sh` |
| Device discovery and tool reconnection | `scripts/test-tool-recovery.sh` |
| Bound ADB requests, server restart safety, emulator discovery, native gRPC lifetime, and control cancellation | `scripts/test-device-connection.sh` |
| Media source retention and drag cancellation | `scripts/test-media-lifetime.sh` |
| Capture export file permissions | `scripts/test-capture-export.sh` |
| Device inventory, emulator commands, and authentication policy | `StandaloneTests/DeviceManager/test.sh`, with `SNAPO_DERIVED_DATA` and `SNAPO_TEST_ADB` unset |

The app-runtime suite runs the real shutdown coordinator with gated service doubles,
real connection targets, and touch-setting leases. It opens no app or device.

The device-connection and Device Manager suites exercise anonymous XPC connections
inside the test process; they do not launch the app or its helper.
The device-connection suite also runs a synthetic loopback gRPC server to verify
that native operations cannot reconnect after their original socket closes.
It also checks that identity verification requires a matching fresh log marker,
retries a delayed subscription, and joins a pending marker write on cancellation.
These synthetic checks do not establish compatibility with a real emulator.
The Device Manager suite checks native socket ownership using isolated loopback
connections and rejects unverified console peers before sending credentials.
The Device Manager command above skips signed XPC integration and real ADB startup.
Keep those omissions explicit. Recording and recovery reuse package products from a
matching `Snap-OIntegrationTests` build through `SNAPO_DERIVED_DATA`; set
`SNAPO_TEST_CONFIGURATION` to that build's configuration. A headless-only build does
not produce those dependencies. Without `SNAPO_DERIVED_DATA`, the scripts build the
integration scheme first, without running its tests.

### Checks that affect the desktop

These standalone entry points also require explicit approval for local execution:

- `scripts/test-tool-selection.sh` runs selected app-hosted integration tests.
- `scripts/test-startup-capture.sh` includes session tests that open AppKit windows.
  `scripts/test-media-lifetime.sh --windows` runs those checks directly; its default stays headless.
- `SNAPO_TEST_WINDOWS=1 scripts/test-preview-input.sh --filter WindowVisibilityTests`
  opens two small windows to check native cover/uncover events. The default run
  uses controlled window state and opens no windows.
- `scripts/test-live-preview-frame-export.sh` creates test windows and sends events, except with `--ownership-only`, `--frames-only`, or `--build-only`.
- `StandaloneTests/DeviceManager/test.sh` also launches signed test apps when
  `SNAPO_DERIVED_DATA` is set. `StandaloneTests/AndroidHostSecurity/test.sh` does the same when
  given a built helper or `SNAPO_DERIVED_DATA`.

A standalone executable is not necessarily a console-only test. Inspect its setup
before selecting an unlisted suite. For toolbar layout or view wiring, a build and
changed-file lint are the default local checks; report interaction coverage as pending
unless an approved UI check or relevant CI tests cover it.

## Focused tests

| Behavior | Controlled dependency |
| --- | --- |
| Pointer preparation and pacing | Preparation task, backend event signals, and `TestClock` |
| Keyboard connection and cleanup | Transport request and close signals |
| Recording deadlines and shared touch settings | `TestClock` deadlines and cancellation-aware operation gates |
| Startup, capture modes, and Device Manager state | Observable values and device-service signals |
| Discovery retries and cooldowns | Scoped `TestClock` |
| Tool recovery and metadata policy | Fake HTTP probe results and service change streams |
| Browser messages and page events | Origin values, bridge commands, and the delivery queue |
| Tool host page selection and readiness | A fake `ToolPageContainer`, without creating WebKit views |
| Local Web Inspector actions | An object that records supported selector calls |
| Playback scrubbing | Seek queue requests and explicit completions |
| Recording collection and cleanup | A controlled recording loader |
| Rename focus | A manually executed focus callback |
| Emulator launch arguments and JWT claims | Configuration values, a fixed signing time, and a test key |

The app uses `Dependencies`; the app-hosted tests also use `DependenciesTestSupport`.
The startup/session, recording, and recovery scripts reuse compiled package
products through `scripts/test-swift-packages.sh`.
Set `SNAPO_DERIVED_DATA` to an existing integration `build-for-testing` output to avoid rebuilding;
CI passes the output from its native test build. Set `SNAPO_TEST_CONFIGURATION`
to match that build's configuration; CI uses Debug and local scripts default to Local.
Without `SNAPO_DERIVED_DATA`, these scripts update the build in `app-macos/.build/tests` first.
Later runs reuse that build instead of compiling packages in a fresh temporary directory.

## Standalone compilation

The scripts use `scripts/test-swift.sh` to compile each suite in one pass.
`-whole-module-optimization -Onone` avoids repeated work across source files while
keeping assertions enabled. Swift's compiler cache reuses unchanged compilation
results. The compiler checks source and dependency contents before reuse.

With `SNAPO_DERIVED_DATA`, scripts share Xcode's `CompilationCache.noindex`.
Otherwise, they cache results under `app-macos/.build/tests`.
CI runs `xcrun llvm-cas --prune` after the standalone scripts, then saves the cache.
This trims unused file capacity that standalone `swiftc` leaves behind.
Without this step, the archive processes tens of gigabytes of empty space.
Each script reports compile/link time and test execution time separately.

Device Manager list and inventory tests share one executable. Other suites still
compile separately when they replace the same service with different fake types.
Their compiled code cannot be shared without changing those test boundaries.

The standalone startup, session, and recovery executables use
`withMainSerialExecutor` from swift-concurrency-extras to control task scheduling.
Its executor override is global, so keep it out of parallel Xcode test suites.

All native suites share observation and signal helpers in
`Snap-OIntegrationTests/AsyncTestSupport.swift`. Standalone gates live in
`StandaloneTests/Support/TestGate.swift`.
Their actors notify state changes instead of polling counters. History tests
consume repository updates and inject operation failures; deadline mechanics have
separate fake-clock coverage.

### Capture refactor test migration

The current preview checks use the shared owners. They do not run a saved copy of the old implementation.

| Previous checks | Current checks |
| --- | --- |
| Session readiness, formats, streaming time, cancellation | `LivePreviewSessionStateTests`, `SharedPreviewVideoTests` |
| Boot polling, emulator density, physical wake, cancellation during setup | `PreviewSetupTests` |
| Shared touch settings, live preference changes, timeouts, partial writes, repeated release | `TouchSettingTests` |
| Independent windows, connection replacement, final cleanup | `SharedLivePreviewTests` |
| Video restart, bounded retries, stable-stream recovery | `PreviewVideoTests` |
| Window visibility delivery, callback replacement, and stale notifications | `WindowVisibilityTests` in `test-preview-input.sh` |
| Attachment hide/show, remount, repeated close | `LivePreviewAttachmentTests` |
| Clipboard focus, late messages, remount, close | `LivePreviewClipboardTests` |
| Old view discarding the current keyboard's work | `test-live-preview-frame-export.sh --ownership-only` |
| Capture results, per-device failures, recording cleanup | `test-recording.sh` |
| Pane selection, pending review, background finalization, window visibility | `CapturePaneTests` in `test-media-lifetime.sh` |
| Only the displayed device has a preview attachment; thumbnails use snapshots | `CapturePaneTests` in `test-media-lifetime.sh` |
| Thumbnail refresh, cached images, and selection changes | `LivePreviewThumbnailTests` in `Snap-OUnitTests` |
| Next-device selection, wraparound, batch order before new devices | Three-device cases in `CapturePaneTests` |
| Startup mode, queued command order, device readiness, saved selection | `CaptureStartupTests` in `test-media-lifetime.sh` |
| Unused windows and shutdown through pending cleanup | `WorkspaceLifetimeTests` in `test-media-lifetime.sh` |
| Native hidden-window reuse, remount and close | `WorkspaceLifetimeTests` with `test-media-lifetime.sh --windows` |
| Repeated termination, deadline reply and late cleanup | `AppTerminationTests` in `test-app-runtime.sh` |
| File-drop lifetime, remount, and independent window transfers | `FileDropTests` in `test-preview-input.sh` |
| Control actions, remount and attachment close | `EmulatorControlsTests` in `Snap-OIntegrationTests` |
| Pending screenshots and key commands, stale results | `PreviewRequestTests` in `test-preview-input.sh` |
| Superseded device-open requests, late errors, close | `CapturePaneTests.closeJoinsSupersededDeviceOpen` |
| Saving blocks new captures; old callbacks cannot replace a new review | `CapturePaneTests` |
| History deletion, window-local selection, fixed export edits | `CaptureReviewOwnershipTests` |
| Deleting selected history returns to live with or without devices | `CapturePaneTests.deletingSelectedHistoryItemReturnsToLive` |
| Rotation writes, restoration, cancellation and emulator behavior | `LivePreviewRotationTests` |

The old session harness expected a separate stream and keyboard for each preview.
The new tests require shared resources and reject input from old views.
The old global capture reservation has also been replaced.
Recording tests require independent devices and a single recording per emulator connection.

`test-startup-capture.sh --connections-only` runs the current input/setup suite.
`--sessions-only` adds the current video suite.
`--controllers-only` and `--modes-only` run the current pane/media checks without windows.
The default runs the two window checks and the shared-video suite. CI runs runtime,
input, and headless pane checks separately.
The old startup, controller, mode and review test files have been removed.
The table maps their supported workflows to checks against the current owners.
Close waits for cancelled device-open requests; late progress and errors cannot replace the current selection.
A failed device-open request keeps its target for retry. Cancel restores the previous content.
Starting a new capture cancels the request and rejects any late result.
An accepted save blocks new captures until it finishes.
History changes from another window do not rewrite this review's selection.
Export requests keep their crop and trim values when later edits change.

Some old expectations changed with the approved design:

- Capture admission is per device, with no global capture slot.
- Command callers no longer own a cancellable task. The pane owns pending commands until they run or close drops them.
- Each failed device updates its own batch item. It does not abort healthy recordings.
- Stop opens review with pending items. Return to Live lets finalization finish in the background.
- Deleting the selected saved item returns to live, even with no connected device.
- Deleting history leaves unsaved review items alone.

The review's existing history task remembers the last selection it wrote.
It writes again only when its own selection changes, including when pending media becomes ready.
This needs no extra observer or owner.
New results stay visible while history refreshes.
The deletion filter hides only sources confirmed missing by the current history check.
`CaptureReviewOwnershipTests.arrivingMediaStaysVisibleWhileHistoryRefreshes` covers a result arriving after an older history snapshot.
The legacy attachment fixture has been removed. File-drop and control tests use the shared service.
Command-routing and thumbnail checks now run only in `Snap-OUnitTests`; the redundant
`test-preview-lifetime.sh` runner was removed.

## Framework and transport boundaries

Use real I/O only when that I/O is the behavior under test. Examples include ADB
framing and connection teardown, kernel socket deadlines, file ownership, and view
mounting or layout. Keep those tests small. Use framework completion callbacks
or async APIs where available. Test video settings, timestamps, and recovery with
controlled metadata and fake writers; do not invoke codecs or media export.

The remaining integration checks have specific boundary requirements:

| Checks | Why real I/O remains |
| --- | --- |
| ADB framing, socket transfer, cancellation, and socket deadlines | Verify the transport adapter against actual descriptor behavior. |
| File retention, atomic replacement, sandbox access, and discard | Verify Snap-O preserves user files across failures. |
| AppKit focus, Escape, menus, window mounting, and occlusion | Verify native event routing and view/window lifecycle. |
| Frontend ZIP validation | Verify archive entry handling, traversal rejection, and expansion limits. |

Keep command parsing, retry rules, selection, and result handling in unit tests even
when nearby code needs one of these checks. Do not add a real service merely to
produce input for a state assertion.

The former physical-device video smoke test is covered by controlled shared-source
and recording-writer tests. Device playback remains a manual check.

CI runs both the Xcode test target and the standalone scripts in
`.github/workflows/mac.yml`. The Xcode target does not include the standalone
suites. Use the local selection guidance above instead of repeating all CI checks.
`scripts/test-capture-history.sh` covers the additional history tests.

### File-transfer unit and integration tests

`DeviceFileCommandTests` covers file-command parsing, quoting, and policy in the unit target.
`ADBFileTransferTests` retains the file-drop UI state check.

`ADBFileTransferIntegrationTests` uses real socket pairs and temporary files to
check upload bytes, protocol framing, and device error responses. It is opt-in:

```sh
TEST_RUNNER_SNAPO_FILE_TRANSFER_INTEGRATION=1 xcodebuild test-without-building \
  -xctestrun "$SNAPO_DERIVED_DATA/Build/Products/"Snap-OIntegrationTests_*.xctestrun \
  -destination 'platform=macOS' \
  -only-testing:Snap-OIntegrationTests/ADBFileTransferIntegrationTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

The device cases additionally require `SNAPO_RESTRICTED_DEVICE` or
`SNAPO_FILE_TRANSFER_DEVICE` in the test process environment.

### Remaining app-hosted test boundaries

Moving a test must preserve its behavior checks. Do not replace the code under test with a stub,
increase timeouts, or weaken assertions to make a migration pass.

- Preview retry, session readiness, density, screenshot deadlines, capture conflicts, playback seeks,
  file-command rules, and video-packet parsing now run in `Snap-OUnitTests` with the same production sources.
- View mounting, native focus, menus, and window visibility still need app-hosted checks.
- Socket descriptor ownership has focused native checks. Media export uses fake results.
- Some clipboard, pointer, tool policy, and file-drop state tests could also run headlessly.
  Their source files still couple those rules to transport or view code. Separate those dependencies
  before moving the tests; do not compile the whole app or add fake production types to the unit target.
