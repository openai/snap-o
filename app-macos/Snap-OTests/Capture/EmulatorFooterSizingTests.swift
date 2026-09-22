import AppKit
@testable import Snap_O
import Testing

@Suite("Emulator footer sizing")
@MainActor
struct EmulatorFooterSizingTests {
  @Test
  func resizingPreservesPreviewAspectAboveFooter() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let coordinator = WindowSizingController.Coordinator()
    let display = DisplayInfo(size: CGSize(width: 1080, height: 2400), densityScale: 3)
    coordinator.update(
      layout: .capture, displayInfo: display, capturePaneWidth: 360, captureFooterHeight: EmulatorFooter.height,
      capturePaneWidthChanged: { _ in }, presentationChanged: { _ in }
    )
    coordinator.attach(to: window)
    let resized = coordinator.windowWillResize(window, to: NSSize(width: 400, height: 500))
    let previewHeight = resized.height - WindowChromeMetrics.totalToolbarHeight - EmulatorFooter.height
    #expect(abs(previewHeight - resized.width / display.aspectRatio) <= 0.5)
  }

  @Test
  func toolWindowDoesNotReserveFooterSpace() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let coordinator = WindowSizingController.Coordinator()
    coordinator.update(
      layout: .tool, displayInfo: nil, capturePaneWidth: 360, captureFooterHeight: EmulatorFooter.height,
      capturePaneWidthChanged: { _ in }, presentationChanged: { _ in }
    )
    coordinator.attach(to: window)
    let proposed = NSSize(width: 1000, height: 700)
    #expect(coordinator.windowWillResize(window, to: proposed) == proposed)
  }

  @Test(arguments: [WorkspaceLayout.capture, .both])
  func footerHeightChangesPreserveUserWindowSize(layout: WorkspaceLayout) async throws {
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 1100, height: 700),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let coordinator = WindowSizingController.Coordinator()
    func update(footerHeight: CGFloat, density: CGFloat) {
      coordinator.update(
        layout: layout,
        displayInfo: DisplayInfo(size: CGSize(width: 1080, height: 1920), densityScale: density),
        capturePaneWidth: 360, captureFooterHeight: footerHeight,
        capturePaneWidthChanged: { _ in }, presentationChanged: { _ in }
      )
    }
    update(footerHeight: 0, density: 3)
    coordinator.attach(to: window)
    window.setFrame(
      NSRect(x: 100, y: 100, width: layout == .capture ? 340 : 1100, height: 700),
      display: false
    )
    let original = window.frame
    // Switching capture modes can update display metadata in the same render as the footer.
    update(footerHeight: EmulatorFooter.height, density: 2.75)
    try await Task.sleep(for: .milliseconds(400))
    #expect(abs(window.frame.width - original.width) < 0.5)
    #expect(abs(window.frame.maxY - original.maxY) < 0.5)
    #expect(abs(window.frame.height - original.height - EmulatorFooter.height) < 0.5)
    update(footerHeight: 0, density: 3)
    try await Task.sleep(for: .milliseconds(400))
    #expect(abs(window.frame.height - original.height) < 0.5)
    #expect(abs(window.frame.width - original.width) < 0.5)
    update(footerHeight: EmulatorFooter.height, density: 3)
    update(footerHeight: 0, density: 3)
    try await Task.sleep(for: .milliseconds(800))
    #expect(abs(window.frame.height - original.height) < 0.5)
    #expect(abs(window.frame.maxY - original.maxY) < 0.5)
  }
}
