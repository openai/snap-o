import Foundation
import Observation

/// Owns stream startup and cleanup independently of SwiftUI view updates.
@Observable
@MainActor
final class LivePreviewLifecycle<Renderer> {
  enum Phase { case idle, waitingForCleanup, waitingToReconnect, starting, streaming }

  let connection: LivePreviewConnection?
  private(set) var renderer: Renderer?
  private(set) var phase = Phase.idle
  var isConnecting: Bool {
    phase != .idle
  }

  private(set) var isWindowVisible = false

  @ObservationIgnored private let start: @MainActor () async -> Renderer?
  @ObservationIgnored private let stop: @MainActor (Renderer) async -> Void
  @ObservationIgnored private let waitUntilStop: @MainActor (Renderer) async -> Error?
  @ObservationIgnored private let canReconnect: @MainActor () -> Bool
  @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
  @ObservationIgnored private let waitBeforeReconnect: @MainActor (Duration) async throws -> Void
  @ObservationIgnored private var streamTask: Task<Void, Never>?
  private var lifecycleID: UUID?
  private var isViewVisible = false
  private var shouldRecoverDisplayChange = false

  init(
    connection: LivePreviewConnection?,
    start: @escaping @MainActor () async -> Renderer?,
    stop: @escaping @MainActor (Renderer) async -> Void,
    waitUntilStop: @escaping @MainActor (Renderer) async -> Error?,
    canReconnect: @escaping @MainActor () -> Bool,
    waitBeforeReconnect: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
  ) {
    self.connection = connection
    self.start = start
    self.stop = stop
    self.waitUntilStop = waitUntilStop
    self.canReconnect = canReconnect
    self.now = now
    self.waitBeforeReconnect = waitBeforeReconnect
  }

  func appear() {
    isViewVisible = true
    startIfNeeded()
  }

  func updateWindowVisibility(_ visible: Bool) {
    isWindowVisible = visible
    startIfNeeded()
  }

  func connect() {
    guard streamTask == nil, let connection else { return }
    connection.hasFailed = false
    startIfNeeded()
  }

  func restart() {
    guard isViewVisible else { return }
    disappear()
    shouldRecoverDisplayChange = true
    connection?.hasFailed = false
    appear()
  }

  func disappear() {
    isViewVisible = false
    shouldRecoverDisplayChange = false
    lifecycleID = nil
    let taskToStop = streamTask
    taskToStop?.cancel()
    streamTask = nil
    phase = .idle
    let rendererToStop = renderer
    renderer = nil
    guard let connection, taskToStop != nil || rendererToStop != nil else { return }

    let previousCleanup = connection.cleanupTask
    connection.cleanupTask = Task {
      await previousCleanup?.value
      if let rendererToStop { await stop(rendererToStop) }
      // Startup may return an operation after the view has gone away.
      await taskToStop?.value
    }
  }

  private func startIfNeeded() {
    guard isViewVisible, isWindowVisible, streamTask == nil,
          let connection, !connection.hasFailed else { return }
    let id = UUID()
    let previousCleanup = connection.cleanupTask
    let recoveringDisplayChange = shouldRecoverDisplayChange
    shouldRecoverDisplayChange = false
    lifecycleID = id
    phase = .starting
    streamTask = Task(priority: .userInitiated) {
      defer {
        if lifecycleID == id {
          lifecycleID = nil
          streamTask = nil
          phase = .idle
        }
      }
      if let previousCleanup {
        phase = .waitingForCleanup
        await previousCleanup.value
      }
      guard isActive(id) else { return }
      let delays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(3)]
      var isRecovering = recoveringDisplayChange
      var retryIndex = 0
      while isActive(id) {
        if isRecovering {
          guard canReconnect() else {
            connection.hasFailed = true
            return
          }
          phase = .waitingToReconnect
          do { try await waitBeforeReconnect(delays[retryIndex]) } catch { return }
          retryIndex += 1
          guard isActive(id) else { return }
          guard canReconnect() else {
            connection.hasFailed = true
            return
          }
        }
        phase = .starting
        connection.cleanupTask = nil
        let newRenderer = await start()
        guard isActive(id) else {
          if let newRenderer { await stop(newRenderer) }
          return
        }
        var streamError: Error?
        if let newRenderer {
          renderer = newRenderer
          phase = .streaming
          let streamStarted = now()
          streamError = await waitUntilStop(newRenderer)
          guard isActive(id) else { return }
          renderer = nil
          // A later disconnect gets a fresh budget after a stable stream, not after every retry.
          if streamStarted.duration(to: now()) >= .seconds(10) {
            retryIndex = 0
          }
          isRecovering = true
        }
        let retry = isRecovering && canReconnect() && retryIndex < delays.count
        connection.hasFailed = !retry
        if let newRenderer {
          let cleanup = Task { await stop(newRenderer) }
          connection.cleanupTask = cleanup
          await cleanup.value
          guard isActive(id) else { return }
        }
        guard retry else {
          if let streamError {
            SnapOLog.ui.error("Live preview stopped: \(streamError.localizedDescription, privacy: .public)")
          }
          return
        }
      }
    }
  }

  private func isActive(_ id: UUID) -> Bool {
    !Task.isCancelled && lifecycleID == id
  }
}
