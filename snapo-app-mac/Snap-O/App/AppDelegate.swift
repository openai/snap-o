import AppKit
import Foundation

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    !flag
  }

  func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
    false
  }

  func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
    false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    AppSettings.shared.isAppTerminating = true
    return .terminateNow
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      if UpdateCoordinator.shared.handle(url: url) { continue }
      if SnapOCommandCoordinator.shared.handle(url: url) { continue }
    }
  }
}
