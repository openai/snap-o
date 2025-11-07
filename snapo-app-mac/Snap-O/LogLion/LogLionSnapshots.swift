import AppKit
import Foundation

// MARK: - Core Value Types

struct LogLionRange: Sendable, Hashable {
  var location: Int
  var length: Int

  init(location: Int, length: Int) {
    self.location = location
    self.length = length
  }

  init(nsRange: NSRange) {
    self.init(location: nsRange.location, length: nsRange.length)
  }

  var nsRange: NSRange {
    NSRange(location: location, length: length)
  }
}

struct LogLionColor: Sendable, Equatable {
  var red: Double
  var green: Double
  var blue: Double
  var alpha: Double

  init(red: Double, green: Double, blue: Double, alpha: Double) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  func withAlpha(_ value: Double) -> LogLionColor {
    LogLionColor(red: red, green: green, blue: blue, alpha: value)
  }

  func blended(with other: LogLionColor, fraction: Double) -> LogLionColor {
    guard (0...1).contains(fraction) else { return self }
    let inverse = 1 - fraction
    return LogLionColor(
      red: red * inverse + other.red * fraction,
      green: green * inverse + other.green * fraction,
      blue: blue * inverse + other.blue * fraction,
      alpha: alpha * inverse + other.alpha * fraction
    )
  }

  @MainActor
  init(nsColor: NSColor) {
    let converted = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
    red = Double(converted.redComponent)
    green = Double(converted.greenComponent)
    blue = Double(converted.blueComponent)
    alpha = Double(converted.alphaComponent)
  }

  @MainActor
  func makeNSColor() -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
  }
}

struct LogLionColorHighlight: Sendable, Equatable {
  let range: LogLionRange
  let color: LogLionColor
}

// MARK: - Filter Snapshots

struct LogLionQuickFilterSnapshot: Sendable, Equatable {
  var pattern: String
}

struct LogLionFilterClauseSnapshot: Sendable, Equatable {
  let field: LogLionFilterField
  let pattern: String
  let isInverted: Bool
  let isCaseSensitive: Bool
}

struct LogLionFilterConditionSnapshot: Sendable, Equatable {
  let clauses: [LogLionFilterClauseSnapshot]
}

struct LogLionFilterMatchSnapshot: Sendable, Equatable {
  let isMatch: Bool
  let fieldRanges: [LogLionFilterField: [LogLionRange]]

  static let noMatch = LogLionFilterMatchSnapshot(isMatch: false, fieldRanges: [:])
}

struct LogLionFilterSnapshot: Sendable, Equatable {
  let id: UUID
  let action: LogLionFilterAction
  let isHighlightEnabled: Bool
  let color: LogLionColor
  let conditions: [LogLionFilterConditionSnapshot]
}

struct LogLionFilterConfigurationSnapshot: Sendable, Equatable {
  var filters: [[LogLionFilterSnapshot]]
  var quickFilter: LogLionQuickFilterSnapshot?

  init(filters: [[LogLionFilterSnapshot]] = [],
       quickFilter: LogLionQuickFilterSnapshot? = nil) {
    self.filters = filters
    self.quickFilter = quickFilter
  }
}

struct LogLionRegexCacheKey: Hashable {
  let pattern: String
  let isCaseSensitive: Bool
}

// MARK: - Rendered Payloads

struct LogLionRenderedSnapshot: Sendable, Identifiable, Equatable {
  let id: UUID
  let entry: LogLionEntry
  let rowHighlightColor: LogLionColor?
  let fieldHighlights: [LogLionFilterField: [LogLionColorHighlight]]

  init(entry: LogLionEntry,
       rowHighlightColor: LogLionColor? = nil,
       fieldHighlights: [LogLionFilterField: [LogLionColorHighlight]] = [:]) {
    id = entry.id
    self.entry = entry
    self.rowHighlightColor = rowHighlightColor
    self.fieldHighlights = fieldHighlights
  }
}

struct LogLionTabMetrics: Sendable, Equatable {
  var unreadDelta: Int
  var droppedEntries: Int

  init(unreadDelta: Int = 0,
       droppedEntries: Int = 0) {
    self.unreadDelta = unreadDelta
    self.droppedEntries = droppedEntries
  }

  static let empty = LogLionTabMetrics()
}

enum LogLionTabError: Sendable, Equatable {
  case streamWarning(message: String)
  case regexFailure(pattern: String, message: String?)
  case backlogDropped(droppedCount: Int)
  case slowProcessing(count: Int)
  case stateInconsistency(message: String)
}

struct LogLionTabUpdate: Sendable, Equatable {
  var backingEntries: [LogLionEntry]
  var renderedEntries: [LogLionRenderedSnapshot]
  var metrics: LogLionTabMetrics
  var errors: [LogLionTabError]
  var didReset: Bool
  var isPinnedToBottomHint: Bool?

  init(backingEntries: [LogLionEntry] = [],
       renderedEntries: [LogLionRenderedSnapshot] = [],
       metrics: LogLionTabMetrics = .empty,
       errors: [LogLionTabError] = [],
       didReset: Bool = false,
       isPinnedToBottomHint: Bool? = nil) {
    self.backingEntries = backingEntries
    self.renderedEntries = renderedEntries
    self.metrics = metrics
    self.errors = errors
    self.didReset = didReset
    self.isPinnedToBottomHint = isPinnedToBottomHint
  }
}

// MARK: - Stream Events

enum LogLionStreamEvent: Sendable, Equatable {
  case connected
  case disconnected(reason: String?)
  case reconnecting(attempt: Int, reason: String?)
  case resumed
  case stopped
}

enum LogLionEvent: Sendable, Equatable {
  case entry(LogLionEntry)
  case stream(LogLionStreamEvent)
}

// MARK: - Builders

@MainActor
extension LogLionFilterSnapshot {
  init(filter: LogLionFilter) {
    let conditionSnapshots = [
      LogLionFilterConditionSnapshot(
        clauses: filter.condition.clauses.map { clause in
          LogLionFilterClauseSnapshot(
            field: clause.field,
            pattern: clause.pattern,
            isInverted: clause.isInverted,
            isCaseSensitive: clause.isCaseSensitive
          )
        }
      )
    ]

    self.init(
      id: filter.id,
      action: filter.action,
      isHighlightEnabled: filter.isHighlightEnabled,
      color: LogLionColor(nsColor: filter.accentNSColor),
      conditions: conditionSnapshots
    )
  }
}

extension LogLionFilterSnapshot {
  func evaluate(entry: LogLionEntry,
                regexCache: inout [LogLionRegexCacheKey: NSRegularExpression]) -> LogLionFilterMatchSnapshot {
    guard let condition = conditions.first else { return .noMatch }
    return evaluate(condition: condition, entry: entry, regexCache: &regexCache)
  }

  private func evaluate(condition: LogLionFilterConditionSnapshot,
                        entry: LogLionEntry,
                        regexCache: inout [LogLionRegexCacheKey: NSRegularExpression]) -> LogLionFilterMatchSnapshot {
    var didProcessClause = false
    var didFindMatch = false
    var fieldHighlights: [LogLionFilterField: [LogLionRange]] = [:]

    for clause in condition.clauses {
      guard !clause.pattern.isEmpty,
            let regex = cachedRegex(
              for: clause.pattern,
              isCaseSensitive: clause.isCaseSensitive,
              cache: &regexCache
            ),
            let target = entry.value(for: clause.field) else {
        continue
      }

      didProcessClause = true

      let nsString = target as NSString
      let fullRange = NSRange(location: 0, length: nsString.length)
      let matches = regex.matches(in: target, options: [], range: fullRange)

      let hasMatch = !matches.isEmpty
      let clausePasses = clause.isInverted ? !hasMatch : hasMatch
      guard clausePasses else { continue }

      didFindMatch = true

      guard !clause.isInverted else { continue }

      if clause.field == .raw {
        for candidateField in LogLionFilterField.allCases where candidateField != .raw {
          guard let candidateValue = entry.value(for: candidateField) else { continue }
          let candidateNSString = candidateValue as NSString
          let candidateRange = NSRange(location: 0, length: candidateNSString.length)
          let candidateMatches = regex.matches(in: candidateValue, options: [], range: candidateRange)
          if !candidateMatches.isEmpty {
            let ranges = candidateMatches.map { LogLionRange(nsRange: $0.range) }
            fieldHighlights[candidateField, default: []].append(contentsOf: ranges)
          }
        }
      } else {
        let ranges = matches.map { LogLionRange(nsRange: $0.range) }
        fieldHighlights[clause.field, default: []].append(contentsOf: ranges)
      }
    }

    guard didProcessClause else {
      return LogLionFilterMatchSnapshot(isMatch: true, fieldRanges: [:])
    }

    return LogLionFilterMatchSnapshot(isMatch: didFindMatch, fieldRanges: fieldHighlights)
  }

  private func cachedRegex(for pattern: String,
                           isCaseSensitive: Bool,
                           cache: inout [LogLionRegexCacheKey: NSRegularExpression]) -> NSRegularExpression? {
    let key = LogLionRegexCacheKey(pattern: pattern, isCaseSensitive: isCaseSensitive)
    if let existing = cache[key] {
      return existing
    }
    let options: NSRegularExpression.Options = isCaseSensitive ? [] : [.caseInsensitive]
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
      return nil
    }
    cache[key] = regex
    return regex
  }
}
