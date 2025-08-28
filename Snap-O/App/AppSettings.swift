import SwiftUI

@MainActor
@Observable
final class AppSettings {
  var showTouchesDuringCapture: Bool {
    didSet {
      UserDefaults.standard.set(showTouchesDuringCapture, forKey: Self.key)
    }
  }

  private static let key = "showTouchesDuringCapture"

  init() {
    showTouchesDuringCapture = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
  }
}
