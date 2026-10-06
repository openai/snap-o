import Foundation
import Observation

enum CaptureKind { case screenshots, recording }

@MainActor
protocol CaptureBatch: AnyObject {
  var id: UUID { get }
  var kind: CaptureKind { get }
  var items: [CaptureItem] { get }
  var isComplete: Bool { get }
  func start()
  func close() async
}

@Observable
@MainActor
final class CaptureItem: Identifiable {
  enum State {
    case pending
    case recording
    case collecting
    case ready(CaptureMedia, warning: String? = nil)
    case failed(String)
    case cancelled
  }

  let id = UUID()
  let device: Device
  let target: DeviceTarget?
  private(set) var state: State = .pending

  init(device: Device) {
    self.device = device
    target = device.connection
  }

  var media: CaptureMedia? {
    guard case .ready(let media, _) = state else { return nil }
    return media
  }

  var warning: String? {
    guard case .ready(_, let warning) = state else { return nil }
    return warning
  }

  // Only the batch producing this item changes its outcome.
  func update(_ state: State) {
    self.state = state
  }
}
