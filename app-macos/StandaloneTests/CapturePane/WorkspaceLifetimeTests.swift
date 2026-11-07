import AppKit
import Foundation
import Testing

extension CapturePaneTests {
  @Test
  func unusedWindowsAreReleasedAndLateWindowsCannotStart() async {
    let fixture = Fixture()
    let workspaces = fixture.workspaces()
    weak var released: CaptureWindowSession?
    do {
      let session = workspaces.makeSession()
      released = session
    }
    #expect(released == nil)
    await workspaces.shutdown()
    let late = workspaces.makeSession()
    #expect(late.isClosed)
    late.showLivePreview()
    late.openDevice(.serial("A"))
    late.startIfNeeded()
    await late.close().value
    #expect(fixture.recordings.value.isEmpty)
    #expect(late.capture.deviceOpenRequest == nil)
    await fixture.close()
  }

  @Test
  func workspaceShutdownJoinsOpenAndAlreadyClosingWindows() async throws {
    let fixture = Fixture()
    let workspaces = fixture.workspaces()
    let first = workspaces.makeSession()
    let second = workspaces.makeSession()
    await fixture.start(first.capture, second.capture)
    first.capture.startRecording()
    second.capture.startRecording()
    let firstBatch = try #require(first.capture.recording)
    let secondBatch = try #require(second.capture.recording)
    let firstGate = TestSuspension()
    let secondGate = TestSuspension()
    firstBatch.closeGate = firstGate
    secondBatch.closeGate = secondGate
    let firstClose = first.close()
    await firstGate.waitUntilStarted()
    let finished = TestValue(false)
    let shutdown = Task { await workspaces.shutdown()
      finished.value = true
    }
    await secondGate.waitUntilStarted()
    #expect(first.isClosed && second.isClosed && !finished.value)
    let repeated = workspaces.beginShutdown()
    firstGate.resume()
    await firstClose.value
    #expect(!finished.value, "The second window still owns pending cleanup")
    secondGate.resume()
    await shutdown.value
    await repeated.value
    #expect(firstBatch.closeCount == 1 && secondBatch.closeCount == 1)
    await fixture.close()
  }

  @Test(.enabled(if: CommandLine.arguments.contains("--windows")))
  func hiddenLaunchWindowCanBeReusedThenClosed() async throws {
    _ = NSApplication.shared
    let fixture = Fixture()
    let pane = fixture.pane()
    let session = fixture.window(pane, showsCapture: false, showsTool: true)
    session.showLivePreview()
    let window = Self.testWindow()
    session.attach(to: window)
    #expect(!window.isVisible && !session.isClosed)
    #expect(fixture.screenshots.value.isEmpty && fixture.recordings.value.isEmpty)
    window.close()
    #expect(!session.isClosed, "Closing an unused SwiftUI launch window must preserve pending commands")
    session.attach(to: window)
    window.orderFront(nil)
    NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
    try await waitForState { pane.currentPreview != nil }
    #expect(session.tools.starts == 1)
    window.close()
    #expect(session.isClosed)
    await session.close().value
    await fixture.close()
  }

  @Test(.enabled(if: CommandLine.arguments.contains("--windows")))
  func remountKeepsTheWindowSessionAndOtherWindowsPreview() async throws {
    _ = NSApplication.shared
    let fixture = Fixture()
    let pane = fixture.pane()
    let other = fixture.pane()
    let session = fixture.window(pane, showsCapture: true, showsTool: true)
    let window = Self.testWindow()
    session.attach(to: window)
    window.orderFront(nil)
    NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
    try await waitForState { pane.currentPreview != nil }
    await fixture.start(other)
    let ownAttachment = try #require(pane.livePreviewAttachment(for: "A"))
    let otherAttachment = try #require(other.livePreviewAttachment(for: "A"))
    for _ in 0 ..< 3 {
      window.contentView = NSView()
      session.attach(to: window)
    }
    #expect(pane.livePreviewAttachment(for: "A") === ownAttachment)
    #expect(session.tools.starts == 1)
    window.close()
    await session.close().value
    #expect(ownAttachment.isClosed && !otherAttachment.isClosed)
    session.startIfNeeded()
    session.showLivePreview()
    #expect(fixture.recordings.value.isEmpty)
    await other.close()
    await fixture.close()
  }

  private static func testWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: -10000, y: -10000, width: 1, height: 1),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = NSView()
    return window
  }
}
