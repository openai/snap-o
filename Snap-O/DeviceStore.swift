import SwiftUI

@MainActor
@Observable
final class DeviceStore {
  private let tracker: DeviceTracker
  var devices: [Device] = [] // published for all windows

  init(tracker: DeviceTracker) {
    self.tracker = tracker
  }

  func start() async {
    for await list in await tracker.deviceStream() {
      devices = list
    }
  }
}
