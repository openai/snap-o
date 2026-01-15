import Combine
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppSettings {
  static let shared = AppSettings()

  var showTouchesDuringCapture: Bool = UserDefaults.standard.bool(forKey: "showTouchesDuringCapture") {
    didSet { UserDefaults.standard.set(showTouchesDuringCapture, forKey: "showTouchesDuringCapture") }
  }

  var recordAsBugReport: Bool = UserDefaults.standard.bool(forKey: "recordAsBugReport") {
    didSet { UserDefaults.standard.set(recordAsBugReport, forKey: "recordAsBugReport") }
  }

  var isAppTerminating: Bool = false
}
