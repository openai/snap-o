import Foundation
import Observation

enum WorkspaceLayout: String {
  case capture
  case network
  case both

  var showsCapture: Bool {
    self != .network
  }

  var showsNetwork: Bool {
    self != .capture
  }
}

struct WorkspaceLayoutSnapshot: Codable, Hashable {
  let showsCapture: Bool
  let showsNetwork: Bool
  let capturePaneWidth: CGFloat

  @MainActor
  static func persisted() -> Self {
    let defaults = UserDefaults.standard
    let hasStoredVisibility = defaults.object(forKey: "workspace.showsCapture") != nil
      || defaults.object(forKey: "workspace.showsNetwork") != nil
    let storedWidth = defaults.double(forKey: "workspace.capturePaneWidth")

    return Self(
      showsCapture: hasStoredVisibility ? defaults.bool(forKey: "workspace.showsCapture") : true,
      showsNetwork: hasStoredVisibility ? defaults.bool(forKey: "workspace.showsNetwork") : false,
      capturePaneWidth: storedWidth > 0
        ? max(260, storedWidth)
        : WorkspaceLayoutController.defaultCapturePaneWidth
    )
  }
}

struct WorkspaceWindowConfiguration: Codable, Hashable {
  let id: UUID
  let workspace: WorkspaceLayoutSnapshot

  init(workspace: WorkspaceLayoutSnapshot) {
    id = UUID()
    self.workspace = workspace
  }
}

enum WorkspaceWindowID {
  static let main = "main-workspace"
}

@Observable
@MainActor
final class WorkspaceLayoutController {
  static let defaultCapturePaneWidth: CGFloat = 360

  private enum Keys {
    static let showsCapture = "workspace.showsCapture"
    static let showsNetwork = "workspace.showsNetwork"
    static let capturePaneWidth = "workspace.capturePaneWidth"
  }

  private(set) var showsCapture: Bool
  private(set) var showsNetwork: Bool
  private(set) var capturePaneWidth: CGFloat

  var layout: WorkspaceLayout {
    if showsCapture, showsNetwork { return .both }
    return showsNetwork ? .network : .capture
  }

  var canToggleCapture: Bool {
    !showsCapture || showsNetwork
  }

  var canToggleNetwork: Bool {
    !showsNetwork || showsCapture
  }

  init(snapshot: WorkspaceLayoutSnapshot? = nil) {
    let snapshot = snapshot ?? .persisted()
    showsCapture = snapshot.showsCapture || !snapshot.showsNetwork
    showsNetwork = snapshot.showsNetwork
    capturePaneWidth = max(260, snapshot.capturePaneWidth)
  }

  var snapshot: WorkspaceLayoutSnapshot {
    WorkspaceLayoutSnapshot(
      showsCapture: showsCapture,
      showsNetwork: showsNetwork,
      capturePaneWidth: capturePaneWidth
    )
  }

  func resizeCapturePane(to width: CGFloat) {
    capturePaneWidth = max(260, width)
  }

  func persistCapturePaneWidth() {
    UserDefaults.standard.set(capturePaneWidth, forKey: Keys.capturePaneWidth)
  }

  func toggleCapture() {
    setCaptureVisible(!showsCapture)
  }

  func toggleNetwork() {
    setNetworkVisible(!showsNetwork)
  }

  func revealCapture() {
    setCaptureVisible(true)
  }

  func setCaptureVisible(_ visible: Bool) {
    guard visible || showsNetwork else { return }
    showsCapture = visible
    persistVisibility()
  }

  func setNetworkVisible(_ visible: Bool) {
    guard visible || showsCapture else { return }
    showsNetwork = visible
    persistVisibility()
  }

  private func persistVisibility() {
    UserDefaults.standard.set(showsCapture, forKey: Keys.showsCapture)
    UserDefaults.standard.set(showsNetwork, forKey: Keys.showsNetwork)
  }
}
