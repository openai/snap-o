import Foundation
@testable import Snap_O
import Testing

@Suite("Workspace layout persistence")
@MainActor
struct WorkspaceLayoutTests {
  @Test
  func persistence() throws {
    let suite = "WorkspaceLayoutTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    migration(defaults: defaults, suite: suite)

    let initial = WorkspaceLayoutController(defaults: defaults)
    #expect(initial.layout == .capture)
    #expect(initial.capturePaneWidth == WorkspaceLayoutController.defaultCapturePaneWidth)

    defaults.set(false, forKey: "workspace.showsCapture")
    defaults.set(true, forKey: "workspace.showsNetwork")
    defaults.set(420, forKey: "workspace.capturePaneWidth")
    defaults.set("{{20, 40}, {940, 700}}", forKey: "workspace.windowFrame.network")
    let restored = WorkspaceLayoutController(defaults: defaults)
    #expect(restored.layout == .tool && restored.capturePaneWidth == 420)
    #expect(restored.layout.rawValue == "inspector")
    #expect(defaults.string(forKey: "workspace.windowFrame.inspector") == "{{20, 40}, {940, 700}}")
    #expect(defaults.object(forKey: "workspace.windowFrame.network") == nil)
    #expect(defaults.bool(forKey: "workspace.showsInspector"))
    #expect(defaults.object(forKey: "workspace.showsNetwork") == nil)
    restored.toggleTool()
    #expect(restored.layout == .tool, "Keep at least one pane visible")
    restored.toggleCapture()
    #expect(restored.layout == .both)
    restored.toggleTool()
    #expect(restored.layout == .capture)
    #expect(WorkspaceLayoutController(defaults: defaults).snapshot == restored.snapshot)
    #expect(defaults.object(forKey: "workspace.showsInspector") as? Bool == false)
    #expect(defaults.object(forKey: "workspace.showsNetwork") == nil)
    restored.toggleCapture()
    #expect(restored.layout == .capture, "Keep at least one pane visible")

    let savedWindow = Data("""
    {"id":"00000000-0000-0000-0000-000000000001",
     "workspace":{"showsCapture":true,"showsNetwork":true,"capturePaneWidth":400}}
    """.utf8)
    let window = try JSONDecoder().decode(WorkspaceWindowConfiguration.self, from: savedWindow)
    let layout = WorkspaceLayoutController(snapshot: window.workspace, defaults: defaults)
    #expect(layout.layout == .both && layout.capturePaneWidth == 400)
    let encoded = try JSONEncoder().encode(window)
    let decoded = try JSONDecoder().decode(WorkspaceWindowConfiguration.self, from: encoded)
    #expect(decoded == window)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let workspace = try #require(object["workspace"] as? [String: Any])
    #expect(workspace["showsInspector"] as? Bool == true)
    #expect(workspace["showsNetwork"] == nil, "Write only the current saved-window key")
    let mixedWindow = Data("""
    {"showsCapture":true,"showsInspector":false,"showsNetwork":true,"capturePaneWidth":400}
    """.utf8)
    let mixed = try JSONDecoder().decode(WorkspaceLayoutSnapshot.self, from: mixedWindow)
    #expect(!mixed.showsTool, "Prefer the current key even when its value is false")

    let invalid = WorkspaceLayoutSnapshot(showsCapture: false, showsTool: false, capturePaneWidth: 100)
    let repaired = WorkspaceLayoutController(snapshot: invalid, defaults: defaults)
    #expect(repaired.layout == .capture && repaired.capturePaneWidth == 260)
  }

  private func migration(defaults: UserDefaults, suite: String) {
    for visible in [false, true] {
      defaults.set(visible, forKey: "workspace.showsNetwork")
      let snapshot = WorkspaceLayoutSnapshot.persisted(defaults: defaults)
      #expect(snapshot.showsTool == visible)
      #expect(defaults.object(forKey: "workspace.showsInspector") as? Bool == visible)
      #expect(defaults.object(forKey: "workspace.showsNetwork") == nil)
      #expect(WorkspaceLayoutSnapshot.persisted(defaults: defaults) == snapshot, "Migration is idempotent")
      defaults.removePersistentDomain(forName: suite)
    }

    defaults.set(true, forKey: "workspace.showsNetwork")
    defaults.set(false, forKey: "workspace.showsInspector")
    defaults.set("{{10, 10}, {940, 700}}", forKey: "workspace.windowFrame.network")
    defaults.set("{{20, 20}, {1000, 800}}", forKey: "workspace.windowFrame.inspector")
    let snapshot = WorkspaceLayoutSnapshot(showsCapture: false, showsTool: true, capturePaneWidth: 400)
    _ = WorkspaceLayoutController(snapshot: snapshot, defaults: defaults)
    #expect(defaults.object(forKey: "workspace.showsInspector") as? Bool == false)
    #expect(defaults.string(forKey: "workspace.windowFrame.inspector") == "{{20, 20}, {1000, 800}}")
    #expect(defaults.object(forKey: "workspace.showsNetwork") == nil)
    #expect(defaults.object(forKey: "workspace.windowFrame.network") == nil)
    defaults.removePersistentDomain(forName: suite)
  }
}
