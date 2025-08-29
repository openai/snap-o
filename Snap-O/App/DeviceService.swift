import SwiftUI

@MainActor
final class DeviceService {
  let store: DeviceStore

  private let tracker: DeviceTracker
  private var started = false

  init(adbService: ADBService) {
    tracker = DeviceTracker(adbClient: adbService.client)
    store = DeviceStore(tracker: tracker)
  }

  func start() async {
    guard !started else { return }
    started = true
    await store.start()
  }
}
