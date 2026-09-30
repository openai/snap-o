import AppKit
@testable import Snap_O
import Testing

@Suite("Recording Escape shortcut", .serialized)
@MainActor
struct RecordingEscapeHandlerTests {
  @Test
  func stopsWithNativeFocusAndRemovesMonitorOnDetach() throws {
    let window = RecordingTestWindow()
    let content = RecordingFocusTarget()
    let handler = RecordingEscapeHandler.EscapeView()
    window.contentView = content
    content.addSubview(handler)
    defer { window.contentView = nil }
    #expect(window.makeFirstResponder(content))
    var stops = 0
    handler.stopRecording = { stops += 1 }
    let escape = try keyEvent(in: window)

    #expect(!handler.handleKeyDown(escape), "Idle previews must still receive Escape")
    NSApp.sendEvent(escape)
    #expect(stops == 0)

    handler.isRecording = true
    NSApp.sendEvent(escape)
    #expect(stops == 1, "The monitor must stop recording even when a native view has focus")
    #expect(window.firstResponder === content)
    #expect(handler.handleKeyDown(escape), "Recording Escape must be consumed before reaching the preview")
    #expect(stops == 2)
    let repeatedEscape = try keyEvent(in: window, isRepeat: true)
    #expect(handler.handleKeyDown(repeatedEscape))
    NSApp.sendEvent(repeatedEscape)
    #expect(stops == 2, "Holding Escape must not request another stop")

    handler.removeFromSuperview()
    NSApp.sendEvent(escape)
    #expect(stops == 2, "Removing the handler must remove its event monitor")
    #expect(!handler.handleKeyDown(escape))
  }

  @Test
  func onlyStopsTheRecordingInTheKeyWindow() throws {
    let first = RecordingTestWindow()
    let second = RecordingTestWindow()
    let firstHandler = RecordingEscapeHandler.EscapeView()
    let secondHandler = RecordingEscapeHandler.EscapeView()
    first.contentView = firstHandler
    second.contentView = secondHandler
    defer {
      first.contentView = nil
      second.contentView = nil
    }
    var stops = [0, 0]
    firstHandler.isRecording = true
    secondHandler.isRecording = true
    firstHandler.stopRecording = { stops[0] += 1 }
    secondHandler.stopRecording = { stops[1] += 1 }
    first.testIsKey = false

    try NSApp.sendEvent(keyEvent(in: second))
    #expect(stops == [0, 1])
    #expect(try !firstHandler.handleKeyDown(keyEvent(in: first)))
    #expect(try !firstHandler.handleKeyDown(keyEvent(in: second)))
    first.testIsKey = true
    second.testIsKey = false
    try NSApp.sendEvent(keyEvent(in: first))
    #expect(stops == [1, 1])
  }

  @Test
  func preservesOtherKeysModifiersAndSheets() throws {
    let window = RecordingTestWindow()
    let handler = RecordingEscapeHandler.EscapeView()
    window.contentView = handler
    defer { window.contentView = nil }
    handler.isRecording = true
    var stops = 0
    handler.stopRecording = { stops += 1 }

    for modifiers: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
      #expect(try !handler.handleKeyDown(keyEvent(in: window, modifiers: modifiers)))
    }
    #expect(try !handler.handleKeyDown(keyEvent(in: window, code: 36)))
    window.testSheet = NSWindow()
    #expect(try !handler.handleKeyDown(keyEvent(in: window)))
    window.testSheet = nil
    #expect(stops == 0)
    #expect(try handler.handleKeyDown(keyEvent(in: window, modifiers: .capsLock)))
    #expect(stops == 1)
  }

  @Test
  func letsTextCompositionHandleEscapeFirst() throws {
    let window = RecordingTestWindow()
    let text = NSTextView()
    let handler = RecordingEscapeHandler.EscapeView()
    window.contentView = text
    text.addSubview(handler)
    defer { window.contentView = nil }
    #expect(window.makeFirstResponder(text))
    handler.isRecording = true
    var stops = 0
    handler.stopRecording = { stops += 1 }
    text.setMarkedText(
      "compose",
      selectedRange: NSRange(location: 7, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    #expect(text.hasMarkedText())
    #expect(try !handler.handleKeyDown(keyEvent(in: window)))
    #expect(stops == 0)
    text.unmarkText()
    #expect(try handler.handleKeyDown(keyEvent(in: window)))
    #expect(stops == 1)
  }

  private func keyEvent(
    in window: NSWindow, code: UInt16 = 53, modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false
  ) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
      charactersIgnoringModifiers: "\u{1B}", isARepeat: isRepeat, keyCode: code
    ))
  }
}

@MainActor
private final class RecordingTestWindow: NSWindow {
  var testIsKey = true
  var testSheet: NSWindow?

  init() {
    super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
  }

  override var isKeyWindow: Bool {
    testIsKey
  }

  override var attachedSheet: NSWindow? {
    testSheet
  }
}

@MainActor
private final class RecordingFocusTarget: NSView {
  override var acceptsFirstResponder: Bool {
    true
  }
}
