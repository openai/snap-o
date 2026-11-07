import Foundation
import Testing

@MainActor
struct CaptureCoordinatorTests {
  @Test
  func previewAndRecordingLeasesAreIndependent() async throws {
    let coordinator = CaptureCoordinator()
    let target = DeviceTarget(serial: "synthetic", transportID: "1")
    let preview = try coordinator.acquire(target: target, for: .livePreview)
    let otherPreview = try coordinator.acquire(target: target, for: .livePreview)
    let recording = try coordinator.acquire(target: target, for: .recording)
    let otherRecording = try coordinator.acquire(
      target: DeviceTarget(serial: "another-device", transportID: "2"), for: .recording
    )
    coordinator.release(preview)
    coordinator.release(recording)
    let screenshot = try coordinator.acquire(target: target, for: .screenshot)
    coordinator.release(otherPreview)
    coordinator.release(screenshot)
    coordinator.release(otherRecording)
    await coordinator.waitUntilIdle()
  }

  @Test
  func captureCompatibilityAppliesInBothAcquisitionOrders() async throws {
    let activities: [DeviceCaptureActivity] = [.screenshot, .livePreview, .recording, .bugReportRecording]
    for serial in ["phone", "emulator-5554"] {
      for existing in activities {
        for requested in activities {
          for overlaps in [false, true] {
            let coordinator = CaptureCoordinator()
            let target = DeviceTarget(serial: serial, transportID: "1")
            let nextTarget = overlaps ? target : DeviceTarget(serial: serial, transportID: "2")
            let first = try coordinator.acquire(target: target, for: existing)
            let conflicts = overlaps && (
              existing == .bugReportRecording || requested == .bugReportRecording
                || (serial.hasPrefix("emulator-") && existing == .recording && requested == .recording)
            )
            if conflicts {
              #expect(throws: CaptureCoordinationError.deviceBusy(deviceID: serial, activity: existing)) {
                try coordinator.acquire(target: nextTarget, for: requested)
              }
            } else {
              let second = try coordinator.acquire(target: nextTarget, for: requested)
              coordinator.release(second)
            }
            coordinator.release(first)
            let next = try coordinator.acquire(target: nextTarget, for: requested)
            coordinator.release(next)
            await coordinator.waitUntilIdle()
          }
        }
      }
    }
  }
}
