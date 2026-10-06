import Foundation

struct MediaEdits: Equatable {
  var crop: CGRect = CaptureCropGeometry.fullImage
  var trim: CaptureTrimRange?
}

struct CaptureExportRequest: Equatable {
  let capture: CaptureMedia
  let edits: MediaEdits

  init(capture: CaptureMedia, crop: CGRect = CaptureCropGeometry.fullImage, trim: CaptureTrimRange? = nil) {
    self.capture = capture
    edits = MediaEdits(crop: crop, trim: trim)
  }

  init(capture: CaptureMedia, edits: MediaEdits) {
    self.capture = capture
    self.edits = edits
  }

  func replacingSource(with url: URL) -> Self {
    let media: Media = capture.media.isImage
      ? .image(url: url, data: capture.media.common)
      : .video(url: url, data: capture.media.common)
    return Self(capture: CaptureMedia(id: capture.id, device: capture.device, media: media), edits: edits)
  }

  var crop: CGRect { edits.crop }
  var trim: CaptureTrimRange? { edits.trim }
}
