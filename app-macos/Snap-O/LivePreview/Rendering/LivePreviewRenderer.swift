import Foundation

/// Connects a live-preview session to its interactive AppKit surface.
struct LivePreviewRenderer {
  let session: LivePreviewSession
  let device: Device
  let sendPointer: (LivePreviewPointerAction, LivePreviewPointerSource, [CGPoint], CGSize) -> Void

  var deviceID: String {
    device.id
  }
}
