import Foundation
import Observation

enum WorkspaceLayout: String {
  case capture
  case tool = "inspector"
  case both

  var showsCapture: Bool {
    self != .tool
  }

  var showsTool: Bool {
    self != .capture
  }
}

struct WorkspaceLayoutSnapshot: Codable, Hashable {
  let showsCapture: Bool
  let showsTool: Bool
  let capturePaneWidth: CGFloat

  private enum CodingKeys: String, CodingKey {
    case showsCapture
    case showsTool = "showsInspector"
    case capturePaneWidth
  }

  private enum LegacyCodingKeys: String, CodingKey {
    case showsNetwork
  }

  init(showsCapture: Bool, showsTool: Bool, capturePaneWidth: CGFloat) {
    self.showsCapture = showsCapture
    self.showsTool = showsTool
    self.capturePaneWidth = capturePaneWidth
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    showsCapture = try container.decode(Bool.self, forKey: .showsCapture)
    showsTool = try container.decodeIfPresent(Bool.self, forKey: .showsTool)
      ?? decoder.container(keyedBy: LegacyCodingKeys.self).decode(Bool.self, forKey: .showsNetwork)
    capturePaneWidth = try container.decode(CGFloat.self, forKey: .capturePaneWidth)
  }

  @MainActor
  static func persisted(defaults: UserDefaults = .standard) -> Self {
    WorkspacePreferences.migrate(defaults: defaults)
    let hasStoredVisibility = defaults.object(forKey: WorkspacePreferences.showsCapture) != nil
      || defaults.object(forKey: WorkspacePreferences.showsTool) != nil
    let storedWidth = defaults.double(forKey: WorkspacePreferences.capturePaneWidth)

    return Self(
      showsCapture: hasStoredVisibility ? defaults.bool(forKey: WorkspacePreferences.showsCapture) : true,
      showsTool: hasStoredVisibility ? defaults.bool(forKey: WorkspacePreferences.showsTool) : false,
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

  private let defaults: UserDefaults

  private(set) var showsCapture: Bool
  private(set) var showsTool: Bool
  private(set) var capturePaneWidth: CGFloat

  var layout: WorkspaceLayout {
    if showsCapture, showsTool { return .both }
    return showsTool ? .tool : .capture
  }

  var canToggleCapture: Bool {
    !showsCapture || showsTool
  }

  var canToggleTool: Bool {
    !showsTool || showsCapture
  }

  init(snapshot: WorkspaceLayoutSnapshot? = nil, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    WorkspacePreferences.migrate(defaults: defaults)
    let snapshot = snapshot ?? .persisted(defaults: defaults)
    showsCapture = snapshot.showsCapture || !snapshot.showsTool
    showsTool = snapshot.showsTool
    capturePaneWidth = max(260, snapshot.capturePaneWidth)
  }

  var snapshot: WorkspaceLayoutSnapshot {
    WorkspaceLayoutSnapshot(
      showsCapture: showsCapture,
      showsTool: showsTool,
      capturePaneWidth: capturePaneWidth
    )
  }

  func resizeCapturePane(to width: CGFloat) {
    capturePaneWidth = max(260, width)
  }

  func persistCapturePaneWidth() {
    defaults.set(capturePaneWidth, forKey: WorkspacePreferences.capturePaneWidth)
  }

  func toggleCapture() {
    setCaptureVisible(!showsCapture)
  }

  func toggleTool() {
    setToolVisible(!showsTool)
  }

  func revealCapture() {
    setCaptureVisible(true)
  }

  func setCaptureVisible(_ visible: Bool) {
    guard visible || showsTool else { return }
    showsCapture = visible
    persistVisibility()
  }

  func setToolVisible(_ visible: Bool) {
    guard visible || showsCapture else { return }
    showsTool = visible
    persistVisibility()
  }

  private func persistVisibility() {
    defaults.set(showsCapture, forKey: WorkspacePreferences.showsCapture)
    defaults.set(showsTool, forKey: WorkspacePreferences.showsTool)
  }
}

private enum WorkspacePreferences {
  static let showsCapture = "workspace.showsCapture"
  static let showsTool = "workspace.showsInspector"
  static let capturePaneWidth = "workspace.capturePaneWidth"

  static func migrate(defaults: UserDefaults) {
    for (oldKey, newKey) in [
      ("workspace.showsNetwork", showsTool),
      ("workspace.windowFrame.network", "workspace.windowFrame.inspector")
    ] {
      guard let value = defaults.object(forKey: oldKey) else { continue }
      if defaults.object(forKey: newKey) == nil {
        defaults.set(value, forKey: newKey)
      }
      defaults.removeObject(forKey: oldKey)
    }
  }
}
