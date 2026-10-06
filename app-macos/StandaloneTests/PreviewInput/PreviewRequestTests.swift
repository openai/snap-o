import Clocks
import DependenciesTestSupport
import Foundation
import Observation
import Testing

@MainActor
@Suite(.dependency(\.continuousClock, TestClock()))
struct PreviewRequestTests {
  @Test(arguments: [false, true])
  func closeJoinsPendingDeviceRequest(screenshot: Bool) async throws {
    let probe = PreviewRequestProbe()
    let gate = TestGate()
    probe.gate = gate
    let fixture = try SharedLivePreviewTests.Fixture(adb: ADBService(requests: probe))
    let attachment = fixture.service.attach(to: fixture.target())
    try await fixture.focus(attachment)
    let request = Task {
      if screenshot {
        _ = try await attachment.screenshot()
      } else {
        try await attachment.sendKey("HOME")
      }
    }
    await gate.waitUntilEntered()
    let completed = TestValue(0)
    let first = Task { await attachment.close()
      completed.value += 1
    }
    try await waitForState { probe.cancellations == 1 }
    let second = await startTestTask { await attachment.close()
      completed.value += 1
    }
    first.cancel()
    #expect(completed.value == 0)
    await #expect(throws: CancellationError.self) { _ = try await attachment.screenshot() }
    #expect(probe.targets.count == 1)
    await gate.open()
    await first.value
    await second.value
    await #expect(throws: CancellationError.self) { try await request.value }
    #expect(completed.value == 2)
    await fixture.close()
  }

  @Test
  func oldRequestCannotPublishIntoAReplacementConnection() async throws {
    let probe = PreviewRequestProbe()
    let gate = TestGate()
    probe.gate = gate
    let fixture = try SharedLivePreviewTests.Fixture(adb: ADBService(requests: probe))
    let target = fixture.target()
    let old = fixture.service.attach(to: target)
    try await fixture.ready(old)
    let request = Task { try await old.screenshot() }
    await gate.waitUntilEntered()
    target.invalidate()
    let replacement = fixture.target()
    let current = fixture.service.attach(to: replacement)
    try await fixture.ready(current)
    probe.gate = nil
    #expect(try await current.screenshot() == Data("screenshot".utf8))
    await gate.open()
    await #expect(throws: CancellationError.self) { _ = try await request.value }
    #expect(probe.targets == [target, replacement])
    #expect(!current.isClosed)
    await fixture.close()
  }
}

@Observable
@MainActor
final class PreviewRequestProbe {
  var gate: TestGate?
  var cancellations = 0
  var targets: [DeviceTarget] = []

  func run(target: DeviceTarget?) async throws {
    guard let target else { preconditionFailure("Unbound device request") }
    _ = try target.requireTransport(for: target.serial)
    targets.append(target)
    let gate = gate
    await withTaskCancellationHandler {
      await gate?.wait()
    } onCancel: {
      Task { @MainActor in self.cancellations += 1 }
    }
    // Return even after cancellation to check that the attachment rejects late results.
  }
}
