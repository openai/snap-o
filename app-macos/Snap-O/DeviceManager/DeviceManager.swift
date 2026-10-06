import Foundation
import Observation

@Observable
@MainActor
final class DeviceManager {
  private(set) var emulators: [ManagedEmulator] = []
  private(set) var inventory = DeviceInventory()
  var connectedDevices: [Device] {
    inventory.connected ?? []
  }

  var latestDevices: [Device] {
    inventory.ready ?? []
  }

  private(set) var adbServerState: ADBServerState = .connecting
  @ObservationIgnored private var adbRecoveryTask: Task<Void, Never>?

  @ObservationIgnored private var trackedDevices: [Device]?
  @ObservationIgnored private var readyDevices: [Device]?
  @ObservationIgnored private var observationTask: Task<Void, Never>?
  private(set) var matchingSerials: Set<String> = []
  @ObservationIgnored private var matchingTasks: [Int: Task<Void, Never>] = [:]
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  private var shutdownTask: Task<Void, Never>?
  var isShuttingDown: Bool {
    shutdownTask != nil
  }

  private var trackedConnections: [EmulatorConnection] = []
  private(set) var isRefreshing = false
  private(set) var hasLoaded = false
  private(set) var loadError: String?
  private(set) var actions: [String: String] = [:]
  var actionError: String?
  private(set) var launchErrors: [String: String] = [:]

  var entries: [DeviceManagerEntry] {
    let visibleEmulators = emulators.map { device in
      var device = device
      if !matchingSerials.isEmpty, device.serial == nil, device.state == .unavailable {
        device.state = .starting
        device.detail = nil
      }
      return device
    }
    return DeviceManagerEntry.list(
      emulators: visibleEmulators,
      connectedDevices: connectedDevices.filter { !matchingSerials.contains($0.id) }
    )
  }

  @ObservationIgnored private let deviceTracker: DeviceTracker
  @ObservationIgnored private let adb: ADBService
  @ObservationIgnored private let client: AndroidHostClient
  @ObservationIgnored private var actionTasks: [String: Task<Void, Never>] = [:]
  private var inventoryGeneration = 0
  private var bootConnections: [EmulatorConnection] = []
  private var inventoryConnections: [EmulatorConnection] = []

  init(adb: ADBService, deviceTracker: DeviceTracker, client: AndroidHostClient = AndroidHostClient()) {
    self.adb = adb
    self.deviceTracker = deviceTracker
    self.client = client
  }

  func resolve(_ request: DeviceOpenRequest, progress: (String) -> Void) async throws -> String {
    let resolver = DeviceOpenResolver {
      DeviceOpenSnapshot(
        connectedSerials: Set(self.connectedDevices.map(\.id)),
        emulators: self.entries.compactMap {
          guard case .emulator(let device) = $0 else { return nil }
          return device
        },
        hasLoaded: self.hasLoaded,
        isRefreshing: self.isRefreshing || !self.matchingSerials.isEmpty,
        loadError: self.loadError,
        actions: self.actions,
        launchErrors: self.launchErrors
      )
    } start: { self.start($0) }
    return try await resolver.resolve(request, progress: progress)
  }

  func startupStatus(for device: ManagedEmulator) -> String? {
    if let action = actions[device.id] { return action }
    switch device.state {
    case .starting: return device.serial == nil ? "Connecting" : "Booting"
    case .offline: return "Connecting"
    case .stopping: return device.state.title
    case .stopped, .running, .unavailable: return nil
    }
  }

  func screenshot(for target: DeviceTarget) async throws -> Data {
    guard shutdownTask == nil, connectedDevices.contains(where: { $0.connection == target }) else {
      throw ADBError.protocolFailure("The device connection is no longer available.")
    }
    _ = try target.requireTransport(for: target.serial)
    let exec = await adb.exec().bound(to: target)
    guard shutdownTask == nil else { throw CancellationError() }
    return try await exec.screencapPNG(deviceID: target.serial)
  }

  func delete(_ device: ManagedEmulator) {
    guard shutdownTask == nil, actions[device.id] == nil, device.canDelete else { return }
    beginAction(for: device.id, status: "Deleting")
    actionTasks[device.id] = Task { [weak self] in
      guard let self else { return }
      defer { finishAction(for: device.id) }
      guard !Task.isCancelled else { return }
      do {
        let connections = try await emulatorConnections()
        try Task.checkCancellation()
        let inventory = try await client.delete(device.id, serials: connections.map(\.serial))
        try Task.checkCancellation()
        applyAction(inventory, id: device.id)
      } catch is CancellationError {
        return
      } catch {
        actionError = error.localizedDescription
      }
    }
  }

  func start() {
    guard shutdownTask == nil, observationTask == nil else { return }
    // Begin device discovery before window setup can delay it.
    observationTask = Task.immediate {
      guard !Task.isCancelled else { return }
      await deviceTracker.startTracking()
      guard !Task.isCancelled else { return }
      async let serverState: Void = observeServerState()
      async let connections: Void = observeConnections(preview: true)
      async let properties: Void = observeConnections(preview: false)
      await observeEmulators()
      await connections
      await properties
      await serverState
    }
  }

  func retryADBServer() {
    guard shutdownTask == nil, adbRecoveryTask == nil else { return }
    adbRecoveryTask = Task {
      defer { adbRecoveryTask = nil }
      guard !Task.isCancelled else { return }
      await deviceTracker.retryADBServer()
    }
  }

  private func observeServerState() async {
    for await state in await deviceTracker.serverStateStream() {
      guard !Task.isCancelled else { return }
      adbServerState = state
    }
  }

  func waitForReadyDevices() async -> [Device]? {
    guard !Task.isCancelled, !isShuttingDown else { return nil }
    start()
    for await (isShuttingDown, devices) in Observations({ (self.isShuttingDown, self.inventory.ready) }) {
      guard !Task.isCancelled, !isShuttingDown else { return nil }
      if let devices { return devices }
    }
    return nil
  }

  private func observeConnections(preview: Bool) async {
    let stream = if preview {
      await deviceTracker.previewDeviceStream()
    } else {
      await deviceTracker.deviceStream()
    }
    for await devices in stream {
      guard !Task.isCancelled else { return }
      if preview {
        trackedDevices = devices
        matchEmulators(in: devices)
      } else {
        readyDevices = devices
      }
      publishDevices()
    }
  }

  private func matchEmulators(in devices: [Device]) {
    guard observationTask != nil else { return }
    let connections = devices.filter { EmulatorGRPCEndpoint.isEmulator($0.id) }.map {
      EmulatorConnection(serial: $0.id, transportID: $0.transportID, state: .starting)
    }.sorted { $0.serial < $1.serial }
    guard connections != trackedConnections else { return }
    matchingSerials = Set(connections.filter { cachedEmulator(for: $0) == nil }.map(\.serial))
    guard actions.isEmpty else { return }
    trackedConnections = connections
    cancelMatching()
    inventoryGeneration += 1
    let generation = inventoryGeneration
    matchingTasks[generation] = Task {
      defer {
        matchingTasks[generation] = nil
        if generation == inventoryGeneration { matchingSerials = [] }
      }
      do {
        let inventory = try await loadInventory(connections: connections)
        guard !Task.isCancelled, generation == inventoryGeneration else { return }
        bootConnections = EmulatorConnection.reconcileBootChecks(bootConnections, current: connections)
        apply(inventory, connections: bootConnections)
        hasLoaded = true
        loadError = nil
      } catch is CancellationError {
        return
      } catch {
        // Keep unmatched devices accessible when the console cannot identify them.
        guard generation == inventoryGeneration else { return }
        loadError = error.localizedDescription
      }
    }
  }

  private func cachedEmulator(for connection: EmulatorConnection) -> ManagedEmulator? {
    guard inventoryConnections.contains(where: {
      $0.serial == connection.serial && $0.transportID == connection.transportID
    }) else { return nil }
    return emulators.first { $0.serial == connection.serial }
  }

  private func loadInventory(connections: [EmulatorConnection]) async throws -> EmulatorInventory {
    let known = connections.compactMap { cachedEmulator(for: $0) }
    let unmatched = connections.filter { connection in !known.contains { $0.serial == connection.serial } }
    try Task.checkCancellation()
    let inventory = try await client.snapshot(serials: unmatched.map(\.serial))
    return EmulatorInventory(devices: inventory.devices.map { device in
      guard let match = known.first(where: { $0.id == device.id }) else { return device }
      var device = device
      device.serial = match.serial
      if device.state != .stopping {
        device.state = .offline
        device.detail = nil
      }
      return device
    })
  }

  private func publishDevices() {
    let connected = (trackedDevices ?? []).map(resolveName)
    let ready = (readyDevices ?? []).filter { device in
      connected.contains { $0.id == device.id && $0.connection == device.connection && $0.transportID == device.transportID }
    }.map(resolveName)
    inventory = DeviceInventory(
      connected: trackedDevices == nil ? nil : connected,
      ready: readyDevices == nil ? nil : ready
    )
  }

  private func resolveName(_ device: Device) -> Device {
    guard device.id.hasPrefix("emulator-") else { return device }
    let connection = inventoryConnections.first { $0.serial == device.id && $0.transportID == device.transportID }
    let emulator = emulators.first { $0.avdName.replacingOccurrences(of: "_", with: " ") == device.avdName }
      ?? emulators.first { connection != nil && $0.serial == device.id }
    // Keep a resolved name through temporary console failures, but never across transports.
    let previous = connectedDevices
      .first { $0.id == device.id && $0.connection == device.connection && $0.transportID == device.transportID }
    return Device(
      id: device.id, model: device.model, androidVersion: device.androidVersion,
      vendorModel: device.vendorModel, manufacturer: device.manufacturer, avdName: device.avdName,
      displayName: emulator?.title ?? previous?.displayName, transportID: device.transportID, connection: device.connection
    )
  }

  private func observeEmulators() async {
    while !Task.isCancelled {
      await refresh()
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
    }
  }

  func refresh() async {
    guard shutdownTask == nil, !isRefreshing, actions.isEmpty else { return }
    isRefreshing = true
    let task = Task {
      defer {
        isRefreshing = false
        refreshTask = nil
      }
      guard !Task.isCancelled else { return }
      await refreshInventory()
    }
    refreshTask = task
    await withTaskCancellationHandler {
      await task.value
    } onCancel: { task.cancel() }
  }

  private func refreshInventory() async {
    let generation = inventoryGeneration
    do {
      // Local AVDs do not depend on Android responding to shell requests.
      if !hasLoaded {
        let inventory = try await client.snapshot(serials: [])
        guard generation == inventoryGeneration else { return }
        apply(inventory, connections: [])
        hasLoaded = true
      }
      let connections = try await emulatorConnections(checkBoot: false)
      let inventory = try await loadInventory(connections: connections)
      guard generation == inventoryGeneration else { return }
      bootConnections = EmulatorConnection.reconcileBootChecks(bootConnections, current: connections)
      apply(inventory, connections: bootConnections)
      loadError = nil
      hasLoaded = true
      guard bootConnections.contains(where: { $0.state == .starting }) else { return }
      let checked = try await emulatorConnections()
      guard generation == inventoryGeneration,
            connections.count == checked.count,
            connections.allSatisfy({ connection in
              checked.contains { $0.serial == connection.serial && $0.transportID == connection.transportID }
            }) else { return }
      bootConnections = checked
      apply(inventory, connections: checked)
    } catch is CancellationError {
      return
    } catch {
      guard generation == inventoryGeneration else { return }
      loadError = error.localizedDescription
      hasLoaded = true
    }
  }

  func start(_ device: ManagedEmulator, coldBoot: Bool = false) {
    guard shutdownTask == nil, actions[device.id] == nil else { return }
    beginAction(for: device.id, status: "Starting")
    launchErrors.removeValue(forKey: device.id)
    actionTasks[device.id] = Task { [weak self] in
      guard let self else { return }
      defer { finishAction(for: device.id) }
      guard !Task.isCancelled else { return }
      do {
        let connections = try await emulatorConnections()
        try Task.checkCancellation()
        let inventory = try await client.start(device.id, coldBoot: coldBoot, serials: connections.map(\.serial))
        try Task.checkCancellation()
        // A cold boot invalidates the old transport and its boot-completion result.
        applyAction(inventory, id: device.id)
      } catch is CancellationError {
        return
      } catch {
        launchErrors[device.id] = error.localizedDescription
        actionError = error.localizedDescription
      }
    }
  }

  func stop(_ device: ManagedEmulator) {
    guard shutdownTask == nil, actions[device.id] == nil, let serial = device.serial else { return }
    beginAction(for: device.id, status: "Stopping")
    actionTasks[device.id] = Task { [weak self] in
      guard let self else { return }
      defer { finishAction(for: device.id) }
      guard !Task.isCancelled else { return }
      do {
        let inventory = try await client.stop(device.id, serial: serial)
        try Task.checkCancellation()
        applyAction(inventory, id: device.id)
      } catch is CancellationError {
        return
      } catch {
        actionError = error.localizedDescription
      }
    }
  }

  private func beginAction(for id: String, status: String) {
    inventoryGeneration += 1
    cancelMatching()
    trackedConnections = []
    actions[id] = status
  }

  private func finishAction(for id: String) {
    actions.removeValue(forKey: id)
    actionTasks.removeValue(forKey: id)
    matchEmulators(in: trackedDevices ?? [])
  }

  private func cancelMatching() {
    for task in matchingTasks.values {
      task.cancel()
    }
  }

  @discardableResult
  func shutdown() -> Task<Void, Never> {
    if let shutdownTask { return shutdownTask }
    let pending = [adbRecoveryTask, observationTask, refreshTask].compactMap(\.self)
      + Array(matchingTasks.values) + Array(actionTasks.values)
    for task in pending {
      task.cancel()
    }
    adbRecoveryTask = nil
    observationTask = nil
    refreshTask = nil
    inventoryGeneration += 1
    matchingTasks.removeAll()
    matchingSerials = []
    actionTasks.removeAll()
    client.close()
    let task = Task {
      for task in pending {
        await task.value
      }
    }
    shutdownTask = task
    return task
  }

  private func apply(_ inventory: EmulatorInventory, connections: [EmulatorConnection]) {
    inventoryConnections = connections
    emulators = EmulatorConnection.applying(connections, to: inventory)
    publishDevices()
  }

  private func applyAction(_ inventory: EmulatorInventory, id: String) {
    guard shutdownTask == nil else { return }
    if let serial = emulators.first(where: { $0.id == id })?.serial {
      bootConnections.removeAll { $0.serial == serial }
    }
    // Action replies describe the changed AVD; preserve other devices until the next native refresh.
    emulators = inventory.devices.map { device in
      device.id == id ? device : emulators.first { $0.id == device.id } ?? device
    }
    publishDevices()
  }

  private func emulatorConnections(checkBoot: Bool = true) async throws -> [EmulatorConnection] {
    try Task.checkCancellation()
    let exec = await adb.exec()
    try Task.checkCancellation()
    return try await exec.emulatorConnections(checkBoot: checkBoot)
  }
}
