import Dependencies
import Foundation
import Observation

/// Owns emulator controls through view remounts and joins their work at preview teardown.
@Observable
@MainActor
final class EmulatorControlsController {
  struct Failure {
    let action: EmulatorControlAction
    let message: String
  }

  let target: DeviceTarget
  private(set) var controls: EmulatorControls?
  private(set) var pendingAction: EmulatorControlAction?
  private(set) var failure: Failure?
  @ObservationIgnored private let load: @MainActor (DeviceTarget) async throws -> EmulatorControls
  @ObservationIgnored private let apply: @MainActor (DeviceTarget, String, EmulatorControlAction) async throws -> Void
  @ObservationIgnored private let close: @MainActor () -> Void
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var cleanup: Task<Void, Never>?
  @ObservationIgnored private var shutdownTask: Task<Void, Never>?
  @ObservationIgnored private var invalidationHandler: UUID?
  @Dependency(\.continuousClock)
  @ObservationIgnored private var clock
  private var mountID: UUID?
  private var viewID: UUID?

  init(
    target: DeviceTarget,
    load: @escaping @MainActor (DeviceTarget) async throws -> EmulatorControls,
    apply: @escaping @MainActor (DeviceTarget, String, EmulatorControlAction) async throws -> Void,
    close: @escaping @MainActor () -> Void
  ) {
    self.target = target
    self.load = load
    self.apply = apply
    self.close = close
    invalidationHandler = try? target.onInvalidation { [weak self] in
      Task { @MainActor in self?.beginShutdown() }
    }
  }

  func appear(viewID: UUID) {
    guard shutdownTask == nil, target.isValid, self.viewID != viewID else { return }
    disappear()
    self.viewID = viewID
    let id = UUID()
    mountID = id
    let previous = cleanup
    task = Task {
      await previous?.value
      guard isActive(id) else { return }
      await loadControls(id: id)
      if isActive(id) { task = nil }
    }
  }

  func perform(_ action: EmulatorControlAction, didChangeDisplay: @escaping @MainActor () -> Void) {
    guard let id = mountID, isActive(id), task == nil, let controls else { return }
    pendingAction = action
    failure = nil
    task = Task {
      defer {
        if isActive(id) {
          pendingAction = nil
          task = nil
        }
      }
      do {
        try Task.checkCancellation()
        try await apply(target, controls.avdPath, action)
        guard isActive(id) else { return }
        didChangeDisplay()
        await loadControls(id: id)
      } catch {
        if isActive(id) { failure = Failure(action: action, message: error.localizedDescription) }
      }
    }
  }

  func dismissFailure() {
    failure = nil
  }

  func disappear(viewID: UUID? = nil) {
    guard mountID != nil, viewID == nil || self.viewID == viewID else { return }
    mountID = nil
    self.viewID = nil
    controls = nil
    pendingAction = nil
    failure = nil
    let pending = task
    pending?.cancel()
    task = nil
    let previous = cleanup
    cleanup = Task {
      await previous?.value
      await pending?.value
      // Keep XPC alive until the helper acknowledges cancellation.
      close()
    }
  }

  func waitForCleanup() async {
    await cleanup?.value
  }

  @discardableResult
  func beginShutdown() -> Task<Void, Never> {
    if let shutdownTask { return shutdownTask }
    if let invalidationHandler { target.removeInvalidationHandler(invalidationHandler) }
    invalidationHandler = nil
    disappear()
    let pending = cleanup
    let shutdown = Task<Void, Never> { await pending?.value }
    shutdownTask = shutdown
    return shutdown
  }

  func shutdown() async {
    await beginShutdown().value
  }

  private func loadControls(id: UUID) async {
    var delay = 1
    while isActive(id) {
      do {
        let result = try await load(target)
        guard isActive(id) else { return }
        controls = result
        return
      } catch {
        guard isActive(id) else { return }
        controls = nil
        // Preview may precede Android's window service.
        do { try await clock.sleep(for: .seconds(delay)) } catch { return }
        delay = min(delay * 2, 5)
      }
    }
  }

  private func isActive(_ id: UUID) -> Bool {
    !Task.isCancelled && shutdownTask == nil && target.isValid && mountID == id
  }
}
