# Native test synchronization

CI uses Xcode 26.4.1. Use the same version for local validation; Xcode 26.1.1
fails to compile the locked dependency test support. The app still targets macOS 26+.

CI builds the app and packages in Debug. The custom Local configuration makes
Swift packages use release optimization, which slows fresh test builds.
CI resolves locked packages during that build, then runs the generated `.xctestrun`
file directly. The test step does not need to resolve packages again.

Test one behavior at a time. Use controlled inputs for everything outside that
behavior, including discovery, device operations, framework results, and time.

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
- Hold fake operations with continuations. Signal when the operation enters the gate.
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

## Local test selection

Choose tests for the changed behavior and its callers, not just the changed filename.
Shared lifecycle or transport changes need broader coverage than a toolbar layout change.
Use the smallest set that covers the affected behavior. Do not rerun successful checks
without a relevant source, dependency, build-input change, or unresolved failure.
An unchanged patch with recorded validation does not need another full local run.

For Swift code changes, build the app and lint the changed files. A `build` or
`build-for-testing` action compiles code without running the test app.
Documentation-only changes need a content and link review, not an app build.

Use these existing console-only suites when their coverage matches the change.
Paths are relative to `app-macos/`:

| Changed behavior | Local check |
| --- | --- |
| Recording service failures, deadlines, and cleanup | `scripts/test-recording.sh` |
| Emulator frame conversion, launch arguments, and discovery parsing | `scripts/test-emulator-preview.sh` |
| Device discovery and tool reconnection | `scripts/test-tool-recovery.sh` |
| Capture export file permissions | `scripts/test-capture-export.sh` |
| Device inventory, emulator commands, and authentication policy | `Tests/DeviceManager/test.sh`, with `SNAPO_DERIVED_DATA` and `SNAPO_TEST_ADB` unset |

The Device Manager command above skips signed XPC integration and real ADB startup.
Keep those omissions explicit; a console-only pass does not cover them.
For recording and recovery, reuse a matching `build-for-testing` output through
`SNAPO_DERIVED_DATA` and set `SNAPO_TEST_CONFIGURATION` to that build's configuration.

### Checks that affect the desktop

Run these locally only when the user explicitly requests or approves them.
Otherwise, use applicable console-only checks and leave the remaining coverage to CI.

- `Snap-OTests` has Snap-O as its `TEST_HOST`. Both `test` and
  `test-without-building` launch the app, even with `-only-testing`.
  `scripts/test-tool-selection.sh` uses this target too.
- `scripts/test-startup-capture.sh` includes session tests that open AppKit windows.
- `scripts/test-live-preview-frame-export.sh` creates test windows and sends events.
- `Tests/DeviceManager/test.sh` also launches signed test apps when
  `SNAPO_DERIVED_DATA` is set. `Tests/AndroidHostSecurity/test.sh` does the same when
  given a built helper or `SNAPO_DERIVED_DATA`.

A standalone executable is not necessarily a console-only test. Inspect its setup
before selecting an unlisted suite. When a local app-hosted run is approved, filter
it to the relevant suites or test methods instead of running the whole target.

For toolbar layout or view wiring, a build and changed-file lint are the default
local checks. They do not verify interaction behavior; report that coverage as
pending unless an approved UI check or the relevant CI tests cover it.

The full native CI run remains the submission check. Report which local checks ran,
which coverage was deferred, and the actual CI result when available.

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
| Local Web Inspector actions | An object that records supported selector calls |
| Playback scrubbing | Seek queue requests and explicit completions |
| Recording collection and cleanup | A controlled recording loader |
| Rename focus | A manually executed focus callback |
| Emulator launch arguments and JWT claims | Configuration values, a fixed signing time, and a test key |

The app uses `Dependencies`; the Xcode tests also use `DependenciesTestSupport`.
The startup/session, recording, and recovery scripts reuse compiled package
products through `scripts/test-swift-packages.sh`.
Set `SNAPO_DERIVED_DATA` to an existing `build-for-testing` output to avoid rebuilding;
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
`Snap-OTests/AsyncTestSupport.swift`. Standalone gates live in
`Tests/Support/TestGate.swift`.
Their actors notify state changes instead of polling counters. History tests
consume repository updates and inject operation failures; deadline mechanics have
separate fake-clock coverage.

## Framework and transport boundaries

Use real I/O only when that I/O is the behavior under test. Examples include ADB
framing and connection teardown, kernel socket deadlines, video pixels and file
formats, and view mounting or layout. Keep those tests small. Use framework
completion callbacks or async APIs where available; video fixtures use the
writer's async receiver rather than polling readiness.

The physical-device preview/recording smoke test remains opt-in through
`SNAPO_VIDEO_DEVICE_ID`. It is separate from deterministic state coverage.

CI runs both the Xcode test target and the standalone scripts in
`.github/workflows/mac.yml`. The Xcode target does not include the standalone
suites. Use the local selection guidance above instead of repeating all CI checks.
`scripts/test-capture-history.sh` covers the additional history tests.

### File-transfer unit and integration tests

`ADBFileTransferTests` covers file-command parsing, quoting, policy, and UI state.

`ADBFileTransferIntegrationTests` uses real socket pairs and temporary files to
check upload bytes, protocol framing, and device error responses. It is opt-in:

```sh
TEST_RUNNER_SNAPO_FILE_TRANSFER_INTEGRATION=1 xcodebuild test-without-building \
  -xctestrun "$SNAPO_DERIVED_DATA/Build/Products/"*.xctestrun \
  -destination 'platform=macOS' \
  -only-testing:Snap-OTests/ADBFileTransferIntegrationTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

The device cases additionally require `SNAPO_RESTRICTED_DEVICE` or
`SNAPO_FILE_TRANSFER_DEVICE` in the test process environment.
