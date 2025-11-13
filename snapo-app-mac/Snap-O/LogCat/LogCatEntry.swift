import Foundation

enum LogCatLevel: String, CaseIterable {
  case verbose = "V"
  case debug = "D"
  case info = "I"
  case warn = "W"
  case error = "E"
  case fatal = "F"
  case assert = "A"
  case unknown = "?"

  init(symbol: String) {
    self = LogCatLevel(rawValue: symbol) ?? .unknown
  }

  var description: String {
    switch self {
    case .verbose: "Verbose"
    case .debug: "Debug"
    case .info: "Info"
    case .warn: "Warn"
    case .error: "Error"
    case .fatal: "Fatal"
    case .assert: "Assert"
    case .unknown: "Unknown"
    }
  }
}

struct LogCatHighlight: Identifiable, Equatable {
  enum Style: Equatable {
    case emphasis
    case warning
    case error
  }

  let id = UUID()
  var style: Style
  var note: String?
}

struct LogCatEntry: Identifiable, Equatable {
  let id = UUID()
  var timestampString: String
  var timestamp: Date?
  var pid: Int?
  var tid: Int?
  var level: LogCatLevel
  var tag: String
  var message: String
  var raw: String
  var highlights: [LogCatHighlight] = []
}

extension LogCatEntry {
  func value(for field: LogCatFilterField) -> String? {
    switch field {
    case .timestamp:
      timestampString
    case .pid:
      pid.map(String.init)
    case .tid:
      tid.map(String.init)
    case .level:
      level.rawValue
    case .tag:
      tag
    case .message:
      message
    case .raw:
      raw
    }
  }
}

extension LogCatEntry: Sendable {}

extension LogCatHighlight: Sendable {}
