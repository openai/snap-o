import AppKit
import Observation
import OSLog
import SwiftUI

struct CaptureMedia {
  struct Device { let id: String }
  let device = Device(id: "test-device")
}

struct FileStore {}
enum SnapOLog { static let ui = Logger(subsystem: "Snap-O.VisibilityTests", category: "test") }

@MainActor
final class LivePreviewSession {
  private var stopped = false
  private var continuation: CheckedContinuation<Error?, Never>?
  func waitUntilStop() async -> Error? {
    if stopped { return nil }
    return await withCheckedContinuation { continuation = $0 }
  }

  func stop() {
    stopped = true
    continuation?.resume(returning: nil)
    continuation = nil
  }
}

struct LivePreviewRenderer {
  struct Operation { let id = UUID() }
  let operation = Operation()
  let session: LivePreviewSession
}

struct LivePreviewRendererView: View {
  let renderer: LivePreviewRenderer
  let fileStore: FileStore
  var body: some View {
    Color.green
  }
}

/// Drives the production view lifecycle without a device or an on-screen window.
@Observable
@MainActor
final class Visibility {
  static let shared = Visibility()
  var isVisible = false
  var reportedVisibility: Bool?
}

struct WindowVisibilityReader: View {
  let visibilityDidChange: (Bool) -> Void
  var body: some View {
    Color.clear
      .onAppear { reportVisibility() }
      .onChange(of: Visibility.shared.isVisible) { reportVisibility() }
  }

  private func reportVisibility() {
    let isVisible = Visibility.shared.isVisible
    visibilityDidChange(isVisible)
    Visibility.shared.reportedVisibility = isVisible
  }
}

@MainActor
final class TestHost: LivePreviewHosting {
  var starts = 0
  var stops: [UUID] = []
  var active: Set<UUID> = []
  var busyStarts = 0
  var delayStart = false
  var startContinuation: CheckedContinuation<Void, Never>?
  var delayStop = false
  var stopContinuation: CheckedContinuation<Void, Never>?
  var latestSession: LivePreviewSession?
  func startLivePreviewStream(for _: String) async -> LivePreviewRenderer? {
    starts += 1
    guard active.isEmpty else {
      busyStarts += 1
      return nil
    }
    if delayStart { await withCheckedContinuation { startContinuation = $0 } }
    let renderer = LivePreviewRenderer(session: LivePreviewSession())
    latestSession = renderer.session
    active.insert(renderer.operation.id)
    return renderer
  }

  func stopLivePreviewStream(_ renderer: LivePreviewRenderer) async {
    stops.append(renderer.operation.id)
    renderer.session.stop()
    if delayStop { await withCheckedContinuation { stopContinuation = $0 } }
    active.remove(renderer.operation.id)
  }
}

@main
@MainActor
struct LivePreviewVisibilityTests {
  static func eventually(_ message: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(condition(), message)
  }

  static func pump() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
  }

  static func main() {
    _ = NSApplication.shared
    let host = TestHost()
    let view = NSHostingView(rootView: LiveCaptureView(host: host, capture: CaptureMedia(), fileStore: FileStore()))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    eventually("Visibility reader must attach") { Visibility.shared.reportedVisibility == false }
    precondition(host.starts == 0, "Hidden preview must not start")
    Visibility.shared.isVisible = true
    eventually("Visible preview starts once") { host.starts == 1 && host.active.count == 1 }
    precondition(!NSApplication.shared.isActive, "Test must leave the app inactive")
    host.delayStop = true
    Visibility.shared.isVisible = false
    eventually("Cleanup should be pending") { host.stopContinuation != nil }
    Visibility.shared.isVisible = true
    eventually("Uncover during pending cleanup") { Visibility.shared.reportedVisibility == true }
    pump()
    precondition(host.starts == 1, "Replacement must wait for cleanup")
    Visibility.shared.isVisible = false
    eventually("Hide while waiting for cleanup") { Visibility.shared.reportedVisibility == false }
    Visibility.shared.isVisible = true
    eventually("Uncover again while waiting for cleanup") { Visibility.shared.reportedVisibility == true }
    pump()
    precondition(host.starts == 1, "Repeated visibility changes must not bypass cleanup")
    host.delayStop = false
    host.stopContinuation?.resume()
    host.stopContinuation = nil
    eventually("Restart once after cleanup") { host.starts == 2 && host.active.count == 1 }
    Visibility.shared.isVisible = false
    eventually("Hidden preview must stop") { host.active.isEmpty && host.stops.count == 2 }
    pump()
    precondition(host.starts == 2, "Hidden preview must not retry")
    Visibility.shared.isVisible = true
    eventually("Visible preview restarts") { host.starts == 3 && host.active.count == 1 }
    Visibility.shared.isVisible = false
    eventually("Hidden preview must stop again") { host.active.isEmpty && host.stops.count == 3 }
    host.delayStart = true
    Visibility.shared.isVisible = true
    eventually("Startup should be pending") { host.startContinuation != nil }
    Visibility.shared.isVisible = false
    eventually("Hide during pending startup") { Visibility.shared.reportedVisibility == false }
    Visibility.shared.isVisible = true
    eventually("Uncover during pending startup") { Visibility.shared.reportedVisibility == true }
    pump()
    precondition(host.starts == 4, "Replacement must wait for cancelled startup")
    host.delayStart = false
    host.delayStop = true
    host.startContinuation?.resume()
    host.startContinuation = nil
    eventually("Late startup cleanup should be pending") { host.stopContinuation != nil }
    pump()
    precondition(host.starts == 4, "Replacement must wait for late startup cleanup")
    host.delayStop = false
    host.stopContinuation?.resume()
    host.stopContinuation = nil
    eventually("Preview should recover after cancelled startup") { host.active.count == 1 }
    eventually("Restart after late startup cleanup") { host.starts == 5 && host.stops.count == 4 }
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
    pump()
    precondition(host.active.count == 1 && host.stops.count == 4, "Visible preview must keep running while inactive")
    host.delayStop = true
    host.latestSession?.stop()
    eventually("Spontaneous stop cleanup should be pending") { host.stopContinuation != nil }
    Visibility.shared.isVisible = false
    eventually("Hide during spontaneous cleanup") { Visibility.shared.reportedVisibility == false }
    Visibility.shared.isVisible = true
    eventually("Uncover during spontaneous cleanup") { Visibility.shared.reportedVisibility == true }
    pump()
    precondition(host.starts == 5, "Replacement must wait for spontaneous stop cleanup")
    host.delayStop = false
    host.stopContinuation?.resume()
    host.stopContinuation = nil
    eventually("Restart after spontaneous cleanup") { host.starts == 6 && host.active.count == 1 }
    window.contentView = nil
    eventually("Removing the view must stop its renderer") { host.active.isEmpty && host.stops.count == 6 }
    precondition(Set(host.stops).count == host.stops.count, "Stop each renderer once")
    precondition(host.busyStarts == 0, "Never restart while the previous operation owns the device")
    print("Live Preview visibility tests passed")
  }
}
