import Foundation
import Observation
import SnapODeviceClient

@Observable
@MainActor
final class InspectorHostModel {
  private(set) var inspectorApps: [InspectableApp] = []
  private(set) var selectedInspector: SelectedAppInspector?
  private(set) var selectedInspectorApp: InspectableApp?
  private(set) var replacementApp: InspectableApp?
  private(set) var preferredInspectorID: InspectorID?
  private(set) var isRestoringInspector = false
  private(set) var appLaunch: AppLaunchState?
  private(set) var isWaiting = true

  var isPageReady: Bool {
    activePage?.isReady ?? false
  }

  var webContainer: InspectorWebContainer? {
    activePage?.container
  }

  var toolbarActions: [InspectorToolbarAction] {
    activePage?.toolbar.actions ?? []
  }

  private var activePage: Page? {
    preferredInspectorID.flatMap { pages[$0] }
  }

  private struct PageIdentity: Equatable {
    let appID: String?
    let server: InspectorServerReference?
    let processIdentity: String?
    let storageIdentifier: UUID?
  }

  private struct Page {
    let identity: PageIdentity
    let container: InspectorWebContainer
    var isReady = false
    var endpointID: UUID?
    var connection = InspectorConnectionState()
    var toolbar = InspectorToolbar(revision: 0, actions: [])
  }

  private var pages: [InspectorID: Page] = [:]
  @ObservationIgnored private let service: InspectorService
  @ObservationIgnored private var pageTransitions: [InspectorID: Task<Void, Never>] = [:]
  @ObservationIgnored private var bindings: [InspectorID: Task<Void, Never>] = [:]
  @ObservationIgnored private var isStopped = false
  @ObservationIgnored private let appInspector: AppInspectorModel

  init(service: InspectorService, preferences: UserDefaults = .standard) {
    self.service = service
    appInspector = AppInspectorModel(
      preferences: preferences,
      discover: { await service.discoverInspectors() },
      changes: { await service.changes() },
      currentDiscovery: { await service.currentInspectors() },
      openApp: { try await service.openApp($0) }
    )
    appInspector.stateChanged = { [weak self] snapshot in self?.apply(snapshot) }
    apply(appInspector.snapshot)
    appInspector.start()
  }

  func stop() {
    guard !isStopped else { return }
    isStopped = true
    appInspector.stop()
    for task in bindings.values {
      task.cancel()
    }
    bindings.removeAll()
    for (kind, page) in pages {
      page.container.stop()
      let transition = pageTransitions[kind]
      pageTransitions[kind] = Task {
        await transition?.value
        await page.container.finishStopping()
        await service.releaseInspectorEndpoint(ownerID: page.container.id)
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

  func openSelectedApp() {
    if let selectedInspectorApp { appInspector.openSelectedApp(appId: selectedInspectorApp.id) }
  }

  func activateToolbarAction(_ id: String, value: String? = nil) {
    guard let kind = preferredInspectorID else { return }
    guard var page = pages[kind], page.isReady,
          let index = page.toolbar.actions.firstIndex(where: { $0.id == id }),
          page.toolbar.actions[index].enabled != false else { return }
    var event = InspectorToolbarEvent(revision: page.toolbar.revision, id: id)
    if page.toolbar.actions[index].type == .search {
      guard let value else { return }
      let revision = (page.toolbar.actions[index].inputRevision ?? 0) + 1
      page.toolbar.actions[index].value = value
      page.toolbar.actions[index].inputRevision = revision
      event.value = value
      event.inputRevision = revision
      pages[kind] = page
    }
    page.container.sendPageEvent(name: "host:toolbar", payload: event)
  }

  private func apply(_ snapshot: AppInspectorSnapshot) {
    guard !isStopped else { return }
    let state = snapshot.state
    if selectedInspector?.kind != state.selection?.kind || selectedInspector?.server != state.selection?.server {
      webContainer?.closeNativeColorPanel()
    }
    inspectorApps = state.apps
    selectedInspector = state.selection
    selectedInspectorApp = state.selectedApp
    replacementApp = state.replacementApp
    preferredInspectorID = state.preferredKind
    isRestoringInspector = state.isRestoring
    appLaunch = snapshot.appLaunch
    guard let kind = state.preferredKind else { return }
    let pageState = snapshot.pageState(for: kind)
    isWaiting = pageState.isWaiting
    let identity = PageIdentity(
      appID: pageState.selectedApp?.id, server: pageState.selection?.server,
      processIdentity: pageState.selectedApp?.manifest?.processIdentity,
      storageIdentifier: InspectorWebPolicy.storageIdentifier(app: pageState.selectedApp, inspector: kind)
    )
    if pages[kind]?.identity != identity { replacePage(kind: kind, identity: identity) }
    for kind in pages.keys {
      synchronizeConnection(kind: kind)
    }
  }

  private func synchronizeConnection(kind: InspectorID) {
    bindings[kind]?.cancel()
    guard let page = pages[kind] else { return }
    let state = appInspector.snapshot.pageState(for: kind)
    guard page.isReady else { return }
    guard state.isActive, state.isConnected, let selection = state.selection else {
      setEndpoint(nil, kind: kind)
      return
    }
    bindings[kind] = Task { [weak self, weak container = page.container] in
      guard let self, let container else { return }
      do {
        let target = try await service.inspectorEndpoint(
          for: selection.server, ownerID: container.id
        ) { [weak self, weak container] in
          guard let container else { return }
          container.stop()
          await container.finishStopping()
          guard let self, !isStopped, pages[kind]?.container === container,
                let identity = pages[kind]?.identity else { return }
          replacePage(kind: kind, identity: identity)
        }
        try await container.allowEndpoint(target.baseURL)
        guard !Task.isCancelled, !isStopped, pages[kind]?.container === container else { return }
        setEndpoint(target, kind: kind)
      } catch {
        guard !Task.isCancelled, pages[kind]?.container === container else { return }
        setEndpoint(nil, kind: kind)
      }
    }
  }

  private func setEndpoint(_ endpoint: InspectorHTTPService.Endpoint?, kind: InspectorID) {
    guard var page = pages[kind] else { return }
    let state = appInspector.snapshot.pageState(for: kind)
    let app = state.selectedApp?.id == page.identity.appID
      ? state.selectedApp : inspectorApps.first { $0.id == page.identity.appID }
    // Hidden pages retain their own app's metadata when another app is selected.
    let manifest = app?.manifest ?? page.connection.manifest
    let inspector = manifest?.app?.inspectors.first { $0.id == kind }
    guard page.endpointID != endpoint?.id || page.connection.manifest != manifest || page.connection.inspector != inspector else { return }
    page.connection.manifest = manifest
    page.connection.inspector = inspector
    page.endpointID = endpoint?.id
    page.connection.revision += 1
    page.connection.baseURL = endpoint?.baseURL.absoluteString
    page.connection.connected = endpoint != nil
    pages[kind] = page
    page.container.sendPageEvent(name: "host:connection", payload: page.connection)
  }

  private func replacePage(kind: InspectorID, identity: PageIdentity) {
    guard let plugin = service.registry.plugin(for: kind) else { return }
    let previous = pages[kind]?.container
    previous?.stop()
    bindings[kind]?.cancel()
    let bridge = InspectorWebBridge()
    let container = InspectorWebContainer(bridge: bridge, plugin: plugin, storageIdentifier: identity.storageIdentifier)
    bridge.isActiveHandler = { [weak self, weak container] in
      guard let self, let container else { return false }
      return !isStopped && preferredInspectorID == kind && pages[kind]?.container === container
    }
    bridge.hostStateHandler = { [weak self, weak container] in
      guard let self, let container, pages[kind]?.container === container else { return InspectorConnectionState() }
      return pages[kind]?.connection ?? InspectorConnectionState()
    }
    bridge.toolbarHandler = { [weak self, weak container] toolbar in
      guard let self, let container, var page = pages[kind], page.container === container,
            toolbar.revision > page.toolbar.revision else { return }
      var toolbar = toolbar
      for index in toolbar.actions.indices where toolbar.actions[index].type == .search {
        if let old = page.toolbar.actions.first(where: { $0.id == toolbar.actions[index].id && $0.type == .search }),
           (old.inputRevision ?? 0) > (toolbar.actions[index].inputRevision ?? 0) {
          toolbar.actions[index].value = old.value
          toolbar.actions[index].inputRevision = old.inputRevision
        }
      }
      page.toolbar = toolbar
      pages[kind] = page
    }
    container.pageReadinessChangedHandler = { [weak self, weak container] isReady in
      guard let self, let container, pages[kind]?.container === container else { return }
      pages[kind]?.isReady = isReady
      if !isReady { pages[kind]?.toolbar = InspectorToolbar(revision: 0, actions: []) }
      synchronizeConnection(kind: kind)
    }
    pages[kind] = Page(identity: identity, container: container)
    let transition = pageTransitions[kind]
    pageTransitions[kind] = Task { [weak self] in
      await transition?.value
      await previous?.finishStopping()
      if let previous { await self?.service.releaseInspectorEndpoint(ownerID: previous.id) }
      guard let self, !isStopped, pages[kind]?.container === container else { return }
      container.start()
      pageTransitions[kind] = nil
    }
  }
}
