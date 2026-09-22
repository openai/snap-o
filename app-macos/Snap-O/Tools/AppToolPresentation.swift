import Foundation

enum AppDiscoveryPhase: Equatable {
  case searching
  case ready
  case failed
}

enum AppToolPresentation: Equatable {
  case findingApps
  case discoveryFailed
  case noApps
  case needsSelection
  case waitingForApp(String)
  case tool

  init(discovery: AppDiscoveryPhase, selection: AppToolState) {
    if let app = selection.selectedApp {
      self = selection.selection != nil && !selection.isRestoring ? .tool : .waitingForApp(app.name)
    } else {
      self = switch discovery {
      case .searching: .findingApps
      case .failed: .discoveryFailed
      case .ready: selection.apps.isEmpty ? .noApps : .needsSelection
      }
    }
  }

  var message: String? {
    switch self {
    case .findingApps: "Finding apps…"
    case .discoveryFailed: "Couldn’t find apps"
    case .noApps: "No apps found"
    case .needsSelection: "Select an app to inspect"
    case .waitingForApp(let name): "Waiting for \(name)"
    case .tool: nil
    }
  }
}
