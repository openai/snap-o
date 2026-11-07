@preconcurrency import AVFoundation
import Clocks
import Dependencies
import DependenciesTestSupport
import Foundation
import Observation
import Testing

@MainActor
@Suite(.dependency(\.continuousClock, TestClock()))
struct PreviewSetupTests {
  @Test
  func emulatorFramesStartBeforeBootAndGainDensityLater() async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    let fixture = try Fixture()
    fixture.probe.bootReady = false
    fixture.probe.densityFailures = 1
    let attachment = fixture.attach()
    try await waitForState { fixture.source.starts == 1 && fixture.probe.bootQueries == 1 }
    #expect(attachment.preview?.display?.densityScale == nil)
    #expect(attachment.preview?.inputReady == false)
    fixture.probe.bootReady = true
    await clock.advance(by: .seconds(1))
    try await waitForState { fixture.probe.densityQueries == 1 }
    #expect(attachment.preview?.inputReady == false)
    await clock.advance(by: .seconds(1))
    try await waitForState { attachment.preview?.inputReady == true }
    #expect(attachment.preview?.display?.densityScale == 3)
    #expect(fixture.source.starts == 1)
    await fixture.close()
    #expect(fixture.probe.writes == [true, false])
    try await clock.checkSuspension()
  }

  @Test(arguments: [false, true])
  func physicalVideoWaitsForWakeButToleratesWakeFailure(fails: Bool) async throws {
    let fixture = try Fixture(serial: "phone")
    let gate = TestGate()
    fixture.probe.wakeGate = gate
    fixture.probe.failsWake = fails
    let attachment = fixture.attach()
    await gate.waitUntilEntered()
    #expect(fixture.source.starts == 0)
    await gate.open()
    try await waitForState { attachment.preview?.inputReady == true && fixture.source.starts == 1 }
    #expect(fixture.probe.keyEvents == ["KEYCODE_WAKEUP"])
    #expect(fixture.probe.densityQueries == 0)
    await fixture.close()
  }

  @Test
  func closeDuringWakeJoinsTheRequestWithoutStartingVideo() async throws {
    let fixture = try Fixture(serial: "phone")
    let gate = TestGate()
    fixture.probe.wakeGate = gate
    let attachment = fixture.attach()
    await gate.waitUntilEntered()
    let finished = TestValue(false)
    let close = Task { await attachment.close()
      finished.value = true
    }
    try await waitForState { fixture.probe.wakeWasCancelled }
    #expect(!finished.value)
    await gate.open()
    await close.value
    #expect(fixture.source.starts == 0)
    #expect(fixture.probe.writes.isEmpty)
    await fixture.close()
  }

  @Test
  func bootFailuresRetryWithBoundedBackoff() async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    let fixture = try Fixture(serial: "phone")
    fixture.probe.bootReady = false
    fixture.probe.bootFailures = 2
    let attachment = fixture.attach()
    try await waitForState { fixture.probe.bootQueries == 1 }
    for (index, seconds) in [1, 2, 4, 8, 10, 10].enumerated() {
      await clock.advance(by: .seconds(seconds) - .milliseconds(1))
      #expect(fixture.probe.bootQueries == index + 1)
      if index == 5 { fixture.probe.bootReady = true }
      await clock.advance(by: .milliseconds(1))
      try await waitForState { fixture.probe.bootQueries == index + 2 }
    }
    try await waitForState { attachment.preview?.inputReady == true }
    #expect(fixture.source.starts == 1)
    await fixture.close()
    try await clock.checkSuspension()
  }

  @Test(arguments: [false, true])
  func closeCancelsBootPolling(emulator: Bool) async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    let fixture = try Fixture(serial: emulator ? "emulator-5554" : "phone")
    fixture.probe.bootReady = false
    _ = fixture.attach()
    try await waitForState { fixture.probe.bootQueries == 1 }
    await fixture.close()
    await clock.advance(by: .seconds(30))
    #expect(fixture.probe.bootQueries == 1)
    #expect(fixture.probe.writes.isEmpty)
    #expect(fixture.source.stops == fixture.source.starts)
    try await clock.checkSuspension()
  }

  @Test(arguments: [false, true])
  func closeJoinsABootRequestThatIgnoresCancellation(emulator: Bool) async throws {
    let fixture = try Fixture(serial: emulator ? "emulator-5554" : "phone")
    let gate = TestGate()
    fixture.probe.bootGate = gate
    let attachment = fixture.attach()
    await gate.waitUntilEntered()
    let finished = TestValue(false)
    let close = Task { await attachment.close()
      finished.value = true
    }
    try await waitForState { fixture.probe.bootWasCancelled }
    #expect(!finished.value)
    await gate.open()
    await close.value
    #expect(fixture.probe.writes.isEmpty)
    #expect(fixture.source.stops == fixture.source.starts)
    if !emulator { #expect(fixture.source.starts == 0) }
    await fixture.close()
  }

  @Test
  func invalidationDuringWakeCannotStartAnOldSource() async throws {
    let fixture = try Fixture(serial: "phone")
    let gate = TestGate()
    fixture.probe.wakeGate = gate
    _ = fixture.attach()
    await gate.waitUntilEntered()
    fixture.target.invalidate()
    await gate.open()
    await fixture.close()
    #expect(fixture.source.starts == 0)
    #expect(fixture.probe.writes.isEmpty)
  }

  @Test
  func previewAndRecordingRestoreTouchesOnlyAfterTheirLastUse() async throws {
    let fixture = try Fixture()
    let first = fixture.attach()
    let second = fixture.attach()
    try await waitForState { first.preview?.inputReady == true }
    let recording = await ShowTouchesOverride.apply(
      target: fixture.target, enabled: true, using: fixture.adb
    )
    await first.close()
    #expect(fixture.source.stops == 0)
    await second.close()
    #expect(fixture.source.stops == 1)
    #expect(fixture.probe.writes == [true])
    await recording.restore(using: fixture.adb)
    #expect(fixture.probe.writes == [true, false])
    await fixture.close()
  }

  @Test(arguments: [false, true])
  func startupPreferenceChangesDoNotReplaceThePreview(changeDuringSetup: Bool) async throws {
    let fixture = try Fixture()
    fixture.settings.showTouchesDuringCapture = false
    let gate = TestGate()
    if changeDuringSetup { fixture.probe.settingsGate = gate }
    let startup = StartupCapturePreparation(
      screenshots: { _ in preconditionFailure("Unexpected screenshot") },
      livePreview: fixture.service
    )
    let device = Device(
      id: fixture.target.serial, model: "Test", androidVersion: "16",
      vendorModel: nil, manufacturer: nil, avdName: nil, connection: fixture.target
    )
    startup.prepare(mode: .livePreview, device: device)
    if changeDuringSetup {
      await gate.waitUntilEntered()
    } else {
      let otherWindow = fixture.attach()
      try await waitForState { otherWindow.preview?.inputReady == true }
      await otherWindow.close()
    }
    fixture.settings.showTouchesDuringCapture = true
    let claimed = try #require(startup.claimLivePreview(for: device))
    if changeDuringSetup { await gate.open() }
    try await waitForState { fixture.probe.showsTouches && claimed.preview?.inputReady == true }
    #expect(fixture.source.starts == 1 && fixture.source.stops == 0)
    #expect(fixture.probe.settingsReads == 1)
    await startup.discard()
    #expect(!claimed.isClosed)
    await claimed.close()
    #expect(!fixture.probe.showsTouches)
    await fixture.close()
  }

  @Test
  func preferenceChangesKeepTheSharedPreviewAndOriginalSetting() async throws {
    let fixture = try Fixture()
    let first = fixture.attach()
    let second = fixture.attach()
    try await waitForState { first.preview?.inputReady == true }
    let recording = await ShowTouchesOverride.apply(
      target: fixture.target, enabled: true, using: fixture.adb
    )
    fixture.settings.showTouchesDuringCapture = false
    try await waitForState { fixture.probe.writes == [true, false] }
    fixture.settings.showTouchesDuringCapture = true
    try await waitForState { fixture.probe.writes == [true, false, true] }
    #expect(fixture.source.starts == 1 && fixture.source.stops == 0)
    #expect(fixture.probe.settingsReads == 1)
    await first.close()
    await second.close()
    #expect(fixture.probe.showsTouches)
    await recording.restore(using: fixture.adb)
    #expect(!fixture.probe.showsTouches)
    await fixture.close()
  }

  @Test
  func closeJoinsAPendingPreferenceChangeBeforeRestoring() async throws {
    let fixture = try Fixture()
    let attachment = fixture.attach()
    try await waitForState { attachment.preview?.inputReady == true }
    let gate = TestGate()
    fixture.probe.writeGate = gate
    fixture.settings.showTouchesDuringCapture = false
    await gate.waitUntilEntered()
    let finished = TestValue(false)
    let close = Task { await attachment.close()
      finished.value = true
    }
    try await waitForState { attachment.isClosed }
    #expect(!finished.value)
    fixture.probe.writeGate = nil
    await gate.open()
    await close.value
    #expect(fixture.probe.writes == [true, false, false])
    #expect(fixture.source.stops == 1)
    await fixture.close()
  }

  @Test
  func closingDuringSettingsReadWaitsForRestoration() async throws {
    let fixture = try Fixture()
    let gate = TestGate()
    fixture.probe.settingsGate = gate
    let attachment = fixture.attach()
    await gate.waitUntilEntered()
    try await waitForState { fixture.source.starts == 1 }
    let finished = TestValue(0)
    let first = Task { await attachment.close()
      finished.value += 1
    }
    try await waitForState { attachment.isClosed }
    let second = Task { await fixture.service.shutdown()
      finished.value += 1
    }
    #expect(finished.value == 0)
    await gate.open()
    await first.value
    await second.value
    #expect(finished.value == 2)
    #expect(fixture.probe.writes == [true, false])
    #expect(fixture.source.stops == 1)
    await fixture.close()
  }

  @Test
  func invalidatedConnectionCannotRestoreSettingsOnItsReplacement() async throws {
    let first = try Fixture()
    let attachment = first.attach()
    try await waitForState { attachment.preview?.inputReady == true }
    first.target.invalidate()
    let replacement = try Fixture()
    let next = replacement.attach()
    try await waitForState { next.preview?.inputReady == true }
    await first.close()
    #expect(first.probe.writes == [true])
    #expect(replacement.probe.writes == [true])
    await replacement.close()
    #expect(replacement.probe.writes == [true, false])
  }

  @Test
  func metadataWithoutAConnectionCannotStartPreview() async throws {
    let fixture = try Fixture()
    let device = Device(
      id: "phone", model: "Test", androidVersion: "16",
      vendorModel: nil, manufacturer: nil, avdName: nil
    )
    #expect(fixture.service.attach(to: device) == nil)
    #expect(fixture.probe.bootQueries == 0 && fixture.source.starts == 0)
    await fixture.close()
  }

  @MainActor
  final class Fixture {
    let target: DeviceTarget
    let probe = PreviewSetupProbe()
    let source = PreviewSetupSource()
    let adb: ADBService
    let settings: AppSettings
    let service: LivePreviewService
    let suite = "PreviewSetupTests." + UUID().uuidString
    let defaults: UserDefaults

    init(serial: String = "emulator-5554") throws {
      target = DeviceTarget(serial: serial, transportID: "1")
      defaults = try #require(UserDefaults(suiteName: suite))
      settings = AppSettings(defaults: defaults)
      settings.showTouchesDuringCapture = true
      adb = ADBService(setup: probe)
      service = LivePreviewService(coordinator: CaptureCoordinator(), adb: adb, settings: settings)
      DeviceVideoSource.sources[target] = source
    }

    func attach() -> LivePreviewAttachment {
      service.attach(to: target)
    }

    func close() async {
      await service.shutdown()
      DeviceVideoSource.sources[target] = nil
      defaults.removePersistentDomain(forName: suite)
    }
  }
}

@Observable
@MainActor
final class PreviewSetupProbe {
  enum Failure: Error { case unavailable }
  var bootReady = true
  var bootFailures = 0
  var densityFailures = 0
  var failsWake = false
  var failsRead = false
  var failsWrite = false
  var bootGate: TestGate?
  var wakeGate: TestGate?
  var settingsGate: TestGate?
  var writeGate: TestGate?
  var bootWasCancelled = false
  var wakeWasCancelled = false
  var bootQueries = 0
  var densityQueries = 0
  var settingsReads = 0
  var keyEvents: [String] = []
  var writes: [Bool] = []
  var timeouts: [Duration?] = []
  var showsTouches = false

  func readBoot() async throws -> Bool {
    bootQueries += 1
    await withTaskCancellationHandler {
      await bootGate?.wait()
    } onCancel: {
      Task { @MainActor in self.bootWasCancelled = true }
    }
    if bootFailures > 0 { bootFailures -= 1
      throw Failure.unavailable
    }
    return bootReady
  }

  func readDensity() throws -> Double {
    densityQueries += 1
    if densityFailures > 0 { densityFailures -= 1
      throw Failure.unavailable
    }
    return 3
  }

  func wake(_ key: String) async throws {
    keyEvents.append(key)
    await withTaskCancellationHandler {
      await wakeGate?.wait()
    } onCancel: {
      Task { @MainActor in self.wakeWasCancelled = true }
    }
    if failsWake { throw Failure.unavailable }
  }

  func readTouches(timeout: Duration?) async throws -> Bool {
    settingsReads += 1
    timeouts.append(timeout)
    await settingsGate?.wait()
    if failsRead { throw Failure.unavailable }
    return showsTouches
  }

  func writeTouches(_ value: Bool, timeout: Duration?) async throws {
    timeouts.append(timeout)
    await writeGate?.wait()
    writes.append(value)
    showsTouches = value
    if failsWrite { throw Failure.unavailable }
  }
}

@Observable
@MainActor
final class PreviewSetupSource: LivePreviewFrameSource {
  let hasIndependentFrames = true
  var starts = 0
  var stops = 0

  func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) {
    starts += 1
    var format: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
      width: 2, height: 3, extensions: nil, formatDescriptionOut: &format
    )
    guard status == noErr, let format else { preconditionFailure("Could not create test video format") }
    deliver(.format(format))
  }

  func stop() {
    stops += 1
  }

  func waitUntilStopped() async {}
}
