import Foundation
import Testing

struct ToolSelectionStateTests {
  @Test
  func appToolOrdering() throws {
    let analytics = ToolID(rawValue: "analytics")
    let logs = ToolID(rawValue: "logs")
    var app = selectionApp(kinds: [.tweaks, logs, .network, analytics])
    // Display labels must not affect the ID-based fallback order.
    app.tools[1].name = "A log viewer"
    app.tools[3].name = "Z analytics viewer"
    for order: [ToolID]? in [nil, [], [.network, .tweaks, .network, .sample]] {
      app.metadata?.toolOrder = order
      app.sortTools()
      let expected: [ToolID] = order?.isEmpty == false
        ? [.network, .tweaks, analytics, logs] : [analytics, logs, .network, .tweaks]
      #expect(app.tools.map(\.kind) == expected)
    }

    app.metadata?.toolOrder = [.tweaks, .network]
    app.sortTools()
    var pending = selectionApp()
    pending.metadata = ToolMetadata.Process(processName: app.processName)
    for index in pending.tools.indices {
      pending.tools[index].compatibility = .unknown
    }
    var owner = ToolSelection()
    let unsaved = owner.serialized
    owner.reconcile([pending])
    #expect(owner.state.selection == nil && owner.serialized == unsaved, "HTTP readiness must not finalize startup selection")
    owner.reconcile([app])
    #expect(owner.state.selection?.kind == .tweaks, "Initial selection follows the app order")
    #expect(owner.state.selectedApp?.tools.map(\.kind) == [.tweaks, .network, analytics, logs])

    var explicit = ToolSelection()
    explicit.reconcile([pending])
    explicit.selectApp(pending)
    explicit.reconcile([app])
    #expect(explicit.state.selection?.kind == .network, "An explicit choice before metadata loads is preserved")

    try owner.selectTool(app, option: #require(app.tools.first { $0.kind == logs }))

    var partial = app
    partial.tools.removeAll { $0.kind == .tweaks || $0.kind == logs }
    owner.reconcile([partial])
    #expect(owner.state.selection == nil)
    #expect(owner.state.selectedApp?.tools.map(\.kind) == [.tweaks, .network, analytics, logs])
    owner.reconcile([app])
    #expect(owner.state.selection?.kind == logs, "Reconnection preserves the selected tool")

    app.metadata?.toolOrder = [.network]
    owner.reconcile([app])
    #expect(owner.state.selectedApp?.tools.map(\.kind) == [.network, analytics, logs, .tweaks])
    #expect(owner.state.selection?.kind == logs, "Metadata updates do not change selection")
    var restored = ToolSelection(saved: owner.serialized)
    restored.reconcile([app])
    #expect(restored.state.selection?.kind == logs, "Saved selection takes priority over app order")
  }

  @Test
  func restoration() {
    var owner = selected(.tweaks)
    #expect(owner.state.selectedApp?.metadata == selectionApp().metadata, "Selection retains the process manifest for the tool page")
    let displayed = owner.state.displayed[.tweaks]
    owner.reconcile([])
    #expect(owner.state.selection == nil && owner.state.displayed[.tweaks] == displayed, "Retain disconnected values")
    owner.reconcile([selectionApp()])
    #expect(owner.state.selection?.kind == .tweaks, "Reconnect the same process")
    owner.reconcile([selectionApp(20)])
    #expect(owner.state.selection == nil && owner.state.replacementApp?.id == selectionApp(20).id, "Require a new-process choice")
    #expect(owner.state.displayed[.tweaks] == displayed, "Do not switch displayed values on discovery")
    owner.selectApp(selectionApp(20))
    #expect(owner.state.selection?.appId == selectionApp(20).id, "Accept an explicit replacement")
    var restored = ToolSelection(saved: owner.serialized)
    restored.reconcile([selectionApp(30)])
    #expect(restored.state.selection?.kind == .tweaks, "Restore saved tool after restart")

    owner = selected()
    owner.reconcile([selectionApp(kinds: [.tweaks])])
    #expect(owner.state.selection == nil && owner.state.preferredKind == .network, "Wait for a missing tool")
    #expect(owner.state.selectedApp?.tools.count == 2, "Retain toolbar options")
    owner.selectTool(selectionApp(), option: selectionApp().tools[1])
    #expect(owner.state.selection?.kind == .tweaks, "An explicit tool overrides restoration")
    owner.reconcile([])
    owner.selectTool(selectionApp(), option: selectionApp().tools[0])
    #expect(owner.state.selection == nil, "An offline toolbar choice must not reuse a socket")
    owner.reconcile([selectionApp()])
    #expect(owner.state.selection?.kind == .network, "Reconnect chosen tool when it returns")

    let other = selectionApp(20, process: "com.example.other")
    owner.reconcile([selectionApp(), other])
    owner.selectTool(other, option: other.tools[1])
    owner.selectApp(selectionApp())
    #expect(owner.state.selection?.kind == .network, "Remember each app's tool")
    owner.selectApp(other)
    #expect(owner.state.selection?.kind == .tweaks, "Restore other app's tool")
    var updated = selectionApp(20, process: "com.example.other")
    updated.metadata?.name = "Updated app"
    owner.reconcile([updated])
    #expect(owner.state.selectedApp?.metadata?.name == "Updated app", "Refresh selected app metadata")
  }

  @Test
  func replacementTools() {
    let analytics = ToolID(rawValue: "analytics")
    let original = selectionApp(kinds: [analytics, .network])
    for replacement in [
      selectionApp(20, kinds: [.network]),
      selectionApp(kinds: [.network], processIdentity: "boot:10:2")
    ] {
      var owner = ToolSelection()
      owner.reconcile([original])
      owner.reconcile([replacement])
      #expect(owner.state.selection == nil)
      #expect(owner.state.replacementApp == replacement, "Offer the new process even when its tools differ")
      #expect(owner.state.displayed[analytics] != nil, "Keep the old page until explicit reconnection")

      owner.selectApp(replacement)
      #expect(owner.state.selectedApp?.tools.map(\.kind) == [.network])
      #expect(owner.state.selection?.kind == .network, "Choose an available tool if the saved tool is absent")
      #expect(owner.state.displayed[analytics] == nil, "Do not retain pages from the previous process after switching")
      owner.reconcile([replacement])
      #expect(owner.state.selectedApp?.tools.map(\.kind) == [.network])
    }
  }

  @Test
  func disconnectedPluginMetadata() {
    var owner = selected(.network)
    let displayed = owner.state.displayed[.network]
    let disconnected = selectionApp(connectedKinds: [.tweaks])
    owner.reconcile([disconnected])
    #expect(owner.state.apps == [disconnected], "Keep disconnected tools in the picker")
    #expect(owner.state.selection == nil && owner.state.isRestoring, "Do not treat cached metadata as a live connection")
    #expect(owner.state.displayed[.network] == displayed, "Retain the disconnected tool's page")
    #expect(owner.state.selectedApp?.tools.count == 2, "Preserve tool shortcuts")
    owner.selectTool(disconnected, option: disconnected.tools[0])
    #expect(owner.state.selection == nil, "An explicit offline choice still waits for a connection")
    owner.selectTool(disconnected, option: disconnected.tools[1])
    #expect(owner.state.selection?.kind == .tweaks, "A sibling tool remains usable")
    owner.selectTool(disconnected, option: disconnected.tools[0])
    owner.reconcile([selectionApp()])
    #expect(owner.state.selection?.kind == .network, "Reconnect the same cached selection when it becomes available")

    owner = ToolSelection()
    owner.reconcile([selectionApp(connectedKinds: []), selectionApp(20, connectedKinds: [.tweaks])])
    #expect(
      owner.state.selection?.appId == selectionApp(20).id && owner.state.selection?.kind == .tweaks,
      "Startup chooses a connected tool, not the first cached row"
    )
  }

  @Test
  func profilesAndIdentity() {
    var owner = ToolSelection()
    owner.reconcile([selectionApp(process: nil)])
    #expect(owner.state.selection == nil && owner.state.isRestoring, "Wait for identity at startup")
    owner.reconcile([selectionApp(process: nil), selectionApp(20)])
    #expect(owner.state.selection?.appId == selectionApp(20).id, "Unknown identity must not block a usable app")

    owner = selected(.tweaks)
    let saved = owner.serialized
    owner.selectApp(selectionApp(process: nil))
    owner.reconcile([])
    owner.reconcile([selectionApp(process: nil)])
    #expect(owner.state.selection == nil && owner.serialized == saved, "Wait for the explicit app's identity")
    owner.reconcile([selectionApp()])
    #expect(owner.state.selection?.kind == .tweaks, "Resolve its saved tool after identity arrives")
    owner.selectApp(selectionApp(process: nil))
    owner.selectTool(selectionApp(process: nil), option: selectionApp().tools[0])
    owner.reconcile([selectionApp()])
    #expect(owner.state.selection?.kind == .network, "A tool icon overrides an unidentified app-row choice")

    owner = selected()
    let work = selectionApp(20, user: 10)
    owner.reconcile([selectionApp(), work])
    owner.selectTool(work, option: work.tools[1])
    owner.reconcile([selectionApp()])
    #expect(owner.state.selection == nil && owner.state.selectedApp?.androidUserId == 10, "Do not switch profiles")
    owner.reconcile([selectionApp(), selectionApp(30, user: 10)])
    #expect(owner.state.replacementApp?.androidUserId == 10, "Find a replacement in the same profile")
    owner.selectApp(selectionApp())
    #expect(owner.state.displayed[.tweaks] == nil, "Clear values from another profile")

    owner = selected()
    owner.reconcile([selectionApp(user: nil, package: nil)])
    #expect(owner.state.selection == nil, "Unknown profile must not authorize a connection")
    #expect(owner.state.selectedApp?.androidUserId == 0, "Retain the verified launch target")
    owner = ToolSelection()
    owner.reconcile([selectionApp(user: nil)])
    owner.reconcile([selectionApp(user: 10)])
    #expect(owner.state.selectedApp?.androidUserId == 10, "Learn the profile for the same PID")
    owner.reconcile([selectionApp(30)])
    #expect(owner.state.selection == nil && owner.state.replacementApp == nil, "Do not restore another profile")

    for other in [
      selectionApp(20, process: "com.example.other"),
      selectionApp(20, process: "com.example.demo:worker"),
      selectionApp(20, device: "tablet"),
      selectionApp(20, user: 10)
    ] {
      owner = selected()
      owner.reconcile([other])
      #expect(owner.state.selection == nil && owner.state.replacementApp == nil, "Do not follow a different app identity")
    }
  }

  @Test
  func supportedSiblingIsPreferredButLegacyRemainsSelectable() {
    var app = selectionApp()
    app.tools[0].compatibility = .legacy(protocolVersion: 1)
    var selection = ToolSelection()
    selection.reconcile([app])
    #expect(selection.state.preferredKind == .tweaks)
    selection.selectTool(app, option: app.tools[0])
    #expect(selection.state.preferredKind == .network)
  }

  @Test
  func fallback() {
    for compatibility in [ToolCompatibility.metadataUnavailable, .legacy(protocolVersion: 1)] {
      var app = selectionApp(kinds: [.network])
      app.metadata = ToolMetadata.Process(processName: app.processName)
      app.tools[0].compatibility = compatibility
      var owner = ToolSelection()
      owner.reconcile([app])
      #expect(owner.state.preferredKind == .network, "Failed and legacy metadata still allow startup fallback")
    }
    for raw in [nil, "invalid"] {
      var owner = ToolSelection(saved: raw)
      let before = owner.serialized
      owner.reconcile([])
      owner.reconcile([selectionApp(process: nil), selectionApp(20, kinds: [])])
      #expect(owner.state.selection == nil && owner.serialized == before, "Wait for a usable startup app")
      let other = selectionApp(30, kinds: [.network], process: "com.example.other")
      owner.reconcile([selectionApp(process: nil), other])
      #expect(owner.state.selection?.appId == other.id, "Choose the first usable app without a saved choice")
      owner.reconcile([selectionApp(), other])
      #expect(owner.state.selection?.appId == other.id, "Do not override the startup choice later")
      owner.reconcile([selectionApp()])
      #expect(owner.state.selection == nil, "Do not fall back after disconnect")
      var restored = ToolSelection(saved: owner.serialized)
      restored.reconcile([selectionApp(), other])
      #expect(restored.state.selection?.appId == other.id, "Save the startup choice")
    }
    for kind in [ToolID.network, .tweaks] {
      let saved = selected(kind).serialized
      var owner = ToolSelection(saved: saved)
      let otherKind: ToolID = kind == .network ? .tweaks : .network
      let other = selectionApp(30, kinds: [kind], process: "com.example.other")
      let before = owner.serialized
      for _ in 0 ..< 12 {
        owner.reconcile([other, selectionApp(kinds: [otherKind])])
        #expect(owner.state.selection == nil && owner.state.isRestoring, "Wait for the saved tool through partial scans")
        #expect(owner.serialized == before, "Do not overwrite the saved choice during discovery")
      }
      owner.reconcile([other, selectionApp()])
      #expect(owner.state.selection?.kind == kind && owner.state.selection?.appId == selectionApp().id, "Restore the saved tool when ready")
      for _ in 0 ..< 12 {
        owner.reconcile([other, selectionApp(kinds: [otherKind])])
        #expect(owner.state.selection == nil && owner.serialized == before, "Retain the selected tool through a cooldown")
      }
      owner.reconcile([selectionApp()])
      #expect(owner.state.selection?.kind == kind, "Reconnect the selected tool after cooldown")
    }
    for other in [
      selectionApp(20, process: "com.example.other"), selectionApp(20, process: "com.example.demo:worker"),
      selectionApp(20, device: "tablet"), selectionApp(20, user: 10)
    ] {
      var owner = ToolSelection(saved: selected(.tweaks).serialized)
      let before = owner.serialized
      owner.reconcile([other])
      #expect(owner.state.selection == nil && owner.serialized == before, "Do not replace a saved app with a different identity")
      owner.reconcile([other, selectionApp()])
      #expect(owner.state.selection?.appId == selectionApp().id && owner.state.selection?.kind == .tweaks, "Restore the saved identity")
    }
    for user in ["", ",\"androidUserId\":null", ",\"androidUserId\":-1", ",\"androidUserId\":1.5"] {
      let preference = "{\"deviceId\":\"phone\",\"processName\":\"com.example.demo\",\"kind\":\"network\"\(user)}"
      var owner = ToolSelection(saved: "{\"last\":\(preference),\"apps\":[\(preference)]}")
      let before = owner.serialized
      let first = selectionApp(40, kinds: [.tweaks], process: "com.example.other", user: 10)
      owner.reconcile([first, selectionApp()])
      if user.isEmpty || user.contains("null") {
        #expect(owner.state.selection == nil && owner.serialized == before, "Preserve legacy choices without guessing a profile")
        owner.selectApp(first)
      }
      #expect(owner.state.selection?.appId == first.id, "Allow explicit selection or a fallback after invalid preferences")
    }
    var owner = ToolSelection(saved: selected().serialized)
    owner.reconcile([selectionApp(process: nil)])
    owner.selectApp(selectionApp(process: nil))
    owner.reconcile([selectionApp(30, process: "com.example.other"), selectionApp()])
    #expect(owner.state.selection?.appId == selectionApp().id, "Explicit pending choice overrides startup restoration")
  }
}
