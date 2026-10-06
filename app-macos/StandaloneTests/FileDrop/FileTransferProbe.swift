import Foundation

actor FileTransferProbe {
  var exists = false
  var gate: TestGate?
  private(set) var targets: [DeviceTarget] = []
  private(set) var wasCancelled = false {
    didSet { testChanges.signal() }
  }
  private var progress: [@Sendable (Int64) -> Void] = []

  func configure(exists: Bool = false, gate: TestGate? = nil) {
    self.exists = exists
    self.gate = gate
  }

  func transfer(target: DeviceTarget, progress: @escaping @Sendable (Int64) -> Void) async throws {
    targets.append(target)
    self.progress.append(progress)
    await withTaskCancellationHandler {
      await gate?.wait()
    } onCancel: { Task { await self.recordCancellation() } }
    try Task.checkCancellation()
    _ = try target.requireTransport(for: target.serial)
  }

  private func recordCancellation() { wasCancelled = true }
  func report(_ sent: Int64, for index: Int) { progress[index](sent) }
}
