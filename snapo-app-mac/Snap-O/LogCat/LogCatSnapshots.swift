import AppKit
import Foundation

// MARK: - Core Value Types

struct LogCatRange: Sendable, Hashable {
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

struct LogCatColor: Sendable, Equatable {
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

  func withAlpha(_ value: Double) -> LogCatColor {
    LogCatColor(red: red, green: green, blue: blue, alpha: value)
  }

  func blended(with other: LogCatColor, fraction: Double) -> LogCatColor {
    guard (0 ... 1).contains(fraction) else { return self }
    let inverse = 1 - fraction
    return LogCatColor(
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

extension LogCatColor: Codable {}

struct LogCatColorHighlight: Sendable, Equatable {
  let range: LogCatRange
  let color: LogCatColor
}

// MARK: - Filter Snapshots

struct LogCatQuickFilterSnapshot: Sendable, Equatable {
  var pattern: String
}

struct LogCatFilterClauseSnapshot: Sendable, Equatable {
  let field: LogCatFilterField
  let pattern: String
  let isInverted: Bool
  let isCaseSensitive: Bool
}

struct LogCatFilterConditionSnapshot: Sendable, Equatable {
  let clauses: [LogCatFilterClauseSnapshot]
}

struct LogCatFilterMatchSnapshot: Sendable, Equatable {
  let isMatch: Bool
  let fieldRanges: [LogCatFilterField: [LogCatRange]]

  static let noMatch = LogCatFilterMatchSnapshot(isMatch: false, fieldRanges: [:])
}

struct LogCatFilterSnapshot: Sendable, Equatable {
  let id: UUID
  let action: LogCatFilterAction
  let isHighlightEnabled: Bool
  let color: LogCatColor
  let conditions: [LogCatFilterConditionSnapshot]
}

struct LogCatFilterConfigurationSnapshot: Sendable, Equatable {
  var filters: [[LogCatFilterSnapshot]]
  var quickFilter: LogCatQuickFilterSnapshot?

  init(
    filters: [[LogCatFilterSnapshot]] = [],
    quickFilter: LogCatQuickFilterSnapshot? = nil
  ) {
    self.filters = filters
    self.quickFilter = quickFilter
  }
}

struct LogCatRegexCacheKey: Hashable {
  let pattern: String
  let isCaseSensitive: Bool
}

// MARK: - Rendered Payloads

struct LogCatRenderedSnapshot: Sendable, Identifiable, Equatable {
  let id: UUID
  let entry: LogCatEntry
  let rowHighlightColor: LogCatColor?
  let fieldHighlights: [LogCatFilterField: [LogCatColorHighlight]]

  init(
    entry: LogCatEntry,
    rowHighlightColor: LogCatColor? = nil,
    fieldHighlights: [LogCatFilterField: [LogCatColorHighlight]] = [:]
  ) {
    id = entry.id
    self.entry = entry
    self.rowHighlightColor = rowHighlightColor
    self.fieldHighlights = fieldHighlights
  }
}

struct LogCatTabMetrics: Sendable, Equatable {
  var unreadDelta: Int
  var droppedEntries: Int

  init(
    unreadDelta: Int = 0,
    droppedEntries: Int = 0
  ) {
    self.unreadDelta = unreadDelta
    self.droppedEntries = droppedEntries
  }

  static let empty = LogCatTabMetrics()
}

enum LogCatTabError: Sendable, Equatable {
  case streamWarning(message: String)
  case regexFailure(pattern: String, message: String?)
  case backlogDropped(droppedCount: Int)
  case slowProcessing(count: Int)
  case stateInconsistency(message: String)
}

struct LogCatTabUpdate: Sendable, Equatable {
  var entryCount: Int
  var renderedEntries: [LogCatRenderedSnapshot]
  var metrics: LogCatTabMetrics
  var errors: [LogCatTabError]
  var didReset: Bool
  var isPinnedToBottomHint: Bool?

  init(
    entryCount: Int = 0,
    renderedEntries: [LogCatRenderedSnapshot] = [],
    metrics: LogCatTabMetrics = .empty,
    errors: [LogCatTabError] = [],
    didReset: Bool = false,
    isPinnedToBottomHint: Bool? = nil
  ) {
    self.entryCount = entryCount
    self.renderedEntries = renderedEntries
    self.metrics = metrics
    self.errors = errors
    self.didReset = didReset
    self.isPinnedToBottomHint = isPinnedToBottomHint
  }
}

// MARK: - Stream Events

enum LogCatStreamEvent: Sendable, Equatable {
  case connected
  case disconnected(reason: String?)
  case reconnecting(attempt: Int, reason: String?)
  case resumed
  case stopped
}

enum LogCatEvent: Sendable, Equatable {
  case entry(LogCatEntry)
  case stream(LogCatStreamEvent)
}

// MARK: - Builders

@MainActor
extension LogCatFilterSnapshot {
  init(filter: LogCatFilter) {
    let conditionSnapshots = [
      LogCatFilterConditionSnapshot(
        clauses: filter.condition.clauses.map { clause in
          LogCatFilterClauseSnapshot(
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
      color: LogCatColor(nsColor: filter.accentNSColor),
      conditions: conditionSnapshots
    )
  }
}

extension LogCatFilterSnapshot {
  func evaluate(
    entry: LogCatEntry,
    regexCache: inout [LogCatRegexCacheKey: NSRegularExpression]
  ) -> LogCatFilterMatchSnapshot {
    guard let condition = conditions.first else { return .noMatch }
    return evaluate(condition: condition, entry: entry, regexCache: &regexCache)
  }

  private func evaluate(
    condition: LogCatFilterConditionSnapshot,
    entry: LogCatEntry,
    regexCache: inout [LogCatRegexCacheKey: NSRegularExpression]
  ) -> LogCatFilterMatchSnapshot {
    var didProcessClause = false
    var didFindMatch = false
    var fieldHighlights: [LogCatFilterField: [LogCatRange]] = [:]

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
        for candidateField in LogCatFilterField.allCases where candidateField != .raw {
          guard let candidateValue = entry.value(for: candidateField) else { continue }
          let candidateNSString = candidateValue as NSString
          let candidateRange = NSRange(location: 0, length: candidateNSString.length)
          let candidateMatches = regex.matches(in: candidateValue, options: [], range: candidateRange)
          if !candidateMatches.isEmpty {
            let ranges = candidateMatches.map { LogCatRange(nsRange: $0.range) }
            fieldHighlights[candidateField, default: []].append(contentsOf: ranges)
          }
        }
      } else {
        let ranges = matches.map { LogCatRange(nsRange: $0.range) }
        fieldHighlights[clause.field, default: []].append(contentsOf: ranges)
      }
    }

    guard didProcessClause else {
      return LogCatFilterMatchSnapshot(isMatch: true, fieldRanges: [:])
    }

    return LogCatFilterMatchSnapshot(isMatch: didFindMatch, fieldRanges: fieldHighlights)
  }

  private func cachedRegex(
    for pattern: String,
    isCaseSensitive: Bool,
    cache: inout [LogCatRegexCacheKey: NSRegularExpression]
  ) -> NSRegularExpression? {
    let key = LogCatRegexCacheKey(pattern: pattern, isCaseSensitive: isCaseSensitive)
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
