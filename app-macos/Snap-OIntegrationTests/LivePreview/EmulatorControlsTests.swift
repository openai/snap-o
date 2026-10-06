import Clocks
import Dependencies
import DependenciesTestSupport
import Foundation
import Observation
#if !SNAPO_STANDALONE_TESTS
@testable import Snap_O
#endif
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct EmulatorControlsTests {
  @Test
  func actionRefreshesControlsAndNotifiesOnce() async throws {
    let fixture = ControlsFixture()
    let owner = fixture.makeOwner()
    owner.appear(viewID: UUID())
    try await waitForState { owner.controls != nil }
    let changed = TestValue(0)
    owner.perform(.open) { changed.value += 1 }
    owner.perform(.closed) { changed.value += 1 }
    try await waitForState { fixture.loads == 2 && owner.pendingAction == nil }
    #expect(fixture.actions == [.open])
    #expect(changed.value == 1)
    #expect(owner.failure == nil)
    await owner.shutdown()
    #expect(fixture.closes == 1)
  }

  @Test
  func oldViewCannotStopNewMount() async throws {
    let fixture = ControlsFixture()
    let owner = fixture.makeOwner()
    let old = UUID()
    let current = UUID()
    owner.appear(viewID: old)
    try await waitForState { owner.controls != nil }
    owner.appear(viewID: current)
    owner.disappear(viewID: old)
    try await waitForState { fixture.loads == 2 && owner.controls != nil }
    #expect(fixture.closes == 1)
    owner.appear(viewID: current)
    #expect(fixture.loads == 2)
    await owner.shutdown()
    #expect(fixture.closes == 2)
  }

  @Test
  func remountWaitsForOldActionAndRejectsItsResult() async throws {
    let fixture = ControlsFixture()
    let gate = TestSuspension()
    fixture.actionGate = gate
    let owner = fixture.makeOwner()
    owner.appear(viewID: UUID())
    try await waitForState { owner.controls != nil }
    let changed = TestValue(0)
    owner.perform(.open) { changed.value += 1 }
    await gate.waitUntilStarted()
    owner.disappear()
    owner.appear(viewID: UUID())
    #expect(fixture.closes == 0 && fixture.loads == 1)
    gate.resume()
    try await waitForState { fixture.loads == 2 && owner.controls != nil }
    #expect(gate.wasCancelled && changed.value == 0)
    #expect(fixture.closes == 1 && owner.failure == nil)
    await owner.shutdown()
  }

  @Test(.dependency(\.continuousClock, TestClock()))
  func attachmentCloseJoinsPendingControl() async throws {
    let fixture = ControlsFixture()
    let gate = TestSuspension()
    fixture.actionGate = gate
    let owner = fixture.makeOwner()
    let preview = try SharedPreviewTestSupport.Fixture()
    let created = preview.service.attach(to: preview.device(fixture.target)) { _ in owner }
    let attachment = try #require(created)
    owner.appear(viewID: UUID())
    try await waitForState { owner.controls != nil }
    owner.perform(.open) {}
    await gate.waitUntilStarted()
    let completed = TestValue(false)
    let waiter = Task { await attachment.close()
      completed.value = true
    }
    try await waitForState { attachment.isClosed }
    #expect(owner.controls == nil && owner.pendingAction == nil)
    #expect(fixture.closes == 0)
    owner.appear(viewID: UUID())
    owner.perform(.closed) {}
    #expect(fixture.actions == [.open])
    gate.resume()
    await waiter.value
    await attachment.close()
    #expect(completed.value && gate.wasCancelled && fixture.closes == 1)
    await preview.close()
  }

  @Test
  func shutdownJoinsInitialLoadAndSuppressesLateData() async {
    let fixture = ControlsFixture()
    let gate = TestSuspension()
    fixture.loadGate = gate
    let owner = fixture.makeOwner()
    owner.appear(viewID: UUID())
    await gate.waitUntilStarted()
    let stop = owner.beginShutdown()
    #expect(fixture.closes == 0)
    gate.resume()
    await stop.value
    #expect(owner.controls == nil && fixture.closes == 1)
    await owner.shutdown()
    owner.appear(viewID: UUID())
    #expect(fixture.loads == 1 && fixture.closes == 1)
  }

  @Test
  func retryUsesClockAndStopsWithOwner() async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let fixture = ControlsFixture()
      fixture.failLoads = true
      let owner = fixture.makeOwner()
      owner.appear(viewID: UUID())
      try await waitForState { fixture.loads == 1 }
      await clock.advance(by: .seconds(1))
      #expect(fixture.loads == 2)
      await clock.advance(by: .seconds(2))
      #expect(fixture.loads == 3)
      await clock.advance(by: .seconds(4))
      #expect(fixture.loads == 4)
      await clock.advance(by: .seconds(5))
      #expect(fixture.loads == 5)
      await owner.shutdown()
      try await clock.checkSuspension()
      #expect(fixture.closes == 1)
    }
  }

  @Test
  func actionFailureCanBeDismissedAndRetried() async throws {
    let fixture = ControlsFixture()
    fixture.failAction = true
    let owner = fixture.makeOwner()
    owner.appear(viewID: UUID())
    try await waitForState { owner.controls != nil }
    owner.perform(.open) {}
    try await waitForState { owner.failure != nil }
    #expect(owner.failure?.action == .open && owner.pendingAction == nil)
    owner.dismissFailure()
    fixture.failAction = false
    owner.perform(.open) {}
    try await waitForState { fixture.loads == 2 }
    #expect(fixture.actions == [.open, .open] && owner.failure == nil)
    await owner.shutdown()
  }
}

@Observable
@MainActor
private final class ControlsFixture {
  let target = DeviceTarget(serial: "emulator-5554", transportID: "42")
  var loads = 0
  var closes = 0
  var actions: [EmulatorControlAction] = []
  var loadGate: TestSuspension?
  var actionGate: TestSuspension?
  var failLoads = false
  var failAction = false
  private enum Failure: Error { case unavailable }

  func makeOwner() -> EmulatorControlsController {
    EmulatorControlsController(target: target, load: { [self] target in
      #expect(target == self.target)
      loads += 1
      try await loadGate?.wait()
      if failLoads { throw Failure.unavailable }
      return EmulatorControls(avdPath: "/Synthetic.avd", commands: "posture", properties: [:])
    }, apply: { [self] target, path, action in
      #expect(target == self.target && path == "/Synthetic.avd")
      actions.append(action)
      try await actionGate?.wait()
      if failAction { throw Failure.unavailable }
    }, close: { [self] in closes += 1 })
  }
}
