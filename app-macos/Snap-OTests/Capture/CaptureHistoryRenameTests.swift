import AppKit
@testable import Snap_O
import SwiftUI
import Testing

@Suite(.serialized)
@MainActor
struct CaptureHistoryRenameTests {
  @Test
  func enteringRenameFocusesAndSelectsTheNewField() async throws {
    let entry = CaptureHistoryEntry(
      id: UUID(), kind: .image, capturedAt: .now, completedAt: .now, items: [], name: "Test capture"
    )
    let view = NSHostingView(rootView: CaptureHistoryName(entry: entry, isEditing: .constant(false), rename: { _ in }))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    window.contentView = view
    defer { window.contentView = nil }
    view.layoutSubtreeIfNeeded()
    view.rootView = CaptureHistoryName(entry: entry, isEditing: .constant(true), rename: { _ in })
    view.layoutSubtreeIfNeeded()

    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while textField(in: view)?.currentEditor() == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    let field = try #require(textField(in: view))
    let editor = try #require(field.currentEditor())
    #expect(window.firstResponder === editor)
    #expect(editor.selectedRange == NSRange(location: 0, length: entry.displayName.utf16.count))

    editor.selectedRange = NSRange(location: 2, length: 0)
    view.rootView = CaptureHistoryName(entry: entry, isEditing: .constant(true), rename: { _ in })
    view.layoutSubtreeIfNeeded()
    await Task.yield()
    #expect(editor.selectedRange == NSRange(location: 2, length: 0), "Updates must not reset the user's insertion point")
  }

  private func textField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField { return field }
    return view.subviews.lazy.compactMap { textField(in: $0) }.first
  }
}
