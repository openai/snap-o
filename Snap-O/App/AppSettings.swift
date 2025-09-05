import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
  static let shared = AppSettings()

  @Published var showTouchesDuringCapture: Bool {
    didSet {
      UserDefaults.standard.set(showTouchesDuringCapture, forKey: Self.key)
    }
  }

  private static let key = "showTouchesDuringCapture"

  init() {
    showTouchesDuringCapture = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
  }
}
