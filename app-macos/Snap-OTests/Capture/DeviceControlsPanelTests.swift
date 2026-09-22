import AppKit
@testable import Snap_O
import SwiftUI
import Testing

@MainActor
struct DeviceControlsPanelTests {
  private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
  private let window = CGRect(x: 200, y: 150, width: 1000, height: 700)
  private let capture = CGRect(x: 200, y: 150, width: 360, height: 640)

  @Test
  func controlsFloatOutsideWindowInBothPositions() {
    let left = DeviceControlsAnchorView.panelFrame(
      placement: .left, size: CGSize(width: 36, height: 400),
      windowFrame: window, captureFrame: capture, screenFrame: screen
    )
    #expect(left.maxX == window.minX - 8)
    #expect(left.maxY == capture.maxY)
    let below = DeviceControlsAnchorView.panelFrame(
      placement: .below, size: CGSize(width: 340, height: 44),
      windowFrame: window, captureFrame: capture, screenFrame: screen
    )
    #expect(below.maxY == window.minY - 8)
    #expect(below.midX == capture.midX)
  }

  @Test(arguments: DeviceControlsPlacement.allCases)
  func controlsRemainOnScreenNearEdges(_ placement: DeviceControlsPlacement) {
    // A second screen can have negative coordinates.
    let screen = CGRect(x: -1440, y: -300, width: 1440, height: 900)
    let window = CGRect(x: -1440, y: -300, width: 360, height: 700)
    let size = placement == .left ? CGSize(width: 36, height: 400) : CGSize(width: 340, height: 44)
    let frame = DeviceControlsAnchorView.panelFrame(
      placement: placement, size: size, windowFrame: window, captureFrame: window, screenFrame: screen
    )
    #expect(screen.contains(frame))
    #expect(frame.size == size)
  }

  @Test
  func remembersPlacementAndHandlesUnknownSavedValues() throws {
    let suite = "DeviceControlsTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.deviceControlsPlacement == .left)
    settings.deviceControlsPlacement = .below
    #expect(AppSettings(defaults: defaults).deviceControlsPlacement == .below)
    settings.deviceControlsPlacement = .left
    #expect(AppSettings(defaults: defaults).deviceControlsPlacement == .left)
    defaults.set("unknown", forKey: "deviceControlsPlacement")
    #expect(AppSettings(defaults: defaults).deviceControlsPlacement == .left)
  }

  @Test
  func changingPlacementAndRemovingControlsPreservesCaptureSize() async throws {
    let window = NSWindow(
      contentRect: capture, styleMask: [.titled, .resizable], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    func content(_ placement: DeviceControlsPlacement?) -> some View {
      Color.gray.background {
        if let placement {
          DeviceControlsPanel(placement: placement) {
            Image(systemName: "circle").frame(width: 24, height: 32)
          }
        }
      }
    }
    let host = NSHostingView(rootView: content(nil))
    window.contentView = host
    let originalFrame = window.frame
    let originalContentSize = host.frame.size
    for placement: DeviceControlsPlacement? in [.left, .below, nil] {
      host.rootView = content(placement)
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
      #expect(window.frame == originalFrame)
      #expect(host.frame.size == originalContentSize)
    }
  }
}
