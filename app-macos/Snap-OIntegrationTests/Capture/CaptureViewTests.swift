import AppKit
@preconcurrency import AVFoundation
import Clocks
import DependenciesTestSupport
@testable import Snap_O
import SwiftUI
import Testing

@Suite(.serialized)
@MainActor
struct CaptureViewTests {
  @Test
  func sizingPreservesMountedContent() throws {
    var mounted: [NSView] = []
    func surface(_ ratio: CGFloat?) -> some View {
      CaptureSurfaceView(aspectRatio: ratio) {
        SurfaceProbe { mounted.append($0) }
      }
    }
    let view = NSHostingView(rootView: surface(nil))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = view
    defer { window.contentView = nil }
    for (ratio, frame): (CGFloat?, CGRect) in [
      (nil, CGRect(x: 0, y: 0, width: 240, height: 120)),
      (0.5, CGRect(x: 90, y: 0, width: 60, height: 120)),
      (4, CGRect(x: 0, y: 30, width: 240, height: 60)),
      (nil, CGRect(x: 0, y: 0, width: 240, height: 120))
    ] {
      view.rootView = surface(ratio)
      view.layoutSubtreeIfNeeded()
      let preview = try #require(mounted.first)
      #expect(preview.convert(preview.bounds, to: view) == frame)
      #expect(mounted.count == 1, "Sizing changes must preserve the mounted media view")
    }
  }

  @Test
  func fullScreenAnimationKeepsTheMountedPreviewInProportion() async throws {
    let screen = try #require(NSScreen.main)
    let width = min(300, (screen.frame.height / 3).rounded(.down))
    let window = NSWindow(
      contentRect: CGRect(x: screen.frame.midX - width / 2, y: screen.frame.midY - width, width: width, height: width * 2),
      styleMask: [.borderless, .resizable], backing: .buffered, defer: false
    )
    var mounted: [NSView] = []
    let host = NSHostingView(rootView: CaptureSurfaceView(aspectRatio: 0.5) {
      SurfaceProbe { mounted.append($0) }
    })
    window.contentView = host
    defer { window.contentView = nil }
    let suite = "CaptureViewTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let sizing = WindowSizingController.Coordinator(defaults: defaults)
    sizing.attach(to: window)
    host.layoutSubtreeIfNeeded()
    let media = try #require(mounted.first)
    let windowedFrame = window.frame

    func checkAnimation(to destination: CGRect, start: () -> Void) async throws {
      let initialSize = window.frame.size
      let arrived = TestSignal()
      let revision = arrived.revision
      var sawIntermediateSize = false
      let observation = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: nil) { _ in
        MainActor.assumeIsolated {
          host.layoutSubtreeIfNeeded()
          let preview = media.convert(media.bounds, to: host)
          #expect(abs(preview.width - preview.height / 2) <= 1)
          #expect(abs(preview.midX - host.bounds.midX) <= 1)
          #expect(abs(preview.midY - host.bounds.midY) <= 1)
          if window.frame.size == destination.size {
            arrived.signal()
          } else if window.frame.size != initialSize {
            sawIntermediateSize = true
          }
        }
      }
      defer { NotificationCenter.default.removeObserver(observation) }
      start()
      try await arrived.wait(after: revision)
      if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { #expect(sawIntermediateSize) }
      #expect(mounted.count == 1)
    }

    #expect(sizing.customWindowsToEnterFullScreen(for: window)?.first === window)
    sizing.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
    try await checkAnimation(to: screen.frame) {
      sizing.window(window, startCustomAnimationToEnterFullScreenOn: screen, withDuration: 0.5)
    }
    sizing.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
    #expect(sizing.customWindowsToExitFullScreen(for: window)?.first === window)
    sizing.windowWillExitFullScreen(Notification(name: NSWindow.willExitFullScreenNotification, object: window))
    try await checkAnimation(to: windowedFrame) {
      sizing.window(window, startCustomAnimationToExitFullScreenWithDuration: 0.5)
    }
    sizing.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
    #expect(sizing.customWindowsToExitFullScreen(for: window) == nil)
  }

  @Test
  func videoLayerTracksBoundsChanges() throws {
    let store = FileStore(baseDir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { store.purgeExistingFiles() }
    let preview = LivePreviewDisplayView(fileStore: store)
    let video = try #require(preview.layer?.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.first)

    for bounds in [
      CGRect(x: 0, y: 0, width: 240, height: 480),
      CGRect(x: 24, y: 12, width: 480, height: 240),
      CGRect(x: 0, y: 0, width: 240, height: 480)
    ] {
      preview.setFrameSize(bounds.size)
      preview.setBoundsOrigin(bounds.origin)
      preview.needsLayout = true
      preview.layoutSubtreeIfNeeded()
      #expect(video.frame == bounds)
    }
  }

  @Test(.dependency(\.continuousClock, TestClock()))
  func connectButtonClearsTheSelectedConnectionFailure() async throws {
    NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    let fixture = try SharedPreviewTestSupport.Fixture()
    fixture.videoStartupError = CocoaError(.fileReadUnknown)
    let connection = fixture.service.attach(to: fixture.target("phone"))
    try await waitForState { connection.hasFailed }
    let store = FileStore(baseDir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { store.purgeExistingFiles() }
    let view = NSHostingView(rootView: LiveCaptureView(
      device: fixture.device(connection.target), attachment: connection, fileStore: store
    ).environment(AppSettings.shared))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = view
    defer { window.contentView = nil }
    view.layoutSubtreeIfNeeded()
    // The offscreen host does not report a visible window. Model visibility for the button action.
    connection.setVisible(true)
    let button = try #require(connectButton(in: view))
    #expect(button.accessibilityPerformPress?() == true)
    #expect(!connection.hasFailed)
    view.layoutSubtreeIfNeeded()
    #expect(connectButton(in: view) == nil)
    await fixture.close()
  }

  private func connectButton(in element: AnyObject) -> AnyObject? {
    if element.accessibilityLabel?() == "Connect" || element.accessibilityTitle?() == "Connect" {
      return element
    }
    for child in element.accessibilityChildren?() ?? [] {
      if let found = connectButton(in: child as AnyObject) { return found }
    }
    return nil
  }
}

private struct SurfaceProbe: NSViewRepresentable {
  let mounted: (NSView) -> Void
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    mounted(view)
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {}
}
