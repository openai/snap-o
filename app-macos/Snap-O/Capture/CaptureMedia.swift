import Foundation

struct CaptureMedia: Identifiable, Equatable {
  let id: UUID
  let device: Device
  let media: Media

  init(id: UUID = UUID(), device: Device, media: Media) {
    self.id = id
    self.device = device
    self.media = media
  }
}

struct CaptureFailure {
  let device: Device
  let error: Error

  var message: String {
    "\(device.displayTitle): \(error.localizedDescription)"
  }
}

struct ScreenshotCaptureResult {
  let media: [CaptureMedia]
  let failures: [CaptureFailure]
}

extension [CaptureMedia] {
  func media(forDeviceID id: String) -> CaptureMedia? {
    first { $0.device.id == id }
  }
}
