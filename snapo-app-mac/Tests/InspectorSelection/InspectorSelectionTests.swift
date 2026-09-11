import Foundation
import SnapODeviceClient

private func app(
  _ pid: Int = 10, kinds: [InspectorID] = [.network, .tweaks],
  process: String? = "com.example.demo", device: String = "phone", user: Int? = 0,
  package: String? = "com.example.demo", version: Int? = 4, connectedKinds: [InspectorID]? = nil
) -> InspectableApp {
  let manifest = testManifest(pid: pid, kinds: kinds, version: version ?? 4)
  var record = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as! [String: Any]
  record["androidUserId"] = user as Any? ?? NSNull()
  record["processName"] = process as Any? ?? NSNull()
  var packageRecord = record["app"] as! [String: Any]
  packageRecord["packageName"] = package ?? "com.example.demo"
  record["app"] = packageRecord
  let identity = InspectorProcessIdentity(metadata: try! JSONDecoder().decode(
    InspectorProcessMetadata.self, from: JSONSerialization.data(withJSONObject: record)
  ))
  let metadata = InspectorMetadata.Process(
    name: "Demo", packageName: package, processName: process,
    verifiedIdentity: identity, inspectors: manifest.app!.inspectors
  )
  return InspectableApp(
    id: "\(device):pid:\(pid)", pid: pid, deviceId: device, deviceDisplayTitle: "Phone",
    inspectors: kinds.map {
      AppInspectorOption(
        kind: $0, server: .init(deviceId: device, socketName: "snapo_\($0.rawValue)_\(pid)"), protocolVersion: version,
        isConnected: connectedKinds?.contains($0) ?? true, compatibility: .supported
      )
    }, metadata: metadata
  )
}

private func selected(_ kind: InspectorID = .network) -> InspectorSelection {
  var owner = InspectorSelection()
  owner.reconcile([app()])
  owner.selectInspector(app(), option: app().inspectors.first { $0.kind == kind }!)
  return owner
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
  precondition(condition(), "Line \(line): \(message)")
}

@main
struct InspectorSelectionTests {
  @MainActor static func main() async throws {
    try WorkspaceLayoutTests.run()
    restoration()
    metadataDisplay()
    compatibilityTitles()
    disconnectedInspectorMetadata()
    profilesAndIdentity()
    fallback()
    try await modelLifecycle()
    try await hostConnections()
    await pushedDiscovery()
    await canceledDiscoveryRestart()
    print("Inspector selection, restoration, and launch tests passed")
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
      InspectorCompatibility.legacy(protocolVersion: 1).title(for: .network) == "Unsupported Network version",
      "Name the socket's tool"
    )
    expect(
      InspectorCompatibility.missingDescriptor.title(for: .tweaks) == "Unsupported Tweaks version",
      "Name tools without manifest metadata"
    )
    expect(
      InspectorCompatibility.hostAPI(version: 2).title(for: InspectorID(rawValue: "sample")) == "Unsupported Sample version",
      "Custom socket identifiers do not need a built-in tool mapping"
    )
    expect(
      InspectorCompatibility.missingDescriptor.title(for: nil) == "Unsupported tool version",
      "Keep a fallback without a selected tool"
    )
    expect(
      InspectorCompatibility.metadataUnavailable.title(for: .network) == "Inspector unavailable",
      "Do not confuse reachability with version support"
    )
  }

  private static func restoration() {
    var owner = selected(.tweaks)
    expect(owner.state.selectedApp?.metadata == app().metadata, "Selection retains the process manifest for the inspector page")
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
    var restored = InspectorSelection(saved: owner.serialized)
    restored.reconcile([app(30)])
    expect(restored.state.selection?.kind == .tweaks, "Restore saved inspector after restart")

    owner = selected()
    owner.reconcile([app(kinds: [.tweaks])])
    expect(owner.state.selection == nil && owner.state.preferredKind == .network, "Wait for a missing inspector")
    expect(owner.state.selectedApp?.inspectors.count == 2, "Retain toolbar options")
    owner.selectInspector(app(), option: app().inspectors[1])
    expect(owner.state.selection?.kind == .tweaks, "An explicit inspector overrides restoration")
    owner.reconcile([])
    owner.selectInspector(app(), option: app().inspectors[0])
    expect(owner.state.selection == nil, "An offline toolbar choice must not reuse a socket")
    owner.reconcile([app()])
    expect(owner.state.selection?.kind == .network, "Reconnect chosen inspector when it returns")

    let other = app(20, process: "com.example.other")
    owner.reconcile([app(), other])
    owner.selectInspector(other, option: other.inspectors[1])
    owner.selectApp(app())
    expect(owner.state.selection?.kind == .network, "Remember each app's inspector")
    owner.selectApp(other)
    expect(owner.state.selection?.kind == .tweaks, "Restore other app's inspector")
    owner.reconcile([app(20, process: "com.example.other", version: 5)])
    expect(owner.state.selection?.protocolVersion == 5, "Update protocol metadata")
    expect(owner.state.selectedApp?.metadata?.inspectors.first?.protocolVersion == 5, "Refresh the selected process manifest")
  }

  private static func disconnectedInspectorMetadata() {
    var owner = selected(.network)
    let displayed = owner.state.displayed[.network]
    let disconnected = app(connectedKinds: [.tweaks])
    owner.reconcile([disconnected])
    expect(owner.state.apps == [disconnected], "Keep disconnected inspectors in the picker")
    expect(owner.state.selection == nil && owner.state.isRestoring, "Do not treat cached metadata as a live connection")
    expect(owner.state.displayed[.network] == displayed, "Retain the disconnected inspector's page")
    expect(owner.state.selectedApp?.inspectors.count == 2, "Preserve inspector shortcuts")
    owner.selectInspector(disconnected, option: disconnected.inspectors[0])
    expect(owner.state.selection == nil, "An explicit offline choice still waits for a connection")
    owner.selectInspector(disconnected, option: disconnected.inspectors[1])
    expect(owner.state.selection?.kind == .tweaks, "A sibling inspector remains usable")
    owner.selectInspector(disconnected, option: disconnected.inspectors[0])
    owner.reconcile([app()])
    expect(owner.state.selection?.kind == .network, "Reconnect the same cached selection when it becomes available")

    owner = InspectorSelection()
    owner.reconcile([app(connectedKinds: []), app(20, connectedKinds: [.tweaks])])
    expect(
      owner.state.selection?.appId == app(20).id && owner.state.selection?.kind == .tweaks,
      "Startup chooses a connected inspector, not the first cached row"
    )
  }

  private static func profilesAndIdentity() {
    var owner = InspectorSelection()
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
    expect(owner.state.selection?.kind == .tweaks, "Resolve its saved inspector after identity arrives")
    owner.selectApp(app(process: nil))
    owner.selectInspector(app(process: nil), option: app().inspectors[0])
    owner.reconcile([app()])
    expect(owner.state.selection?.kind == .network, "An inspector icon overrides an unidentified app-row choice")

    owner = selected()
    let work = app(20, user: 10)
    owner.reconcile([app(), work])
    owner.selectInspector(work, option: work.inspectors[1])
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
    owner = InspectorSelection()
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
      var owner = InspectorSelection(saved: raw)
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
      var restored = InspectorSelection(saved: owner.serialized)
      restored.reconcile([app(), other])
      expect(restored.state.selection?.appId == other.id, "Save the startup choice")
    }
    for kind in [InspectorID.network, .tweaks] {
      let saved = selected(kind).serialized
      var owner = InspectorSelection(saved: saved)
      let otherKind: InspectorID = kind == .network ? .tweaks : .network
      let other = app(30, kinds: [kind], process: "com.example.other")
      let before = owner.serialized
      for _ in 0 ..< 12 {
        owner.reconcile([other, app(kinds: [otherKind])])
        expect(owner.state.selection == nil && owner.state.isRestoring, "Wait for the saved inspector through partial scans")
        expect(owner.serialized == before, "Do not overwrite the saved choice during discovery")
      }
      owner.reconcile([other, app()])
      expect(owner.state.selection?.kind == kind && owner.state.selection?.appId == app().id, "Restore the saved inspector when ready")
      for _ in 0 ..< 12 {
        owner.reconcile([other, app(kinds: [otherKind])])
        expect(owner.state.selection == nil && owner.serialized == before, "Retain the selected inspector through a cooldown")
      }
      owner.reconcile([app()])
      expect(owner.state.selection?.kind == kind, "Reconnect the selected inspector after cooldown")
    }
    for other in [
      app(20, process: "com.example.other"), app(20, process: "com.example.demo:worker"),
      app(20, device: "tablet"), app(20, user: 10)
    ] {
      var owner = InspectorSelection(saved: selected(.tweaks).serialized)
      let before = owner.serialized
      owner.reconcile([other])
      expect(owner.state.selection == nil && owner.serialized == before, "Do not replace a saved app with a different identity")
      owner.reconcile([other, app()])
      expect(owner.state.selection?.appId == app().id && owner.state.selection?.kind == .tweaks, "Restore the saved identity")
    }
    for user in ["", ",\"androidUserId\":null", ",\"androidUserId\":-1", ",\"androidUserId\":1.5"] {
      let preference = "{\"deviceId\":\"phone\",\"processName\":\"com.example.demo\",\"kind\":\"network\"\(user)}"
      var owner = InspectorSelection(saved: "{\"last\":\(preference),\"apps\":[\(preference)]}")
      let before = owner.serialized
      let first = app(40, kinds: [.tweaks], process: "com.example.other", user: 10)
      owner.reconcile([first, app()])
      if user.isEmpty || user.contains("null") {
        expect(owner.state.selection == nil && owner.serialized == before, "Preserve legacy choices without guessing a profile")
        owner.selectApp(first)
      }
      expect(owner.state.selection?.appId == first.id, "Allow explicit selection or a fallback after invalid preferences")
    }
    var owner = InspectorSelection(saved: selected().serialized)
    owner.reconcile([app(process: nil)])
    owner.selectApp(app(process: nil))
    owner.reconcile([app(30, process: "com.example.other"), app()])
    expect(owner.state.selection?.appId == app().id, "Explicit pending choice overrides startup restoration")
  }

  @MainActor private static func modelLifecycle() async throws {
    let suite = "SnapOInspectorTests.\(UUID().uuidString)"
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
    let model = AppInspectorModel(preferences: defaults, discover: {
      scans += 1
      if delayScan { return try await InspectorDiscoverySnapshot(
        apps: withCheckedThrowingContinuation { scanReply = $0 }
      ) }
      if failScan { throw TestError.failed }
      return InspectorDiscoverySnapshot(apps: apps)
    }, openApp: { input in
      launched.append(input)
      try await withCheckedThrowingContinuation { launchReply = $0 }
    }, sleep: { try await clock.sleep($0) })
    var snapshots: [AppInspectorSnapshot] = []
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
    model.selectInspector(app(), option: app().inspectors[0])
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
    let suite = "SnapOInspectorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let clock = TestClock()
    var apps = [app()]
    let model = AppInspectorModel(preferences: defaults, discover: {
      InspectorDiscoverySnapshot(apps: apps)
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
    model.selectInspector(app(20), option: app(20).inspectors[1])
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
    let suite = "SnapOInspectorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let clock = TestClock()
    let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { continuation.finish() }
    var latest = InspectorDiscoverySnapshot(apps: [app()], revision: 2)
    var scanReply: CheckedContinuation<InspectorDiscoverySnapshot, Never>?
    var scans = 0
    let model = AppInspectorModel(preferences: defaults, discover: {
      scans += 1
      return await withCheckedContinuation { scanReply = $0 }
    }, changes: { updates }, currentDiscovery: { latest }, openApp: { _ in }, sleep: { try await clock.sleep($0) })
    model.start()
    await settle()
    continuation.yield(())
    await settle()
    expect(model.snapshot.state.selectedApp?.metadata == app().metadata, "Publish completed metadata before the polling scan returns")
    expect(scans == 1, "A discovery update does not start another device scan")
    scanReply?.resume(returning: InspectorDiscoverySnapshot(apps: [app(20)], revision: 1))
    await settle()
    expect(model.snapshot.state.selectedApp?.id == app().id, "An older scan cannot overwrite a newer discovery update")
    latest = InspectorDiscoverySnapshot(apps: [app(connectedKinds: [])], revision: 3)
    continuation.yield(())
    await settle()
    expect(model.snapshot.state.selection == nil, "Publish a failed health check without another poll")
    expect(model.snapshot.state.selectedApp?.metadata == app().metadata, "Keep metadata when the health check disconnects")
    expect(scans == 1, "Health updates do not start another device scan")
    model.stop()
    let stoppedRevision = model.snapshot.revision
    latest = InspectorDiscoverySnapshot(apps: [app()], revision: 4)
    continuation.yield(())
    clock.cancelAll()
    await settle()
    expect(model.snapshot.revision == stoppedRevision, "Stop consuming discovery updates after shutdown")
    print("Discovery updates publish immediately, ignore stale scans, and stop with the model")
  }

  @MainActor private static func canceledDiscoveryRestart() async {
    let suite = "SnapOInspectorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let clock = TestClock()
    var replies: [CheckedContinuation<InspectorDiscoverySnapshot, Never>] = []
    let model = AppInspectorModel(preferences: defaults, discover: {
      await withCheckedContinuation { replies.append($0) }
    }, openApp: { _ in }, sleep: { try await clock.sleep($0) })
    model.start()
    await settle()
    model.stop()
    model.start()
    await settle()
    expect(replies.count == 2, "Start a new scan after cancellation")
    replies[0].resume(returning: InspectorDiscoverySnapshot(apps: [app()]))
    await settle()
    expect(model.snapshot.loading, "Ignore the canceled scan's result")
    model.refresh()
    await settle()
    expect(replies.count == 2, "The canceled scan must not clear the new scan")
    replies[1].resume(returning: InspectorDiscoverySnapshot(apps: [app(20)]))
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
