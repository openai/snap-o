import AppKit
import Combine
import Foundation
import SwiftUI

enum LogLionFilterAction: String, CaseIterable, Identifiable {
  case include
  case exclude
  case none

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .include:
      "Include"
    case .exclude:
      "Exclude"
    case .none:
      "None"
    }
  }
}

enum LogLionFilterField: String, CaseIterable, Identifiable {
  case timestamp
  case pid
  case tid
  case level
  case tag
  case message
  case raw

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .timestamp: "Timestamp"
    case .pid: "PID"
    case .tid: "TID"
    case .level: "Level"
    case .tag: "Tag"
    case .message: "Message"
    case .raw: "Full Message"
    }
  }
}

struct LogLionFilterCondition: Identifiable, Equatable {
  struct Clause: Identifiable, Equatable {
    let id = UUID()
    var field: LogLionFilterField
    var pattern: String
    var isInverted: Bool
    var isCaseSensitive: Bool

    init(field: LogLionFilterField,
         pattern: String,
         isInverted: Bool = false,
         isCaseSensitive: Bool = false) {
      self.field = field
      self.pattern = pattern
      self.isInverted = isInverted
      self.isCaseSensitive = isCaseSensitive
    }
  }

  let id = UUID()
  var clauses: [Clause]
  private static let defaultClauses: [Clause] = [
    Clause(field: .message, pattern: "", isInverted: false),
    Clause(field: .tag, pattern: "", isInverted: false),
    Clause(field: .level, pattern: "", isInverted: false)
  ]

  init(clauses: [Clause] = LogLionFilterCondition.defaultClauses) {
    self.clauses = clauses.isEmpty ? LogLionFilterCondition.defaultClauses : clauses
  }
}

struct LogLionFilterMatchResult {
  var isMatch: Bool
  var fieldRanges: [LogLionFilterField: [NSRange]]

  static let noMatch = LogLionFilterMatchResult(isMatch: false, fieldRanges: [:])
}

@MainActor
final class LogLionFilter: ObservableObject, Identifiable {
  struct AutoKey: Equatable {
    let action: LogLionFilterAction
    let field: LogLionFilterField
  }

  let id = UUID()

  @Published var name: String
  @Published var isEnabled: Bool
  @Published var action: LogLionFilterAction
  @Published var isHighlightEnabled: Bool
  @Published var color: Color
  @Published var condition: LogLionFilterCondition
  var autoKey: AutoKey?
  init(
    name: String,
    isEnabled: Bool = true,
    action: LogLionFilterAction = .include,
    isHighlightEnabled: Bool = false,
    color: Color = .accentColor,
    condition: LogLionFilterCondition = LogLionFilterCondition(),
    autoKey: AutoKey? = nil
  ) {
    self.name = name
    self.isEnabled = isEnabled
    self.action = action
    self.isHighlightEnabled = isHighlightEnabled
    self.color = color
    self.condition = condition
    self.autoKey = autoKey
  }

  func evaluate(entry: LogLionEntry) -> LogLionFilterMatchResult {
    guard isEnabled else { return .noMatch }

    return evaluate(condition: condition, on: entry)
  }

  nonisolated private func evaluate(condition: LogLionFilterCondition, on entry: LogLionEntry) -> LogLionFilterMatchResult {
    var didProcessClause = false
    var didFindMatch = false
    var fieldHighlights: [LogLionFilterField: [NSRange]] = [:]

    for clause in condition.clauses {
      guard !clause.pattern.isEmpty else { continue }

      let options: NSRegularExpression.Options = clause.isCaseSensitive ? [] : [.caseInsensitive]
      guard let regex = try? NSRegularExpression(pattern: clause.pattern, options: options) else {
        continue
      }

      guard let target = entry.value(for: clause.field) else { continue }
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
            fieldHighlights[candidateField, default: []].append(contentsOf: candidateMatches.map(\.range))
          }
        }
      } else {
        fieldHighlights[clause.field, default: []].append(contentsOf: matches.map(\.range))
      }
    }

    guard didProcessClause else {
      return LogLionFilterMatchResult(isMatch: true, fieldRanges: [:])
    }

    return LogLionFilterMatchResult(isMatch: didFindMatch, fieldRanges: fieldHighlights)
  }

  var accentNSColor: NSColor {
    NSColor(color)
  }
}

extension LogLionFilterAction: Sendable {}
extension LogLionFilterField: Sendable {}
extension LogLionFilterCondition: Sendable {}
extension LogLionFilterCondition.Clause: Sendable {}
