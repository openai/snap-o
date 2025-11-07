import Foundation

enum LogLionLevel: String, CaseIterable {
  case verbose = "V"
  case debug = "D"
  case info = "I"
  case warn = "W"
  case error = "E"
  case fatal = "F"
  case assert = "A"
  case unknown = "?"

  init(symbol: String) {
    self = LogLionLevel(rawValue: symbol) ?? .unknown
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

struct LogLionHighlight: Identifiable, Equatable {
  enum Style: Equatable {
    case emphasis
    case warning
    case error
  }

  let id = UUID()
  var style: Style
  var note: String?
}

struct LogLionEntry: Identifiable, Equatable {
  let id = UUID()
  var timestampString: String
  var timestamp: Date?
  var pid: Int?
  var tid: Int?
  var level: LogLionLevel
  var tag: String
  var message: String
  var raw: String
  var highlights: [LogLionHighlight] = []
}

extension LogLionEntry {
  func value(for field: LogLionFilterField) -> String? {
    switch field {
    case .timestamp:
      return timestampString
    case .pid:
      return pid.map(String.init)
    case .tid:
      return tid.map(String.init)
    case .level:
      return level.rawValue
    case .tag:
      return tag
    case .message:
      return message
    case .raw:
      return raw
    }
  }
}

extension LogLionEntry: Sendable {}

extension LogLionHighlight: Sendable {}
