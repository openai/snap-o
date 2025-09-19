import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
  static let shared = AppSettings()

  @Published var showTouchesDuringCapture: Bool {
    didSet {
      UserDefaults.standard.set(showTouchesDuringCapture, forKey: Self.showTouchesKey)
    }
  }

  @Published var recordAsBugReport: Bool {
    didSet {
      UserDefaults.standard.set(recordAsBugReport, forKey: Self.bugReportKey)
    }
  }

  private static let showTouchesKey = "showTouchesDuringCapture"
  private static let bugReportKey = "recordAsBugReport"

  init() {
    showTouchesDuringCapture = UserDefaults.standard.object(forKey: Self.showTouchesKey) as? Bool ?? true
    recordAsBugReport = UserDefaults.standard.object(forKey: Self.bugReportKey) as? Bool ?? false
  }
}
