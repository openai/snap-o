import Foundation

/// Tracks display changes independently of the screenshot transport.
struct EmulatorPreviewGeometry {
  struct Frame: Equatable {
    let size: CGSize
    var rotation = 0
    var display: UInt32 = 0
    var configuration = Data()
  }

  enum Update: Equatable {
    case unchanged
    case format(displaySize: CGSize?)
    case restart(nativeSize: CGSize?)
  }

  var nativeSize: CGSize?
  private let requestedSize: LivePreviewFrameSize
  private let streamSize: LivePreviewFrameSize
  private var previous: Frame?

  init(requestedSize: LivePreviewFrameSize, nativeSize: CGSize?) {
    self.requestedSize = requestedSize
    self.nativeSize = nativeSize
    streamSize = requestedSize.capped(to: nativeSize)
  }

  func needsNativeSize(for frame: Frame) -> Bool {
    if case .preview = streamSize { return previous != nil && previous != frame }
    return false
  }

  mutating func update(_ frame: Frame) -> Update {
    guard previous != frame else { return .unchanged }
    var displaySize: CGSize?
    if case .preview = streamSize {
      displaySize = nativeSize
      if let native = displaySize,
         abs(native.width * frame.size.height - native.height * frame.size.width) > native.width + native.height {
        // Allow pixel rounding; a different aspect ratio can mean rotation raced the size query.
        displaySize = nil
      }
      if requestedSize.capped(to: displaySize) != streamSize { return .restart(nativeSize: displaySize) }
    }
    previous = frame
    return .format(displaySize: displaySize)
  }
}
