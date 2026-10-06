import AppKit
import Sparkle

@MainActor
final class UpdateCoordinator {
  static let shared = UpdateCoordinator()

  let updaterController: SPUStandardUpdaterController

  private init() {
    updaterController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
  }

  func handle(url: URL) -> Bool {
    guard url.scheme?.lowercased() == "snapo" else { return false }
    let host = url.host?.lowercased() ?? ""
    let path = url.path.lowercased()
    let wantsUpdate = host == "check-updates" ||
      host == "check-for-updates" ||
      host == "updates" ||
      path == "/check-updates" ||
      path == "/check-for-updates"
    if wantsUpdate {
      checkForUpdates()
      return true
    }
    return false
  }

  func checkForUpdates() {
    NSApplication.shared.activate(ignoringOtherApps: true)
    updaterController.updater.checkForUpdates()
  }
}
