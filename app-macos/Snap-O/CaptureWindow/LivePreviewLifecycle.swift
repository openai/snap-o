import Foundation
import Observation

/// Owns stream startup and cleanup independently of SwiftUI view updates.
@Observable
@MainActor
final class LivePreviewLifecycle<Renderer> {
  enum Phase { case idle, waitingForCleanup, starting, streaming }

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
  @ObservationIgnored private var streamTask: Task<Void, Never>?
  private var lifecycleID: UUID?
  private var isViewVisible = false

  init(
    connection: LivePreviewConnection?,
    start: @escaping @MainActor () async -> Renderer?,
    stop: @escaping @MainActor (Renderer) async -> Void,
    waitUntilStop: @escaping @MainActor (Renderer) async -> Error?
  ) {
    self.connection = connection
    self.start = start
    self.stop = stop
    self.waitUntilStop = waitUntilStop
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

  func disappear() {
    isViewVisible = false
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
      phase = .starting
      connection.cleanupTask = nil
      let newRenderer = await start()
      guard isActive(id) else {
        if let newRenderer { await stop(newRenderer) }
        return
      }
      guard let newRenderer else {
        connection.hasFailed = true
        return
      }
      renderer = newRenderer
      phase = .streaming
      let error = await waitUntilStop(newRenderer)
      guard isActive(id) else { return }
      connection.hasFailed = true
      renderer = nil
      let cleanup = Task { await stop(newRenderer) }
      connection.cleanupTask = cleanup
      await cleanup.value
      guard isActive(id) else { return }
      if let error {
        SnapOLog.ui.error("Live preview stopped: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private func isActive(_ id: UUID) -> Bool {
    !Task.isCancelled && lifecycleID == id
  }
}
