import Foundation
import Testing

struct ClipboardSyncStateTests {
  @MainActor
  @Test
  func preferenceDefaultsOnAndRemembersBothChoices() throws {
    let suite = "SnapOClipboardTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.syncClipboard)
    settings.syncClipboard = false
    #expect(!AppSettings(defaults: defaults).syncClipboard)
    settings.syncClipboard = true
    #expect(AppSettings(defaults: defaults).syncClipboard)
  }

  @Test
  func hostCopiesAreSentOnceAndDeviceCopiesAreNotEchoed() {
    var state = ClipboardSyncState()
    #expect(state.hostText("Mac text", changeCount: 1) == "Mac text")
    #expect(state.hostText("Mac text", changeCount: 1) == nil)
    #expect(state.shouldReceive("Mac text", hostChangeCount: 1) == false)
    #expect(state.shouldReceive("Android text", hostChangeCount: 1) == true)
    state.received("Android text", changeCount: 2)
    #expect(state.hostText("Android text", changeCount: 2) == nil)
    #expect(state.hostText("Android text", changeCount: 3) == nil)
  }

  @Test
  func newerHostCopyWinsOverAnIncomingUpdate() {
    var state = ClipboardSyncState()
    _ = state.hostText("First copy", changeCount: 1)
    #expect(state.shouldReceive("Android copy", hostChangeCount: 2) == false)
    #expect(state.hostText("Newer Mac copy", changeCount: 2) == "Newer Mac copy")
  }

  @Test
  func ignoresAnOlderInitialSnapshotWithoutDroppingTheFirstRealCopy() {
    var state = ClipboardSyncState()
    _ = state.hostText("Mac copy", changeCount: 1)
    state.ignoreInitialSnapshot(matching: "Older Android copy")
    #expect(state.shouldReceive("Older Android copy", hostChangeCount: 1) == false)
    #expect(state.shouldReceive("New Android copy", hostChangeCount: 1) == true)

    state.ignoreInitialSnapshot(matching: "")
    #expect(state.shouldReceive("First Android copy after an empty clipboard", hostChangeCount: 1) == true)
  }

  @Test
  func skipsEmptyNontextAndOversizedCopies() {
    var state = ClipboardSyncState()
    #expect(state.hostText(nil, changeCount: 1) == nil)
    #expect(state.hostText("", changeCount: 2) == nil)
    #expect(state.hostText(String(repeating: "a", count: ClipboardSyncState.maximumTextBytes + 1), changeCount: 3) == nil)
    #expect(state.shouldReceive("", hostChangeCount: 3) == false)
    #expect(state.hostText("Unicode 📋\n第二行", changeCount: 4) == "Unicode 📋\n第二行")
  }
}
