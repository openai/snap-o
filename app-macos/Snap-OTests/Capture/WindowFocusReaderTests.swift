import AppKit
@testable import Snap_O
import Testing

@MainActor
struct WindowFocusReaderTests {
  @Test
  func switchingFocusTransfersClipboardSyncToTheSecondPreview() throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    fixture.first.focused = true
    fixture.notify(NSWindow.didBecomeKeyNotification, window: fixture.first)
    let previous = try #require(fixture.firstSync)

    fixture.first.focused = false
    fixture.notify(NSWindow.didResignKeyNotification, window: fixture.first)
    fixture.second.focused = true
    fixture.notify(NSWindow.didBecomeKeyNotification, window: fixture.second)

    previous.receive("first device")
    #expect(fixture.pasteboard.string(forType: .string) == nil)
    let current = try #require(fixture.secondSync)
    current.receive("second device")
    #expect(fixture.pasteboard.string(forType: .string) == "second device")
  }

  @Test
  func appDeactivationStopsClipboardEvenWhenWindowRemainsKey() throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    fixture.first.focused = true
    fixture.notify(NSWindow.didBecomeKeyNotification, window: fixture.first)
    let sync = try #require(fixture.firstSync)

    fixture.active = false
    fixture.notify(NSApplication.didResignActiveNotification)

    sync.receive("inactive device")
    #expect(fixture.pasteboard.string(forType: .string) == nil)
  }
}

@MainActor
private final class FocusWindow: NSWindow {
  var focused = false
  override var isKeyWindow: Bool {
    focused
  }
}

@MainActor
private final class Fixture {
  let first = FocusWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
  let second = FocusWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
  let suite = "WindowFocusTests." + UUID().uuidString
  let settings: AppSettings
  let pasteboard: NSPasteboard
  let defaults: UserDefaults
  var active = true
  let firstFocus = ClipboardSyncFocus()
  let secondFocus = ClipboardSyncFocus()
  var firstSync: ClipboardSync? {
    firstFocus.isFocused ? firstFocus.sync : nil
  }

  var secondSync: ClipboardSync? {
    secondFocus.isFocused ? secondFocus.sync : nil
  }

  init() throws {
    defaults = try #require(UserDefaults(suiteName: suite))
    settings = AppSettings(defaults: defaults)
    pasteboard = NSPasteboard(name: .init(suite))
    first.isReleasedWhenClosed = false
    second.isReleasedWhenClosed = false
    first.contentView = WindowFocusReaderView(isAppActive: { [weak self] in self?.active == true }) { [weak self] focused in
      guard let self else { return }
      firstFocus.update(focused: focused)
      firstFocus.sync = focused ? ClipboardSync(settings: settings, pasteboard: pasteboard) : nil
      _ = firstSync?.synchronizeInitialClipboard(with: "")
    }
    second.contentView = WindowFocusReaderView(isAppActive: { [weak self] in self?.active == true }) { [weak self] focused in
      guard let self else { return }
      secondFocus.update(focused: focused)
      secondFocus.sync = focused ? ClipboardSync(settings: settings, pasteboard: pasteboard) : nil
      _ = secondSync?.synchronizeInitialClipboard(with: "")
    }
  }

  func notify(_ name: Notification.Name, window: NSWindow? = nil) {
    NotificationCenter.default.post(name: name, object: window)
  }

  func close() {
    first.contentView = nil
    second.contentView = nil
    first.close()
    second.close()
    pasteboard.releaseGlobally()
    defaults.removePersistentDomain(forName: suite)
  }
}
