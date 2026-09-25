import AppKit
@preconcurrency import AVFoundation
@testable import Snap_O
import SwiftUI
import Testing

@Suite(.serialized)
@MainActor
struct CaptureViewTests {
  @Test
  func sizingPreservesMountedContent() async throws {
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
      try await eventually { mounted.first?.frame.size == size }
      #expect(mounted.count == 1, "Sizing changes must preserve the mounted media view")
    }
  }

  @Test
  func rotationAndPaneResizingKeepTheVideoLayerAligned() async throws {
    let store = FileStore(baseDir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { store.purgeExistingFiles() }
    var mounted: [LivePreviewDisplayView] = []
    func surface(_ ratio: CGFloat) -> some View {
      CaptureSurfaceView(aspectRatio: ratio) {
        PreviewSurfaceProbe(store: store) { mounted.append($0) }
      }
    }
    let view = NSHostingView(rootView: surface(0.5))
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 450, height: 900),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = view
    window.orderFront(nil)
    defer {
      window.orderOut(nil)
      window.contentView = nil
    }
    for (ratio, width): (CGFloat, CGFloat) in [(0.5, 450), (2, 450), (0.5, 450), (0.5, 360), (0.5, 500)] {
      window.setContentSize(CGSize(width: width, height: 900))
      withAnimation(.linear(duration: 0.05)) { view.rootView = surface(ratio) }
      view.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
      let expected = CGSize(width: min(width, 900 * ratio), height: min(900, width / ratio))
      try await eventually { mounted.first?.frame.size == expected }
      let preview = try #require(mounted.first)
      let video = try #require(preview.layer?.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.first)
      preview.setBoundsOrigin(CGPoint(x: 24, y: 12))
      preview.needsLayout = true
      preview.layoutSubtreeIfNeeded()
      #expect(video.frame == preview.bounds, "Video must fill its view after rotation and pane resizing")
      preview.setBoundsOrigin(.zero)
      preview.needsLayout = true
      preview.layoutSubtreeIfNeeded()
      #expect(video.frame == preview.bounds, "Returning to the original bounds must remove any offset")
      #expect(mounted.count == 1, "Rotation must preserve the live renderer")
    }
  }

  @Test
  func connectButtonClearsTheSelectedConnectionFailure() async throws {
    NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    let host = FailedPreviewHost()
    host.connection.hasFailed = true
    let capture = CaptureMedia(
      device: Device(id: "phone", model: "Phone", androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil),
      media: .livePreview(capturedAt: .now, display: DisplayInfo(size: CGSize(width: 100, height: 200), densityScale: 1))
    )
    let store = FileStore(baseDir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { store.purgeExistingFiles() }
    let view = NSHostingView(rootView: LiveCaptureView(host: host, capture: capture, fileStore: store).environment(AppSettings.shared))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = view
    defer { window.contentView = nil }
    try await eventually { connectButton(in: view) != nil }
    let button = try #require(connectButton(in: view))
    #expect(button.accessibilityPerformPress?() == true)
    #expect(!host.connection.hasFailed)
    try await eventually { connectButton(in: view) == nil }
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

  private func eventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    try #require(condition())
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

@MainActor
private final class FailedPreviewHost: LivePreviewHosting {
  let connection = LivePreviewConnection()
  func canReconnectLivePreview(for _: String) -> Bool {
    true
  }

  func livePreviewConnection(for deviceID: String) -> LivePreviewConnection? {
    #expect(deviceID == "phone")
    return connection
  }

  func startLivePreviewStream(for _: String) async -> LivePreviewRenderer? {
    nil
  }

  func stopLivePreviewStream(_: LivePreviewRenderer) async {}

  func livePreviewScreenshot(for _: String) async throws -> Data {
    Data()
  }
}

private struct PreviewSurfaceProbe: NSViewRepresentable {
  let store: FileStore
  let mounted: (LivePreviewDisplayView) -> Void

  func makeNSView(context: Context) -> LivePreviewDisplayView {
    let view = LivePreviewDisplayView(fileStore: store)
    mounted(view)
    return view
  }

  func updateNSView(_ view: LivePreviewDisplayView, context: Context) {}
}
