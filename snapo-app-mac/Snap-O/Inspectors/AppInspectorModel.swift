import Foundation
import SnapODeviceClient

struct AppLaunchState: Encodable {
  let pending: Bool
  let error: String?
}

struct InspectorHostState: Encodable {
  let revision: Int
  let selection: SelectedAppInspector?
  let selectedApp: InspectableApp?
  let isActive: Bool
  let isConnected: Bool
  let isWaiting: Bool
  let appLaunch: AppLaunchState?
}

struct AppInspectorSnapshot {
  let revision: Int
  let state: AppInspectorState
  let loading: Bool
  let appLaunch: AppLaunchState?

  func pageState(for kind: InspectorID) -> InspectorHostState {
    let displayed = state.displayed[kind]
    let waiting = loading || state.isRestoring || state.selection?.protocolVersion == nil
    let active = state.preferredKind == kind
    let connected = active && !waiting && state.selection?.kind == kind
    return InspectorHostState(
      revision: revision, selection: displayed, selectedApp: state.selectedApp,
      isActive: active, isConnected: connected,
      isWaiting: waiting, appLaunch: appLaunch
    )
  }
}

@MainActor
final class AppInspectorModel {
  var stateChanged: ((AppInspectorSnapshot) -> Void)?

  private let discover: () async throws -> InspectorDiscoverySnapshot
  private let changes: (() async -> AsyncStream<Void>)?
  private let currentDiscovery: (() async -> InspectorDiscoverySnapshot)?
  private let openApp: (OpenAppInput) async throws -> Void
  private let sleep: (Duration) async throws -> Void
  private let preferences: UserDefaults
  private var selection: InspectorSelection
  private var savedPreferences: String?
  private var revision = 0
  private var loading = true
  private var running = false
  private var refreshTask: Task<Void, Never>?
  private var pollingTask: Task<Void, Never>?
  private var updatesTask: Task<Void, Never>?
  private var discoveryRevision: UInt64?
  private var launchTask: Task<Void, Never>?
  private var launchPollingTask: Task<Void, Never>?
  private var launchID: UUID?
  private var launchOpening = false
  private var launchWaiting = false
  private var launchError: String?

  init(
    preferences: UserDefaults = .standard,
    discover: @escaping () async throws -> InspectorDiscoverySnapshot,
    changes: (() async -> AsyncStream<Void>)? = nil,
    currentDiscovery: (() async -> InspectorDiscoverySnapshot)? = nil,
    openApp: @escaping (OpenAppInput) async throws -> Void,
    sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.preferences = preferences
    self.discover = discover
    self.changes = changes
    self.currentDiscovery = currentDiscovery
    self.openApp = openApp
    self.sleep = sleep
    savedPreferences = preferences.string(forKey: "inspectorPreferences")
    selection = InspectorSelection(saved: savedPreferences)
  }

  var snapshot: AppInspectorSnapshot {
    AppInspectorSnapshot(
      revision: revision, state: selection.state, loading: loading,
      appLaunch: launchInput == nil ? nil : AppLaunchState(
        pending: launchOpening || launchWaiting, error: launchError
      )
    )
  }

  func start() {
    guard !running else { return }
    running = true
    refresh()
    if let changes, let currentDiscovery {
      updatesTask = Task { [weak self] in
        for await _ in await changes() {
          guard !Task.isCancelled else { return }
          let discovery = await currentDiscovery()
          guard !Task.isCancelled else { return }
          self?.applyDiscovery(discovery)
        }
      }
    }
    let sleep = sleep
    pollingTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await sleep(.milliseconds(2500)) } catch { return }
        guard !Task.isCancelled, let self else { return }
        if !launchWaiting { refresh() }
      }
    }
  }

  func stop() {
    running = false
    pollingTask?.cancel()
    pollingTask = nil
    refreshTask?.cancel()
    refreshTask = nil
    updatesTask?.cancel()
    updatesTask = nil
    cancelLaunch()
  }

  func refresh() {
    guard running, refreshTask == nil else { return }
    refreshTask = Task { [weak self] in
      guard let self else { return }
      defer { if !Task.isCancelled { refreshTask = nil } }
      do {
        let discovery = try await discover()
        guard !Task.isCancelled, running else { return }
        applyDiscovery(discovery)
      } catch {
        // A failed scan does not prove the selected app has disconnected.
      }
    }
  }

  private func applyDiscovery(_ discovery: InspectorDiscoverySnapshot) {
    guard running else { return }
    if let revision = discovery.revision {
      guard discoveryRevision.map({ revision > $0 }) ?? true else { return }
      discoveryRevision = revision
    }
    let previous = launchKey
    selection.reconcile(discovery.apps)
    if previous != launchKey { cancelLaunch() }
    loading = false
    publish()
  }

  func selectApp(_ app: InspectableApp) {
    let previous = launchKey
    selection.selectApp(app)
    if previous != launchKey { cancelLaunch() }
    publish()
  }

  func selectInspector(_ app: InspectableApp, option: AppInspectorOption) {
    let previous = launchKey
    selection.selectInspector(app, option: option)
    if previous != launchKey { cancelLaunch() }
    publish()
  }

  func reconnectToNewProcess() {
    guard let app = selection.state.replacementApp,
          let option = app.inspectors.first(where: { $0.kind == selection.state.preferredKind }) else { return }
    selectInspector(app, option: option)
  }

  func openSelectedApp(appId: String) {
    guard running, selection.state.selectedApp?.id == appId, let input = launchInput, launchID == nil else { return }
    let id = UUID()
    launchID = id
    launchOpening = true
    launchWaiting = true
    launchError = nil
    publish()
    let sleep = sleep
    launchPollingTask = Task { [weak self] in
      for _ in 0 ..< 10 {
        do { try await sleep(.milliseconds(500)) } catch { return }
        guard !Task.isCancelled, self?.launchID == id else { return }
        self?.refresh()
      }
      guard let self, launchID == id else { return }
      launchWaiting = false
      if !launchOpening { launchID = nil }
      publish()
    }
    launchTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await openApp(input)
        guard launchID == id, !Task.isCancelled else { return }
        launchOpening = false
        if !launchWaiting { launchID = nil }
        refresh()
        publish()
      } catch {
        guard launchID == id, !Task.isCancelled else { return }
        cancelLaunch()
        launchError = error.localizedDescription
        publish()
      }
    }
  }

  private var launchInput: OpenAppInput? {
    guard let app = selection.state.selectedApp, let package = app.packageName, !package.isEmpty,
          let user = app.androidUserId, user >= 0 else { return nil }
    return OpenAppInput(deviceId: app.deviceId, packageName: package, androidUserId: user)
  }

  private var launchKey: String? {
    guard let app = selection.state.selectedApp else { return nil }
    return "\(app.deviceId):\(app.androidUserId.map(String.init) ?? "unknown"):\(app.processName ?? app.packageName ?? app.id)"
  }

  private func cancelLaunch() {
    launchID = nil
    launchOpening = false
    launchWaiting = false
    launchError = nil
    launchTask?.cancel()
    launchTask = nil
    launchPollingTask?.cancel()
    launchPollingTask = nil
  }

  private func publish() {
    let saved = selection.serialized
    if saved != savedPreferences {
      preferences.set(saved, forKey: "inspectorPreferences")
      savedPreferences = saved
    }
    revision += 1
    stateChanged?(snapshot)
  }
}
