import AppKit
import Observation
import SwiftUI

@MainActor
final class AppCoordinator {
  let deviceStore: DeviceStore
  let adbClient: ADBClient
  let fileStore: FileStore

  let settings: AppSettings

  private let deviceTracker: DeviceTracker

  private var startedTracking = false

  init() {
    let last = ADBPathManager.lastKnownADBURL()

    adbClient = ADBClient(adbURL: last)
    deviceTracker = DeviceTracker(adbClient: adbClient)
    deviceStore = DeviceStore(tracker: deviceTracker)
    fileStore = FileStore()
    settings = AppSettings()
  }

  func trackDevices() async {
    if await adbClient.currentURL() == nil {
      await updateADBPathFromUserSelection()
      await adbClient.awaitConfigured()
    }

    guard !startedTracking else { return }
    startedTracking = true
    await deviceStore.start()
  }

  func updateADBPathFromUserSelection() async {
    let mgr = ADBPathManager()
    await MainActor.run {
      mgr.promptForADBPath()
    }
    let chosen = ADBPathManager.lastKnownADBURL()
    await adbClient.setURL(chosen)
  }
}
