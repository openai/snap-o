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
  func sizingPreservesMountedContent() {
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
    for (ratio, size): (CGFloat?, CGSize) in [
      (nil, CGSize(width: 240, height: 120)),
      (0.5, CGSize(width: 60, height: 120)),
      (4, CGSize(width: 240, height: 60)),
      (nil, CGSize(width: 240, height: 120))
    ] {
      view.rootView = surface(ratio)
      view.layoutSubtreeIfNeeded()
      #expect(mounted.first?.frame.size == size)
      #expect(mounted.count == 1, "Sizing changes must preserve the mounted media view")
    }
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
    let fixture = try SharedLivePreviewTests.Fixture()
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
