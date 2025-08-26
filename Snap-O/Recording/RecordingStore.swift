import Foundation
import Observation

@MainActor
@Observable
final class RecordingStore {
  private let service: RecordingService
  private(set) var recordingDevices: Set<String> = []

  init(service: RecordingService) {
    self.service = service
    Task { [weak self] in
      guard let self else { return }
      let stream = await service.recordingDevicesStream()
      for await devices in stream {
        updateRecordingDevices(devices)
      }
    }
    Task { [weak self] in
      guard let self else { return }
      await updateRecordingDevices(service.currentRecordingDevices())
    }
  }

  private func updateRecordingDevices(_ devices: Set<String>) {
    recordingDevices = devices
  }

  func isRecording(deviceID: String) -> Bool { recordingDevices.contains(deviceID) }
}
