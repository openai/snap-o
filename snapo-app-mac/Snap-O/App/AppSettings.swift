import Combine
import Foundation
import Observation
import SwiftUI

enum StartupCaptureMode: String, CaseIterable, Identifiable {
  case livePreview
  case screenshot

  var id: Self {
    self
  }

  var title: String {
    switch self {
    case .livePreview: "Live Preview"
    case .screenshot: "Screenshot"
    }
  }
}

@MainActor
@Observable
final class AppSettings {
  static let shared = AppSettings()

  var startupCaptureMode: StartupCaptureMode = UserDefaults.standard.string(forKey: "startupCaptureMode")
    .flatMap(StartupCaptureMode.init(rawValue:)) ?? .livePreview {
    didSet { UserDefaults.standard.set(startupCaptureMode.rawValue, forKey: "startupCaptureMode") }
  }

  var showTouchesDuringCapture: Bool = UserDefaults.standard.bool(forKey: "showTouchesDuringCapture") {
    didSet { UserDefaults.standard.set(showTouchesDuringCapture, forKey: "showTouchesDuringCapture") }
  }

  var recordAsBugReport: Bool = UserDefaults.standard.bool(forKey: "recordAsBugReport") {
    didSet { UserDefaults.standard.set(recordAsBugReport, forKey: "recordAsBugReport") }
  }

  var isAppTerminating: Bool = false
}
