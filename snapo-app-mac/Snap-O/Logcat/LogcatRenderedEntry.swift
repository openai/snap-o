import AppKit
import Foundation

struct LogcatRenderedEntry: Identifiable, Equatable {
  struct Highlight {
    let range: NSRange
    let color: NSColor
  }

  let id: UUID
  let entry: LogcatEntry
  let rowHighlightColor: NSColor?
  let fieldHighlights: [LogcatFilterField: [Highlight]]

  init(entry: LogcatEntry, rowHighlightColor: NSColor?, fieldHighlights: [LogcatFilterField: [Highlight]]) {
    id = entry.id
    self.entry = entry
    self.rowHighlightColor = rowHighlightColor
    self.fieldHighlights = fieldHighlights
  }

  func highlights(for field: LogcatFilterField?) -> [Highlight] {
    guard let field else { return [] }
    return fieldHighlights[field] ?? []
  }

  static func == (lhs: LogcatRenderedEntry, rhs: LogcatRenderedEntry) -> Bool {
    lhs.id == rhs.id
  }
}
