import Observation
import SnapODeviceClient

@Observable
@MainActor
final class NetworkInspectorHostModel {
  private(set) var servers: [NetworkInspectorServer] = []
  private(set) var selectedServer: NetworkInspectorServer?
  private(set) var inspectorApps: [InspectableApp] = []
  private(set) var selectedInspector: SelectedAppInspector?
  private(set) var displayedNetwork: SelectedAppInspector?
  private(set) var selectedInspectorApp: InspectableApp?
  private(set) var preferredInspectorKind: AppInspectorKind?
  private(set) var isRestoringInspector = false
  private(set) var searchText = ""
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
    bridge.appInspectorStateChangedHandler = { [weak self] state in
      self?.apply(state)
    }
    bridge.tweaksStateChangedHandler = { [weak self] state in
      self?.apply(state)
    }
    webContainer.pageReadinessChangedHandler = { [weak self] isReady in
      self?.isPageReady = isReady
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

  func selectApp(_ app: InspectableApp) {
    sendPageEvent(name: "inspector:app-selected", payload: app.id)
  }

  func selectInspector(_ app: InspectableApp, option: AppInspectorOption) {
    sendPageEvent(
      name: "inspector:selected",
      payload: SelectedAppInspector(
        appId: app.id, kind: option.kind, server: option.server, protocolVersion: option.protocolVersion
      )
    )
  }

  func setSearchText(_ searchText: String) {
    sendPageEvent(name: "network:search-text", payload: searchText)
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
    guard let displayedNetwork, displayedNetwork.server == state.selectedServer else { return }
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

  private func apply(_ state: AppInspectorState) {
    if selectedInspector?.kind != state.selection?.kind || selectedInspector?.server != state.selection?.server {
      webContainer.closeNativeColorPanel()
      hasResettableTweaks = false
    }
    if state.displayedNetwork == nil || displayedNetwork?.server != state.displayedNetwork?.server {
      selectedServer = nil
      hasClearableItems = false
      hasVisibleRecords = false
      selectedRecordKind = nil
    }
    inspectorApps = state.apps
    selectedInspector = state.selection
    displayedNetwork = state.displayedNetwork
    selectedInspectorApp = state.selectedApp
    preferredInspectorKind = state.preferredKind
    isRestoringInspector = state.isRestoring
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
}
