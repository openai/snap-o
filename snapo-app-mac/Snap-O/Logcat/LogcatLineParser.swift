import Foundation

enum LogcatParserError: Error {
  case malformedLine(String)
}

enum LogcatLineParser {
  private static let threadtimePattern =
    #"^\s*(?<month>\d{2})-(?<day>\d{2})\s+(?<time>\d{2}:\d{2}:\d{2}\.\d{3})\s+"#
      + #"(?<pid>\d+)\s+(?<tid>\d+)\s+(?<level>[A-Z])\s+(?<tag>.+?):\s+(?<message>.*)$"#

  private static let threadtimeRegex: NSRegularExpression = {
    // The pattern is valid; failure should crash loudly during development.
    do {
      return try NSRegularExpression(pattern: threadtimePattern)
    } catch {
      preconditionFailure("Failed to compile threadtime regex: \(error)")
    }
  }()

  static func parseThreadtime(_ line: String, calendar: Calendar = .current) -> LogcatEntry {
    let nsrange = NSRange(location: 0, length: line.count)
    guard let match = threadtimeRegex.firstMatch(in: line, options: [], range: nsrange) else {
      return LogcatEntry(
        timestampString: "",
        timestamp: nil,
        pid: nil,
        tid: nil,
        level: .unknown,
        tag: "unparsed",
        message: line,
        raw: line
      )
    }

    func substring(_ name: String) -> String {
      let range = match.range(withName: name)
      guard let swiftRange = Range(range, in: line) else { return "" }
      return String(line[swiftRange]).trimmingCharacters(in: .whitespaces)
    }

    let month = substring("month")
    let day = substring("day")
    let time = substring("time")
    let pid = Int(substring("pid"))
    let tid = Int(substring("tid"))
    let levelSymbol = substring("level")
    let tag = substring("tag").trimmingCharacters(in: .whitespaces)
    let message = substring("message")

    let timestampString = "\(month)-\(day) \(time)"
    let timestamp = makeTimestamp(month: month, day: day, time: time, calendar: calendar)

    let level = LogcatLevel(symbol: levelSymbol)

    return LogcatEntry(
      timestampString: timestampString,
      timestamp: timestamp,
      pid: pid,
      tid: tid,
      level: level,
      tag: tag,
      message: message,
      raw: line
    )
  }

  private static func makeTimestamp(
    month: String,
    day: String,
    time: String,
    calendar: Calendar
  ) -> Date? {
    guard
      let monthValue = Int(month),
      let dayValue = Int(day)
    else { return nil }

    let timeParts = time.split(separator: ":")
    guard timeParts.count == 3 else { return nil }

    let secondsPart = timeParts[2].split(separator: ".")
    guard secondsPart.count == 2 else { return nil }

    let year = calendar.component(.year, from: Date())

    var components = DateComponents()
    components.year = year
    components.month = monthValue
    components.day = dayValue
    components.hour = Int(timeParts[0])
    components.minute = Int(timeParts[1])
    components.second = Int(secondsPart[0])
    if let milliseconds = Int(secondsPart[1]) {
      components.nanosecond = milliseconds * 1_000_000
    }

    return calendar.date(from: components)
  }
}
