import AppKit
import Clocks
import DependenciesTestSupport
@testable import Snap_O
import SwiftUI
import Testing

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .dependency(\.continuousClock, TestClock()))
struct LivePreviewHeldKeyButtonTests {
  enum Ending: CaseIterable {
    case release, releaseOutside, removeView
  }

  @Test(arguments: Ending.allCases)
  func gestureSendsOnePressAndRelease(_ ending: Ending) async throws {
    let fixture = try SharedPreviewTestSupport.Fixture()
    let attachment = fixture.service.attach(to: fixture.target())
    try await fixture.focus(attachment)
    let keyboard = try #require(fixture.keyboards.first)
    let window = NSWindow(
      contentRect: CGRect(x: 200, y: 200, width: 128, height: 128),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: AnyView(
      LivePreviewHeldKeyButton(title: "Home", symbol: "circle", attachment: attachment, code: 3)
        .frame(width: 128, height: 128)
    ))
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    host.layoutSubtreeIfNeeded()

    func send(_ type: NSEvent.EventType, at point: CGPoint) throws {
      let event = try #require(NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
        pressure: type == .leftMouseUp ? 0 : 1
      ))
      window.sendEvent(event)
    }

    try send(.leftMouseDown, at: CGPoint(x: 64, y: 64))
    try await keyboard.waitForEvents(1)
    #expect(keyboard.events == [.keyDown(code: 3)])

    var releasePoint = CGPoint(x: 64, y: 64)
    switch ending {
    case .release:
      break
    case .releaseOutside:
      releasePoint = CGPoint(x: 110, y: 110)
      try send(.leftMouseDragged, at: releasePoint)
    case .removeView:
      host.rootView = AnyView(Color.clear)
      host.layoutSubtreeIfNeeded()
      try await keyboard.waitForEvents(2)
    }
    try send(.leftMouseUp, at: releasePoint)
    try await keyboard.waitForEvents(2)
    // Drain earlier input before teardown can discard an accidental extra click.
    let barrier = TestSuspension()
    keyboard.holdCopy(barrier)
    attachment.send(.copy)
    await barrier.waitUntilStarted()
    #expect(keyboard.events == [.keyDown(code: 3), .keyUp(code: 3), .copy])
    barrier.resume()
    await fixture.close()
  }
}
