import Combine
import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
  static let shared = AppSettings()

  @AppStorage("showTouchesDuringCapture") var showTouchesDuringCapture: Bool = true
  @AppStorage("recordAsBugReport") var recordAsBugReport: Bool = false
  @AppStorage("reopenNetworkInspector") var shouldReopenNetworkInspector: Bool = false

  @Published var isAppTerminating: Bool

  init() {
    isAppTerminating = false
  }
}
