import Combine
import Foundation

actor LogLionStreamRouter {
  private var processors: [LogLionTabProcessor] = []

  func updateProcessors(_ processors: [LogLionTabProcessor]) {
    self.processors = processors
  }

  func deliver(_ entry: LogLionEntry) async {
    for processor in processors {
      await processor.enqueue(entry)
    }
  }
}

@MainActor
final class LogLionStore: ObservableObject {
  enum StreamingState: Equatable {
    case noDevice
    case paused
    case streaming
  }

  @Published private(set) var tabs: [LogLionTab] = [] {
    didSet { updateStreamingState() }
  }
  @Published var activeTabID: UUID? {
    didSet {
      guard activeTabID != oldValue else { return }
      for tab in tabs {
        let shouldBeActive = tab.id == activeTabID
        if tab.isActive != shouldBeActive {
          tab.isActive = shouldBeActive
        }
        if shouldBeActive {
          tab.markAsRead()
        }
      }
    }
  }
  @Published private(set) var activeDeviceID: String? {
    didSet { updateStreamingState() }
  }
  @Published private(set) var devices: [Device] = []
  @Published private(set) var streamingState: StreamingState = .noDevice

  private let deviceStore: DeviceStore
  private let logService: LogLionService
  private let logger = SnapOLog.logLion
  private var devicesCancellable: AnyCancellable?
  private struct StreamHandle {
    let id: UUID
    let task: Task<Void, Never>
  }
  private var streamHandle: StreamHandle? {
    didSet { updateStreamingState() }
  }
  private var tabCounter = 0
  private var isStarted = false
  private var streamRouter: LogLionStreamRouter?

  /// Constructs the store on the main actor and wires device change observation.
  init(services: AppServices, deviceStore: DeviceStore) {
    self.deviceStore = deviceStore
    logService = LogLionService(
      adbService: services.adbService,
      deviceTracker: services.deviceTracker
    )
    devices = deviceStore.devices

    devicesCancellable = deviceStore.$devices
      .sink { [weak self] devices in
        Task { @MainActor [weak self] in
          self?.handleDeviceUpdate(devices)
        }
      }
  }

  /// Kicks off device tracking, opens default tabs, and starts log streaming for the active device.
  func start() {
    logger.debug("start() invoked. alreadyStarted=\(self.isStarted, privacy: .public)")
    if !isStarted {
      isStarted = true
      logger.debug("Log streaming enabled. activeDeviceID=\(self.activeDeviceID ?? "nil", privacy: .public)")

      let service = logService
      Task(priority: .utility) {
        await service.start()
      }

      if activeDeviceID == nil {
        activeDeviceID = deviceStore.devices.first?.id
      }

      if tabs.isEmpty {
        for _ in 0..<3 {
          createTab(activate: tabs.isEmpty)
        }
      }
    } else if streamHandle != nil {
      logger.debug("start() ignored because a stream is already running.")
      return
    } else {
      logger.debug("start() requested while already active; resuming streams for \(self.activeDeviceID ?? "nil", privacy: .public)")
    }

    restartStreams(resetExistingEntries: false)
    activeTab?.markAsRead()
  }

  /// Cancels the active stream task, stops rate timers, and marks the store as paused.
  func stop() {
    logger.debug("stop() invoked. isStarted=\(self.isStarted, privacy: .public)")
    guard isStarted else { return }
    isStarted = false
    cancelStream()
    logger.debug("Log streaming paused")
  }

  /// Adds a new tab and activates it, ensuring UI state reflects the addition.
  func addTab() {
    let tab = createTab(activate: true)
    logger.debug("Tab added. id=\(tab.id.uuidString, privacy: .public) totalTabs=\(self.tabs.count, privacy: .public)")
  }

  /// Removes the provided tab, reassigning the active tab when necessary.
  func removeTab(_ tab: LogLionTab) {
    guard tabs.count > 1 else { return }
    guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
    let removingActive = tab.id == activeTabID
    tabs.remove(at: index)

    if tabs.isEmpty {
      activeTabID = nil
      return
    }

    if removingActive {
      let nextIndex = index < tabs.count ? index : tabs.count - 1
      activeTabID = tabs[nextIndex].id
    }
    refreshStreamRouterFeeds()
  }

  /// Switches the active tab selection, collapsing filters on the previously active tab.
  func setActiveTab(_ id: UUID?) {
    guard activeTabID != id else { return }
    Task { @MainActor [weak self] in
      guard let self, self.activeTabID != id else { return }
      let previousActive = self.activeTab
      previousActive?.isFilterCollapsed = true
      self.activeTabID = id
    }
  }

  var activeTab: LogLionTab? {
    guard let id = activeTabID else { return nil }
    return tabs.first { $0.id == id }
  }

  var activeDevice: Device? {
    guard let id = activeDeviceID else { return nil }
    return devices.first { $0.id == id }
  }

  /// Creates a new tab model, optionally activates it, and returns the instance.
  @discardableResult
  private func createTab(activate: Bool) -> LogLionTab {
    tabCounter += 1
    let title = "Tab \(tabCounter)"
    let tab = LogLionTab(title: title)
    tabs.append(tab)

    if activate || activeTabID == nil {
      activeTabID = tab.id
    }

    refreshStreamRouterFeeds()
    return tab
  }

  /// Selects the target device and restarts streaming as needed, clearing tabs when necessary.
  func selectDevice(id: String?) {
    guard activeDeviceID != id else { return }
    activeDeviceID = id

    guard isStarted else { return }

    if let deviceID = id {
      guard devices.contains(where: { $0.id == deviceID }) else {
        activeDeviceID = nil
        cancelStream()
        resetAllTabs()
        return
      }
      restartStreams(resetExistingEntries: true)
    } else {
      cancelStream()
      resetAllTabs()
    }
  }

  /// Manually restarts streaming for the current device without clearing existing entries.
  func reconnect() {
    guard isStarted else { return }
    restartStreams(resetExistingEntries: false)
  }

  /// Resets every tab to its initial state and clears per-tab log rate counters.
  private func resetAllTabs() {
    tabs.forEach {
      $0.reset()
      $0.clearError()
    }
    refreshStreamRouterFeeds()
  }

  private func currentProcessors() -> [LogLionTabProcessor] {
    tabs.map(\.processor)
  }

  private func refreshStreamRouterFeeds() {
    guard let router = streamRouter else { return }
    let processors = currentProcessors()
    Task.detached {
      await router.updateProcessors(processors)
    }
  }

  /// Cancels the current stream, optionally clears existing entries, and starts streaming the selected device.
  private func restartStreams(resetExistingEntries: Bool) {

    cancelStream()

    guard isStarted, let deviceID = activeDeviceID else {
      let reason = isStarted ? "noDevice" : "notStarted"
      logger.debug("restartStreams() skipped. reason=\(reason, privacy: .public)")
      return
    }

    if resetExistingEntries {
      resetAllTabs()
    } else {
      tabs.forEach { $0.clearError() }
    }

    startStreaming(deviceID: deviceID)
  }
  
  /// Cancels and forgets the outstanding streaming task if one exists.
  private func cancelStream() {
    guard let handle = streamHandle else { return }
    handle.task.cancel()
    streamHandle = nil
    streamRouter = nil
  }

  /// Launches a detached task that consumes the service's event stream for the specified device.
  private func startStreaming(deviceID: String) {
    let handleID = UUID()
    print("start stream: \(handleID): \(deviceID)")
    let logService = logService
    let router = LogLionStreamRouter()
    streamRouter = router
    let initialProcessors = currentProcessors()
    let task = Task.detached(priority: .userInitiated) { [weak self, logService, router] in
      let stream = await logService.eventsStream(for: deviceID)
      var didCancel = false
      await router.updateProcessors(initialProcessors)

      for await event in stream {
        guard let store = self else {
          didCancel = true
          break
        }
        if Task.isCancelled {
          didCancel = true
          break
        }

        switch event {
        case .entry(let entry):
          await router.deliver(entry)
        case .stream(let state):
          await store.handleStreamEvent(state, handleID: handleID, deviceID: deviceID)
        }
      }

      if didCancel || Task.isCancelled {
        await self?.handleStreamCancellation(handleID: handleID, deviceID: deviceID)
      }

      await self?.handleStreamCompletion(handleID: handleID, deviceID: deviceID)
    }

    streamHandle = StreamHandle(id: handleID, task: task)
  }

  /// Syncs the store's device list with the tracker and adjusts selections/streams accordingly.
  private func handleDeviceUpdate(_ devices: [Device]) {
    logger.debug("handleDeviceUpdate() received count=\(devices.count, privacy: .public)")
    self.devices = devices

    guard !devices.isEmpty else {
      let shouldReset = activeDeviceID != nil
      activeDeviceID = nil
      if shouldReset {
        cancelStream()
        resetAllTabs()
      }
      return
    }

    if let activeID = activeDeviceID,
       devices.contains(where: { $0.id == activeID }) {
      return
    }

    let fallback = devices.first?.id
    guard activeDeviceID != fallback else { return }
    activeDeviceID = fallback

    guard isStarted else { return }
    restartStreams(resetExistingEntries: true)
  }

  /// Computes the derived `streamingState` based on the current device selection and task handle.
  private func updateStreamingState() {
    let newState: StreamingState

    if activeDeviceID == nil {
      newState = .noDevice
    } else if streamHandle != nil {
      newState = .streaming
    } else if !tabs.isEmpty {
      newState = .paused
    } else {
      newState = .paused
    }

    if streamingState != newState {
      streamingState = newState
    }
  }

  /// Notes that streaming was cancelled for the matched handle; no state changes beyond logging.
  @MainActor
  private func handleStreamCancellation(handleID: UUID, deviceID: String) {
    guard let handle = streamHandle,
          handle.id == handleID else {
      return
    }
    logger.debug("Log stream cancelled for device=\(deviceID, privacy: .public)")
  }

  /// Clears the stored stream handle when the detached task finishes for the active device.
  @MainActor
  private func handleStreamCompletion(handleID: UUID, deviceID: String) {
    guard let handle = streamHandle,
          handle.id == handleID else {
      return
    }
    logger.debug("Log stream finished for device=\(deviceID, privacy: .public)")
    streamHandle = nil
    streamRouter = nil
  }

  /// Responds to service-generated stream status events, updating tab errors and diagnostics.
  @MainActor
  private func handleStreamEvent(_ event: LogLionStreamEvent, handleID: UUID, deviceID: String) {
    guard let handle = streamHandle,
          handle.id == handleID else {
      return
    }

    switch event {
    case .connected:
      tabs.forEach { $0.clearError() }
      logger.debug("ADB stream connected for device=\(deviceID, privacy: .public)")
    case .resumed:
      tabs.forEach { $0.clearError() }
      logger.debug("ADB stream resumed for device=\(deviceID, privacy: .public)")
    case .stopped:
      logger.debug("ADB stream stopped for device=\(deviceID, privacy: .public)")
    case .reconnecting(let attempt, let reason):
      if let reason {
        let message = "Reconnecting (\(attempt)): \(reason)"
        tabs.forEach { $0.setError(message) }
      }
      logger.debug("ADB stream reconnecting attempt=\(attempt, privacy: .public) device=\(deviceID, privacy: .public)")
    case .disconnected(let reason):
      let message = reason ?? "ADB stream disconnected."
      tabs.forEach { $0.setError(message) }
      logger.error("ADB stream disconnected for device=\(deviceID, privacy: .public): \(message, privacy: .public)")
    }
  }
}
