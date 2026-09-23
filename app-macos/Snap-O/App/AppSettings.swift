import Foundation
import Observation

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
  @ObservationIgnored private let defaults: UserDefaults

  var lastViewedDeviceID: String? {
    didSet { defaults.set(lastViewedDeviceID, forKey: "capture.lastViewedDeviceID") }
  }

  var startupCaptureMode: StartupCaptureMode {
    didSet { defaults.set(startupCaptureMode.rawValue, forKey: "startupCaptureMode") }
  }

  var showTouchesDuringCapture: Bool {
    didSet { defaults.set(showTouchesDuringCapture, forKey: "showTouchesDuringCapture") }
  }

  var recordAsBugReport: Bool {
    didSet { defaults.set(recordAsBugReport, forKey: "recordAsBugReport") }
  }

  var syncClipboard: Bool {
    didSet { defaults.set(syncClipboard, forKey: "syncClipboard") }
  }

  var keyboardInput: Bool {
    didSet { defaults.set(keyboardInput, forKey: "keyboardInput") }
  }

  var deviceControlsPlacement: DeviceControlsPlacement {
    didSet { defaults.set(deviceControlsPlacement.rawValue, forKey: "deviceControlsPlacement") }
  }

  var isAppTerminating: Bool = false

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    lastViewedDeviceID = defaults.string(forKey: "capture.lastViewedDeviceID")
    startupCaptureMode = defaults.string(forKey: "startupCaptureMode")
      .flatMap(StartupCaptureMode.init(rawValue:)) ?? .livePreview
    showTouchesDuringCapture = defaults.bool(forKey: "showTouchesDuringCapture")
    recordAsBugReport = defaults.bool(forKey: "recordAsBugReport")
    syncClipboard = defaults.object(forKey: "syncClipboard") as? Bool ?? true
    keyboardInput = defaults.object(forKey: "keyboardInput") as? Bool ?? true
    deviceControlsPlacement = defaults.string(forKey: "deviceControlsPlacement")
      .flatMap(DeviceControlsPlacement.init(rawValue:)) ?? .left
  }
}

enum DeviceControlsPlacement: String, CaseIterable, Identifiable {
  case left
  case below
  case hidden

  var id: Self {
    self
  }

  var title: String {
    switch self {
    case .left: "Left of Window"
    case .below: "Below Capture Pane"
    case .hidden: "Hide"
    }
  }
}
