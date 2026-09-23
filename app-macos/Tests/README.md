# Native test synchronization

Use unit tests for state transitions. Inject discovery, device operations, and time.
The test should decide when an operation succeeds, fails, or is canceled.

- Await an operation's task before checking its final result.
- Wait for observable state with `waitForState` in the Xcode tests. Every value
  read by its condition must support Observation.
- Hold fake operations with continuations. Signal when the operation enters the gate.
- Advance a fake timer only after the operation has registered its wait.
- Check canceled or superseded results after the original task finishes.
- Use test time limits to bound failures, not to synchronize successful tests.

Do not use a fixed number of `Task.yield()` calls or a short sleep to settle work.
A fast local run does not establish that those waits are safe on CI.
Do not mock the model whose behavior the test is checking.

## Timing audit

The Xcode state tests now use completion signals in these areas:

| Area | Synchronization |
| --- | --- |
| Tool discovery and app launch | Task completion, snapshot publication, and a manual timer |
| Tool host discovery state | Observable state and controlled replies; periodic polling suspended |
| Preview lifecycle and recovery | Observable state and fake startup, stop, and reconnect gates |
| Pointer cancellation during rotation lookup | Notification that the fake lookup is suspended |
| Superseded thumbnail requests | Controlled screenshot replies and task completion |

Keep focused integration coverage for real boundaries:

| Area | Why it needs integration coverage |
| --- | --- |
| WebKit navigation and inspector windows | WebKit callbacks and window behavior |
| SwiftUI capture layout and thumbnail appearance | View mounting, task identity, and cancellation on dismissal |
| Video thumbnail mirroring and frame export | AVFoundation decoding and displayed pixel buffers |
| ADB socket timeouts, clipboard cancellation, and HTTP transport | Blocking I/O, framing, timeout enforcement, and connection teardown |
| Emulator console and helper processes | Socket protocol and process lifetime |

The audit also found further conversion candidates. These are not covered by the
state-test changes above:

- The thumbnail picker test uses short sleeps after selection and visibility changes.
  Extract its request policy for unit coverage, retaining one view lifecycle test.
- Standalone startup, capture mode, and live preview session tests already use fake
  device services, but some poll counters or yield repeatedly. Give those fakes
  explicit request and cancellation signals before replacing the waits.
- Tool recovery tests mix socket integration with discovery policy. Keep protocol
  tests on sockets; move cache, retry, and cooldown decisions to controlled inputs.
- Recording readiness and Device Manager tests poll framework or process state.
  Use callbacks where the underlying framework exposes them.

Do not remove integration assertions merely to eliminate a timing wait. First
identify the behavior, then give it deterministic unit coverage or a real event.
