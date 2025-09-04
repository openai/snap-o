import Combine
import SwiftUI

@MainActor
final class DeviceStore: ObservableObject {
  private let tracker: DeviceTracker
  @Published var devices: [Device] = [] // published for all windows
  @Published var hasReceivedInitialDeviceList: Bool = false

  init(tracker: DeviceTracker) {
    self.tracker = tracker
    devices = tracker.latestDevices
  }

  func start() async {
    for await list in tracker.deviceStream() {
      if !hasReceivedInitialDeviceList { hasReceivedInitialDeviceList = true }
      devices = list
    }
  }
}
