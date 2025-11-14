import Foundation

enum LogcatLevel: String, CaseIterable {
  case verbose = "V"
  case debug = "D"
  case info = "I"
  case warn = "W"
  case error = "E"
  case fatal = "F"
  case assert = "A"
  case unknown = "?"

  init(symbol: String) {
    self = LogcatLevel(rawValue: symbol) ?? .unknown
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

struct LogcatHighlight: Identifiable, Equatable {
  enum Style: Equatable {
    case emphasis
    case warning
    case error
  }

  let id = UUID()
  var style: Style
  var note: String?
}

struct LogcatEntry: Identifiable, Equatable {
  let id = UUID()
  var timestampString: String
  var timestamp: Date?
  var pid: Int?
  var tid: Int?
  var level: LogcatLevel
  var tag: String
  var message: String
  var raw: String
  var highlights: [LogcatHighlight] = []
}

extension LogcatEntry {
  func value(for field: LogcatFilterField) -> String? {
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

extension LogcatEntry: Sendable {}

extension LogcatHighlight: Sendable {}
