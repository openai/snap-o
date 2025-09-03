import SwiftUI

@MainActor
final class DeviceService {
  let store: DeviceStore

  private let tracker: DeviceTracker
  private var started = false

  init(adbService: ADBService) {
    tracker = DeviceTracker(adbService: adbService)
    store = DeviceStore(tracker: tracker)
  }

  func start() async {
    guard !started else { return }
    started = true
    await store.start()
  }
}
