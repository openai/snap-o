import Foundation
import Observation

@Observable
@MainActor
final class PluginHostModel {
  private(set) var toolApps: [InspectableApp] = []
  private(set) var selectedTool: SelectedAppTool?
  private(set) var selectedToolApp: InspectableApp?
  private(set) var replacementApp: InspectableApp?
  private(set) var preferredPluginID: PluginID?
  private(set) var isRestoringTool = false
  private(set) var appLaunch: AppLaunchState?
  private(set) var isWaiting = true
  var isDevelopmentServerPresented = false

  var selectedCompatibility: PluginCompatibility {
    selectedToolApp?.tools.first { $0.kind == preferredPluginID }?.compatibility ?? .unknown
  }

  var compatibilityExplanation: PluginCompatibility? {
    // A development frontend can replace a missing archive, but not an unknown tool identity.
    if developmentURL != nil, case .missingFrontend = selectedCompatibility { return nil }
    return selectedCompatibility.title(for: preferredPluginID) == nil ? nil : selectedCompatibility
  }

  var isPageReady: Bool {
    activePage?.isReady ?? false
  }

  var webContainer: ToolWebContainer? {
    activePage?.container
  }

  var frontendError: String? {
    activePage?.error
  }

  var developmentURL: URL? {
    activePage?.identity.developmentURL
  }

  var canConfigureDevelopmentServer: Bool {
    activePage?.identity.storageIdentifier != nil
  }

  func useDevelopmentServer(_ url: URL?) {
    guard let scope = activePage?.identity.storageIdentifier,
          url == nil || ToolWebPolicy.developmentURL(url?.absoluteString ?? "") != nil else { return }
    let key = "inspectorDevelopmentServer." + scope.uuidString
    if let url {
      preferences.set(url.absoluteString, forKey: key)
    } else {
      preferences.removeObject(forKey: key)
    }
    apply(appTool.snapshot)
  }

  func retryFrontend() {
    guard let kind = preferredPluginID, let identity = pages[kind]?.identity else { return }
    replacePage(kind: kind, identity: identity)
  }

  var toolbarActions: [ToolToolbarAction] {
    activePage?.toolbar.actions ?? []
  }

  private var activePage: Page? {
    preferredPluginID.flatMap { pages[$0] }
  }

  private struct PageIdentity: Equatable {
    let appID: String?
    let server: PluginServerReference?
    let processIdentity: String?
    let storageIdentifier: UUID?
    let packageRevision: String?
    let frontend: PluginFrontend?
    let developmentURL: URL?
    let compatibility: PluginCompatibility
  }

  private struct Page {
    let identity: PageIdentity
    let container: ToolWebContainer
    var isReady = false
    var error: String?
    var endpointID: UUID?
    var connection = PluginConnectionState()
    var toolbar = ToolToolbar(revision: 0, actions: [])
  }

  private var pages: [PluginID: Page] = [:]
  @ObservationIgnored private let service: PluginService
  @ObservationIgnored private var pageTransitions: [PluginID: Task<Void, Never>] = [:]
  @ObservationIgnored private var bindings: [PluginID: Task<Void, Never>] = [:]
  @ObservationIgnored private var isStopped = false
  @ObservationIgnored private let appTool: AppToolModel
  @ObservationIgnored private let preferences: UserDefaults

  init(service: PluginService, preferences: UserDefaults = .standard) {
    self.service = service
    self.preferences = preferences
    appTool = AppToolModel(
      preferences: preferences,
      discover: { await service.discoverPlugins() },
      changes: { await service.changes() },
      currentDiscovery: { await service.currentPlugins() },
      openApp: { try await service.openApp($0) }
    )
    appTool.stateChanged = { [weak self] snapshot in self?.apply(snapshot) }
    apply(appTool.snapshot)
    appTool.start()
  }

  func stop() {
    guard !isStopped else { return }
    isStopped = true
    appTool.stop()
    for task in pageTransitions.values {
      task.cancel()
    }
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
        await service.releasePluginEndpoint(ownerID: page.container.id)
      }
    }
    pages.removeAll()
  }

  func selectApp(_ app: InspectableApp) {
    appTool.selectApp(app)
  }

  func selectTool(_ app: InspectableApp, option: AppToolOption) {
    appTool.selectTool(app, option: option)
  }

  func reconnectToNewProcess() {
    appTool.reconnectToNewProcess()
  }

  func openSelectedApp() {
    if let selectedToolApp { appTool.openSelectedApp(appId: selectedToolApp.id) }
  }

  func activateToolbarAction(_ id: String, value: String? = nil) {
    guard let kind = preferredPluginID else { return }
    guard var page = pages[kind], page.isReady,
          let index = page.toolbar.actions.firstIndex(where: { $0.id == id }),
          page.toolbar.actions[index].enabled != false else { return }
    var event = ToolToolbarEvent(revision: page.toolbar.revision, id: id)
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

  private func apply(_ snapshot: AppToolSnapshot) {
    guard !isStopped else { return }
    let state = snapshot.state
    if selectedTool?.kind != state.selection?.kind || selectedTool?.server != state.selection?.server {
      webContainer?.closeNativeColorPanel()
    }
    toolApps = state.apps
    selectedTool = state.selection
    selectedToolApp = state.selectedApp
    replacementApp = state.replacementApp
    preferredPluginID = state.preferredKind
    isRestoringTool = state.isRestoring
    appLaunch = snapshot.appLaunch
    guard let kind = state.preferredKind else { return }
    let pageState = snapshot.pageState(for: kind)
    isWaiting = pageState.isWaiting
    let scope = ToolWebPolicy.storageIdentifier(app: pageState.selectedApp, tool: kind)
    let developmentURL = scope
      .flatMap { preferences.string(forKey: "inspectorDevelopmentServer." + $0.uuidString) }
      .flatMap(ToolWebPolicy.developmentURL)
    let identity = PageIdentity(
      appID: pageState.selectedApp?.id, server: pageState.selection?.server,
      processIdentity: pageState.selectedApp?.metadata?.verifiedIdentity?.processIdentity,
      storageIdentifier: scope, packageRevision: pageState.selectedApp?.metadata?.verifiedIdentity?.revision,
      frontend: pageState.selectedApp?.metadata?.tools.first { $0.id == kind }?.frontend,
      developmentURL: developmentURL, compatibility: selectedCompatibility
    )
    if pages[kind]?.identity != identity { replacePage(kind: kind, identity: identity) }
    for kind in pages.keys {
      synchronizeConnection(kind: kind)
    }
  }

  private func synchronizeConnection(kind: PluginID) {
    bindings[kind]?.cancel()
    guard let page = pages[kind] else { return }
    let state = appTool.snapshot.pageState(for: kind)
    guard page.isReady else { return }
    guard state.isActive, state.isConnected, let selection = state.selection else {
      setEndpoint(nil, kind: kind)
      return
    }
    bindings[kind] = Task { [weak self, weak container = page.container] in
      guard let self, let container else { return }
      do {
        let target = try await service.pluginEndpoint(
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

  private func setEndpoint(_ endpoint: PluginHTTPService.Endpoint?, kind: PluginID) {
    guard var page = pages[kind] else { return }
    let state = appTool.snapshot.pageState(for: kind)
    let app = state.selectedApp?.id == page.identity.appID
      ? state.selectedApp : toolApps.first { $0.id == page.identity.appID }
    // Hidden pages retain their own app's metadata when another app is selected.
    let metadata = app?.metadata ?? page.connection.metadata
    let tool = metadata?.tools.first { $0.id == kind }
    guard page.endpointID != endpoint?.id || page.connection.metadata != metadata || page.connection.tool != tool else { return }
    page.connection.metadata = metadata
    page.connection.tool = tool
    page.endpointID = endpoint?.id
    page.connection.revision += 1
    page.connection.baseURL = endpoint?.baseURL.absoluteString
    page.connection.connected = endpoint != nil
    pages[kind] = page
    page.container.sendPageEvent(name: "host:connection", payload: page.connection)
  }

  private func replacePage(kind: PluginID, identity: PageIdentity) {
    let metadata = appTool.snapshot.pageState(for: kind).selectedApp?.metadata
    let previous = pages[kind]?.container
    previous?.stop()
    bindings[kind]?.cancel()
    let bridge = ToolWebBridge()
    let container = ToolWebContainer(
      bridge: bridge,
      storageIdentifier: identity.storageIdentifier, developmentURL: identity.developmentURL
    )
    bridge.isActiveHandler = { [weak self, weak container] in
      guard let self, let container else { return false }
      return !isStopped && preferredPluginID == kind && pages[kind]?.container === container
    }
    bridge.hostStateHandler = { [weak self, weak container] in
      guard let self, let container, pages[kind]?.container === container else { return PluginConnectionState() }
      return pages[kind]?.connection ?? PluginConnectionState()
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
      if isReady { pages[kind]?.error = nil }
      if !isReady { pages[kind]?.toolbar = ToolToolbar(revision: 0, actions: []) }
      synchronizeConnection(kind: kind)
    }
    container.pageLoadFailedHandler = { [weak self, weak container] message in
      guard let self, let container, pages[kind]?.container === container else { return }
      pages[kind]?.error = message
    }
    pages[kind] = Page(identity: identity, container: container)
    let transition = pageTransitions[kind]
    transition?.cancel()
    pageTransitions[kind] = Task { [weak self] in
      await transition?.value
      await previous?.finishStopping()
      if let previous { await self?.service.releasePluginEndpoint(ownerID: previous.id) }
      guard let self, !Task.isCancelled, !isStopped, pages[kind]?.container === container else { return }
      defer {
        if pages[kind]?.container === container { pageTransitions[kind] = nil }
      }
      switch identity.compatibility {
      case .supported: break
      case .missingFrontend where identity.developmentURL != nil: break
      default: return
      }
      do {
        let frontend: PluginFrontendBundle?
        if identity.developmentURL != nil {
          frontend = nil
        } else if identity.frontend != nil {
          guard let server = identity.server, let processIdentity = metadata?.verifiedIdentity,
                let tool = metadata?.tools.first(where: { $0.id == kind }),
                tool.frontend?.hostApiVersion == 1 else { throw PluginError.frontendUnavailable }
          frontend = try await service.pluginFrontend(for: server, identity: processIdentity, tool: tool)
        } else {
          throw PluginError.frontendUnavailable
        }
        guard !Task.isCancelled, !isStopped, pages[kind]?.container === container else { return }
        container.start(frontend: frontend)
      } catch {
        guard !Task.isCancelled, !isStopped, pages[kind]?.container === container else { return }
        pages[kind]?.error = error.localizedDescription
      }
    }
  }
}
