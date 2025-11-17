import AppKit
import Foundation

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool { false }
  func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool { false }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    AppSettings.shared.isAppTerminating = true
    return .terminateNow
  }
}
