import Foundation

struct CaptureMedia: Identifiable, Equatable {
  let id: UUID
  let deviceID: String
  let device: Device
  let media: Media

  init(id: UUID = UUID(), deviceID: String, device: Device, media: Media) {
    self.id = id
    self.deviceID = deviceID
    self.device = device
    self.media = media
  }
}

extension Array where Element == CaptureMedia {
  func media(forDeviceID id: String) -> CaptureMedia? {
    first { $0.deviceID == id }
  }
}
