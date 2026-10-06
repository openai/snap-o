import Clocks
import DependenciesTestSupport
import Foundation
import Testing

@Suite("File drop lifetime", .dependency(\.continuousClock, TestClock()))
@MainActor
struct FileDropTests {
  private func device(_ target: DeviceTarget?) -> Device {
    Device(
      id: "file-device", model: "Test phone", androidVersion: "16", vendorModel: nil,
      manufacturer: nil, avdName: nil, connection: target
    )
  }

  private func source() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
    try Data(repeating: 1, count: 100).write(to: url)
    return url
  }

  @Test
  func unavailableConnectionRejectsDrop() async {
    let url = URL(fileURLWithPath: "/tmp/synthetic.apk")
    let missing = DeviceFileDrop(device: device(nil))
    #expect(!missing.receive([url]))
    let target = DeviceTarget(serial: "file-device", transportID: "1")
    let connected = DeviceFileDrop(device: device(target))
    target.invalidate()
    #expect(!connected.receive([url]))
    await connected.shutdown()
  }

  @Test
  func mixedAPKDropCanBeCancelledBeforeTransfer() async {
    let model = DeviceFileDrop(device: device(DeviceTarget(serial: "file-device", transportID: "1")))
    let apk = URL(fileURLWithPath: "/tmp/synthetic.apk")
    let text = URL(fileURLWithPath: "/tmp/synthetic.txt")
    #expect(model.receive([apk, text, apk]))
    #expect(model.asksToInstall && model.pendingFiles == [apk, text])
    #expect(model.installMessage == "1 other file will copy to Downloads.")
    model.cancel()
    #expect(model.canAcceptDrop && model.pendingFiles.isEmpty)
    await model.shutdown()
  }

  @Test
  func oldViewDisappearanceDoesNotCancelCurrentTransfer() async throws {
    let target = DeviceTarget(serial: "file-device", transportID: "1")
    let probe = FileTransferProbe()
    let gate = TestGate()
    await probe.configure(gate: gate)
    let model = DeviceFileDrop(device: device(target), adb: ADBClient(probe: probe))
    let fixture = try SharedPreviewTestSupport.Fixture()
    fixture.makeFileDrop = { _ in model }
    let attachment = try #require(fixture.service.attach(to: device(target)))
    let oldView = UUID()
    attachment.mount(oldView)
    attachment.mount(UUID())
    let url = try source()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(model.receive([url]))
    await waitForActorTestState { await gate.waitCount == 1 }
    attachment.unmount(oldView)
    await gate.open()
    await waitForObservedTestState { !model.isBusy }
    #expect(model.status == "1 copied to Downloads")
    #expect(await probe.wasCancelled == false)
    await attachment.close()
    await fixture.close()
  }

  @Test
  func cancellationEndsConflictPrompt() async throws {
    let probe = FileTransferProbe()
    await probe.configure(exists: true)
    let model = DeviceFileDrop(
      device: device(DeviceTarget(serial: "file-device", transportID: "1")), adb: ADBClient(probe: probe)
    )
    let url = try source()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(model.receive([url]))
    await waitForObservedTestState { model.asksAboutConflict }
    await model.shutdown()
    #expect(!model.asksAboutConflict && !model.isBusy && !model.canAcceptDrop)
    #expect(await probe.targets.isEmpty)
  }

  @Test(arguments: [false, true])
  func attachmentJoinsTransferCleanup(invalidates: Bool) async throws {
    let target = DeviceTarget(serial: "file-device", transportID: "1")
    let probe = FileTransferProbe()
    let gate = TestGate()
    await probe.configure(gate: gate)
    let model = DeviceFileDrop(device: device(target), adb: ADBClient(probe: probe))
    let fixture = try SharedPreviewTestSupport.Fixture()
    fixture.makeFileDrop = { _ in model }
    let attachment = try #require(fixture.service.attach(to: device(target)))
    let url = try source()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(model.receive([url]))
    await waitForActorTestState { await gate.waitCount == 1 }
    if invalidates { target.invalidate() }
    let finished = TestValue(false)
    let stop = Task { await attachment.close()
      finished.value = true
    }
    await waitForActorTestState { await probe.wasCancelled }
    #expect(!finished.value, "Attachment teardown must join the transfer's cleanup")
    #expect(!model.canAcceptDrop)
    await gate.open()
    await stop.value
    #expect(!model.isBusy && finished.value)
    #expect(await probe.targets == [target])
    let replacement = DeviceTarget(serial: target.serial, transportID: "2")
    #expect(await probe.targets.contains(replacement) == false)
    await fixture.close()
  }

  @Test
  func anotherWindowCanTransferWhileOldWindowCleanupWaits() async throws {
    let target = DeviceTarget(serial: "file-device", transportID: "1")
    let firstProbe = FileTransferProbe()
    let gate = TestGate()
    await firstProbe.configure(gate: gate)
    let firstDrop = DeviceFileDrop(device: device(target), adb: ADBClient(probe: firstProbe))
    let secondDrop = DeviceFileDrop(device: device(target), adb: ADBClient(probe: FileTransferProbe()))
    var drops = [firstDrop, secondDrop]
    let fixture = try SharedPreviewTestSupport.Fixture()
    fixture.makeFileDrop = { _ in drops.removeFirst() }
    let first = try #require(fixture.service.attach(to: device(target)))
    let second = try #require(fixture.service.attach(to: device(target)))
    try await fixture.ready(second)
    let url = try source()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(firstDrop.receive([url]))
    await gate.waitUntilEntered()
    let finished = TestValue(false)
    let closing = Task { await first.close()
      finished.value = true
    }
    await waitForActorTestState { await firstProbe.wasCancelled }
    #expect(secondDrop.receive([url]))
    try await waitForState { secondDrop.status == "1 copied to Downloads" }
    #expect(!finished.value && !second.isClosed)
    #expect(fixture.sources.count == 1 && fixture.sources[0].stops == 0)
    await gate.open()
    await closing.value
    #expect(fixture.sources[0].stops == 0)
    await second.close()
    #expect(fixture.sources[0].stops == 1)
    await fixture.close()
  }

  @Test
  func transferRejectsOverlappingDropsAndRetainsItsConnection() async throws {
    let target = DeviceTarget(serial: "file-device", transportID: "1")
    let probe = FileTransferProbe()
    let gate = TestGate()
    await probe.configure(gate: gate)
    let model = DeviceFileDrop(device: device(target), adb: ADBClient(probe: probe))
    let url = try source()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(model.receive([url]))
    await waitForActorTestState { await gate.waitCount == 1 }
    #expect(!model.receive([url]) && model.isBusy)
    await probe.report(25, for: 0)
    await waitForObservedTestState { model.progress == 0.25 }
    await gate.open()
    await waitForObservedTestState { !model.isBusy }
    #expect(model.status == "1 copied to Downloads" && model.progress == nil)
    #expect(await probe.targets == [target])
    await model.shutdown()
  }
}
