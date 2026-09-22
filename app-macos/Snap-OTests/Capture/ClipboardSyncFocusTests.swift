import AppKit
@testable import Snap_O
import Testing

@MainActor
struct ClipboardSyncFocusTests {
  @Test
  func switchingFocusStopsThePreviousPreview() throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let first = fixture.makeFocus()
    let second = fixture.makeFocus()
    first.update(focused: true, appActive: true)

    first.update(focused: false, appActive: true)
    second.update(focused: true, appActive: true)

    first.sync?.receive("background device")
    #expect(fixture.pasteboard.string(forType: .string) == nil)
    second.sync?.receive("focused device")
    #expect(fixture.pasteboard.string(forType: .string) == "focused device")
  }

  @Test
  func appDeactivationStopsTheFocusedPreview() throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let focus = fixture.makeFocus()
    focus.update(focused: true, appActive: true)

    focus.update(focused: true, appActive: false)

    focus.sync?.receive("inactive device")
    #expect(fixture.pasteboard.string(forType: .string) == nil)
    #expect(!focus.isActive)
  }
}

@MainActor
private final class Fixture {
  let suite = "ClipboardFocusTests." + UUID().uuidString
  let settings: AppSettings
  let pasteboard: NSPasteboard
  let defaults: UserDefaults

  init() throws {
    defaults = try #require(UserDefaults(suiteName: suite))
    settings = AppSettings(defaults: defaults)
    pasteboard = NSPasteboard(name: .init(suite))
  }

  func makeFocus() -> ClipboardSyncFocus {
    let focus = ClipboardSyncFocus()
    focus.sync = ClipboardSync(settings: settings, pasteboard: pasteboard)
    _ = focus.sync?.synchronizeInitialClipboard(with: "")
    return focus
  }

  func close() {
    pasteboard.releaseGlobally()
    defaults.removePersistentDomain(forName: suite)
  }
}
