import Foundation

@MainActor
enum WorkspaceLayoutTests {
  static func run() throws {
    let suite = "WorkspaceLayoutTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    migration(defaults: defaults, suite: suite)

    let initial = WorkspaceLayoutController(defaults: defaults)
    precondition(initial.layout == .capture)
    precondition(initial.capturePaneWidth == WorkspaceLayoutController.defaultCapturePaneWidth)

    defaults.set(false, forKey: "workspace.showsCapture")
    defaults.set(true, forKey: "workspace.showsNetwork")
    defaults.set(420, forKey: "workspace.capturePaneWidth")
    defaults.set("{{20, 40}, {940, 700}}", forKey: "workspace.windowFrame.network")
    let restored = WorkspaceLayoutController(defaults: defaults)
    precondition(restored.layout == .inspector && restored.capturePaneWidth == 420)
    precondition(restored.layout.rawValue == "inspector")
    precondition(defaults.string(forKey: "workspace.windowFrame.inspector") == "{{20, 40}, {940, 700}}")
    precondition(defaults.object(forKey: "workspace.windowFrame.network") == nil)
    precondition(defaults.bool(forKey: "workspace.showsInspector"))
    precondition(defaults.object(forKey: "workspace.showsNetwork") == nil)
    restored.toggleInspector()
    precondition(restored.layout == .inspector, "Keep at least one pane visible")
    restored.toggleCapture()
    precondition(restored.layout == .both)
    restored.toggleInspector()
    precondition(restored.layout == .capture)
    precondition(WorkspaceLayoutController(defaults: defaults).snapshot == restored.snapshot)
    precondition(defaults.object(forKey: "workspace.showsInspector") as? Bool == false)
    precondition(defaults.object(forKey: "workspace.showsNetwork") == nil)
    restored.toggleCapture()
    precondition(restored.layout == .capture, "Keep at least one pane visible")

    let savedWindow = Data("""
    {"id":"00000000-0000-0000-0000-000000000001",
     "workspace":{"showsCapture":true,"showsNetwork":true,"capturePaneWidth":400}}
    """.utf8)
    let window = try JSONDecoder().decode(WorkspaceWindowConfiguration.self, from: savedWindow)
    let layout = WorkspaceLayoutController(snapshot: window.workspace, defaults: defaults)
    precondition(layout.layout == .both && layout.capturePaneWidth == 400)
    let encoded = try JSONEncoder().encode(window)
    let decoded = try JSONDecoder().decode(WorkspaceWindowConfiguration.self, from: encoded)
    precondition(decoded == window)
    let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    let workspace = object["workspace"] as! [String: Any]
    precondition(workspace["showsInspector"] as? Bool == true)
    precondition(workspace["showsNetwork"] == nil, "Write only the current saved-window key")
    let mixedWindow = Data("""
    {"showsCapture":true,"showsInspector":false,"showsNetwork":true,"capturePaneWidth":400}
    """.utf8)
    let mixed = try JSONDecoder().decode(WorkspaceLayoutSnapshot.self, from: mixedWindow)
    precondition(!mixed.showsInspector, "Prefer the current key even when its value is false")

    let invalid = WorkspaceLayoutSnapshot(showsCapture: false, showsInspector: false, capturePaneWidth: 100)
    let repaired = WorkspaceLayoutController(snapshot: invalid, defaults: defaults)
    precondition(repaired.layout == .capture && repaired.capturePaneWidth == 260)
    print("Workspace layout persistence tests passed")
  }

  private static func migration(defaults: UserDefaults, suite: String) {
    for visible in [false, true] {
      defaults.set(visible, forKey: "workspace.showsNetwork")
      let snapshot = WorkspaceLayoutSnapshot.persisted(defaults: defaults)
      precondition(snapshot.showsInspector == visible)
      precondition(defaults.object(forKey: "workspace.showsInspector") as? Bool == visible)
      precondition(defaults.object(forKey: "workspace.showsNetwork") == nil)
      precondition(WorkspaceLayoutSnapshot.persisted(defaults: defaults) == snapshot, "Migration is idempotent")
      defaults.removePersistentDomain(forName: suite)
    }

    defaults.set(true, forKey: "workspace.showsNetwork")
    defaults.set(false, forKey: "workspace.showsInspector")
    defaults.set("{{10, 10}, {940, 700}}", forKey: "workspace.windowFrame.network")
    defaults.set("{{20, 20}, {1000, 800}}", forKey: "workspace.windowFrame.inspector")
    let snapshot = WorkspaceLayoutSnapshot(showsCapture: false, showsInspector: true, capturePaneWidth: 400)
    _ = WorkspaceLayoutController(snapshot: snapshot, defaults: defaults)
    precondition(defaults.object(forKey: "workspace.showsInspector") as? Bool == false)
    precondition(defaults.string(forKey: "workspace.windowFrame.inspector") == "{{20, 20}, {1000, 800}}")
    precondition(defaults.object(forKey: "workspace.showsNetwork") == nil)
    precondition(defaults.object(forKey: "workspace.windowFrame.network") == nil)
    defaults.removePersistentDomain(forName: suite)
  }
}
