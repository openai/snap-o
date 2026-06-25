import Observation
import SnapODeviceClient

@Observable
@MainActor
final class NetworkInspectorHostModel {
  private(set) var servers: [NetworkInspectorServer] = []
  private(set) var selectedServer: NetworkInspectorServer?
  private(set) var searchText = ""
  private(set) var sortNewestFirst = false
  private(set) var hasClearableItems = false
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

  func selectServer(_ server: NetworkInspectorServer) {
    sendPageEvent(
      name: "network:selected-server",
      payload: NetworkServerReference(deviceId: server.deviceId, socketName: server.socketName)
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

  private func dispatch(_ output: NetworkInspectorOutput) {
    switch output {
    case .event(let event):
      sendPageEvent(name: "network:event", payload: event)
    case .status(let status):
      sendPageEvent(name: "network:status", payload: status)
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
