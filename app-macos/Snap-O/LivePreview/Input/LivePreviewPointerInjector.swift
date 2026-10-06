import Dependencies
import Foundation

/// Keeps each connection's pointer work independent and joins it before releasing the connection.
actor LivePreviewPointerInjector {
  typealias PreferredBackendFactory = @Sendable (DeviceTarget) async throws -> any LivePreviewPointerBackend

  private struct Entry {
    let session: LivePreviewPointerSession
    let invalidationHandler: UUID
  }

  private struct Cleanup {
    let id = UUID()
    let task: Task<Void, Never>
  }

  private let makePreferredBackend: PreferredBackendFactory
  private let fallbackBackend: any LivePreviewPointerBackend
  private let clock: AnyClock<Duration>
  private var sessions: [DeviceTarget: Entry] = [:]
  private var cleanups: [DeviceTarget: Cleanup] = [:]
  private var shutdownTask: Task<Void, Never>?

  init(adb: ADBService) {
    self.init(
      makePreferredBackend: { target in
        try await UInputLivePreviewPointerBackend.start(adb: adb, target: target)
      },
      fallbackBackend: ShellLivePreviewPointerBackend(adb: adb)
    )
  }

  init(
    makePreferredBackend: @escaping PreferredBackendFactory,
    fallbackBackend: any LivePreviewPointerBackend
  ) {
    self.makePreferredBackend = makePreferredBackend
    self.fallbackBackend = fallbackBackend
    @Dependency(\.continuousClock)
    var clock
    self.clock = AnyClock(clock)
  }

  @discardableResult
  func prepare(target: DeviceTarget) async -> Task<Void, Never>? {
    await session(for: target)?.prepare()
  }

  func enqueue(_ event: LivePreviewPointerEvent) async {
    guard !Task.isCancelled else { return }
    await session(for: event.target)?.enqueue(event)
  }

  func releaseInput(for target: DeviceTarget) async {
    await sessions[target]?.session.releaseInput()
  }

  private func session(for target: DeviceTarget) async -> LivePreviewPointerSession? {
    guard shutdownTask == nil, target.isValid else { return nil }
    if let cleanup = cleanups[target] {
      await cleanup.task.value
      if cleanups[target]?.id == cleanup.id { cleanups.removeValue(forKey: target) }
    }
    guard shutdownTask == nil, target.isValid else { return nil }
    if let entry = sessions[target] { return entry.session }
    do {
      let handler = try target.onInvalidation { [weak self] in
        Task { await self?.stopDevice(target) }
      }
      let session = LivePreviewPointerSession(
        target: target, makeBackend: makePreferredBackend, fallback: fallbackBackend, clock: clock
      )
      sessions[target] = Entry(session: session, invalidationHandler: handler)
      return session
    } catch {
      return nil
    }
  }

  func stopDevice(_ target: DeviceTarget) async {
    if let cleanup = cleanups[target] { await cleanup.task.value
      return
    }
    guard let entry = sessions.removeValue(forKey: target) else { return }
    target.removeInvalidationHandler(entry.invalidationHandler)
    let cleanup = Cleanup(task: Task { await entry.session.stop() })
    cleanups[target] = cleanup
    await cleanup.task.value
    if cleanups[target]?.id == cleanup.id { cleanups.removeValue(forKey: target) }
  }

  func stopAll() async {
    if let shutdownTask { await shutdownTask.value
      return
    }
    let entries = sessions
    let pending = Array(cleanups.values)
    sessions.removeAll()
    for (target, entry) in entries {
      target.removeInvalidationHandler(entry.invalidationHandler)
    }
    let fallback = fallbackBackend
    let task = Task {
      await withTaskGroup(of: Void.self) { group in
        for entry in entries.values {
          group.addTask { await entry.session.stop() }
        }
        for cleanup in pending {
          group.addTask { await cleanup.task.value }
        }
      }
      await fallback.stop()
    }
    shutdownTask = task
    await task.value
    cleanups.removeAll()
  }
}

/// Owns one backend and two ordered queues; mouse movement never waits for touch pacing.
private actor LivePreviewPointerSession {
  private enum BackendState {
    case preparing(Task<Void, Never>)
    case ready(any LivePreviewPointerBackend)
    case fallback
  }

  private enum TouchRoute {
    case preferred(any LivePreviewPointerBackend)
    case fallback
    case discarded
  }

  private let target: DeviceTarget
  private let makeBackend: LivePreviewPointerInjector.PreferredBackendFactory
  private let fallback: any LivePreviewPointerBackend
  private let clock: AnyClock<Duration>
  private var state: BackendState?
  private var route: TouchRoute?
  private var nextTouchSend: AnyClock<Duration>.Instant?
  private var touchEvents: [LivePreviewPointerEvent] = []
  private var mouseEvents: [LivePreviewPointerEvent] = []
  private var touchTask: Task<Void, Never>?
  private var mouseTask: Task<Void, Never>?
  private var shutdownTask: Task<Void, Never>?
  private var inputRelease: Task<Void, Never>?
  private var lastTouch: LivePreviewPointerEvent?
  private var pressedMouse: LivePreviewPointerEvent?
  private var isStopping = false

  init(
    target: DeviceTarget, makeBackend: @escaping LivePreviewPointerInjector.PreferredBackendFactory,
    fallback: any LivePreviewPointerBackend, clock: AnyClock<Duration>
  ) {
    self.target = target
    self.makeBackend = makeBackend
    self.fallback = fallback
    self.clock = clock
  }

  @discardableResult
  func prepare() -> Task<Void, Never>? {
    guard !isStopping, target.isValid else { return nil }
    if case .preparing(let task) = state { return task }
    guard state == nil else { return nil }
    let task = Task { [makeBackend, target] in
      do {
        let backend = try await makeBackend(target)
        guard !isStopping, target.isValid else { await backend.stop()
          return
        }
        state = .ready(backend)
        SnapOLog.ui.info("Live Preview drag backend ready: uinput (\(target.serial, privacy: .private))")
      } catch {
        guard !isStopping, target.isValid else { return }
        state = .fallback
        SnapOLog.ui.info(
          "uinput unavailable for \(target.serial, privacy: .private); using shell input: \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    state = .preparing(task)
    return task
  }

  func enqueue(_ event: LivePreviewPointerEvent) {
    guard !Task.isCancelled, !isStopping, inputRelease == nil, target.isValid else { return }
    if event.source == .mouse {
      if event.action == .move, let last = mouseEvents.indices.last, mouseEvents[last].action == .move {
        mouseEvents[last] = event
      } else {
        mouseEvents.append(event)
      }
      if mouseTask == nil { mouseTask = Task { await flushMouse() } }
    } else {
      if event.action == .down { mouseEvents.removeAll() }
      if event.action == .move, let last = touchEvents.indices.last,
         touchEvents[last].action == .move, touchEvents[last].locations.count == event.locations.count {
        touchEvents[last] = event
      } else {
        touchEvents.append(event)
      }
      if touchTask == nil { touchTask = Task { await flushTouch() } }
    }
  }

  func releaseInput() async {
    if let inputRelease { await inputRelease.value
      return
    }
    guard !isStopping else { await shutdownTask?.value
      return
    }
    let pending = [touchTask, mouseTask].compactMap(\.self)
    for task in pending {
      task.cancel()
    }
    touchEvents.removeAll()
    mouseEvents.removeAll()
    let release = Task {
      for task in pending {
        await task.value
      }
      guard !isStopping, target.isValid else { return }
      if let lastTouch { try? await sendTouch(cancel(lastTouch)) }
      if let pressedMouse { try? await fallback.send(cancel(pressedMouse)) }
      route = nil
      lastTouch = nil
      pressedMouse = nil
      nextTouchSend = nil
    }
    inputRelease = release
    await release.value
    inputRelease = nil
  }

  private func cancel(_ event: LivePreviewPointerEvent) -> LivePreviewPointerEvent {
    LivePreviewPointerEvent(
      target: event.target, action: .cancel, source: event.source,
      locations: event.locations, displaySize: event.displaySize
    )
  }

  func stop() async {
    if let shutdownTask { await shutdownTask.value
      return
    }
    isStopping = true
    let preparation: Task<Void, Never>?
    let backend: (any LivePreviewPointerBackend)?
    switch state {
    case .preparing(let task): (preparation, backend) = (task, nil)
    case .ready(let ready): (preparation, backend) = (nil, ready)
    case .fallback, nil: (preparation, backend) = (nil, nil)
    }
    let pending = [preparation, touchTask, mouseTask, inputRelease].compactMap(\.self)
    for task in pending {
      task.cancel()
    }
    touchEvents.removeAll()
    mouseEvents.removeAll()
    route = nil
    lastTouch = nil
    pressedMouse = nil
    state = nil
    let task = Task {
      await backend?.stop()
      for work in pending {
        await work.value
      }
    }
    shutdownTask = task
    await task.value
  }

  private func flushTouch() async {
    defer { touchTask = nil }
    while !Task.isCancelled, !isStopping, let pending = touchEvents.first {
      if pending.action == .move, let deadline = nextTouchSend, clock.now < deadline {
        do { try await clock.sleep(until: deadline) } catch { return }
        continue
      }
      let event = touchEvents.removeFirst()
      nextTouchSend = clock.now.advanced(by: minimumMoveInterval)
      do { try await sendTouch(event) } catch is CancellationError {} catch {
        SnapOLog.ui.error("Failed to send pointer event: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private var minimumMoveInterval: Duration {
    switch route {
    case .preferred(let backend): return backend.minimumMoveInterval
    case .fallback, .discarded: return fallback.minimumMoveInterval
    case nil:
      if case .ready(let backend) = state { return backend.minimumMoveInterval }
      return fallback.minimumMoveInterval
    }
  }

  private func flushMouse() async {
    defer { mouseTask = nil }
    while !Task.isCancelled, !isStopping, !mouseEvents.isEmpty {
      let event = mouseEvents.removeFirst()
      do {
        guard target.isValid else { return }
        if event.action == .down || pressedMouse != nil { pressedMouse = event }
        try await fallback.send(event)
        if event.action == .up || event.action == .cancel { pressedMouse = nil }
      } catch is CancellationError {} catch {
        SnapOLog.ui.error("Failed to send pointer event: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private func sendTouch(_ event: LivePreviewPointerEvent) async throws {
    guard target.isValid, !isStopping else { return }
    lastTouch = event
    if event.action == .down {
      try await sendDown(event)
      return
    }
    guard let route else { return }
    let endsGesture = event.action == .up || event.action == .cancel
    defer {
      if endsGesture {
        self.route = nil
        lastTouch = nil
      }
    }
    switch route {
    case .preferred(let backend):
      do { try await backend.send(event) } catch {
        guard !isStopping else { return }
        state = .fallback
        if !endsGesture { self.route = .discarded }
        await backend.stop()
        throw error
      }
    case .fallback: try await fallback.send(event)
    case .discarded: break
    }
  }

  private func sendDown(_ event: LivePreviewPointerEvent) async throws {
    guard route == nil else { return }
    if state == nil { prepare() }
    if event.locations.count > 1, case .preparing(let task) = state { await task.value }
    guard !Task.isCancelled, !isStopping, target.isValid, let state else { return }
    switch state {
    case .ready(let backend):
      do { try await backend.send(event) } catch {
        guard !isStopping else { return }
        self.state = .fallback
        route = .discarded
        await backend.stop()
        throw error
      }
      guard !isStopping else { return }
      route = .preferred(backend)
    case .preparing, .fallback:
      guard event.locations.count == 1 else { route = .discarded
        return
      }
      // Keep the route even when the reply fails: Android may have received Down.
      route = .fallback
      try await fallback.send(event)
    }
  }
}
