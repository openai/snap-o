import Foundation

extension Date {
  private static let inspectorTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.timeZone = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("j:mm:ss.SSS")
    return formatter
  }()

  var inspectorTimeString: String {
    Date.inspectorTimeFormatter.string(from: self)
  }

  func inspectorRelativeTimeString(reference: Date = .now) -> String {
    let seconds = Int(round(reference.timeIntervalSince(self)))
    if seconds == 0 { return "just now" }

    let absoluteSeconds = abs(seconds)
    let isFuture = seconds < 0

    let (value, unit): (Int, String) =
      absoluteSeconds < 60 ? (absoluteSeconds, "s") :
      absoluteSeconds < 3600 ? (absoluteSeconds / 60, "m") :
      absoluteSeconds < 86400 ? (absoluteSeconds / 3600, "h") :
      (absoluteSeconds / 86400, "d")

    return isFuture ? "in \(value)\(unit)" : "\(value)\(unit) ago"
  }
}
