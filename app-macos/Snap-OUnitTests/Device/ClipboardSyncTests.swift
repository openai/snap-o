import AppKit
import Testing

struct ClipboardSyncTests {
  @MainActor
  @Test(arguments: [nil, "", String(repeating: "A", count: ClipboardSyncState.maximumTextBytes + 1)])
  func initialSnapshotPreservesUnsupportedContent(text: String?) {
    let pasteboard = TextPasteboardDouble()
    if let text { pasteboard.replaceText(text) } else { pasteboard.setUnsupportedContent() }
    let originalCount = pasteboard.changeCount
    let sync = makeSync(pasteboard)
    #expect(sync.synchronizeInitialClipboard(with: "Old device text") == nil)
    sync.receive("Old device text")
    #expect(pasteboard.changeCount == originalCount)
    sync.receive("New device copy")
    #expect(pasteboard.text == "New device copy")
  }

  @MainActor
  @Test
  func initialSyncImportsOnlyIntoAnEmptyPasteboard() {
    let pasteboard = TextPasteboardDouble()
    let sync = makeSync(pasteboard)
    #expect(sync.synchronizeInitialClipboard(with: "Device text") == nil)
    #expect(pasteboard.text == "Device text")
    pasteboard.replaceText("Mac text")
    let nextSync = makeSync(pasteboard)
    #expect(nextSync.synchronizeInitialClipboard(with: "Old device text") == "Mac text")
    #expect(pasteboard.text == "Mac text")
  }

  @MainActor
  @Test(arguments: ["Shared text", "Unicode 📋\n第二行"])
  func matchingStartupTextIsNotRewritten(text: String) {
    let pasteboard = TextPasteboardDouble()
    pasteboard.replaceText(text)
    let originalCount = pasteboard.changeCount
    let sync = makeSync(pasteboard)
    #expect(sync.synchronizeInitialClipboard(with: text) == nil)
    sync.receive(text)
    #expect(pasteboard.changeCount == originalCount)
    // A skipped write must still allow subsequent device copies.
    sync.receive("New device copy")
    #expect(pasteboard.text == "New device copy")
    let reconnected = makeSync(pasteboard)
    #expect(reconnected.synchronizeInitialClipboard(with: "New device copy") == nil)
  }

  @MainActor
  private func makeSync(_ pasteboard: TextPasteboardDouble) -> ClipboardSync {
    let defaults = UserDefaults(suiteName: "ClipboardSyncTests." + UUID().uuidString)!
    return ClipboardSync(settings: AppSettings(defaults: defaults), pasteboard: pasteboard) { _, _ in
      Issue.record("Initial clipboard policy must not open a device connection")
    }
  }
}
