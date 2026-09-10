import Foundation
import Observation
import SnapODeviceClient

@Observable
@MainActor
final class NetworkInspectorHostModel {
  private enum Keys {
    static let exclusionFilters = "networkInspector.exclusionFilters"
    static let exclusionFiltersDidChange = Notification.Name("networkInspector.exclusionFiltersDidChange")
    static let hiddenHosts = "networkInspector.hiddenHosts"
  }

  private(set) var selectedServer: NetworkInspectorServer?
  private(set) var inspectorApps: [InspectableApp] = []
  private(set) var selectedInspector: SelectedAppInspector?
  private(set) var displayedNetwork: SelectedAppInspector?
  private(set) var selectedInspectorApp: InspectableApp?
  private(set) var replacementApp: InspectableApp?
  private(set) var preferredInspectorKind: AppInspectorKind?
  private(set) var isRestoringInspector = false
  private(set) var searchText = ""
  private(set) var exclusionFilters = NetworkInspectorHostModel.loadExclusionFilters()
  private(set) var sortNewestFirst = false
  private(set) var hasClearableItems = false
  private(set) var hasResettableTweaks = false
  private(set) var selectedRecordKind: String?
  private(set) var hasVisibleRecords = false
  var isPageReady: Bool {
    pages[preferredInspectorKind ?? .network]?.isReady ?? false
  }

  var webContainer: NetworkInspectorWebContainer? {
    pages[preferredInspectorKind ?? .network]?.container
  }

  private struct PageIdentity: Equatable {
    let appID: String?
    let server: InspectorServerReference?
  }

  private struct Page {
    let identity: PageIdentity
    let container: NetworkInspectorWebContainer
    var isReady = false
  }

  private var pages: [AppInspectorKind: Page] = [:]
  @ObservationIgnored private let service: NetworkInspectorService
  @ObservationIgnored private var pageTransitions: [AppInspectorKind: Task<Void, Never>] = [:]
  @ObservationIgnored private var isStopped = false
  @ObservationIgnored private let appInspector: AppInspectorModel
  @ObservationIgnored private var outputTask: Task<Void, Never>?
  @ObservationIgnored private var exclusionFiltersObserver: NSObjectProtocol?

  init(service: NetworkInspectorService, preferences: UserDefaults = .standard) {
    self.service = service
    appInspector = AppInspectorModel(
      preferences: preferences,
      discover: { await service.discoverInspectors() },
      openApp: { try await service.openApp($0) }
    )
    appInspector.stateChanged = { [weak self] snapshot in self?.apply(snapshot) }
    exclusionFiltersObserver = NotificationCenter.default.addObserver(
      forName: Keys.exclusionFiltersDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.reloadExclusionFilters()
      }
    }
    apply(appInspector.snapshot)
    appInspector.start()

    outputTask = Task { [weak self] in
      await self?.consumeOutputs(from: service)
    }
  }

  func stop() {
    guard !isStopped else { return }
    isStopped = true
    outputTask?.cancel()
    outputTask = nil
    if let exclusionFiltersObserver {
      NotificationCenter.default.removeObserver(exclusionFiltersObserver)
      self.exclusionFiltersObserver = nil
    }
    appInspector.stop()
    for (kind, page) in pages {
      page.container.stop()
      let transition = pageTransitions[kind]
      pageTransitions[kind] = Task {
        await transition?.value
        await page.container.finishStopping()
      }
    }
    pages.removeAll()
  }

  func selectApp(_ app: InspectableApp) {
    appInspector.selectApp(app)
  }

  func selectInspector(_ app: InspectableApp, option: AppInspectorOption) {
    appInspector.selectInspector(app, option: option)
  }

  func reconnectToNewProcess() {
    appInspector.reconnectToNewProcess()
  }

  func setSearchText(_ searchText: String) {
    sendPageEvent(name: "network:search-text", payload: searchText)
  }

  func addExclusionFilter(_ value: String) {
    guard let filter = Self.normalizedExclusionFilter(value) else { return }

    var filters = Self.loadExclusionFilters()
    guard !filters.contains(filter) else { return }

    filters.append(filter)
    filters.sort()
    saveExclusionFilters(filters)
  }

  func removeExclusionFilter(_ filter: String) {
    var filters = Self.loadExclusionFilters()
    guard let index = filters.firstIndex(of: filter) else { return }

    filters.remove(at: index)
    saveExclusionFilters(filters)
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

  private func apply(_ snapshot: AppInspectorSnapshot) {
    guard !isStopped else { return }
    apply(snapshot.state)
    let kind = snapshot.state.preferredKind ?? .network
    let state = snapshot.pageState(for: kind)
    selectedServer = snapshot.pageState(for: .network).networkServer
    let identity = PageIdentity(appID: state.selectedApp?.id, server: state.selection?.server)
    if pages[kind]?.identity != identity {
      replacePage(kind: kind, identity: identity)
    }
    for (kind, page) in pages {
      page.container.sendPageEvent(name: "inspector:state", payload: snapshot.pageState(for: kind))
    }
  }

  private func replacePage(kind: AppInspectorKind, identity: PageIdentity) {
    let previous = pages[kind]?.container
    previous?.stop()
    if kind == .network {
      searchText = ""
      sortNewestFirst = false
      hasClearableItems = false
      selectedRecordKind = nil
      hasVisibleRecords = false
    } else {
      hasResettableTweaks = false
    }

    let bridge = NetworkInspectorWebBridge(service: service, kind: kind)
    let container = NetworkInspectorWebContainer(bridge: bridge, kind: kind)
    bridge.inspectorHostStateHandler = { [weak self] in self?.appInspector.snapshot.pageState(for: kind) }
    bridge.openSelectedAppHandler = { [weak self] appID in self?.appInspector.openSelectedApp(appId: appID) }
    bridge.inspectorStateChangedHandler = { [weak self] state in self?.apply(state) }
    bridge.tweaksStateChangedHandler = { [weak self] state in self?.apply(state) }
    bridge.exclusionFiltersHandler = { [weak self] in self?.exclusionFilters ?? [] }
    bridge.addExclusionFilterHandler = { [weak self] filter in self?.addExclusionFilter(filter) }
    bridge.removeExclusionFilterHandler = { [weak self] filter in self?.removeExclusionFilter(filter) }
    container.pageReadinessChangedHandler = { [weak self, weak container] isReady in
      guard let self, let container, pages[kind]?.container === container else { return }
      pages[kind]?.isReady = isReady
      if isReady {
        container.sendPageEvent(name: "network:exclusion-filters", payload: exclusionFilters)
        container.sendPageEvent(name: "inspector:state", payload: appInspector.snapshot.pageState(for: kind))
      }
    }
    pages[kind] = Page(identity: identity, container: container)
    let transition = pageTransitions[kind]
    pageTransitions[kind] = Task { [weak self] in
      // Finish old requests and stream cleanup before a new page can send commands.
      await transition?.value
      await previous?.finishStopping()
      guard let self, !isStopped, pages[kind]?.container === container else { return }
      container.start()
      pageTransitions[kind] = nil
    }
  }

  private func apply(_ state: NetworkInspectorNativeState) {
    guard let displayedNetwork, displayedNetwork.server == state.selectedServer else { return }
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
      webContainer?.closeNativeColorPanel()
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
    replacementApp = state.replacementApp
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
      for page in pages.values {
        page.container.recoverFromEventOverflow()
      }
    }
  }

  private func sendPageEvent(name: String, payload: some Encodable) {
    if name.hasPrefix("network:") {
      pages[.network]?.container.sendPageEvent(name: name, payload: payload)
    } else if name.hasPrefix("tweaks:") {
      pages[.tweaks]?.container.sendPageEvent(name: name, payload: payload)
    } else {
      webContainer?.sendPageEvent(name: name, payload: payload)
    }
  }

  private func saveExclusionFilters(_ filters: [String]) {
    exclusionFilters = filters
    UserDefaults.standard.set(filters, forKey: Keys.exclusionFilters)
    sendPageEvent(name: "network:exclusion-filters", payload: filters)
    NotificationCenter.default.post(name: Keys.exclusionFiltersDidChange, object: nil)
  }

  private func reloadExclusionFilters() {
    let filters = Self.loadExclusionFilters()
    guard exclusionFilters != filters else { return }

    exclusionFilters = filters
    sendPageEvent(name: "network:exclusion-filters", payload: filters)
  }

  private static func loadExclusionFilters() -> [String] {
    let stored = UserDefaults.standard.stringArray(forKey: Keys.exclusionFilters)
      ?? UserDefaults.standard.stringArray(forKey: Keys.hiddenHosts)
      ?? []
    return Array(Set(stored.compactMap(normalizedExclusionFilter))).sorted()
  }

  private static func normalizedExclusionFilter(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return trimmed.hasPrefix("-") ? trimmed.lowercased() : "-\(trimmed.lowercased())"
  }
}
