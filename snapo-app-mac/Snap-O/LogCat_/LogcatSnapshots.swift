import AppKit
import Foundation

// MARK: - Core Value Types

struct LogcatRange: Sendable, Hashable {
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

struct LogcatColor: Sendable, Equatable {
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

  func withAlpha(_ value: Double) -> LogcatColor {
    LogcatColor(red: red, green: green, blue: blue, alpha: value)
  }

  func blended(with other: LogcatColor, fraction: Double) -> LogcatColor {
    guard (0 ... 1).contains(fraction) else { return self }
    let inverse = 1 - fraction
    return LogcatColor(
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

extension LogcatColor: Codable {}

struct LogcatColorHighlight: Sendable, Equatable {
  let range: LogcatRange
  let color: LogcatColor
}

// MARK: - Filter Snapshots

struct LogcatQuickFilterSnapshot: Sendable, Equatable {
  var pattern: String
}

struct LogcatFilterClauseSnapshot: Sendable, Equatable {
  let field: LogcatFilterField
  let pattern: String
  let isInverted: Bool
  let isCaseSensitive: Bool
}

struct LogcatFilterConditionSnapshot: Sendable, Equatable {
  let clauses: [LogcatFilterClauseSnapshot]
}

struct LogcatFilterMatchSnapshot: Sendable, Equatable {
  let isMatch: Bool
  let fieldRanges: [LogcatFilterField: [LogcatRange]]

  static let noMatch = LogcatFilterMatchSnapshot(isMatch: false, fieldRanges: [:])
}

struct LogcatFilterSnapshot: Sendable, Equatable {
  let id: UUID
  let action: LogcatFilterAction
  let isHighlightEnabled: Bool
  let color: LogcatColor
  let conditions: [LogcatFilterConditionSnapshot]
}

struct LogcatFilterConfigurationSnapshot: Sendable, Equatable {
  var filters: [[LogcatFilterSnapshot]]
  var quickFilter: LogcatQuickFilterSnapshot?

  init(
    filters: [[LogcatFilterSnapshot]] = [],
    quickFilter: LogcatQuickFilterSnapshot? = nil
  ) {
    self.filters = filters
    self.quickFilter = quickFilter
  }
}

struct LogcatRegexCacheKey: Hashable {
  let pattern: String
  let isCaseSensitive: Bool
}

// MARK: - Rendered Payloads

struct LogcatRenderedSnapshot: Sendable, Identifiable, Equatable {
  let id: UUID
  let entry: LogcatEntry
  let rowHighlightColor: LogcatColor?
  let fieldHighlights: [LogcatFilterField: [LogcatColorHighlight]]

  init(
    entry: LogcatEntry,
    rowHighlightColor: LogcatColor? = nil,
    fieldHighlights: [LogcatFilterField: [LogcatColorHighlight]] = [:]
  ) {
    id = entry.id
    self.entry = entry
    self.rowHighlightColor = rowHighlightColor
    self.fieldHighlights = fieldHighlights
  }
}

struct LogcatTabMetrics: Sendable, Equatable {
  var unreadDelta: Int
  var droppedEntries: Int

  init(
    unreadDelta: Int = 0,
    droppedEntries: Int = 0
  ) {
    self.unreadDelta = unreadDelta
    self.droppedEntries = droppedEntries
  }

  static let empty = LogcatTabMetrics()
}

enum LogcatTabError: Sendable, Equatable {
  case streamWarning(message: String)
  case regexFailure(pattern: String, message: String?)
  case backlogDropped(droppedCount: Int)
  case slowProcessing(count: Int)
  case stateInconsistency(message: String)
}

struct LogcatTabUpdate: Sendable, Equatable {
  var entryCount: Int
  var renderedEntries: [LogcatRenderedSnapshot]
  var metrics: LogcatTabMetrics
  var errors: [LogcatTabError]
  var didReset: Bool
  var isPinnedToBottomHint: Bool?

  init(
    entryCount: Int = 0,
    renderedEntries: [LogcatRenderedSnapshot] = [],
    metrics: LogcatTabMetrics = .empty,
    errors: [LogcatTabError] = [],
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

enum LogcatStreamEvent: Sendable, Equatable {
  case connected
  case disconnected(reason: String?)
  case reconnecting(attempt: Int, reason: String?)
  case resumed
  case stopped
}

enum LogcatEvent: Sendable, Equatable {
  case entry(LogcatEntry)
  case stream(LogcatStreamEvent)
}

// MARK: - Builders

@MainActor
extension LogcatFilterSnapshot {
  init(filter: LogcatFilter) {
    let conditionSnapshots = [
      LogcatFilterConditionSnapshot(
        clauses: filter.condition.clauses.map { clause in
          LogcatFilterClauseSnapshot(
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
      color: LogcatColor(nsColor: filter.accentNSColor),
      conditions: conditionSnapshots
    )
  }
}

extension LogcatFilterSnapshot {
  func evaluate(
    entry: LogcatEntry,
    regexCache: inout [LogcatRegexCacheKey: NSRegularExpression]
  ) -> LogcatFilterMatchSnapshot {
    guard let condition = conditions.first else { return .noMatch }
    return evaluate(condition: condition, entry: entry, regexCache: &regexCache)
  }

  private func evaluate(
    condition: LogcatFilterConditionSnapshot,
    entry: LogcatEntry,
    regexCache: inout [LogcatRegexCacheKey: NSRegularExpression]
  ) -> LogcatFilterMatchSnapshot {
    var didProcessClause = false
    var didFindMatch = false
    var fieldHighlights: [LogcatFilterField: [LogcatRange]] = [:]

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
        for candidateField in LogcatFilterField.allCases where candidateField != .raw {
          guard let candidateValue = entry.value(for: candidateField) else { continue }
          let candidateNSString = candidateValue as NSString
          let candidateRange = NSRange(location: 0, length: candidateNSString.length)
          let candidateMatches = regex.matches(in: candidateValue, options: [], range: candidateRange)
          if !candidateMatches.isEmpty {
            let ranges = candidateMatches.map { LogcatRange(nsRange: $0.range) }
            fieldHighlights[candidateField, default: []].append(contentsOf: ranges)
          }
        }
      } else {
        let ranges = matches.map { LogcatRange(nsRange: $0.range) }
        fieldHighlights[clause.field, default: []].append(contentsOf: ranges)
      }
    }

    guard didProcessClause else {
      return LogcatFilterMatchSnapshot(isMatch: true, fieldRanges: [:])
    }

    return LogcatFilterMatchSnapshot(isMatch: didFindMatch, fieldRanges: fieldHighlights)
  }

  private func cachedRegex(
    for pattern: String,
    isCaseSensitive: Bool,
    cache: inout [LogcatRegexCacheKey: NSRegularExpression]
  ) -> NSRegularExpression? {
    let key = LogcatRegexCacheKey(pattern: pattern, isCaseSensitive: isCaseSensitive)
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
