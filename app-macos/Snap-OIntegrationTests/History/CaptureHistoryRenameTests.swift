import AppKit
@testable import Snap_O
import SwiftUI
import Testing

@Suite(.serialized)
@MainActor
struct CaptureHistoryRenameTests {
  @Test
  func enteringRenameFocusesAndSelectsTheNewField() throws {
    let entry = CaptureHistoryEntry(
      id: UUID(), kind: .image, capturedAt: .now, completedAt: .now, items: [], name: "Test capture"
    )
    let field = CaptureHistoryRenameField()
    var focus: (@MainActor @Sendable () -> Void)?
    field.scheduleFocus = { focus = $0 }
    let parent = CaptureHistoryNameField(entry: entry, isEditing: .constant(true), rename: { _ in })
    let coordinator = parent.makeCoordinator()
    coordinator.beginEditing(field)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    window.contentView = field
    defer { window.contentView = nil }
    let scheduledFocus = try #require(focus)
    scheduledFocus()
    let editor = try #require(field.currentEditor())
    #expect(window.firstResponder === editor)
    #expect(editor.selectedRange == NSRange(location: 0, length: entry.displayName.utf16.count))

    editor.selectedRange = NSRange(location: 2, length: 0)
    coordinator.beginEditing(field)
    #expect(editor.selectedRange == NSRange(location: 2, length: 0), "Updates must not reset the user's insertion point")
  }
}
