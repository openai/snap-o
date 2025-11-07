import AppKit
import Foundation

struct LogLionRenderedEntry: Identifiable, Equatable {
  struct Highlight {
    let range: NSRange
    let color: NSColor
  }

  let id: UUID
  let entry: LogLionEntry
  let rowHighlightColor: NSColor?
  let fieldHighlights: [LogLionFilterField: [Highlight]]

  init(entry: LogLionEntry, rowHighlightColor: NSColor?, fieldHighlights: [LogLionFilterField: [Highlight]]) {
    self.id = entry.id
    self.entry = entry
    self.rowHighlightColor = rowHighlightColor
    self.fieldHighlights = fieldHighlights
  }

  func highlights(for field: LogLionFilterField?) -> [Highlight] {
    guard let field else { return [] }
    return fieldHighlights[field] ?? []
  }

  static func == (lhs: LogLionRenderedEntry, rhs: LogLionRenderedEntry) -> Bool {
    lhs.id == rhs.id
  }
}
