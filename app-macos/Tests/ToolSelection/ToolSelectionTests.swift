import Foundation

private func app(
  _ pid: Int = 10, kinds: [ToolID] = [.network, .tweaks],
  process: String? = "com.example.demo", device: String = "phone", user: Int? = 0,
  package: String? = "com.example.demo", version: Int? = 4, connectedKinds: [ToolID]? = nil
) -> InspectableApp {
  let manifest = testManifest(pid: pid, kinds: kinds, version: version ?? 4)
  var record = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as! [String: Any]
  record["androidUserId"] = user as Any? ?? NSNull()
  record["processName"] = process as Any? ?? NSNull()
  var packageRecord = record["app"] as! [String: Any]
  packageRecord["packageName"] = package ?? "com.example.demo"
  record["app"] = packageRecord
  let identity = ToolProcessIdentity(metadata: try! JSONDecoder().decode(
    ToolProcessMetadata.self, from: JSONSerialization.data(withJSONObject: record)
  ))
  let metadata = ToolMetadata.Process(
    name: "Demo", packageName: package, processName: process,
    verifiedIdentity: identity, tools: manifest.app!.tools
  )
  return InspectableApp(
    id: "\(device):pid:\(pid)", pid: pid, deviceId: device, deviceDisplayTitle: "Phone",
    tools: kinds.map {
      AppToolOption(
        kind: $0, server: .init(deviceId: device, socketName: "snapo_\($0.rawValue)_\(pid)"), protocolVersion: version,
        isConnected: connectedKinds?.contains($0) ?? true, compatibility: .supported
      )
    }, metadata: metadata
  )
}

private func selected(_ kind: ToolID = .network) -> ToolSelection {
  var owner = ToolSelection()
  owner.reconcile([app()])
  owner.selectTool(app(), option: app().tools.first { $0.kind == kind }!)
  return owner
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
  precondition(condition(), "Line \(line): \(message)")
}

@main
struct ToolSelectionTests {
  @MainActor static func main() async throws {
    var unversioned = ToolMetadata()
    expect(
      unversioned.applyPackageMetadata(testManifest(pid: 10, kinds: [.sample], version: nil), kind: .sample),
      "Accept bundled tool metadata without a protocol version"
    )
    expect(unversioned.compatibility == .supported, "Open bundled tools without a protocol version")
    expect(unversioned.protocolVersion == nil, "Do not invent a protocol version")
    try WorkspaceLayoutTests.run()
    restoration()
    metadataDisplay()
    compatibilityTitles()
    disconnectedPluginMetadata()
    profilesAndIdentity()
    fallback()
    try await modelLifecycle()
    try await hostConnections()
    await pushedDiscovery()
    await canceledDiscoveryRestart()
    print("Tool selection, restoration, and launch tests passed")
  }

  private static func metadataDisplay() {
    var value = app()
    value.metadata?.name = "Updated label"
    value.metadata?.iconBase64 = "updated-icon"
    expect(value.name == "Updated label" && value.appIconBase64 == "updated-icon", "Display the current metadata")
    value.metadata?.name = nil
    expect(value.name == "com.example.demo", "Fall back to the process name")
    value.metadata?.processName = nil
    value.metadata?.packageName = "com.example.package"
    expect(value.name == "com.example.package", "Fall back to the package name")
    value.metadata = nil
    expect(value.name == "Process 10", "Keep a label before metadata arrives")
    expect(value.androidUserId == nil && value.appIconBase64 == nil, "Do not retain details outside metadata")
  }

  private static func compatibilityTitles() {
    expect(
      ToolCompatibility.legacy(protocolVersion: 1).title(for: .network) == "Unsupported Network version",
      "Name the socket's tool"
    )
    expect(
      ToolCompatibility.missingDescriptor.title(for: .tweaks) == "Unsupported Tweaks version",
      "Name tools without manifest metadata"
    )
    expect(
      ToolCompatibility.hostAPI(version: 2).title(for: ToolID(rawValue: "sample")) == "Unsupported Sample version",
      "Custom socket identifiers do not need a built-in tool mapping"
    )
    expect(
      ToolCompatibility.missingDescriptor.title(for: nil) == "Unsupported tool version",
      "Keep a fallback without a selected tool"
    )
    expect(
      ToolCompatibility.metadataUnavailable.title(for: .network) == "Tool unavailable",
      "Do not confuse reachability with version support"
    )
  }

  private static func restoration() {
    var owner = selected(.tweaks)
    expect(owner.state.selectedApp?.metadata == app().metadata, "Selection retains the process manifest for the tool page")
    let displayed = owner.state.displayed[.tweaks]
    owner.reconcile([])
    expect(owner.state.selection == nil && owner.state.displayed[.tweaks] == displayed, "Retain disconnected values")
    owner.reconcile([app()])
    expect(owner.state.selection?.kind == .tweaks, "Reconnect the same process")
    owner.reconcile([app(20)])
    expect(owner.state.selection == nil && owner.state.replacementApp?.id == app(20).id, "Require a new-process choice")
    expect(owner.state.displayed[.tweaks] == displayed, "Do not switch displayed values on discovery")
    owner.selectApp(app(20))
    expect(owner.state.selection?.appId == app(20).id, "Accept an explicit replacement")
    var restored = ToolSelection(saved: owner.serialized)
    restored.reconcile([app(30)])
    expect(restored.state.selection?.kind == .tweaks, "Restore saved tool after restart")

    owner = selected()
    owner.reconcile([app(kinds: [.tweaks])])
    expect(owner.state.selection == nil && owner.state.preferredKind == .network, "Wait for a missing tool")
    expect(owner.state.selectedApp?.tools.count == 2, "Retain toolbar options")
    owner.selectTool(app(), option: app().tools[1])
    expect(owner.state.selection?.kind == .tweaks, "An explicit tool overrides restoration")
    owner.reconcile([])
    owner.selectTool(app(), option: app().tools[0])
    expect(owner.state.selection == nil, "An offline toolbar choice must not reuse a socket")
    owner.reconcile([app()])
    expect(owner.state.selection?.kind == .network, "Reconnect chosen tool when it returns")

    let other = app(20, process: "com.example.other")
    owner.reconcile([app(), other])
    owner.selectTool(other, option: other.tools[1])
    owner.selectApp(app())
    expect(owner.state.selection?.kind == .network, "Remember each app's tool")
    owner.selectApp(other)
    expect(owner.state.selection?.kind == .tweaks, "Restore other app's tool")
    owner.reconcile([app(20, process: "com.example.other", version: 5)])
    expect(owner.state.selection?.protocolVersion == 5, "Update protocol metadata")
    expect(owner.state.selectedApp?.metadata?.tools.first?.protocolVersion == 5, "Refresh the selected process manifest")
  }

  private static func disconnectedPluginMetadata() {
    var owner = selected(.network)
    let displayed = owner.state.displayed[.network]
    let disconnected = app(connectedKinds: [.tweaks])
    owner.reconcile([disconnected])
    expect(owner.state.apps == [disconnected], "Keep disconnected tools in the picker")
    expect(owner.state.selection == nil && owner.state.isRestoring, "Do not treat cached metadata as a live connection")
    expect(owner.state.displayed[.network] == displayed, "Retain the disconnected tool's page")
    expect(owner.state.selectedApp?.tools.count == 2, "Preserve tool shortcuts")
    owner.selectTool(disconnected, option: disconnected.tools[0])
    expect(owner.state.selection == nil, "An explicit offline choice still waits for a connection")
    owner.selectTool(disconnected, option: disconnected.tools[1])
    expect(owner.state.selection?.kind == .tweaks, "A sibling tool remains usable")
    owner.selectTool(disconnected, option: disconnected.tools[0])
    owner.reconcile([app()])
    expect(owner.state.selection?.kind == .network, "Reconnect the same cached selection when it becomes available")

    owner = ToolSelection()
    owner.reconcile([app(connectedKinds: []), app(20, connectedKinds: [.tweaks])])
    expect(
      owner.state.selection?.appId == app(20).id && owner.state.selection?.kind == .tweaks,
      "Startup chooses a connected tool, not the first cached row"
    )
  }

  private static func profilesAndIdentity() {
    var owner = ToolSelection()
    owner.reconcile([app(process: nil)])
    expect(owner.state.selection == nil && owner.state.isRestoring, "Wait for identity at startup")
    owner.reconcile([app(process: nil), app(20)])
    expect(owner.state.selection?.appId == app(20).id, "Unknown identity must not block a usable app")

    owner = selected(.tweaks)
    let saved = owner.serialized
    owner.selectApp(app(process: nil))
    owner.reconcile([])
    owner.reconcile([app(process: nil)])
    expect(owner.state.selection == nil && owner.serialized == saved, "Wait for the explicit app's identity")
    owner.reconcile([app()])
    expect(owner.state.selection?.kind == .tweaks, "Resolve its saved tool after identity arrives")
    owner.selectApp(app(process: nil))
    owner.selectTool(app(process: nil), option: app().tools[0])
    owner.reconcile([app()])
    expect(owner.state.selection?.kind == .network, "A tool icon overrides an unidentified app-row choice")

    owner = selected()
    let work = app(20, user: 10)
    owner.reconcile([app(), work])
    owner.selectTool(work, option: work.tools[1])
    owner.reconcile([app()])
    expect(owner.state.selection == nil && owner.state.selectedApp?.androidUserId == 10, "Do not switch profiles")
    owner.reconcile([app(), app(30, user: 10)])
    expect(owner.state.replacementApp?.androidUserId == 10, "Find a replacement in the same profile")
    owner.selectApp(app())
    expect(owner.state.displayed[.tweaks] == nil, "Clear values from another profile")

    owner = selected()
    owner.reconcile([app(user: nil, package: nil)])
    expect(owner.state.selection == nil, "Unknown profile must not authorize a connection")
    expect(owner.state.selectedApp?.androidUserId == 0, "Retain the verified launch target")
    owner = ToolSelection()
    owner.reconcile([app(user: nil)])
    owner.reconcile([app(user: 10)])
    expect(owner.state.selectedApp?.androidUserId == 10, "Learn the profile for the same PID")
    owner.reconcile([app(30)])
    expect(owner.state.selection == nil && owner.state.replacementApp == nil, "Do not restore another profile")

    for other in [
      app(20, process: "com.example.other"),
      app(20, process: "com.example.demo:worker"),
      app(20, device: "tablet"),
      app(20, user: 10)
    ] {
      owner = selected()
      owner.reconcile([other])
      expect(owner.state.selection == nil && owner.state.replacementApp == nil, "Do not follow a different app identity")
    }
  }

  private static func fallback() {
    for raw in [nil, "invalid"] {
      var owner = ToolSelection(saved: raw)
      let before = owner.serialized
      owner.reconcile([])
      owner.reconcile([app(process: nil), app(20, kinds: [])])
      expect(owner.state.selection == nil && owner.serialized == before, "Wait for a usable startup app")
      let other = app(30, kinds: [.network], process: "com.example.other")
      owner.reconcile([app(process: nil), other])
      expect(owner.state.selection?.appId == other.id, "Choose the first usable app without a saved choice")
      owner.reconcile([app(), other])
      expect(owner.state.selection?.appId == other.id, "Do not override the startup choice later")
      owner.reconcile([app()])
      expect(owner.state.selection == nil, "Do not fall back after disconnect")
      var restored = ToolSelection(saved: owner.serialized)
      restored.reconcile([app(), other])
      expect(restored.state.selection?.appId == other.id, "Save the startup choice")
    }
    for kind in [ToolID.network, .tweaks] {
      let saved = selected(kind).serialized
      var owner = ToolSelection(saved: saved)
      let otherKind: ToolID = kind == .network ? .tweaks : .network
      let other = app(30, kinds: [kind], process: "com.example.other")
      let before = owner.serialized
      for _ in 0 ..< 12 {
        owner.reconcile([other, app(kinds: [otherKind])])
        expect(owner.state.selection == nil && owner.state.isRestoring, "Wait for the saved tool through partial scans")
        expect(owner.serialized == before, "Do not overwrite the saved choice during discovery")
      }
      owner.reconcile([other, app()])
      expect(owner.state.selection?.kind == kind && owner.state.selection?.appId == app().id, "Restore the saved tool when ready")
      for _ in 0 ..< 12 {
        owner.reconcile([other, app(kinds: [otherKind])])
        expect(owner.state.selection == nil && owner.serialized == before, "Retain the selected tool through a cooldown")
      }
      owner.reconcile([app()])
      expect(owner.state.selection?.kind == kind, "Reconnect the selected tool after cooldown")
    }
    for other in [
      app(20, process: "com.example.other"), app(20, process: "com.example.demo:worker"),
      app(20, device: "tablet"), app(20, user: 10)
    ] {
      var owner = ToolSelection(saved: selected(.tweaks).serialized)
      let before = owner.serialized
      owner.reconcile([other])
      expect(owner.state.selection == nil && owner.serialized == before, "Do not replace a saved app with a different identity")
      owner.reconcile([other, app()])
      expect(owner.state.selection?.appId == app().id && owner.state.selection?.kind == .tweaks, "Restore the saved identity")
    }
    for user in ["", ",\"androidUserId\":null", ",\"androidUserId\":-1", ",\"androidUserId\":1.5"] {
      let preference = "{\"deviceId\":\"phone\",\"processName\":\"com.example.demo\",\"kind\":\"network\"\(user)}"
      var owner = ToolSelection(saved: "{\"last\":\(preference),\"apps\":[\(preference)]}")
      let before = owner.serialized
      let first = app(40, kinds: [.tweaks], process: "com.example.other", user: 10)
      owner.reconcile([first, app()])
      if user.isEmpty || user.contains("null") {
        expect(owner.state.selection == nil && owner.serialized == before, "Preserve legacy choices without guessing a profile")
        owner.selectApp(first)
      }
      expect(owner.state.selection?.appId == first.id, "Allow explicit selection or a fallback after invalid preferences")
    }
    var owner = ToolSelection(saved: selected().serialized)
    owner.reconcile([app(process: nil)])
    owner.selectApp(app(process: nil))
    owner.reconcile([app(30, process: "com.example.other"), app()])
    expect(owner.state.selection?.appId == app().id, "Explicit pending choice overrides startup restoration")
  }

  @MainActor private static func modelLifecycle() async throws {
    let suite = "SnapOPluginTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(selected(.tweaks).serialized, forKey: "inspectorPreferences")
    let clock = TestClock()
    var scans = 0
    var apps = [app()]
    var failScan = false
    var scanReply: CheckedContinuation<[InspectableApp], Error>?
    var delayScan = false
    var launchReply: CheckedContinuation<Void, Error>?
    var launched: [OpenAppInput] = []
    let model = AppToolModel(preferences: defaults, discover: {
      scans += 1
      if delayScan { return try await ToolDiscoverySnapshot(
        apps: withCheckedThrowingContinuation { scanReply = $0 }
      ) }
      if failScan { throw TestError.failed }
      return ToolDiscoverySnapshot(apps: apps)
    }, openApp: { input in
      launched.append(input)
      try await withCheckedThrowingContinuation { launchReply = $0 }
    }, sleep: { try await clock.sleep($0) })
    var snapshots: [AppToolSnapshot] = []
    model.stateChanged = { snapshots.append($0) }
    model.start()
    await settle()
    expect(scans == 1 && !model.snapshot.loading, "Scan immediately and finish loading")
    expect(model.snapshot.state.selection?.kind == .tweaks, "Hydrate preferences before discovery")
    let firstRevision = model.snapshot.revision
    failScan = true
    model.refresh()
    await settle()
    expect(model.snapshot.state.selection?.kind == .tweaks, "A failed scan must not disconnect")
    failScan = false
    delayScan = true
    model.refresh()
    await settle()
    let slowScanCount = scans
    model.refresh()
    expect(scans == slowScanCount, "Do not overlap discovery requests")
    model.selectTool(app(), option: app().tools[0])
    scanReply?.resume(returning: apps)
    scanReply = nil
    await settle()
    expect(model.snapshot.state.selection?.kind == .network, "Honor native selection during a scan")
    expect(model.snapshot.revision > firstRevision, "Publish increasing revisions")
    delayScan = false

    apps = []
    model.refresh()
    await settle()
    model.openSelectedApp(appId: model.snapshot.state.selectedApp!.id)
    model.openSelectedApp(appId: model.snapshot.state.selectedApp!.id)
    await settle()
    expect(launched.count == 1 && launched[0].androidUserId == 0, "Prevent duplicate app launches")
    expect(model.snapshot.appLaunch?.pending == true, "Show pending launch")
    for _ in 0 ..< 10 {
      clock.advance(.milliseconds(500))
      await settle()
    }
    expect(model.snapshot.appLaunch?.pending == true, "Do not allow duplicate launch while ADB is still running")
    launchReply?.resume()
    launchReply = nil
    await settle()
    expect(model.snapshot.appLaunch?.pending == false, "Complete after both ADB and the wait window")
    model.openSelectedApp(appId: model.snapshot.state.selectedApp!.id)
    await settle()
    launchReply?.resume(throwing: TestError.failed)
    launchReply = nil
    await settle()
    expect(model.snapshot.appLaunch?.error != nil && model.snapshot.appLaunch?.pending == false, "Publish launch errors")

    let work = app(20, process: "com.example.demo:worker", user: 10)
    apps = [work]
    model.refresh()
    await settle()
    model.selectApp(work)
    model.openSelectedApp(appId: app().id)
    expect(model.snapshot.appLaunch?.pending == false, "Ignore an Open click from the previous app")
    model.openSelectedApp(appId: model.snapshot.state.selectedApp!.id)
    await settle()
    expect(
      launched.last?.androidUserId == 10 && launched.last?.packageName == "com.example.demo",
      "Launch a secondary process through its package and profile"
    )
    model.selectApp(app())
    launchReply?.resume(throwing: TestError.failed)
    launchReply = nil
    await settle()
    expect(
      model.snapshot.appLaunch?.error == nil && model.snapshot.appLaunch?.pending == false,
      "Ignore a late launch result after switching apps"
    )
    model.selectApp(app(user: nil))
    expect(model.snapshot.appLaunch == nil, "Do not launch without a verified profile")

    model.selectApp(work)
    model.openSelectedApp(appId: model.snapshot.state.selectedApp!.id)
    await settle()
    let published = snapshots.count
    model.stop()
    launchReply?.resume()
    launchReply = nil
    clock.advance(.milliseconds(500))
    clock.advance(.milliseconds(2500))
    await settle()
    expect(snapshots.count == published, "Stop publishing and polling after shutdown")
    clock.cancelAll()
    await settle()
  }

  @MainActor private static func hostConnections() async throws {
    let suite = "SnapOPluginTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let clock = TestClock()
    var apps = [app()]
    let model = AppToolModel(preferences: defaults, discover: {
      ToolDiscoverySnapshot(apps: apps)
    }, openApp: { _ in }, sleep: { try await clock.sleep($0) })
    expect(model.snapshot.pageState(for: .network).isWaiting, "Wait for initial native discovery")
    model.start()
    await settle()
    var page = model.snapshot.pageState(for: .network)
    expect(page.isActive && page.isConnected && !page.isWaiting, "Publish the active Network connection")
    expect(page.selection?.protocolVersion == 4, "Publish connection protocol metadata")
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as! [String: Any]
    expect(json["state"] == nil && json["apps"] == nil, "Do not send native selection internals to pages")
    expect(model.snapshot.pageState(for: .tweaks).selection == nil, "Send only this page's connection")
    apps = []
    model.refresh()
    await settle()
    page = model.snapshot.pageState(for: .network)
    expect(!page.isConnected && !page.isConnected, "Disconnect retained data")
    expect(page.selection?.protocolVersion == 4, "Retain connection metadata for captured data")
    apps = [app(20)]
    model.refresh()
    await settle()
    page = model.snapshot.pageState(for: .network)
    expect(!page.isConnected && page.selection?.server.socketName == "snapo_network_10", "Do not follow replacement discovery")
    model.reconnectToNewProcess()
    page = model.snapshot.pageState(for: .network)
    expect(page.isConnected && page.selection?.server.socketName == "snapo_network_20", "Connect only after native approval")
    model.selectTool(app(20), option: app(20).tools[1])
    page = model.snapshot.pageState(for: .network)
    expect(!page.isActive && !page.isConnected, "Deactivate the hidden Network page")
    expect(page.selection?.server.socketName == "snapo_network_20", "Keep the hidden page mounted with its data")
    expect(model.snapshot.pageState(for: .tweaks).isConnected, "Activate Tweaks from the native choice")
    apps = [app(20, version: nil)]
    model.refresh()
    await settle()
    page = model.snapshot.pageState(for: .tweaks)
    expect(!page.isConnected && page.isWaiting, "Wait for Tweaks protocol metadata in the host")
    apps = [app(20, version: 1)]
    model.refresh()
    await settle()
    expect(model.snapshot.pageState(for: .tweaks).isConnected, "Allow known older Tweaks protocols")
    model.stop()
    clock.cancelAll()
    await settle()
  }

  @MainActor private static func pushedDiscovery() async {
    let suite = "SnapOPluginTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let clock = TestClock()
    let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { continuation.finish() }
    var latest = ToolDiscoverySnapshot(apps: [app()], revision: 2)
    var scanReply: CheckedContinuation<ToolDiscoverySnapshot, Never>?
    var scans = 0
    let model = AppToolModel(preferences: defaults, discover: {
      scans += 1
      return await withCheckedContinuation { scanReply = $0 }
    }, changes: { updates }, currentDiscovery: { latest }, openApp: { _ in }, sleep: { try await clock.sleep($0) })
    model.start()
    await settle()
    continuation.yield(())
    await settle()
    expect(model.snapshot.state.selectedApp?.metadata == app().metadata, "Publish completed metadata before the polling scan returns")
    expect(scans == 1, "A discovery update does not start another device scan")
    scanReply?.resume(returning: ToolDiscoverySnapshot(apps: [app(20)], revision: 1))
    await settle()
    expect(model.snapshot.state.selectedApp?.id == app().id, "An older scan cannot overwrite a newer discovery update")
    latest = ToolDiscoverySnapshot(apps: [app(connectedKinds: [])], revision: 3)
    continuation.yield(())
    await settle()
    expect(model.snapshot.state.selection == nil, "Publish a failed health check without another poll")
    expect(model.snapshot.state.selectedApp?.metadata == app().metadata, "Keep metadata when the health check disconnects")
    expect(scans == 1, "Health updates do not start another device scan")
    model.stop()
    let stoppedRevision = model.snapshot.revision
    latest = ToolDiscoverySnapshot(apps: [app()], revision: 4)
    continuation.yield(())
    clock.cancelAll()
    await settle()
    expect(model.snapshot.revision == stoppedRevision, "Stop consuming discovery updates after shutdown")
    print("Discovery updates publish immediately, ignore stale scans, and stop with the model")
  }

  @MainActor private static func canceledDiscoveryRestart() async {
    let suite = "SnapOPluginTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let clock = TestClock()
    var replies: [CheckedContinuation<ToolDiscoverySnapshot, Never>] = []
    let model = AppToolModel(preferences: defaults, discover: {
      await withCheckedContinuation { replies.append($0) }
    }, openApp: { _ in }, sleep: { try await clock.sleep($0) })
    model.start()
    await settle()
    model.stop()
    model.start()
    await settle()
    expect(replies.count == 2, "Start a new scan after cancellation")
    replies[0].resume(returning: ToolDiscoverySnapshot(apps: [app()]))
    await settle()
    expect(model.snapshot.loading, "Ignore the canceled scan's result")
    model.refresh()
    await settle()
    expect(replies.count == 2, "The canceled scan must not clear the new scan")
    replies[1].resume(returning: ToolDiscoverySnapshot(apps: [app(20)]))
    await settle()
    expect(model.snapshot.state.selectedApp?.id == app(20).id, "Publish only the restarted scan")
    model.stop()
    clock.cancelAll()
    await settle()
  }

  @MainActor private static func settle() async {
    for _ in 0 ..< 30 {
      await Task.yield()
    }
  }
}

private enum TestError: Error { case failed }

@MainActor
private final class TestClock {
  private var waits: [(Duration, CheckedContinuation<Void, Error>)] = []

  func sleep(_ duration: Duration) async throws {
    try await withCheckedThrowingContinuation { waits.append((duration, $0)) }
  }

  func advance(_ duration: Duration) {
    let ready = waits.filter { $0.0 == duration }
    waits.removeAll { $0.0 == duration }
    for (_, continuation) in ready {
      continuation.resume()
    }
  }

  func cancelAll() {
    let pending = waits
    waits.removeAll()
    for (_, continuation) in pending {
      continuation.resume(throwing: CancellationError())
    }
  }
}
