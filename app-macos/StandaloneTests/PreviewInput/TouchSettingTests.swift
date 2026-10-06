import Clocks
import Dependencies
import DependenciesTestSupport
import Foundation
import Testing

@MainActor
@Suite(.dependency(\.continuousClock, TestClock()))
struct TouchSettingTests {
  @Test(arguments: [false, true], [false, true])
  func lastReleaseRestoresOriginalValue(original: Bool, requested: Bool) async throws {
    let fixture = try PreviewSetupTests.Fixture()
    fixture.probe.showsTouches = original
    let lease = await ShowTouchesOverride.apply(target: fixture.target, enabled: requested, using: fixture.adb)
    await lease.restore(using: fixture.adb)
    #expect(fixture.probe.writes == (original == requested ? [] : [requested, original]))
    await fixture.close()
  }

  @Test(arguments: [false, true], [false, true])
  func latestPreferenceLastsUntilBothUsersLeave(original: Bool, releaseNewestFirst: Bool) async throws {
    let fixture = try PreviewSetupTests.Fixture()
    fixture.probe.showsTouches = original
    let first = await ShowTouchesOverride.apply(target: fixture.target, enabled: original, using: fixture.adb)
    let second = await ShowTouchesOverride.apply(target: fixture.target, enabled: !original, using: fixture.adb)
    await (releaseNewestFirst ? second : first).restore(using: fixture.adb)
    #expect(fixture.probe.writes == [!original])
    await (releaseNewestFirst ? first : second).restore(using: fixture.adb)
    #expect(fixture.probe.writes == [!original, original])
    await fixture.close()
  }

  @Test
  func releasedLeaseCannotChangeAnotherUsersSetting() async throws {
    let fixture = try PreviewSetupTests.Fixture()
    let first = await ShowTouchesOverride.apply(target: fixture.target, enabled: true, using: fixture.adb)
    let second = await ShowTouchesOverride.apply(target: fixture.target, enabled: true, using: fixture.adb)
    await first.restore(using: fixture.adb)
    await first.setEnabled(false, using: fixture.adb)
    #expect(fixture.probe.writes == [true])
    await second.restore(using: fixture.adb)
    #expect(fixture.probe.writes == [true, false])
    await fixture.close()
  }

  @Test
  func failedReadDoesNotWriteAndPartialWriteStillRestores() async throws {
    let unreadable = try PreviewSetupTests.Fixture()
    unreadable.probe.failsRead = true
    let skipped = await ShowTouchesOverride.apply(target: unreadable.target, enabled: true, using: unreadable.adb)
    await skipped.restore(using: unreadable.adb)
    #expect(unreadable.probe.writes.isEmpty)
    await unreadable.close()

    let partial = try PreviewSetupTests.Fixture()
    partial.probe.failsWrite = true
    let lease = await ShowTouchesOverride.apply(target: partial.target, enabled: true, using: partial.adb)
    await lease.restore(using: partial.adb)
    #expect(partial.probe.writes == [true, false])
    await partial.close()
  }

  @Test
  func failedPreferenceUpdateStillRestoresTheOriginalValue() async throws {
    let fixture = try PreviewSetupTests.Fixture()
    fixture.probe.failsWrite = true
    let first = await ShowTouchesOverride.apply(target: fixture.target, enabled: true, using: fixture.adb)
    let second = await ShowTouchesOverride.apply(target: fixture.target, enabled: false, using: fixture.adb)
    await first.restore(using: fixture.adb)
    await second.restore(using: fixture.adb)
    #expect(fixture.probe.writes == [true, false, false])
    await fixture.close()
  }

  @Test(arguments: [false, true])
  func cancelledOrTimedOutAcquisitionRetainsItsCleanup(cancel: Bool) async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    let fixture = try PreviewSetupTests.Fixture()
    let gate = TestGate()
    fixture.probe.settingsGate = gate
    let setup = await startTestTask {
      await ShowTouchesOverride.apply(target: fixture.target, enabled: true, using: fixture.adb)
    }
    await gate.waitUntilEntered()
    if cancel { setup.cancel() } else { await clock.advance(by: .seconds(3)) }
    let lease = await setup.value
    let finished = TestValue(false)
    let close = await startTestTask { await lease.restore(using: fixture.adb)
      finished.value = true
    }
    #expect(!finished.value)
    await gate.open()
    await close.value
    #expect(fixture.probe.writes == [true, false])
    #expect(fixture.probe.timeouts.allSatisfy { $0 == .seconds(3) })
    await fixture.close()
    try await clock.checkSuspension()
  }

  @Test(arguments: [false, true])
  func repeatedReleaseJoinsRestorationDespiteCancellation(cancel: Bool) async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    let fixture = try PreviewSetupTests.Fixture()
    let lease = await ShowTouchesOverride.apply(target: fixture.target, enabled: true, using: fixture.adb)
    let gate = TestGate()
    fixture.probe.writeGate = gate
    let finished = TestValue(0)
    let first = await startTestTask { await lease.restore(using: fixture.adb)
      finished.value += 1
    }
    await gate.waitUntilEntered()
    if cancel { first.cancel() } else { await clock.advance(by: .seconds(3)) }
    let second = await startTestTask { await lease.restore(using: fixture.adb)
      finished.value += 1
    }
    #expect(finished.value == 0)
    await gate.open()
    await first.value
    await second.value
    #expect(finished.value == 2)
    #expect(fixture.probe.writes == [true, false])
    await fixture.close()
    try await clock.checkSuspension()
  }

  @Test
  func timedOutWaiterDoesNotCancelAnotherUsersSettings() async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    let fixture = try PreviewSetupTests.Fixture()
    let gate = TestGate()
    fixture.probe.settingsGate = gate
    let ownerClock = TestClock()
    let first = withDependencies { $0.continuousClock = ownerClock } operation: {
      Task { await ShowTouchesOverride.apply(target: fixture.target, enabled: true, using: fixture.adb) }
    }
    await gate.waitUntilEntered()
    let second = await startTestTask {
      await ShowTouchesOverride.apply(target: fixture.target, enabled: false, using: fixture.adb)
    }
    await clock.advance(by: .seconds(3))
    let abandoned = await second.value
    await abandoned.restore(using: fixture.adb)
    #expect(fixture.probe.writes.isEmpty)
    await gate.open()
    let active = await first.value
    let joined = await ShowTouchesOverride.apply(target: fixture.target, enabled: false, using: fixture.adb)
    await joined.restore(using: fixture.adb)
    await active.restore(using: fixture.adb)
    #expect(fixture.probe.writes == [true, false, false])
    await fixture.close()
    try await clock.checkSuspension()
    try await ownerClock.checkSuspension()
  }

  @Test
  func reacquisitionDoesNotDetachPreviousRestoration() async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    let fixture = try PreviewSetupTests.Fixture()
    let first = await ShowTouchesOverride.apply(target: fixture.target, enabled: true, using: fixture.adb)
    let gate = TestGate()
    fixture.probe.writeGate = gate
    let release = Task { await first.restore(using: fixture.adb) }
    await gate.waitUntilEntered()
    let acquire = await startTestTask {
      await ShowTouchesOverride.apply(target: fixture.target, enabled: false, using: fixture.adb)
    }
    await clock.advance(by: .seconds(3))
    let next = await acquire.value
    let finished = TestValue(false)
    let repeated = await startTestTask { await first.restore(using: fixture.adb)
      finished.value = true
    }
    #expect(!finished.value)
    await gate.open()
    await release.value
    await repeated.value
    await next.restore(using: fixture.adb)
    #expect(fixture.probe.writes == [true, false])
    await fixture.close()
    try await clock.checkSuspension()
  }
}
