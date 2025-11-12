import OSLog

enum SnapOLog {
  private static let subsystem = "com.openai.snapo"

  static let adb = Logger(subsystem: subsystem, category: "adb")
  static let tracker = Logger(subsystem: subsystem, category: "tracker")
  static let recording = Logger(subsystem: subsystem, category: "recording")
  static let ui = Logger(subsystem: subsystem, category: "ui")
  static let storage = Logger(subsystem: subsystem, category: "storage")
  static let perf = Logger(subsystem: subsystem, category: "perf")
  static let network = Logger(subsystem: subsystem, category: "network")
  static let logCat = Logger(subsystem: subsystem, category: "logcat")
}
