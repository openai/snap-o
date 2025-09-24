import AppKit
import SwiftUI

@MainActor
final class NetworkInspectorWindowController: NSObject, NSWindowDelegate {
  private var windowController: NSWindowController?

  func showWindow() {
    if let windowController {
      windowController.showWindow(nil)
      windowController.window?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let hostingController = NSHostingController(rootView: NetworkInspectorView())
    let window = NSWindow(contentViewController: hostingController)
    window.title = "Network Inspector"
    window.setContentSize(NSSize(width: 640, height: 480))
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.isReleasedWhenClosed = false
    window.center()
    window.delegate = self

    let controller = NSWindowController(window: window)
    windowController = controller

    controller.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    guard
      let window = notification.object as? NSWindow,
      window == windowController?.window
    else { return }

    window.delegate = nil
    windowController = nil
  }
}
