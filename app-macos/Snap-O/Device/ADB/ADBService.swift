import Foundation

struct ADBServerSnapshot {
  let id: ADBServerID
  var state: ADBServerState = .connecting
  var inventory = DeviceInventory()
}

/// Owns discovery for all servers. Device operations remain bound to their targets.
actor ADBService: DeviceTracking {
  private var trackers: [(ADBServerID, any DeviceTracking)]
  private var servers: [ADBServerID: ADBServerSnapshot]
  private var tasks: [ADBServerID: Task<Void, Never>] = [:]
  private var generations: [ADBServerID: UUID] = [:]
  private var revisions: [ADBServerID: UUID] = [:]
  private var retiring: [UUID: Task<Void, Never>] = [:]
  private var hasStarted = false
  private var shutdownTask: Task<Void, Never>?
  private var observers: [UUID: AsyncStream<[ADBServerSnapshot]>.Continuation] = [:]

  init(trackers: [(ADBServerID, any DeviceTracking)] = []) {
    self.trackers = trackers
    servers = Dictionary(uniqueKeysWithValues: trackers.map { ($0.0, ADBServerSnapshot(id: $0.0)) })
  }

  /// Unbound clients are only for local discovery; bound clients use their target's server.
  func exec() -> ADBClient {
    ADBClient()
  }

  func startTracking() {
    guard !hasStarted, shutdownTask == nil else { return }
    hasStarted = true
    for (id, tracker) in trackers {
      start(id, tracker: tracker)
    }
  }

  private func start(_ id: ADBServerID, tracker: any DeviceTracking) {
    let generation = UUID()
    generations[id] = generation
    tasks[id] = Task {
      await tracker.startTracking()
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          for await devices in await tracker.previewDeviceStream() {
            await self.update(id, generation: generation, connected: devices)
          }
        }
        group.addTask {
          for await devices in await tracker.deviceStream() {
            await self.update(id, generation: generation, ready: devices)
          }
        }
        group.addTask {
          for await state in await tracker.serverStateStream() {
            await self.update(id, generation: generation, state: state)
          }
        }
      }
    }
  }

  /// Join the old owner before reusing a profile ID. Other servers keep their sessions.
  func replaceRemote(_ id: ADBServerID, tracker: (any DeviceTracking)?) async throws {
    guard case .remote = id, shutdownTask == nil else { throw CancellationError() }
    let revision = UUID()
    revisions[id] = revision
    let old = trackers.first { $0.0 == id }?.1
    trackers.removeAll { $0.0 == id }
    generations[id] = nil
    servers[id] = nil
    let observer = tasks.removeValue(forKey: id)
    observer?.cancel()
    publish()
    if let old {
      let retirementID = UUID()
      let cleanup = Task {
        await old.stopTracking()
        await observer?.value
      }
      retiring[retirementID] = cleanup
      await cleanup.value
      retiring[retirementID] = nil
    }
    guard shutdownTask == nil, !Task.isCancelled, revisions[id] == revision else { throw CancellationError() }
    if let tracker {
      trackers.append((id, tracker))
      servers[id] = ADBServerSnapshot(id: id)
      if hasStarted { start(id, tracker: tracker) }
      publish()
    }
  }

  func snapshots() -> AsyncStream<[ADBServerSnapshot]> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<[ADBServerSnapshot]>.makeStream(bufferingPolicy: .bufferingNewest(1))
    guard shutdownTask == nil else {
      continuation.finish()
      return stream
    }
    observers[id] = continuation
    continuation.yield(snapshot)
    continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
    return stream
  }

  private var snapshot: [ADBServerSnapshot] {
    trackers.compactMap { servers[$0.0] }
  }

  private func update(_ id: ADBServerID, generation: UUID, connected: [Device]) {
    guard shutdownTask == nil, generations[id] == generation else { return }
    servers[id]?.inventory.connected = connected
    publish()
  }

  private func update(_ id: ADBServerID, generation: UUID, ready: [Device]) {
    guard shutdownTask == nil, generations[id] == generation else { return }
    servers[id]?.inventory.ready = ready
    publish()
  }

  private func update(_ id: ADBServerID, generation: UUID, state: ADBServerState) {
    guard shutdownTask == nil, generations[id] == generation else { return }
    servers[id]?.state = state
    publish()
  }

  private func publish() {
    let value = snapshot
    for observer in observers.values {
      observer.yield(value)
    }
  }

  private func removeObserver(_ id: UUID) {
    observers[id] = nil
  }

  func previewDeviceStream() -> AsyncStream<[Device]> {
    mapSnapshots { servers in
      guard servers.contains(where: { $0.inventory.connected != nil }) else { return nil }
      return servers.flatMap { $0.inventory.connected ?? [] }
    }
  }

  func deviceStream() -> AsyncStream<[Device]> {
    mapSnapshots { servers in
      guard servers.contains(where: { $0.inventory.ready != nil }) else { return nil }
      return servers.flatMap { server in
        (server.inventory.ready ?? []).filter { device in
          server.inventory.connected?.contains { $0.connection == device.connection } == true
        }
      }
    }
  }

  /// Existing local recovery controls describe only the built-in local server.
  func serverStateStream() -> AsyncStream<ADBServerState> {
    mapSnapshots { $0.first { $0.id == .local }?.state }
  }

  private func mapSnapshots<Value: Sendable & Equatable>(
    _ transform: @escaping @Sendable ([ADBServerSnapshot]) -> Value?
  ) -> AsyncStream<Value> {
    let source = snapshots()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task {
        var previous: Value?
        for await snapshot in source {
          if let value = transform(snapshot), value != previous {
            previous = value
            continuation.yield(value)
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func retryADBServer() async {
    await trackers.first { $0.0 == .local }?.1.retryADBServer()
  }

  func stopTracking() async {
    if let shutdownTask { await shutdownTask.value
      return
    }
    let pending = Array(tasks.values)
    let closing = Array(retiring.values)
    for task in pending {
      task.cancel()
    }
    for observer in observers.values {
      observer.finish()
    }
    observers.removeAll()
    let task = Task {
      await withTaskGroup(of: Void.self) { group in
        for (_, tracker) in trackers {
          group.addTask { await tracker.stopTracking() }
        }
      }
      for task in pending + closing {
        await task.value
      }
    }
    shutdownTask = task
    await task.value
  }
}
