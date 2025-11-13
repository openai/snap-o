import Combine
@preconcurrency import Dispatch
import Foundation

actor LogCatStreamRouter {
  private var processors: [LogCatTabProcessor] = []

  func updateProcessors(_ processors: [LogCatTabProcessor]) {
    self.processors = processors
  }

  func deliver(_ entry: LogCatEntry) async {
    for processor in processors {
      await processor.enqueue(entry)
    }
  }
}

enum LogCatSidebarSelection: Hashable {
  case tab(UUID)
  case crashes
}

struct LogCatCrashRecord: Identifiable, Equatable {
  let id: String
  let timestampString: String
  let timestamp: Date?
  private(set) var entries: [LogCatEntry]

  init(
    timestampString: String,
    timestamp: Date?,
    entries: [LogCatEntry]
  ) {
    self.timestampString = timestampString
    self.timestamp = timestamp
    self.entries = entries
    id = LogCatCrashRecord.makeIdentifier(timestampString: timestampString, entries: entries)
  }

  var messages: [String] {
    entries.map(\.message)
  }

  var title: String {
    let value = messages.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? "Crash" : value
  }

  var processName: String? {
    guard messages.indices.contains(1) else { return nil }
    let line = messages[1]
    guard let range = line.range(of: "Process:") else { return nil }
    var substring = line[range.upperBound...]
    if let comma = substring.firstIndex(of: ",") {
      substring = substring[..<comma]
    }
    let trimmed = substring.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  var errorTitle: String? {
    guard messages.indices.contains(2) else { return nil }
    let value = messages[2].trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  var formattedTimestamp: String {
    if let timestamp {
      return Self.displayFormatter.string(from: timestamp)
    }
    let trimmed = timestampString.split(separator: ".").first.map(String.init) ?? timestampString
    let parts = trimmed.split(separator: " ")
    if parts.count == 2 {
      let date = parts[0].replacingOccurrences(of: "-", with: "/")
      return "\(date) \(parts[1])"
    }
    return timestampString.isEmpty ? "Unknown time" : timestampString
  }

  var preferredTitle: String {
    errorTitle ?? title
  }

  func matches(entry: LogCatEntry, tolerance: TimeInterval = 0.005) -> Bool {
    if let recordDate = timestamp,
       let entryDate = entry.timestamp {
      return abs(recordDate.timeIntervalSince(entryDate)) <= tolerance
    }
    return timestampString == entry.timestampString
  }

  mutating func append(_ entry: LogCatEntry) {
    entries.append(entry)
  }

  private static func makeIdentifier(timestampString: String, entries: [LogCatEntry]) -> String {
    let title = entries.first?.message.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let key = title.isEmpty ? UUID().uuidString : title
    return "\(timestampString)|\(key)"
  }

  private static let displayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MM/dd HH:mm:ss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()
}

@MainActor
final class LogCatStore: ObservableObject {
  enum StreamingState: Equatable {
    case noDevice
    case paused
    case streaming
  }

  @Published private(set) var tabs: [LogCatTab] = [] {
    didSet { updateStreamingState() }
  }

  @Published var activeTabID: UUID? {
    didSet {
      if activeTabID != nil, isCrashPaneActive {
        isCrashPaneActive = false
      }
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
      scheduleTabsPersistence()
    }
  }

  @Published var isCrashPaneActive = false {
    didSet {
      guard isCrashPaneActive != oldValue else { return }
      if isCrashPaneActive {
        refreshCrashBuffer()
      } else {
        crashLoadTask?.cancel()
      }
    }
  }

  @Published private(set) var crashes: [LogCatCrashRecord] = []
  @Published var selectedCrashID: LogCatCrashRecord.ID?
  @Published private(set) var activeDeviceID: String? {
    didSet { updateStreamingState() }
  }

  @Published private(set) var devices: [Device] = []
  @Published private(set) var streamingState: StreamingState = .noDevice

  private let deviceStore: DeviceStore
  private let logService: LogCatService
  private let adbService: ADBService
  private let logger = SnapOLog.logCat
  private var devicesCancellable: AnyCancellable?
  private struct StreamHandle {
    let id: UUID
    let task: Task<Void, Never>
  }

  private static let tabsPreferencesKey = "LogCatTabsPreferences"
  private var streamHandle: StreamHandle? {
    didSet { updateStreamingState() }
  }

  private var tabCounter = 0
  private var isStarted = false
  private var streamRouter: LogCatStreamRouter?
  private var crashLoadTask: Task<Void, Never>?
  private var tabsPersistenceWorkItem: DispatchWorkItem?
  private var isRestoringTabsFromPreferences = false

  /// Constructs the store on the main actor and wires device change observation.
  init(services: AppServices, deviceStore: DeviceStore) {
    self.deviceStore = deviceStore
    adbService = services.adbService
    logService = LogCatService(
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

    restoreTabsFromPreferences()
  }

  deinit {
    crashLoadTask?.cancel()
  }

  /// Kicks off device tracking, opens default tabs, and starts log streaming for the active device.
  func start() {
    let alreadyStarted = isStarted
    logger.debug("start() invoked. alreadyStarted=\(alreadyStarted, privacy: .public)")
    if !isStarted {
      isStarted = true
      let deviceIDForLog = activeDeviceID ?? "nil"
      logger.debug("Log streaming enabled. activeDeviceID=\(deviceIDForLog, privacy: .public)")

      let service = logService
      Task(priority: .utility) {
        await service.start()
      }

      if activeDeviceID == nil {
        activeDeviceID = deviceStore.devices.first?.id
      }

      if tabs.isEmpty {
        createTab(activate: true)
      }
    } else if streamHandle != nil {
      logger.debug("start() ignored because a stream is already running.")
      return
    } else {
      let resumeDeviceID = activeDeviceID ?? "nil"
      logger.debug("start() requested while already active; resuming streams for \(resumeDeviceID, privacy: .public)")
    }

    restartStreams(resetExistingEntries: false)
    activeTab?.markAsRead()
  }

  /// Cancels the active stream task, stops rate timers, and marks the store as paused.
  func stop() {
    let alreadyStarted = isStarted
    logger.debug("stop() invoked. isStarted=\(alreadyStarted, privacy: .public)")
    guard isStarted else { return }
    isStarted = false
    cancelStream()
    logger.debug("Log streaming paused")
  }

  /// Adds a new tab and activates it, ensuring UI state reflects the addition.
  func addTab() {
    let tab = createTab(activate: true)
    let tabCount = tabs.count
    logger.debug("Tab added. id=\(tab.id.uuidString, privacy: .public) totalTabs=\(tabCount, privacy: .public)")
  }

  /// Removes the provided tab, reassigning the active tab when necessary.
  func removeTab(_ tab: LogCatTab) {
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
    scheduleTabsPersistence()
  }

  /// Switches the active tab selection, collapsing filters on the previously active tab.
  func setActiveTab(_ id: UUID?) {
    guard activeTabID != id else { return }
    Task { @MainActor [weak self] in
      guard let self, activeTabID != id else { return }
      let previousActive = activeTab
      previousActive?.isFilterCollapsed = true
      activeTabID = id
    }
  }

  func handleSidebarSelection(_ selection: LogCatSidebarSelection?) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      switch selection {
      case .crashes:
        if isCrashPaneActive {
          refreshCrashBuffer()
        } else {
          isCrashPaneActive = true
        }
      case .tab(let id):
        isCrashPaneActive = false
        setActiveTab(id)
      case nil:
        isCrashPaneActive = false
        setActiveTab(nil)
      }
    }
  }

  func selectCrash(id: LogCatCrashRecord.ID?) {
    guard selectedCrashID != id else { return }
    Task { @MainActor [weak self] in
      guard let self, selectedCrashID != id else { return }
      selectedCrashID = id
    }
  }

  var activeTab: LogCatTab? {
    guard let id = activeTabID else { return nil }
    return tabs.first { $0.id == id }
  }

  var selectedCrash: LogCatCrashRecord? {
    guard let id = selectedCrashID else { return nil }
    return crashes.first { $0.id == id }
  }

  var activeDevice: Device? {
    guard let id = activeDeviceID else { return nil }
    return devices.first { $0.id == id }
  }

  /// Creates a new tab model, optionally activates it, and returns the instance.
  @discardableResult
  private func createTab(activate: Bool) -> LogCatTab {
    tabCounter += 1
    let title = "Tab \(tabCounter)"
    let tab = LogCatTab(title: title)
    tab.isPinnedToBottom = true
    configureTabForPersistence(tab)
    tabs.append(tab)

    if activate || activeTabID == nil {
      activeTabID = tab.id
    }

    refreshStreamRouterFeeds()
    scheduleTabsPersistence()
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
        clearCrashData()
        return
      }
      clearCrashData()
      restartStreams(resetExistingEntries: true)
      if isCrashPaneActive {
        refreshCrashBuffer()
      }
    } else {
      cancelStream()
      resetAllTabs()
      clearCrashData()
    }
  }

  /// Manually restarts streaming for the current device without clearing existing entries.
  func reconnect() {
    guard isStarted else { return }
    restartStreams(resetExistingEntries: false)
  }

  // MARK: - Persistence

  private func configureTabForPersistence(_ tab: LogCatTab) {
    tab.onConfigurationChange = { [weak self] in
      self?.scheduleTabsPersistence()
    }
  }

  private func restoreTabsFromPreferences() {
    guard let data = UserDefaults.standard.data(forKey: Self.tabsPreferencesKey),
          !data.isEmpty else {
      return
    }

    isRestoringTabsFromPreferences = true
    defer { isRestoringTabsFromPreferences = false }

    do {
      let snapshot = try JSONDecoder().decode(LogCatTabsPreferences.self, from: data)
      let (restoredTabs, activeIndex) = snapshot.makeTabs()
      guard !restoredTabs.isEmpty else { return }
      restoredTabs.forEach { configureTabForPersistence($0) }
      tabCounter = max(tabCounter, restoredTabs.count)
      tabs = restoredTabs

      if let index = activeIndex,
         restoredTabs.indices.contains(index) {
        activeTabID = restoredTabs[index].id
      } else {
        activeTabID = restoredTabs.first?.id
      }
    } catch {
      logger.error("Failed to restore LogCat tabs: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func scheduleTabsPersistence() {
    guard !isRestoringTabsFromPreferences else { return }
    tabsPersistenceWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.persistTabsToPreferences()
    }
    tabsPersistenceWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
  }

  private func persistTabsToPreferences() {
    guard !isRestoringTabsFromPreferences else { return }
    let snapshot = LogCatTabsPreferences(tabs: tabs, activeTabID: activeTabID)
    do {
      let data = try JSONEncoder().encode(snapshot)
      UserDefaults.standard.set(data, forKey: Self.tabsPreferencesKey)
    } catch {
      logger.error("Failed to persist LogCat tabs: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Resets every tab to its initial state and clears per-tab log rate counters.
  private func resetAllTabs() {
    for tab in tabs {
      tab.reset()
      tab.clearError()
    }
    refreshStreamRouterFeeds()
  }

  private func clearCrashData() {
    crashLoadTask?.cancel()
    crashLoadTask = nil
    crashes = []
    selectedCrashID = nil
  }

  private func currentProcessors() -> [LogCatTabProcessor] {
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
      clearCrashData()
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
    let router = LogCatStreamRouter()
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
        clearCrashData()
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
    clearCrashData()
    restartStreams(resetExistingEntries: true)
    if isCrashPaneActive {
      refreshCrashBuffer()
    }
  }

  /// Computes the derived `streamingState` based on the current device selection and task handle.
  private func updateStreamingState() {
    let newState: StreamingState = if activeDeviceID == nil {
      .noDevice
    } else if streamHandle != nil {
      .streaming
    } else if !tabs.isEmpty {
      .paused
    } else {
      .paused
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
  private func handleStreamEvent(_ event: LogCatStreamEvent, handleID: UUID, deviceID: String) {
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

  private func refreshCrashBuffer() {
    crashLoadTask?.cancel()

    guard let deviceID = activeDeviceID else {
      crashes = []
      selectedCrashID = nil
      return
    }

    crashLoadTask = Task(priority: .userInitiated) { [weak self] in
      guard let self else { return }

      defer { self.crashLoadTask = nil }

      do {
        let exec = await adbService.exec()
        let output = try await exec.runShellString(deviceID: deviceID, command: "logcat -b crash -v threadtime -d")
        let records = await Task.detached(priority: .userInitiated) {
          LogCatStore.buildCrashRecords(from: output)
        }.value

        crashes = records
        if let selection = selectedCrashID,
           records.contains(where: { $0.id == selection }) {
          return
        }
        selectedCrashID = records.first?.id
      } catch {
        crashes = []
        selectedCrashID = nil
        logger.error("Failed to load crash log: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private nonisolated static func buildCrashRecords(from output: String) -> [LogCatCrashRecord] {
    var records: [LogCatCrashRecord] = []
    var currentRecord: LogCatCrashRecord?

    func commit() {
      if let record = currentRecord {
        records.append(record)
        currentRecord = nil
      }
    }

    output.enumerateLines { line, _ in
      guard !line.isEmpty else { return }
      let entry = LogCatLineParser.parseThreadtime(line)

      if entry.timestampString.isEmpty {
        if var record = currentRecord {
          record.append(entry)
          currentRecord = record
        }
        return
      }

      if var record = currentRecord,
         record.matches(entry: entry) {
        record.append(entry)
        currentRecord = record
        return
      }

      commit()
      currentRecord = LogCatCrashRecord(
        timestampString: entry.timestampString,
        timestamp: entry.timestamp,
        entries: [entry]
      )
    }

    commit()
    return records.sorted { lhs, rhs in
      let lhsDate = lhs.timestamp ?? .distantPast
      let rhsDate = rhs.timestamp ?? .distantPast
      if lhsDate != rhsDate {
        return lhsDate > rhsDate
      }
      return lhs.timestampString > rhs.timestampString
    }
  }
}
