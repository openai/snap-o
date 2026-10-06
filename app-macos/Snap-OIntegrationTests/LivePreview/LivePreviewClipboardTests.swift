import Clocks
import DependenciesTestSupport
import Foundation
#if !SNAPO_STANDALONE_TESTS
@testable import Snap_O
#endif
import Testing

@MainActor
@Suite(.dependency(\.continuousClock, TestClock()))
struct LivePreviewClipboardTests {
  enum Disable: CaseIterable { case hidden, inactive, preference }

  @Test(arguments: Disable.allCases)
  func disabledClipboardRejectsUpdates(reason: Disable) async throws {
    let fixture = try SharedLivePreviewTests.Fixture()
    let attachment = fixture.service.attach(to: fixture.target())
    try await fixture.focus(attachment)
    try await waitForState { fixture.clipboards.count == 1 }
    await fixture.clipboards[0].waitUntilReceiving()
    switch reason {
    case .hidden: attachment.setVisible(false)
    case .inactive: attachment.setFocused(false)
    case .preference: attachment.setClipboardEnabled(false)
    }
    await fixture.clipboards[0].deliver("background device")
    #expect(fixture.pasteboard.string(forType: .string) != "background device")
    #expect(fixture.sources[0].stops == (reason == .hidden ? 1 : 0))
    await fixture.close()
  }

  @Test
  func oldViewCannotDisableClipboardAfterRemount() async throws {
    let fixture = try SharedLivePreviewTests.Fixture()
    let attachment = fixture.service.attach(to: fixture.target())
    let old = UUID()
    attachment.mount(old)
    attachment.updatePresentation(viewID: old, visible: true, focused: true, syncClipboard: true)
    try await waitForState { attachment.acceptsInput && fixture.clipboards.count == 1 }
    await fixture.clipboards[0].waitUntilReceiving()
    let current = UUID()
    attachment.mount(current)
    attachment.updatePresentation(viewID: current, visible: true, focused: true, syncClipboard: true)
    attachment.updatePresentation(viewID: old, visible: false, focused: false, syncClipboard: false)
    attachment.unmount(old)
    await fixture.clipboards[0].deliver("current device")
    #expect(fixture.pasteboard.string(forType: .string) == "current device")
    #expect(fixture.clipboardConnections == 1)
    await fixture.close()
  }

  @Test
  func closeRejectsLateClipboardAndJoinsConnectionCleanup() async throws {
    let fixture = try SharedLivePreviewTests.Fixture()
    let cleanup = TestSuspension()
    fixture.clipboardCleanup = cleanup
    let attachment = fixture.service.attach(to: fixture.target())
    try await fixture.focus(attachment)
    try await waitForState { fixture.clipboards.count == 1 }
    await fixture.clipboards[0].waitUntilReceiving()
    let finished = TestValue(false)
    let close = Task { await attachment.close(); finished.value = true }
    await cleanup.waitUntilStarted()
    await fixture.clipboards[0].deliver("late device")
    #expect(fixture.pasteboard.string(forType: .string) != "late device")
    #expect(!finished.value)
    cleanup.resume()
    await close.value
    await fixture.close()
  }
}
