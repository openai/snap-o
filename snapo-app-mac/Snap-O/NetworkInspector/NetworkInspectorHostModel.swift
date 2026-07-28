import Foundation
import Observation
import SnapODeviceClient

@Observable
@MainActor
final class NetworkInspectorHostModel {
  private enum Keys {
    static let hiddenHosts = "networkInspector.hiddenHosts"
  }

  private(set) var servers: [NetworkInspectorServer] = []
  private(set) var selectedServer: NetworkInspectorServer?
  private(set) var inspectorApps: [InspectableApp] = []
  private(set) var selectedInspector: SelectedAppInspector?
  private(set) var searchText = ""
  private(set) var hiddenHosts = UserDefaults.standard.stringArray(forKey: Keys.hiddenHosts) ?? []
  private(set) var sortNewestFirst = false
  private(set) var hasClearableItems = false
  private(set) var hasResettableTweaks = false
  private(set) var selectedRecordKind: String?
  private(set) var hasVisibleRecords = false
  private(set) var isPageReady = false

  @ObservationIgnored let webContainer: NetworkInspectorWebContainer
  @ObservationIgnored private var outputTask: Task<Void, Never>?

  init(service: NetworkInspectorService) {
    let bridge = NetworkInspectorWebBridge(service: service)
    webContainer = NetworkInspectorWebContainer(bridge: bridge)

    bridge.inspectorStateChangedHandler = { [weak self] state in
      self?.apply(state)
    }
    bridge.inspectorAppsChangedHandler = { [weak self] apps in
      self?.applyInspectorApps(apps)
    }
    bridge.tweaksStateChangedHandler = { [weak self] state in
      self?.apply(state)
    }
    bridge.hiddenHostsHandler = { [weak self] in
      self?.hiddenHosts ?? []
    }
    bridge.addHiddenHostHandler = { [weak self] host in
      self?.addHiddenHost(host)
    }
    webContainer.pageReadinessChangedHandler = { [weak self] isReady in
      guard let self else { return }
      isPageReady = isReady
      if isReady {
        sendPageEvent(name: "network:hidden-hosts", payload: hiddenHosts)
      }
    }
    webContainer.start()

    outputTask = Task { [weak self] in
      await self?.consumeOutputs(from: service)
    }
  }

  func stop() {
    outputTask?.cancel()
    outputTask = nil
    webContainer.stop()
  }

  func selectServer(_ server: NetworkInspectorServer) {
    sendPageEvent(
      name: "network:selected-server",
      payload: NetworkServerReference(deviceId: server.deviceId, socketName: server.socketName)
    )
  }

  func selectInspector(_ app: InspectableApp, option: AppInspectorOption) {
    let selection = SelectedAppInspector(
      appId: app.id,
      kind: option.kind,
      server: option.server
    )
    if selectedInspector?.appId != selection.appId
      || selectedInspector?.kind != selection.kind
      || selectedInspector?.server != selection.server {
      webContainer.closeNativeColorPanel()
    }
    if selectedInspector?.kind != selection.kind || selectedInspector?.server != selection.server {
      hasResettableTweaks = false
    }
    selectedInspector = selection
    sendPageEvent(name: "inspector:selected", payload: selection)

    if option.kind == .network,
       let server = servers.first(where: {
         $0.deviceId == option.server.deviceId && $0.socketName == option.server.socketName
       }) {
      selectServer(server)
    }
  }

  var selectedInspectorApp: InspectableApp? {
    guard let selectedInspector else { return nil }
    return inspectorApps.first { $0.id == selectedInspector.appId }
  }

  func setSearchText(_ searchText: String) {
    sendPageEvent(name: "network:search-text", payload: searchText)
  }

  func addHiddenHost(_ value: String) {
    guard let host = Self.normalizedHost(value), !hiddenHosts.contains(host) else { return }

    hiddenHosts.append(host)
    hiddenHosts.sort()
    saveHiddenHosts()
  }

  func removeHiddenHost(_ host: String) {
    guard let index = hiddenHosts.firstIndex(of: host) else { return }

    hiddenHosts.remove(at: index)
    saveHiddenHosts()
  }

  func setSortNewestFirst(_ sortNewestFirst: Bool) {
    sendPageEvent(name: "network:sort-newest-first", payload: sortNewestFirst)
  }

  func clearCompletedRecords() {
    sendPageEvent(name: "network:clear-completed", payload: true)
  }

  func copySelectedURL() {
    sendPageEvent(name: "network:copy-selected-url", payload: true)
  }

  func copySelectedCurl() {
    sendPageEvent(name: "network:copy-selected-curl", payload: true)
  }

  func exportVisibleRecordsAsHar() {
    sendPageEvent(name: "network:export-visible-har", payload: true)
  }

  func resetTweaks() {
    sendPageEvent(name: "tweaks:reset", payload: true)
  }

  private func apply(_ state: NetworkInspectorNativeState) {
    servers = state.servers
    selectedServer = state.selectedServer.flatMap { selection in
      state.servers.first {
        $0.deviceId == selection.deviceId && $0.socketName == selection.socketName
      }
    }
    searchText = state.searchText
    sortNewestFirst = state.sortNewestFirst
    hasClearableItems = state.hasClearableItems
    selectedRecordKind = state.selectedRecordKind
    hasVisibleRecords = state.hasVisibleRecords
  }

  private func apply(_ state: TweaksInspectorNativeState) {
    guard selectedInspector?.kind == .tweaks,
          selectedInspector?.server == state.server
    else {
      return
    }

    hasResettableTweaks = state.hasResettableTweaks
  }

  private func applyInspectorApps(_ apps: [InspectableApp]) {
    inspectorApps = apps

    if let selection = selectedInspector,
       apps.contains(where: { app in
         app.id == selection.appId && app.inspectors.contains {
           $0.kind == selection.kind && $0.server == selection.server
         }
       }) {
      return
    }

    if let selectedServer,
       let app = apps.first(where: {
         $0.deviceId == selectedServer.deviceId && $0.inspectors.contains {
           $0.kind == .network && $0.server.socketName == selectedServer.socketName
         }
       }),
       let network = app.inspectors.first(where: { $0.kind == .network }) {
      selectInspector(app, option: network)
      return
    }

    guard let app = apps.first, let option = app.inspectors.first else {
      webContainer.closeNativeColorPanel()
      selectedInspector = nil
      hasResettableTweaks = false
      return
    }
    selectInspector(app, option: option)
  }

  private func dispatch(_ output: NetworkInspectorOutput) {
    switch output {
    case .event(let event):
      sendPageEvent(name: "network:event", payload: event)
    case .status(let status):
      sendPageEvent(name: "network:status", payload: status)
    case .tweaks(let event):
      sendPageEvent(name: "tweaks:changed", payload: event)
    }
  }

  private func consumeOutputs(from service: NetworkInspectorService) async {
    while !Task.isCancelled {
      let stream = await service.outputStream()
      for await output in stream {
        guard !Task.isCancelled else { return }
        dispatch(output)
      }
      guard !Task.isCancelled, await service.isRunning() else { return }

      // A producer-side buffer overflow finishes the stream. Reloading stops the
      // old server stream and makes the page request a complete replay.
      webContainer.recoverFromEventOverflow()
    }
  }

  private func sendPageEvent(name: String, payload: some Encodable) {
    webContainer.sendPageEvent(name: name, payload: payload)
  }

  private func saveHiddenHosts() {
    UserDefaults.standard.set(hiddenHosts, forKey: Keys.hiddenHosts)
    sendPageEvent(name: "network:hidden-hosts", payload: hiddenHosts)
  }

  private static func normalizedHost(_ value: String) -> String? {
    var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("*.") {
      trimmed.removeFirst(2)
    }
    guard !trimmed.isEmpty else { return nil }

    let input = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let components = URLComponents(string: input),
          let scheme = components.scheme?.lowercased(),
          ["http", "https", "ws", "wss"].contains(scheme),
          components.user == nil,
          components.password == nil,
          let rawHost = components.host?.lowercased()
    else {
      return nil
    }

    let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
    return host.isEmpty ? nil : host
  }
}
