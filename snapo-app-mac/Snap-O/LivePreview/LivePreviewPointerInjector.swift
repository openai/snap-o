import Foundation

/// Serializes pointer events, selects a backend, and keeps each gesture on one backend.
actor LivePreviewPointerInjector {
  private typealias PreferredBackendFactory = @Sendable (String) async throws -> any LivePreviewPointerBackend

  private enum DeviceState {
    case preparing(generation: UUID, task: Task<Void, Never>)
    case ready(generation: UUID, backend: any LivePreviewPointerBackend)
    case fallback(generation: UUID)

    var generation: UUID {
      switch self {
      case .preparing(let generation, _),
           .ready(let generation, _),
           .fallback(let generation):
        generation
      }
    }
  }

  private enum TouchRoute {
    case preferred(generation: UUID, backend: any LivePreviewPointerBackend)
    case fallback(generation: UUID)
    case discarded(generation: UUID)

    var generation: UUID {
      switch self {
      case .preferred(let generation, _),
           .fallback(let generation),
           .discarded(let generation):
        generation
      }
    }
  }

  private let makePreferredBackend: PreferredBackendFactory
  private let fallbackBackend: any LivePreviewPointerBackend
  private var deviceStates: [String: DeviceState] = [:]
  private var touchRoutes: [String: TouchRoute] = [:]
  private var pendingEvents: [LivePreviewPointerEvent] = []
  private var isFlushing = false

  init(adb: ADBService) {
    makePreferredBackend = { deviceID in
      try await UInputLivePreviewPointerBackend.start(
        adb: adb,
        deviceID: deviceID
      )
    }
    fallbackBackend = ShellLivePreviewPointerBackend(adb: adb)
  }

  func prepare(deviceID: String) {
    guard deviceStates[deviceID] == nil else { return }

    let generation = UUID()
    let makePreferredBackend = makePreferredBackend
    let task = Task { [weak self] in
      do {
        let backend = try await makePreferredBackend(deviceID)
        guard let self else {
          await backend.stop()
          return
        }
        await self.finishPreparation(
          backend,
          deviceID: deviceID,
          generation: generation
        )
      } catch {
        await self?.failPreparation(
          error,
          deviceID: deviceID,
          generation: generation
        )
      }
    }
    deviceStates[deviceID] = .preparing(generation: generation, task: task)
  }

  func enqueue(_ event: LivePreviewPointerEvent) async {
    if event.action == .move,
       let index = pendingEvents.lastIndex(where: {
         $0.deviceID == event.deviceID && $0.source == event.source
       }),
       pendingEvents[index].action == .move {
      pendingEvents[index] = event
    } else {
      pendingEvents.append(event)
    }

    guard !isFlushing else { return }
    isFlushing = true
    Task { await flushQueue() }
  }

  func stopDevice(_ deviceID: String) async {
    pendingEvents.removeAll { $0.deviceID == deviceID }
    touchRoutes.removeValue(forKey: deviceID)
    guard let state = deviceStates.removeValue(forKey: deviceID) else { return }
    await stop(state)
  }

  func stopAll() async {
    pendingEvents.removeAll()
    touchRoutes.removeAll()
    let states = Array(deviceStates.values)
    deviceStates.removeAll()
    for state in states {
      await stop(state)
    }
    await fallbackBackend.stop()
  }

  private func finishPreparation(
    _ backend: any LivePreviewPointerBackend,
    deviceID: String,
    generation: UUID
  ) async {
    guard case .preparing(let currentGeneration, _) = deviceStates[deviceID],
          currentGeneration == generation else {
      await backend.stop()
      return
    }
    deviceStates[deviceID] = .ready(generation: generation, backend: backend)
  }

  private func failPreparation(
    _ error: Error,
    deviceID: String,
    generation: UUID
  ) {
    guard case .preparing(let currentGeneration, _) = deviceStates[deviceID],
          currentGeneration == generation else { return }
    deviceStates[deviceID] = .fallback(generation: generation)
    SnapOLog.ui.info(
      "uinput unavailable for \(deviceID, privacy: .private); using shell input: \(error.localizedDescription, privacy: .public)"
    )
  }

  private func stop(_ state: DeviceState) async {
    switch state {
    case .preparing(_, let task):
      task.cancel()
    case .ready(_, let backend):
      await backend.stop()
    case .fallback:
      break
    }
  }

  private func flushQueue() async {
    while !pendingEvents.isEmpty {
      let event = pendingEvents.removeFirst()
      do {
        try await send(event)
      } catch is CancellationError {
        // Teardown can cancel an in-flight backend operation.
      } catch {
        SnapOLog.ui.error(
          "Failed to send pointer event: \(error.localizedDescription, privacy: .public)"
        )
      }
    }

    isFlushing = false

    if !pendingEvents.isEmpty {
      isFlushing = true
      await flushQueue()
    }
  }

  private func send(_ event: LivePreviewPointerEvent) async throws {
    if event.source == .mouse {
      try await fallbackBackend.send(event)
      return
    }

    switch event.action {
    case .down:
      try await sendTouchDown(event)
    case .move:
      try await sendTouchMove(event)
    case .up, .cancel:
      try await sendTouchEnd(event)
    }
  }

  private func sendTouchDown(_ event: LivePreviewPointerEvent) async throws {
    guard touchRoutes[event.deviceID] == nil else { return }
    if deviceStates[event.deviceID] == nil {
      prepare(deviceID: event.deviceID)
    }
    guard let state = deviceStates[event.deviceID] else { return }

    switch state {
    case .ready(let generation, let backend):
      do {
        try await backend.send(event)
      } catch {
        let isCurrent = deviceStates[event.deviceID]?.generation == generation
        if isCurrent {
          deviceStates[event.deviceID] = .fallback(generation: generation)
          touchRoutes[event.deviceID] = .discarded(generation: generation)
        }
        await backend.stop()
        if isCurrent { throw error }
        return
      }

      guard deviceStates[event.deviceID]?.generation == generation,
            touchRoutes[event.deviceID] == nil else { return }
      touchRoutes[event.deviceID] = .preferred(
        generation: generation,
        backend: backend
      )

    case .preparing(let generation, _), .fallback(let generation):
      try await fallbackBackend.send(event)
      guard deviceStates[event.deviceID]?.generation == generation,
            touchRoutes[event.deviceID] == nil else { return }
      touchRoutes[event.deviceID] = .fallback(generation: generation)
    }
  }

  private func sendTouchMove(_ event: LivePreviewPointerEvent) async throws {
    switch touchRoutes[event.deviceID] {
    case .preferred(let generation, let backend):
      do {
        try await backend.send(event)
      } catch {
        let isCurrent = deviceStates[event.deviceID]?.generation == generation &&
          touchRoutes[event.deviceID]?.generation == generation
        if isCurrent {
          deviceStates[event.deviceID] = .fallback(generation: generation)
          touchRoutes[event.deviceID] = .discarded(generation: generation)
        }
        await backend.stop()
        if isCurrent { throw error }
      }
    case .fallback:
      try await fallbackBackend.send(event)
    case .discarded, nil:
      break
    }
  }

  private func sendTouchEnd(_ event: LivePreviewPointerEvent) async throws {
    guard let route = touchRoutes[event.deviceID] else { return }
    defer {
      if touchRoutes[event.deviceID]?.generation == route.generation {
        touchRoutes.removeValue(forKey: event.deviceID)
      }
    }

    switch route {
    case .preferred(let generation, let backend):
      do {
        try await backend.send(event)
      } catch {
        let isCurrent = deviceStates[event.deviceID]?.generation == generation
        if isCurrent {
          deviceStates[event.deviceID] = .fallback(generation: generation)
        }
        await backend.stop()
        if isCurrent { throw error }
      }
    case .fallback:
      try await fallbackBackend.send(event)
    case .discarded:
      break
    }
  }
}
