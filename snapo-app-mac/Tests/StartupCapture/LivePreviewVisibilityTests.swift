import AppKit
import AVFoundation
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

struct LivePreviewRendererView: NSViewRepresentable {
  let renderer: LivePreviewRenderer
  let fileStore: FileStore
  let isVisible: Bool

  @MainActor static var displayView: NSView?

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    Self.displayView = view
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    nsView.isHidden = !isVisible
  }
}

/// Exercise the production playback view without loading media or running a decoder.
@MainActor
final class AVQueuePlayer {
  static var latest: AVQueuePlayer?
  var timeControlStatus = AVPlayer.TimeControlStatus.paused

  init() {
    Self.latest = self
  }

  func play() {
    timeControlStatus = .playing
  }

  func pause() {
    timeControlStatus = .paused
  }
}

struct AVPlayerItem {
  let url: URL
}

struct AVPlayerLooper {
  let player: AVQueuePlayer
  let templateItem: AVPlayerItem
}

struct VideoPlayer: View {
  let player: AVQueuePlayer
  var body: some View {
    Color.clear
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
  var requestedDeviceIDs: [String] = []
  var failsToStart = false
  var stops: [UUID] = []
  var active: Set<UUID> = []
  var busyStarts = 0
  var delayStart = false
  var startContinuation: CheckedContinuation<Void, Never>?
  var delayStop = false
  var stopContinuation: CheckedContinuation<Void, Never>?
  var latestSession: LivePreviewSession?
  func startLivePreviewStream(for deviceID: String) async -> LivePreviewRenderer? {
    starts += 1
    requestedDeviceIDs.append(deviceID)
    guard active.isEmpty else {
      busyStarts += 1
      return nil
    }
    if delayStart { await withCheckedContinuation { startContinuation = $0 } }
    if failsToStart { return nil }
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

  static func accessibleElement(named name: String, in element: AnyObject) -> AnyObject? {
    let value: String? = element.accessibilityValue?()
    if element.accessibilityLabel?() == name || element.accessibilityTitle?() == name
      || value == name {
      return element
    }
    for child in element.accessibilityChildren?() ?? [] {
      if let found = accessibleElement(named: name, in: child as AnyObject) {
        return found
      }
    }
    return nil
  }

  static func connect(in view: NSView) {
    guard let button = accessibleElement(named: "Connect", in: view) else {
      preconditionFailure("Missing Connect button")
    }
    precondition(button.accessibilityPerformPress?() == true, "Connect must be accessible")
  }

  static func main() {
    // Enable SwiftUI accessibility nodes without requiring VoiceOver or an external test app.
    NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    let host = TestHost()
    func surface(aspectRatio: CGFloat?, mountsPreview: Bool = true) -> some View {
      CaptureSurfaceView(aspectRatio: aspectRatio) {
        if mountsPreview {
          LiveCaptureView(host: host, capture: CaptureMedia(), fileStore: FileStore())
        }
      }
    }
    let view = NSHostingView(rootView: surface(aspectRatio: nil))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
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
    eventually("Renderer must attach") { LivePreviewRendererView.displayView != nil }
    let displayView = LivePreviewRendererView.displayView
    let sizingCases: [(CGFloat?, CGSize)] = [
      (nil, CGSize(width: 240, height: 120)),
      (0.5, CGSize(width: 60, height: 120)),
      (nil, CGSize(width: 240, height: 120)),
      (4, CGSize(width: 240, height: 60)),
      (0.5, CGSize(width: 60, height: 120)),
      (nil, CGSize(width: 240, height: 120))
    ]
    for (aspectRatio, expectedSize) in sizingCases {
      view.rootView = surface(aspectRatio: aspectRatio)
      view.layoutSubtreeIfNeeded()
      pump()
      precondition(host.starts == 1 && host.stops.isEmpty, "Inspector toggles must not restart the stream")
      precondition(LivePreviewRendererView.displayView === displayView, "Inspector toggles must preserve the display view")
      precondition(displayView?.frame.size == expectedSize, "Preview must fit the device or fill the capture-only pane")
    }
    let originalSession = host.latestSession
    for _ in 0 ..< 3 {
      Visibility.shared.isVisible = false
      eventually("Covered preview hides its presentation") { displayView?.isHidden == true }
      pump()
      precondition(host.active.count == 1 && host.stops.isEmpty, "Covered preview must keep running")
      Visibility.shared.isVisible = true
      eventually("Uncovered preview restores presentation") { displayView?.isHidden == false }
      precondition(host.starts == 1 && host.latestSession === originalSession, "Uncover must reuse the same session")
      precondition(LivePreviewRendererView.displayView === displayView, "Uncover must preserve the renderer")
    }
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
    pump()
    precondition(host.active.count == 1 && host.stops.isEmpty, "Visible preview must keep running while inactive")

    host.delayStop = true
    host.latestSession?.stop()
    eventually("Spontaneous stop cleanup should be pending") { host.stopContinuation != nil }
    Visibility.shared.isVisible = false
    eventually("Hide during spontaneous cleanup") { Visibility.shared.reportedVisibility == false }
    Visibility.shared.isVisible = true
    eventually("Uncover during spontaneous cleanup") { Visibility.shared.reportedVisibility == true }
    pump()
    precondition(host.starts == 1, "Replacement must wait for spontaneous stop cleanup")
    Visibility.shared.isVisible = false
    eventually("Keep recovery hidden") { Visibility.shared.reportedVisibility == false }
    host.delayStop = false
    host.stopContinuation?.resume()
    host.stopContinuation = nil
    eventually("Stopped preview releases its operation") { host.active.isEmpty }
    pump()
    precondition(host.starts == 1, "Hidden preview must not reconnect automatically")
    Visibility.shared.isVisible = true
    eventually("Dropped stream shows its error") { accessibleElement(named: "Live preview unavailable", in: view) != nil }
    pump()
    precondition(host.starts == 1, "Uncover must not reconnect a failed stream")
    connect(in: view)
    eventually("Connect starts a replacement") { host.starts == 2 && host.active.count == 1 }
    eventually("Replacement becomes visible") { LivePreviewRendererView.displayView?.isHidden == false }
    eventually("Connected preview hides the failure action") { accessibleElement(named: "Connect", in: view) == nil }

    host.delayStop = true
    view.rootView = surface(aspectRatio: nil, mountsPreview: false)
    eventually("Removing the preview must stop it") { host.stopContinuation != nil }
    host.delayStop = false
    host.stopContinuation?.resume()
    host.stopContinuation = nil
    eventually("Removed preview releases its operation") { host.active.isEmpty && host.stops.count == 2 }

    host.delayStart = true
    view.rootView = surface(aspectRatio: nil)
    eventually("Startup should be pending") { host.startContinuation != nil }
    Visibility.shared.isVisible = false
    eventually("Hide during pending startup") { Visibility.shared.reportedVisibility == false }
    host.delayStart = false
    host.startContinuation?.resume()
    host.startContinuation = nil
    eventually("Pending startup completes while covered") { host.active.count == 1 }
    eventually("Late renderer stays hidden") { LivePreviewRendererView.displayView?.isHidden == true }
    precondition(host.starts == 3 && host.stops.count == 2, "Hiding during startup must not cancel it")
    Visibility.shared.isVisible = true
    eventually("Late renderer becomes visible") { LivePreviewRendererView.displayView?.isHidden == false }
    precondition(host.starts == 3, "Uncover must reuse the late renderer")
    view.rootView = surface(aspectRatio: nil, mountsPreview: false)
    eventually("Removing the late renderer stops it") { host.active.isEmpty && host.stops.count == 3 }

    host.delayStart = true
    view.rootView = surface(aspectRatio: nil)
    eventually("Final startup should be pending") { host.startContinuation != nil }
    window.contentView = nil
    pump()
    host.delayStart = false
    host.startContinuation?.resume()
    host.startContinuation = nil
    eventually("Removed view cleans up late startup") { host.active.isEmpty && host.stops.count == 4 }
    precondition(Set(host.stops).count == host.stops.count, "Stop each renderer once")
    precondition(host.busyStarts == 0, "Never restart while the previous operation owns the device")
    print("Live Preview visibility tests passed")
    testFailedConnection()
    testRecordingPlaybackVisibility()
  }

  static func testFailedConnection() {
    Visibility.shared.isVisible = true
    let host = TestHost()
    host.failsToStart = true
    let view = NSHostingView(rootView: LiveCaptureView(host: host, capture: CaptureMedia(), fileStore: FileStore()))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    eventually("Failed startup shows a concise error") { accessibleElement(named: "Live preview unavailable", in: view) != nil }
    pump()
    precondition(host.starts == 1 && host.active.isEmpty, "Failed startup must not retry automatically")

    for _ in 0 ..< 3 {
      Visibility.shared.isVisible = false
      pump()
      Visibility.shared.isVisible = true
      pump()
    }
    precondition(host.starts == 1, "Window visibility must not restart failed startup")

    connect(in: view)
    eventually("Manual retry can fail again") { host.starts == 2 && accessibleElement(named: "Connect", in: view) != nil }
    pump()
    precondition(host.starts == 2, "Failed manual retry must wait for another click")

    host.failsToStart = false
    host.delayStart = true
    connect(in: view)
    eventually("Connect starts one pending attempt") { host.starts == 3 && host.startContinuation != nil }
    eventually("Pending attempt hides Connect") { accessibleElement(named: "Connect", in: view) == nil }
    host.delayStart = false
    host.startContinuation?.resume()
    host.startContinuation = nil
    eventually("Manual connection succeeds") { host.active.count == 1 }
    precondition(host.requestedDeviceIDs == Array(repeating: "test-device", count: 3), "Connect must keep the same device")
    precondition(host.busyStarts == 0, "Connect must not overlap attempts")
    window.contentView = nil
    eventually("Removing reconnected preview releases it") { host.active.isEmpty }
    print("Live Preview manual connection tests passed")
  }

  static func testRecordingPlaybackVisibility() {
    Visibility.shared.isVisible = false
    Visibility.shared.reportedVisibility = nil
    let view = NSHostingView(rootView: VideoLoopingView(url: URL(fileURLWithPath: "/synthetic-recording.mp4")))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    eventually("Playback view must attach while hidden") {
      AVQueuePlayer.latest != nil && Visibility.shared.reportedVisibility == false
    }
    guard let player = AVQueuePlayer.latest else { preconditionFailure("Playback player must exist") }
    precondition(player.timeControlStatus == .paused, "Hidden recording must not autoplay")

    Visibility.shared.isVisible = true
    eventually("Visible recording autoplays") { player.timeControlStatus == .playing }
    for _ in 0 ..< 3 {
      Visibility.shared.isVisible = false
      eventually("Covered recording pauses") { player.timeControlStatus == .paused }
      Visibility.shared.isVisible = true
      eventually("Uncovered recording resumes") { player.timeControlStatus == .playing }
    }

    player.pause()
    Visibility.shared.isVisible = false
    eventually("Cover manually paused recording") { Visibility.shared.reportedVisibility == false }
    Visibility.shared.isVisible = true
    eventually("Uncover manually paused recording") { Visibility.shared.reportedVisibility == true }
    precondition(player.timeControlStatus == .paused, "Uncover must preserve a manual pause")

    player.timeControlStatus = .waitingToPlayAtSpecifiedRate
    Visibility.shared.isVisible = false
    eventually("Covered buffering recording pauses") { player.timeControlStatus == .paused }
    Visibility.shared.isVisible = true
    eventually("Uncovered buffering recording resumes") { player.timeControlStatus == .playing }

    window.contentView = nil
    eventually("Removing the playback view pauses it") { player.timeControlStatus == .paused }
    print("Recording playback visibility tests passed")
  }
}
