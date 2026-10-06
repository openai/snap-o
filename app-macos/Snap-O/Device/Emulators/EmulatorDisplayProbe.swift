import Foundation

/// One host request borrows display readings from one fixed device connection.
@MainActor
final class EmulatorDisplayProbe: NSObject, EmulatorDisplayProvider {
  private let target: DeviceTarget
  private let read: @Sendable (DeviceTarget) async throws -> String
  private var active = true
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var invalidationHandler: UUID?

  init(target: DeviceTarget, read: @escaping @Sendable (DeviceTarget) async throws -> String) throws {
    self.target = target
    self.read = read
    super.init()
    invalidationHandler = try target.onInvalidation { [weak self] in
      Task { @MainActor in self?.cancel() }
    }
  }

  nonisolated func readDisplay(reply: @escaping @Sendable (String?, String?) -> Void) {
    Task { @MainActor in beginRead(reply: reply) }
  }

  private func beginRead(reply: @escaping @Sendable (String?, String?) -> Void) {
    guard active, target.isValid else {
      reply(nil, "The device connection is no longer available.")
      return
    }
    let id = UUID()
    tasks[id] = Task {
      defer { tasks[id] = nil }
      do {
        let value = try await read(target)
        try Task.checkCancellation()
        guard active, target.isValid else { throw CancellationError() }
        reply(value, nil)
      } catch {
        reply(nil, error.localizedDescription)
      }
    }
  }

  func cancel() {
    active = false
    for task in tasks.values { task.cancel() }
  }

  func shutdown() async {
    cancel()
    if let invalidationHandler {
      target.removeInvalidationHandler(invalidationHandler)
      self.invalidationHandler = nil
    }
    let pending = Array(tasks.values)
    for task in pending { await task.value }
  }
}
