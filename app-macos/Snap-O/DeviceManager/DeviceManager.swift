import Foundation
import Observation

@Observable
@MainActor
final class DeviceManager {
  private(set) var emulators: [ManagedEmulator] = []
  private(set) var connectedDevices: [Device] = []
  private(set) var isRefreshing = false
  private(set) var hasLoaded = false
  private(set) var loadError: String?
  private(set) var actions: [String: String] = [:]
  var actionError: String?
  @ObservationIgnored var selectPreview: ((String) -> LivePreviewRequest?)?

  var entries: [DeviceManagerEntry] {
    DeviceManagerEntry.list(emulators: emulators, connectedDevices: connectedDevices)
  }

  @ObservationIgnored private let deviceTracker: DeviceTracker
  @ObservationIgnored private let adb: ADBService
  @ObservationIgnored private let client = EmulatorClient()
  @ObservationIgnored private var actionTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var previewTask: Task<Void, Never>?
  private var previewAVD: String?
  private var inventoryGeneration = 0

  init(adb: ADBService, deviceTracker: DeviceTracker) {
    self.adb = adb
    self.deviceTracker = deviceTracker
  }

  func startupStatus(for device: ManagedEmulator) -> String? {
    if let action = actions[device.id] { return action }
    switch device.state {
    case .starting: return device.serial == nil ? "Connecting" : "Booting"
    case .offline: return "Connecting"
    case .running: return previewAVD == device.id ? "Starting preview" : nil
    case .stopping: return device.state.title
    case .stopped, .unavailable: return nil
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
    actions[device.id] = "Deleting"
    actionTasks[device.id] = Task { [weak self] in
      guard let self else { return }
      defer {
        actions.removeValue(forKey: device.id)
        actionTasks.removeValue(forKey: device.id)
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

  func observe() async {
    async let connections: Void = observeConnections()
    await observeEmulators()
    await connections
  }

  private func observeConnections() async {
    let stream = await deviceTracker.deviceStream()
    for await devices in stream {
      guard !Task.isCancelled else { return }
      connectedDevices = devices
    }
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
      let connections = try await emulatorConnections()
      let inventory = try await client.snapshot(serials: connections.map(\.serial))
      guard generation == inventoryGeneration else { return }
      apply(inventory, connections: connections)
      loadError = nil
      hasLoaded = true
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
    previewTask?.cancel()
    previewAVD = device.id
    inventoryGeneration += 1
    actions[device.id] = "Starting"
    actionTasks[device.id] = Task { [weak self] in
      guard let self else { return }
      defer {
        actions.removeValue(forKey: device.id)
        actionTasks.removeValue(forKey: device.id)
      }
      do {
        let connections = try await emulatorConnections()
        let inventory = try await client.start(device.id, coldBoot: coldBoot, serials: connections.map(\.serial))
        // A cold boot invalidates the old transport and its boot-completion result.
        applyAction(inventory, id: device.id)
        if previewAVD == device.id { waitForPreview(device.id) }
      } catch is CancellationError {
        return
      } catch {
        if previewAVD == device.id { previewAVD = nil }
        actionError = error.localizedDescription
      }
    }
  }

  func stop(_ device: ManagedEmulator) {
    guard actions[device.id] == nil, let serial = device.serial else { return }
    inventoryGeneration += 1
    if previewAVD == device.id {
      previewTask?.cancel()
      previewAVD = nil
    }
    actions[device.id] = "Stopping"
    actionTasks[device.id] = Task { [weak self] in
      guard let self else { return }
      defer {
        actions.removeValue(forKey: device.id)
        actionTasks.removeValue(forKey: device.id)
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
    previewTask?.cancel()
    previewTask = nil
    previewAVD = nil
    for task in actionTasks.values {
      task.cancel()
    }
    actionTasks.removeAll()
    client.close()
  }

  private func apply(_ inventory: EmulatorInventory, connections: [EmulatorConnection]) {
    emulators = EmulatorConnection.applying(connections, to: inventory)
  }

  private func applyAction(_ inventory: EmulatorInventory, id: String) {
    // Action replies describe the changed AVD; preserve other devices until the next native refresh.
    emulators = inventory.devices.map { device in
      device.id == id ? device : emulators.first { $0.id == device.id } ?? device
    }
  }

  private func emulatorConnections() async throws -> [EmulatorConnection] {
    let exec = await adb.exec()
    do {
      return try await exec.emulatorConnections()
    } catch ADBError.serverUnavailable {
      try Task.checkCancellation()
      try await client.startADBServer()
      return try await exec.emulatorConnections()
    }
  }

  private func waitForPreview(_ id: String) {
    previewTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if !Task.isCancelled, previewAVD == id { previewAVD = nil }
      }
      let deadline = Date().addingTimeInterval(180)
      while !Task.isCancelled, Date() < deadline {
        await refresh()
        guard !Task.isCancelled else { return }
        if let device = emulators.first(where: { $0.id == id }) {
          if device.state == .running, let serial = device.serial,
             connectedDevices.contains(where: { $0.id == serial }) {
            if let request = selectPreview?(serial) {
              do {
                try await request.waitForFrame()
              } catch is CancellationError {
                return
              } catch {
                actionError = error.localizedDescription
              }
            }
            return
          }
          if device.state == .stopped, let detail = device.detail {
            actionError = detail
            return
          }
        }
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
      }
      if !Task.isCancelled { actionError = "The emulator has not finished booting. You can open Live Preview once it is running." }
    }
  }
}
