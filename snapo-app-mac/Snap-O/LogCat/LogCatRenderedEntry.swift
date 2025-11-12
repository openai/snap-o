import AppKit
import Foundation

struct LogCatRenderedEntry: Identifiable, Equatable {
  struct Highlight {
    let range: NSRange
    let color: NSColor
  }

  let id: UUID
  let entry: LogCatEntry
  let rowHighlightColor: NSColor?
  let fieldHighlights: [LogCatFilterField: [Highlight]]

  init(entry: LogCatEntry, rowHighlightColor: NSColor?, fieldHighlights: [LogCatFilterField: [Highlight]]) {
    id = entry.id
    self.entry = entry
    self.rowHighlightColor = rowHighlightColor
    self.fieldHighlights = fieldHighlights
  }

  func highlights(for field: LogCatFilterField?) -> [Highlight] {
    guard let field else { return [] }
    return fieldHighlights[field] ?? []
  }

  static func == (lhs: LogCatRenderedEntry, rhs: LogCatRenderedEntry) -> Bool {
    lhs.id == rhs.id
  }
}
