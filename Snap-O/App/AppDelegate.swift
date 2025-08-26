import AppKit
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if let window = NSApplication.shared.windows.first {
      window.makeKeyAndOrderFront(nil)
    }
    return true
  }

  func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool { false }
  func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool { false }
}
