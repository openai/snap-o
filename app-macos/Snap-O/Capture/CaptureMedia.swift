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
