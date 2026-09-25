import AppKit

extension LivePreviewDisplayView: @preconcurrency NSTextInputClient {
  var canSendKeyboardInput: Bool {
    keyboardArmed && keyboard != nil && hasVisiblePreview
      && window?.firstResponder === self && window?.isKeyWindow == true && NSApp.isActive
  }

  func configureKeyboard(_ handler: (any LivePreviewKeyboardHandling)?) {
    guard keyboard !== handler else { return }
    releaseKeyboardFocus()
    keyboard?.stop()
    keyboard = handler
    keyboard?.prepare()
  }

  func releaseKeyboardFocus() {
    keyboardArmed = false
    unmarkText()
    inputContext?.discardMarkedText()
    keyboard?.discardPendingInput()
  }

  override func resignFirstResponder() -> Bool {
    releaseKeyboardFocus()
    return super.resignFirstResponder()
  }

  override func keyDown(with event: NSEvent) {
    guard canSendKeyboardInput, !event.modifierFlags.contains(.command) else {
      super.keyDown(with: event)
      return
    }
    if event.keyCode == 53 {
      if cancelGestureForEscape() { return }
      if hasMarkedText() {
        unmarkText()
        inputContext?.discardMarkedText()
        return
      }
    }
    if !hasMarkedText(), let code = Self.androidKeyCode(event.keyCode) {
      sendKeyboard(.key(code: code, modifiers: event.modifierFlags.contains(.shift) ? 1 : 0))
    } else {
      interpretKeyEvents([event])
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard canSendKeyboardInput,
          event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else {
      return super.performKeyEquivalent(with: event)
    }
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "c": copy(nil)
    case "v": paste(nil)
    default: return super.performKeyEquivalent(with: event)
    }
    return true
  }

  @objc
  func paste(_ sender: Any?) {
    guard canSendKeyboardInput, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
    sendKeyboard(.paste(text))
  }

  func sendKeyboard(_ event: LivePreviewKeyboardEvent) {
    guard canSendKeyboardInput else { return }
    keyboard?.send(event)
  }

  static func androidKeyCode(_ macCode: UInt16) -> UInt32? {
    switch macCode {
    case 36, 76: 66 // Return and keypad Enter.
    case 48: 61 // Tab.
    case 51: 67 // Backspace.
    case 53: 111 // Escape.
    case 117: 112 // Forward delete.
    case 123: 21 // Left.
    case 124: 22 // Right.
    case 125: 20 // Down.
    case 126: 19 // Up.
    case 115: 122 // Home.
    case 119: 123 // End.
    default: nil
    }
  }

  func insertText(_ string: Any, replacementRange: NSRange) {
    let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    unmarkText()
    if !text.isEmpty { sendKeyboard(.text(text)) }
  }

  override func doCommand(by selector: Selector) {
    let code: UInt32? = switch selector {
    case #selector(insertNewline(_:)): 66
    case #selector(insertTab(_:)), #selector(insertBacktab(_:)): 61
    case #selector(deleteBackward(_:)): 67
    case #selector(deleteForward(_:)): 112
    case #selector(moveLeft(_:)): 21
    case #selector(moveRight(_:)): 22
    case #selector(moveDown(_:)): 20
    case #selector(moveUp(_:)): 19
    default: nil
    }
    if let code { sendKeyboard(.key(code: code)) }
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    guard canSendKeyboardInput else { return }
    markedText = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
    markedSelection = selectedRange
  }

  func unmarkText() {
    markedText = NSAttributedString()
    markedSelection = NSRange(location: 0, length: 0)
  }

  func hasMarkedText() -> Bool {
    markedText.length > 0
  }

  func markedRange() -> NSRange {
    NSRange(location: hasMarkedText() ? 0 : NSNotFound, length: markedText.length)
  }

  func selectedRange() -> NSRange {
    markedSelection
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    []
  }

  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
    let intersection = NSIntersectionRange(range, NSRange(location: 0, length: markedText.length))
    actualRange?.pointee = intersection
    return intersection.length > 0 ? markedText.attributedSubstring(from: intersection) : nil
  }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    actualRange?.pointee = markedRange()
    return window?.convertToScreen(convert(NSRect(x: bounds.midX, y: bounds.maxY, width: 1, height: 1), to: nil)) ?? .zero
  }

  func characterIndex(for point: NSPoint) -> Int {
    NSNotFound
  }
}
