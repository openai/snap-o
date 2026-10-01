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
Do not send probe gestures or trigger repeated discovery to detect readiness.
Do not mock the model whose behavior the test is checking.

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
CI saves the cache after all standalone scripts finish.
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

Run both the Xcode test target and the standalone scripts in
`.github/workflows/mac.yml`. The Xcode target does not include the standalone
suites. `scripts/test-capture-history.sh` covers the additional history tests.
