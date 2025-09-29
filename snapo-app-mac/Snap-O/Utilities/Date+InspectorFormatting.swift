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
}
