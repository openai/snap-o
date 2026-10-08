import Foundation

enum CaptureKind { case screenshot, recording }

enum CaptureState {
  case pending
  case recording
  case collecting
  case ready(CaptureMedia, warning: String? = nil)
  case failed(String)
  case cancelled
}

@MainActor
protocol CaptureOperation: AnyObject {
  var id: UUID { get }
  var kind: CaptureKind { get }
  var device: Device { get }
  var state: CaptureState { get }
  var isComplete: Bool { get }
  func start()
  func close() async
}

extension CaptureOperation {
  var media: CaptureMedia? {
    guard case .ready(let media, _) = state else { return nil }
    return media
  }

  var warning: String? {
    guard case .ready(_, let warning) = state else { return nil }
    return warning
  }
}
