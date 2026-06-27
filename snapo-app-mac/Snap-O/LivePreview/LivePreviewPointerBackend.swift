import CoreGraphics

/// Input source reported by the live-preview surface.
enum LivePreviewPointerSource: String {
  case touchscreen
  case mouse
}

enum LivePreviewPointerAction: String {
  case down = "DOWN"
  case up = "UP"
  case move = "MOVE"
  case cancel = "CANCEL"
}

struct LivePreviewPointerEvent {
  let deviceID: String
  let action: LivePreviewPointerAction
  let source: LivePreviewPointerSource
  let location: CGPoint
  let displaySize: CGSize
}

protocol LivePreviewPointerBackend: Sendable {
  func send(_ event: LivePreviewPointerEvent) async throws
  func stop() async
}

extension LivePreviewPointerBackend {
  func stop() async {}
}
