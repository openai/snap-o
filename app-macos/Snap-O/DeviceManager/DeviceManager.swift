import Foundation
import Observation

@Observable
@MainActor
final class DeviceManager {
  private(set) var emulators: [ManagedEmulator] = []
  private(set) var connectedDevices: [Device] = []
  private(set) var latestDevices: [Device] = []

  @ObservationIgnored private var trackedDevices: [Device]?
  @ObservationIgnored private var readyDevices: [Device]?
  @ObservationIgnored private var observers: [UUID: (preview: Bool, continuation: AsyncStream<[Device]>.Continuation)] = [:]
  @ObservationIgnored private var observationTask: Task<Void, Never>?
  private(set) var matchingSerials: Set<String> = []
  @ObservationIgnored private var matchingTask: Task<Void, Never>?
  private var trackedConnections: [EmulatorConnection] = []
  private(set) var isRefreshing = false
  private(set) var hasLoaded = false
  private(set) var loadError: String?
  private(set) var actions: [String: String] = [:]
  var actionError: String?

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
  @ObservationIgnored private let client: EmulatorClient
  @ObservationIgnored private var actionTasks: [String: Task<Void, Never>] = [:]
  private var inventoryGeneration = 0
  private var bootConnections: [EmulatorConnection] = []
  private var inventoryConnections: [EmulatorConnection] = []

  init(adb: ADBService, deviceTracker: DeviceTracker, client: EmulatorClient = EmulatorClient()) {
    self.adb = adb
    self.deviceTracker = deviceTracker
    self.client = client
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

  func screenshot(for serial: String) async throws -> Data {
    let exec = await adb.exec()
    return try await withThrowingTaskGroup(of: Data.self) { group in
      group.addTask { try await exec.screencapPNG(deviceID: serial) }
      group.addTask {
        try await Task.sleep(for: .seconds(5))
        throw ADBError.requestTimedOut("Device thumbnail timed out")
      }
      defer { group.cancelAll() }
      guard let image = try await group.next() else { throw CancellationError() }
      return image
    }
  }

  func delete(_ device: ManagedEmulator) {
    guard actions[device.id] == nil, device.canDelete else { return }
    inventoryGeneration += 1
    matchingTask?.cancel()
    trackedConnections = []
    actions[device.id] = "Deleting"
    actionTasks[device.id] = Task { [weak self] in
      guard let self else { return }
      defer {
        actions.removeValue(forKey: device.id)
        actionTasks.removeValue(forKey: device.id)
        matchEmulators(in: trackedDevices ?? [])
      }
      do {
        let connections = try await emulatorConnections()
        let inventory = try await client.delete(device.id, serials: connections.map(\.serial))
        applyAction(inventory, id: device.id)
      } catch is CancellationError {
        return
      } catch {
        actionError = error.localizedDescription
      }
    }
  }

  func start() {
    guard observationTask == nil else { return }
    observationTask = Task {
      await deviceTracker.startTracking()
      async let connections: Void = observeConnections(preview: true)
      async let properties: Void = observeConnections(preview: false)
      await observeEmulators()
      await connections
      await properties
    }
  }

  func previewDeviceStream() -> AsyncStream<[Device]> {
    stream(preview: true)
  }

  func deviceStream() -> AsyncStream<[Device]> {
    stream(preview: false)
  }

  private func stream(preview: Bool) -> AsyncStream<[Device]> {
    start()
    let id = UUID()
    return AsyncStream { continuation in
      observers[id] = (preview, continuation)
      if preview ? trackedDevices != nil : readyDevices != nil {
        continuation.yield(preview ? connectedDevices : latestDevices)
      }
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor in self?.observers.removeValue(forKey: id) }
      }
    }
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
    matchingTask?.cancel()
    inventoryGeneration += 1
    let generation = inventoryGeneration
    matchingTask = Task {
      defer {
        if generation == inventoryGeneration {
          matchingSerials = []
          matchingTask = nil
        }
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
      connected.contains { $0.id == device.id && $0.transportID == device.transportID }
    }.map(resolveName)
    let changedPreview = connected != connectedDevices
    let changedReady = ready != latestDevices
    connectedDevices = connected
    latestDevices = ready
    for observer in observers.values {
      if observer.preview, trackedDevices != nil, changedPreview || connected.isEmpty {
        observer.continuation.yield(connected)
      } else if !observer.preview, readyDevices != nil, changedReady || ready.isEmpty {
        observer.continuation.yield(ready)
      }
    }
  }

  private func resolveName(_ device: Device) -> Device {
    guard device.id.hasPrefix("emulator-") else { return device }
    let connection = inventoryConnections.first { $0.serial == device.id && $0.transportID == device.transportID }
    let emulator = emulators.first { $0.avdName.replacingOccurrences(of: "_", with: " ") == device.avdName }
      ?? emulators.first { connection != nil && $0.serial == device.id }
    // Keep a resolved name through temporary console failures, but never across transports.
    let previous = connectedDevices.first { $0.id == device.id && $0.transportID == device.transportID }
    return Device(
      id: device.id, model: device.model, androidVersion: device.androidVersion,
      vendorModel: device.vendorModel, manufacturer: device.manufacturer, avdName: device.avdName,
      displayName: emulator?.title ?? previous?.displayName, transportID: device.transportID
    )
  }

  private func observeEmulators() async {
    while !Task.isCancelled {
      await refresh()
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
    }
  }

  func refresh() async {
    guard !isRefreshing, actions.isEmpty else { return }
    let generation = inventoryGeneration
    isRefreshing = true
    defer { isRefreshing = false }
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
    guard actions[device.id] == nil else { return }
    inventoryGeneration += 1
    matchingTask?.cancel()
    trackedConnections = []
    actions[device.id] = "Starting"
    actionTasks[device.id] = Task { [weak self] in
      guard let self else { return }
      defer {
        actions.removeValue(forKey: device.id)
        actionTasks.removeValue(forKey: device.id)
        matchEmulators(in: trackedDevices ?? [])
      }
      do {
        let connections = try await emulatorConnections()
        let inventory = try await client.start(device.id, coldBoot: coldBoot, serials: connections.map(\.serial))
        // A cold boot invalidates the old transport and its boot-completion result.
        applyAction(inventory, id: device.id)
      } catch is CancellationError {
        return
      } catch {
        actionError = error.localizedDescription
      }
    }
  }

  func stop(_ device: ManagedEmulator) {
    guard actions[device.id] == nil, let serial = device.serial else { return }
    inventoryGeneration += 1
    matchingTask?.cancel()
    trackedConnections = []
    actions[device.id] = "Stopping"
    actionTasks[device.id] = Task { [weak self] in
      guard let self else { return }
      defer {
        actions.removeValue(forKey: device.id)
        actionTasks.removeValue(forKey: device.id)
        matchEmulators(in: trackedDevices ?? [])
      }
      do {
        let inventory = try await client.stop(device.id, serial: serial)
        applyAction(inventory, id: device.id)
      } catch is CancellationError {
        return
      } catch {
        actionError = error.localizedDescription
      }
    }
  }

  func shutdown() {
    inventoryGeneration += 1
    matchingTask?.cancel()
    matchingTask = nil
    matchingSerials = []
    observationTask?.cancel()
    observationTask = nil
    for observer in observers.values {
      observer.continuation.finish()
    }
    observers.removeAll()
    for task in actionTasks.values {
      task.cancel()
    }
    actionTasks.removeAll()
    client.close()
  }

  private func apply(_ inventory: EmulatorInventory, connections: [EmulatorConnection]) {
    inventoryConnections = connections
    emulators = EmulatorConnection.applying(connections, to: inventory)
    publishDevices()
  }

  private func applyAction(_ inventory: EmulatorInventory, id: String) {
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
    let exec = await adb.exec()
    do {
      return try await exec.emulatorConnections(checkBoot: checkBoot)
    } catch ADBError.serverUnavailable {
      try Task.checkCancellation()
      try await client.startADBServer()
      return try await exec.emulatorConnections(checkBoot: checkBoot)
    }
  }
}
